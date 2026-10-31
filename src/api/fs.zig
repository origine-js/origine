//! `api.fs`: grants over a host directory and the typed natives behind them.
//!
//! A `FsGrant` owns directory/file handles; guest code holds JS DirRef/FileRef
//! instances with private state, and native functions bound
//! to that grant. Argument types below (`DirRef`, `Path`, ...) validate at the
//! binding boundary, so the ops only see checked values.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const binding = @import("binding.zig");
const init_cache = @import("init_cache.zig");
const func = binding.func;
const Call = binding.Call;
const sys = @import("../managed/sys.zig");
const host_mod = @import("host.zig");
const Host = host_mod.Host;
const ScopeState = host_mod.ScopeState;

/// Largest file `readAll` returns, regardless of the requested limit.
const max_read_bytes: usize = 256 << 20;
/// Largest integer a JS Number holds exactly (2^53 - 1).
const max_exact: u64 = 9007199254740991;

// ---- argument types ----------------------------------------------------------

/// A directory descriptor: two JS arguments, `(fs, id)`. `{0, 0}` is the cwd
/// sentinel and names the grant root.
pub const DirRef = struct {
    fs: u32,
    id: u32,

    pub const arity = 2;
    pub fn decode(call: *Call, index: usize) !DirRef {
        return .{ .fs = try binding.decode(u32, call, index), .id = try binding.decode(u32, call, index + 1) };
    }
};

/// A file descriptor: two JS arguments, `(fs, id)`.
pub const FileRef = struct {
    fs: u32,
    id: u32,

    pub const arity = 2;
    pub fn decode(call: *Call, index: usize) !FileRef {
        return .{ .fs = try binding.decode(u32, call, index), .id = try binding.decode(u32, call, index + 1) };
    }
};

/// Rejects NUL (`InvalidInput`: a malformed path) and, as policy denials (`PermissionDenied`, like
/// the OS's own), absolute paths, `..` components and the `__codecache__` directories
/// of a graph's code caches (V8 trusts them, so a guest must not be able to plant them).
/// Lexical only: symlinks inside the root are not resolved here, so following one can leave the
/// root (docs/api-design.md). The Rust twin is `clean` in rust/crates/origine_api_fs.
pub fn cleanPath(path: []const u8) !void {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidInput;
    if (path.len != 0 and path[0] == '/') return error.PermissionDenied;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, init_cache.dir_name)) return error.PermissionDenied;
    }
}

/// True when `path` names the grant root itself (empty or only `.` components).
fn namesRoot(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len != 0 and !std.mem.eql(u8, part, ".")) return false;
    return true;
}

/// A relative path inside the grant; may be empty (the directory itself).
pub const Path = struct {
    bytes: []const u8,

    pub fn decode(call: *Call, index: usize) !Path {
        const text = try binding.decode([]const u8, call, index);
        try cleanPath(text);
        return .{ .bytes = text };
    }
};

/// A path that must name an entry: non-empty after cleaning (`.` alone is allowed).
pub const EntryPath = struct {
    bytes: []const u8,

    pub fn decode(call: *Call, index: usize) !EntryPath {
        const text = try binding.decode([]const u8, call, index);
        try cleanPath(text);
        if (text.len == 0) return error.InvalidInput;
        return .{ .bytes = text };
    }
};

/// A path that must not name the grant root, for operations that could destroy it.
pub const SubPath = struct {
    bytes: []const u8,

    pub fn decode(call: *Call, index: usize) !SubPath {
        const text = try binding.decode([]const u8, call, index);
        try cleanPath(text);
        if (namesRoot(text)) return error.InvalidInput;
        return .{ .bytes = text };
    }
};

/// A byte limit with `std.Io.Limit` semantics: Infinity is unlimited, otherwise a
/// non-negative number of bytes.
pub const Limit = struct {
    bytes: usize,

    pub fn decode(call: *Call, index: usize) !Limit {
        const arg = call.arg(index);
        if (!arg.isNumber()) return error.InvalidArgument;
        const number = arg.numberValue(call.ctx) orelse return error.InvalidArgument;
        if (std.math.isInf(number)) return if (number > 0) .{ .bytes = std.math.maxInt(usize) } else error.InvalidArgument;
        if (!(number >= 0)) return error.InvalidArgument;
        return .{ .bytes = @intFromFloat(@min(number, @as(f64, @floatFromInt(std.math.maxInt(usize) / 2)))) };
    }
};

/// `[kind, size]` as a JS array.
const Stat = struct { u32, f64 };

fn kindCode(kind: sys.File.Kind) u32 {
    return switch (kind) {
        .file => 1,
        .directory => 2,
        .sym_link => 3,
        else => 4,
    };
}

/// Converts a file size to f64, failing with `FileTooLarge` instead of rounding.
fn exactSize(size: u64) !f64 {
    if (size > max_exact) return error.FileTooLarge;
    return @floatFromInt(size);
}

// ---- grant -------------------------------------------------------------------

pub const FsGrant = struct {
    host: *Host,
    /// The scope this grant was requested in; valid until `Host.destroy`. Its errno cell is the
    /// grant's, and disposing the scope closes the grant (see `Host.release`).
    owner: *ScopeState,
    closed: bool = false,
    id: u32,
    root: sys.Dir,
    /// The grant's access (`api.fs.requestSync({ access })`): 'r' reads, 'w' writes, 'rw' both.
    /// Handles are read/write natively, so a write-only grant is enforced here: see `readable`.
    read: bool,
    write: bool,
    files: std.ArrayList(?sys.File) = .empty,
    dirs: std.ArrayList(?sys.Dir) = .empty,

    // Binding State protocol (see binding.zig).
    pub fn errnoCell(self: *FsGrant) *u32 {
        return self.owner.errnoCell();
    }
    pub fn errorDetail(self: *FsGrant) ?v8.Object {
        return self.owner.errorDetail();
    }
    pub fn isDetached(self: *const FsGrant) bool {
        return self.owner.isDetached();
    }
    pub fn allocator(self: *FsGrant) std.mem.Allocator {
        return self.host.allocator;
    }

    /// Closes every open file and directory and the root. Idempotent: a disposed scope closes its
    /// grants early, and `Host.destroy` closes them all again.
    pub fn deinit(self: *FsGrant) void {
        if (self.closed) return;
        self.closed = true;
        for (self.files.items) |slot| if (slot) |opened| opened.close();
        for (self.dirs.items) |slot| if (slot) |opened| opened.close();
        self.root.close();
        self.files.deinit(self.host.allocator);
        self.dirs.deinit(self.host.allocator);
    }

    /// Fails with `PermissionDenied` on a read-only grant.
    fn writable(self: *FsGrant) !void {
        if (!self.write) return error.PermissionDenied;
    }

    /// Fails with `PermissionDenied` on a write-only grant: it may not observe anything that
    /// exists (file contents, stat, directory listings), though its handles could read natively.
    fn readable(self: *FsGrant) !void {
        if (!self.read) return error.PermissionDenied;
    }

    /// The sentinel `{0,0}` names the root; any other descriptor must have been
    /// issued by this grant and still be open.
    fn dir(self: *FsGrant, ref: DirRef) !sys.Dir {
        if (ref.fs == 0 and ref.id == 0) return self.root;
        if (ref.fs != self.id) return error.BadHandle;
        if (ref.id == 0) return self.root;
        if (ref.id > self.dirs.items.len) return error.BadHandle;
        return self.dirs.items[ref.id - 1] orelse error.BadHandle;
    }

    fn file(self: *FsGrant, ref: FileRef) !sys.File {
        if (ref.fs != self.id or ref.id == 0 or ref.id > self.files.items.len) return error.BadHandle;
        return self.files.items[ref.id - 1] orelse error.BadHandle;
    }

    fn storeFile(self: *FsGrant, value: sys.File) !u32 {
        // IDs are never reused: an old JS reference must not name a newly opened resource.
        try self.files.append(self.host.allocator, value);
        return @intCast(self.files.items.len);
    }

    fn storeDir(self: *FsGrant, value: sys.Dir) !u32 {
        // IDs are never reused: an old JS reference must not name a newly opened resource.
        try self.dirs.append(self.host.allocator, value);
        return @intCast(self.dirs.items.len);
    }
};

// ---- fs.requestSync ----------------------------------------------------------

/// Access bits of `native.fsRequest` / `native.fsAsync.request`: 1 read, 2 write (`access: 'r' | 'w' | 'rw'`
/// in src/js/glue/fs.js).
const access_read: u32 = 1;
const access_write: u32 = 2;

/// `native.fsRequest(root?, access)`: opens a sync grant over the host directory (or a
/// subdirectory of it) and returns the grant the host built: its operations, `kind`, `id` and the secret
/// (see `stampGrant`). The glue adds the scope's one `errno` array (shared by identity) and freezes it. The host config is the ceiling:
/// a read-only host rejects a write request with `PermissionDenied` (it is never silently
/// downgraded), and `sync = false` denies the request. `access` is the bits above; anything else is
/// `InvalidInput`. (Async grants live in the Rust runtime: `native.fsAsync`.)
pub fn request(state: *ScopeState, call: *Call, root: ?Path, access: u32) !v8.Value {
    const host = state.host;
    const alloc = host.allocator;
    if (access == 0 or access > (access_read | access_write)) return error.InvalidInput;
    const config = host.fs orelse return error.PermissionDenied;
    if (!config.sync) return error.PermissionDenied;
    if (access & access_write != 0 and !config.write) return error.PermissionDenied;
    const sub = if (root) |path| path.bytes else "";
    const opened = try config.root.openDir(if (sub.len == 0) "." else sub, .{ .iterate = true });
    errdefer opened.close();
    const grant = try alloc.create(FsGrant);
    errdefer alloc.destroy(grant);
    grant.* = .{ .host = host, .owner = state, .id = host.next_fs_id, .root = opened, .read = access & access_read != 0, .write = access & access_write != 0 };
    try host.grants.append(alloc, grant);
    host.next_fs_id += 1;
    const env = call.env();
    const object = try call.object(FsGrant, grant, .{
        .dirOpenFile = func(grantDirOpenFile, .{ .side_effect = .any, .subject = 2 }),
        .dirOpenDir = func(grantDirOpenDir, .{ .side_effect = .any, .subject = 2 }),
        .dirClose = func(grantDirClose, .{ .side_effect = .any }),
        .dirStat = func(grantDirStat, .{ .side_effect = .none, .subject = 2 }),
        .dirSymlinkStat = func(grantDirSymlinkStat, .{ .side_effect = .none, .subject = 2 }),
        .dirRead = func(grantDirRead, .{ .side_effect = .none }),
        .dirCreateDir = func(grantDirCreateDir, .{ .side_effect = .any, .subject = 2 }),
        .dirCreateDirPath = func(grantDirCreateDirPath, .{ .side_effect = .any, .subject = 2 }),
        .dirDeleteFile = func(grantDirDeleteFile, .{ .side_effect = .any, .subject = 2 }),
        .dirDeleteDir = func(grantDirDeleteDir, .{ .side_effect = .any, .subject = 2 }),
        .dirDeleteTree = func(grantDirDeleteTree, .{ .side_effect = .any, .subject = 2 }),
        .dirRename = func(grantDirRename, .{ .side_effect = .any, .subject = 2 }),
        .fileClose = func(grantFileClose, .{ .side_effect = .any }),
        .fileStat = func(grantFileStat, .{ .side_effect = .none }),
        .fileReadAll = func(grantFileReadAll, .{ .side_effect = .any }),
        .fileRead = func(grantFileRead, .{ .side_effect = .any }),
        .filePread = func(grantFilePread, .{ .side_effect = .none }),
        .fileWriteAll = func(grantFileWriteAll, .{ .side_effect = .any }),
        .fileWrite = func(grantFileWrite, .{ .side_effect = .any }),
        .filePwriteAll = func(grantFilePwriteAll, .{ .side_effect = .any }),
        .fileWriteMoveAll = func(grantFileWriteMoveAll, .{ .side_effect = .any }),
        .fileWriteMove = func(grantFileWriteMove, .{ .side_effect = .any }),
        .filePwriteMoveAll = func(grantFilePwriteMoveAll, .{ .side_effect = .any }),
        .fileSetLength = func(grantFileSetLength, .{ .side_effect = .any }),
        .fileSync = func(grantFileSync, .{ .side_effect = .any }),
    });
    try stampGrant(env, object, .sync, grant.id);
    return object.value;
}

// ---- fs.requestAsync ---------------------------------------------------------

/// An async request in flight: the Rust runtime opens the grant; the host builds the grant object when
/// its promise settles, and settles the guest's promise with it.
pub const AsyncRequest = struct {
    host: *Host,
    state: *ScopeState,
    io: u32,
    resolver: v8.Global.Of(v8.Promise.Resolver),
};

/// `native.fsRequestAsync(request, io, root, access)`: calls `request` (`native.fsAsync.request`, the
/// Rust native that opens the grant on `io`) and resolves with the grant object the host builds from
/// its answer. A rejection passes through unchanged. Nothing but this call makes an async grant.
pub fn requestAsync(state: *ScopeState, call: *Call, request_fn: v8.Function, io: u32, root: []const u8, access: u32) !v8.Promise {
    const host = state.host;
    const alloc = host.allocator;
    if (access == 0 or access > (access_read | access_write)) return error.InvalidInput;
    const undef = eu.v.undefined_value(call.isolate).value;
    const args = [_]v8.Value{ eu.v.num_u32(call.isolate, io).numeric.primitive.value, binding.string(call.isolate, root), eu.v.num_u32(call.isolate, access).numeric.primitive.value };
    const answer = request_fn.call(call.ctx, undef, &args) orelse return error.JavaScriptException;
    const promise = v8.Promise.from_opaque(answer.data.handle) orelse return error.Unexpected;
    const resolver = eu.v.promise_resolver(call.ctx) orelse return error.Unexpected;
    const pending = try alloc.create(AsyncRequest);
    errdefer alloc.destroy(pending);
    pending.* = .{ .host = host, .state = state, .io = io, .resolver = .new(call.isolate, resolver) };
    errdefer pending.resolver.deinit();
    try host.async_requests.append(alloc, pending);
    errdefer _ = host.async_requests.pop();
    const data = eu.v.external(call.isolate, pending).value.data;
    const on_ok = v8.Function.init(call.ctx, requestGranted, data, 1, .Throw, .HasSideEffect);
    const on_err = v8.Function.init(call.ctx, requestDenied, data, 1, .Throw, .HasSideEffect);
    _ = promise.then2(call.ctx, on_ok, on_err) orelse return error.Unexpected;
    return resolver.getPromise();
}

fn finishRequest(pending: *AsyncRequest) void {
    const host = pending.host;
    pending.resolver.deinit();
    for (host.async_requests.items, 0..) |item, index| if (item == pending) {
        _ = host.async_requests.swapRemove(index);
        break;
    };
    host.allocator.destroy(pending);
}

fn requestGranted(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = binding.externalPointer(AsyncRequest, info);
    defer finishRequest(pending);
    const isolate = info.isolate();
    const ctx = isolate.getCurrentContext();
    const reply = info.get_arg(0).toObject(ctx) orelse return rejectWith(pending, ctx, binding.string(isolate, "bad grant answer"));
    const id_value = reply.get(ctx, binding.string(isolate, "id")) orelse return rejectWith(pending, ctx, binding.string(isolate, "bad grant answer"));
    if (!id_value.isNumber()) return rejectWith(pending, ctx, binding.string(isolate, "bad grant answer"));
    const id = id_value.u32Value(ctx) orelse return rejectWith(pending, ctx, binding.string(isolate, "bad grant answer"));
    pending.host.async_grants.append(pending.host.allocator, .{ .id = id, .owner = pending.state, .io = pending.io }) catch return rejectWith(pending, ctx, binding.string(isolate, "out of memory"));
    const grant = newGrant(.{ .isolate = isolate, .ctx = ctx }, .async, id) catch return rejectWith(pending, ctx, binding.string(isolate, "grant failed"));
    _ = pending.resolver.deref().resolve(ctx, grant.value);
}

fn requestDenied(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = binding.externalPointer(AsyncRequest, info);
    defer finishRequest(pending);
    _ = pending.resolver.deref().reject(info.isolate().getCurrentContext(), info.get_arg(0));
}

fn rejectWith(pending: *AsyncRequest, ctx: v8.Context, reason: v8.Value) void {
    _ = pending.resolver.deref().reject(ctx, reason);
}

/// `native.fsAsyncClosed(io)`: the io runtime `io` was closed, so the async grants opened on it are
/// no longer accepted as an authority (the Rust runtime refuses their operations too).
pub fn asyncClosed(state: *ScopeState, io: u32) !void {
    for (state.host.async_grants.items) |*grant| if (grant.io == io and grant.owner == state) {
        grant.closed = true;
    };
}

// ---- the secret that makes an object a grant -------------------------------

/// Which kind of grant an object is.
pub const GrantKind = enum(u1) { sync = 0, async = 1 };

/// A grant a script presented, as the host knows it. `id` is the host's id of a sync grant, or the
/// Rust runtime's id of an async one.
pub const GrantRef = struct { kind: GrantKind, id: u32 };

/// An async grant the host built: the Rust runtime owns the grant, so Zig keeps who got it, on which
/// io runtime, and whether that runtime was closed (`fsAsyncClosed`) or the realm went away.
pub const AsyncGrant = struct { id: u32, owner: *ScopeState, io: u32, closed: bool = false };

fn grantKey(isolate: v8.Isolate) v8.Private {
    return v8.Private.forApi(isolate, v8.String.initUtf8(isolate, "origine:fs-grant"));
}

/// Makes `object` a grant: `kind` and `id` as plain properties and the secret, set here and nowhere
/// else. The host builds every grant (`request`, `requestAsync`); the glue adds the async operations
/// and freezes an async one, and cannot give an object the secret or change whose grant this is.
fn stampGrant(env: binding.Env, object: v8.Object, kind: GrantKind, id: u32) !void {
    try binding.set(env, object, "kind", @as([]const u8, if (kind == .sync) "sync" else "async"));
    try binding.set(env, object, "id", id);
    const number = @as(f64, @floatFromInt(@backingInt(kind))) * 4294967296.0 + @as(f64, @floatFromInt(id));
    if (!(object.setPrivate(env.ctx, grantKey(env.isolate), eu.v.num_f64(env.isolate, number).numeric.primitive.value) orelse return error.Unexpected)) return error.Unexpected;
}

fn newGrant(env: binding.Env, kind: GrantKind, id: u32) !v8.Object {
    const object = eu.v.object(env.isolate);
    try stampGrant(env, object, kind, id);
    return object;
}

/// The grant `object` is, if the host built it for this realm: what `derive({ fs })` and
/// `CodeCache.dir` call to learn what they were handed. Anything else is `InvalidInput`.
pub fn grantOf(state: *ScopeState, call: *Call, object: v8.Object) !GrantRef {
    const stamp = object.getPrivate(call.ctx, grantKey(call.isolate)) orelse return error.InvalidInput;
    if (!stamp.isNumber()) return error.InvalidInput;
    const number = stamp.numberValue(call.ctx) orelse return error.InvalidInput;
    const raw: u64 = @intFromFloat(number);
    const kind = std.enums.fromInt(GrantKind, @as(u1, @intCast(raw >> 32))) orelse return error.InvalidInput;
    const id: u32 = @truncate(raw);
    switch (kind) {
        .sync => _ = try syncGrantOf(state, id),
        .async => {
            for (state.host.async_grants.items) |known| if (known.id == id and known.owner == state and !known.closed) return .{ .kind = .async, .id = id };
            return error.InvalidInput;
        },
    }
    return .{ .kind = kind, .id = id };
}

/// The open sync grant `id` of `state`'s realm.
pub fn syncGrantOf(state: *ScopeState, id: u32) !*FsGrant {
    for (state.host.grants.items) |grant| if (grant.id == id and grant.owner == state and !grant.closed) return grant;
    return error.InvalidInput;
}

// ---- ops: (state, [call], args...) -> result ---------------------------------

/// Open bits: 1 write, 2 create, 4 truncate, 8 exclusive (src/js/glue/fs.js `OPEN_MODES`).
fn openFile(g: *FsGrant, dir: DirRef, path: EntryPath, bits: u32) !u32 {
    if (bits & 0b1111 != 0) try g.writable() else try g.readable();
    const parent = try g.dir(dir);
    const opened = if (bits & 2 != 0)
        try parent.createFile(path.bytes, .{ .read = true, .truncate = bits & 4 != 0, .exclusive = bits & 8 != 0 })
    else
        try parent.openFile(path.bytes, .{ .mode = if (bits & 1 != 0) .read_write else .read_only, .allow_directory = false });
    errdefer opened.close();
    return g.storeFile(opened);
}

fn openDir(g: *FsGrant, dir: DirRef, path: Path) !u32 {
    const parent = try g.dir(dir);
    const opened = try parent.openDir(if (path.bytes.len == 0) "." else path.bytes, .{ .iterate = true });
    errdefer opened.close();
    return g.storeDir(opened);
}

/// Metadata of the entry, following a final symlink (`std::fs::metadata`); an empty path is the
/// directory itself. A dangling link is `NotFound`.
fn stat(g: *FsGrant, dir: DirRef, path: Path) !Stat {
    return statOf(g, dir, path, true);
}

/// Metadata of the entry itself (`std::fs::symlink_metadata`): a final symlink is not followed.
fn symlinkStat(g: *FsGrant, dir: DirRef, path: Path) !Stat {
    return statOf(g, dir, path, false);
}

fn statOf(g: *FsGrant, dir: DirRef, path: Path, follow: bool) !Stat {
    try g.readable();
    const parent = try g.dir(dir);
    const info = if (path.bytes.len == 0) try parent.stat() else parent.statFile(path.bytes, .{ .follow_symlinks = follow }) catch |err| switch (err) {
        error.FileNotFound => return missing(g, parent, path.bytes),
        else => |other| return other,
    };
    return .{ kindCode(info.kind), try exactSize(info.size) };
}

/// Zig's `statFile` reports ENOTDIR (a file used as a directory) as `FileNotFound`, while the
/// async backend, like Rust, says `NotADirectory`. On that error path only: when a leading component
/// of `path` exists and is not a directory, report `NotDir` so both backends agree.
fn missing(_: *FsGrant, parent: sys.Dir, path: []const u8) error{ NotDir, FileNotFound } {
    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, from, '/')) |slash| {
        from = slash + 1;
        var stop = slash;
        while (stop > 0 and path[stop - 1] == '/') stop -= 1;
        if (stop == 0) continue;
        const info = parent.statFile(path[0..stop], .{}) catch continue;
        if (info.kind != .directory) return error.NotDir;
    }
    return error.FileNotFound;
}

fn createDir(g: *FsGrant, dir: DirRef, path: EntryPath) !void {
    try g.writable();
    try (try g.dir(dir)).createDir(path.bytes, .default_dir);
}

fn deleteFile(g: *FsGrant, dir: DirRef, path: EntryPath) !void {
    try g.writable();
    try (try g.dir(dir)).deleteFile(path.bytes);
}

/// Returns a flat array `[name0, kind0, name1, kind1, ...]`.
fn readDir(g: *FsGrant, call: *Call, dir: DirRef) !v8.Value {
    try g.readable();
    var list = call.array();
    var iterator = (try g.dir(dir)).iterate();
    while (try iterator.next()) |entry| {
        try list.push(entry.name);
        try list.push(kindCode(entry.kind));
    }
    return list.finish();
}

fn readAll(g: *FsGrant, call: *Call, file_ref: FileRef, limit: Limit) !v8.Value {
    try g.readable();
    const handle = try g.file(file_ref);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(g.allocator());
    var buffer: [16 * 1024]u8 = undefined;
    while (list.items.len < limit.bytes) {
        const want = @min(buffer.len, limit.bytes - list.items.len);
        const count = handle.readStreaming(&.{buffer[0..want]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) break;
        if (list.items.len + count > max_read_bytes) return error.FileTooLarge;
        try list.appendSlice(g.allocator(), buffer[0..count]);
    }
    return call.bytesValue(list.items);
}

fn writeAll(g: *FsGrant, file_ref: FileRef, data: []u8) !void {
    try g.writable();
    const handle = try g.file(file_ref);
    var offset: usize = 0;
    while (offset < data.len) offset += try handle.writeStreaming("", &.{data[offset..]}, 1);
}

fn close(g: *FsGrant, file_ref: FileRef) !void {
    const handle = try g.file(file_ref);
    handle.close();
    g.files.items[file_ref.id - 1] = null;
}

fn closeDir(g: *FsGrant, dir: DirRef) !void {
    if (dir.id == 0) return error.BadHandle; // the root stays open for the grant's lifetime
    const handle = try g.dir(dir);
    handle.close();
    g.dirs.items[dir.id - 1] = null;
}

fn createDirPath(g: *FsGrant, dir: DirRef, path: SubPath) !void {
    try g.writable();
    try (try g.dir(dir)).createDirPath(path.bytes);
}

fn deleteDir(g: *FsGrant, dir: DirRef, path: SubPath) !void {
    try g.writable();
    try (try g.dir(dir)).deleteDir(path.bytes);
}

fn deleteTree(g: *FsGrant, dir: DirRef, path: SubPath) !void {
    try g.writable();
    try (try g.dir(dir)).deleteTree(path.bytes);
}

fn rename(g: *FsGrant, dir: DirRef, old_path: SubPath, new_dir: DirRef, new_path: SubPath) !void {
    try g.writable();
    try sys.Dir.rename(try g.dir(dir), old_path.bytes, try g.dir(new_dir), new_path.bytes);
}

fn fileStat(g: *FsGrant, file_ref: FileRef) !Stat {
    try g.readable();
    const info = try (try g.file(file_ref)).stat();
    return .{ kindCode(info.kind), try exactSize(info.size) };
}

/// Streaming read into the caller's buffer; returns the byte count (0 at end).
fn fileRead(g: *FsGrant, file_ref: FileRef, buffer: []u8) !usize {
    try g.readable();
    const handle = try g.file(file_ref);
    if (buffer.len == 0) return 0;
    return handle.readStreaming(&.{buffer}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => err,
    };
}

fn filePread(g: *FsGrant, file_ref: FileRef, buffer: []u8, offset: u64) !usize {
    try g.readable();
    const handle = try g.file(file_ref);
    if (buffer.len == 0) return 0;
    return handle.readPositional(&.{buffer}, offset);
}

/// Streaming write that may be partial; returns the byte count written.
fn fileWrite(g: *FsGrant, file_ref: FileRef, data: []u8) !usize {
    try g.writable();
    const handle = try g.file(file_ref);
    if (data.len == 0) return 0;
    return handle.writeStreaming("", &.{data}, 1);
}

fn filePwriteAll(g: *FsGrant, file_ref: FileRef, data: []u8, offset: u64) !void {
    try g.writable();
    try (try g.file(file_ref)).writePositionalAll(data, offset);
}

fn fileSetLength(g: *FsGrant, file_ref: FileRef, length: u64) !void {
    try g.writable();
    try (try g.file(file_ref)).setLength(length);
}

fn fileSync(g: *FsGrant, file_ref: FileRef) !void {
    try (try g.file(file_ref)).sync();
}

// ---- the operations a sync grant carries ------------------------------------
//
// JS wrappers validate and unwrap private reference state once, then pass scalar
// `(fs, id)` pairs to these grant-bound operations. Native code checks ownership,
// liveness, paths, buffers, and access before using any resource.

pub const DirHandle = struct {
    ref: DirRef,
    pub const arity = 2;
    pub fn decode(call: *Call, index: usize) !DirHandle {
        return .{ .ref = try DirRef.decode(call, index) };
    }
};

pub const FileHandle = struct {
    ref: FileRef,
    pub const arity = 2;
    pub fn decode(call: *Call, index: usize) !FileHandle {
        return .{ .ref = try FileRef.decode(call, index) };
    }
};

/// Python-style open modes -> native bits (write 1, create 2, truncate 4, exclusive 8). Handles always allow
/// reading when writable, so `x` and `x+` (and `w`/`w+`, `r+`/`rw`) are equivalent natively; `c` and `t`
/// extend Python's set for Rust-style options. Undefined is `r`; anything unknown is `InvalidInput`.
pub const OpenMode = struct {
    bits: u32,

    const table = [_]struct { []const u8, u32 }{
        .{ "r", 0 },   .{ "rw", 1 }, .{ "r+", 1 }, .{ "w", 7 }, .{ "w+", 7 }, .{ "x", 11 },
        .{ "x+", 11 }, .{ "c", 3 },  .{ "c+", 3 }, .{ "t", 5 }, .{ "t+", 5 },
    };

    pub fn decode(call: *Call, index: usize) !OpenMode {
        const arg = call.arg(index);
        if (arg.isUndefined()) return .{ .bits = 0 };
        if (!arg.isString()) return error.InvalidInput;
        var buffer: [8]u8 = undefined;
        const text = arg.toString(call.ctx) orelse return error.InvalidInput;
        if (text.lenUtf8(call.isolate) > buffer.len) return error.InvalidInput;
        const mode = buffer[0..text.writeUtf8(call.isolate, &buffer)];
        for (table) |entry| if (std.mem.eql(u8, entry[0], mode)) return .{ .bits = entry[1] };
        return error.InvalidInput;
    }
};

/// A `Uint8Array` argument, aliased (a different view kind is `InvalidInput`, as the glue checked).
pub const Bytes = struct {
    data: []u8,

    pub fn decode(call: *Call, index: usize) !Bytes {
        const arg = call.arg(index);
        if (!arg.isUint8Array()) return error.InvalidInput;
        return .{ .data = binding.viewBytes(arg) orelse return error.InvalidInput };
    }
};

/// `{ limit }` of `fileReadAll(file, options)`: a non-negative number, `Infinity` or absent for no limit.
pub const ReadOptions = struct {
    limit: Limit,

    pub fn decode(call: *Call, index: usize) !ReadOptions {
        const unlimited: ReadOptions = .{ .limit = .{ .bytes = std.math.maxInt(usize) } };
        const arg = call.arg(index);
        if (arg.isUndefined() or arg.isNull()) return unlimited;
        const object = arg.toObject(call.ctx) orelse return error.InvalidInput;
        const value = object.get(call.ctx, binding.string(call.isolate, "limit")) orelse return error.InvalidInput;
        if (value.isUndefined() or value.isNull()) return unlimited;
        if (!value.isNumber()) return error.InvalidInput;
        const number = value.numberValue(call.ctx) orelse return error.InvalidInput;
        if (std.math.isInf(number)) return if (number > 0) unlimited else error.InvalidInput;
        if (!(number >= 0)) return error.InvalidInput;
        return .{ .limit = .{ .bytes = @intFromFloat(@min(number, @as(f64, @floatFromInt(std.math.maxInt(usize) / 2)))) } };
    }
};

// Internal result payloads are wrapped into JS result classes by glue/fs.js.
fn statValue(call: *Call, info: Stat) !v8.Value {
    return call.value(info);
}

fn grantDirOpenFile(g: *FsGrant, dir: DirHandle, path: EntryPath, mode: OpenMode) !u32 {
    return openFile(g, dir.ref, path, mode.bits);
}

fn grantDirOpenDir(g: *FsGrant, dir: DirHandle, path: Path) !u32 {
    return openDir(g, dir.ref, path);
}

fn grantDirClose(g: *FsGrant, fs: u32, id: u32) !void {
    return closeDir(g, .{ .fs = fs, .id = id });
}

fn grantDirStat(g: *FsGrant, call: *Call, dir: DirHandle, path: Path) !v8.Value {
    return statValue(call, try stat(g, dir.ref, path));
}

fn grantDirSymlinkStat(g: *FsGrant, call: *Call, dir: DirHandle, path: Path) !v8.Value {
    return statValue(call, try symlinkStat(g, dir.ref, path));
}

/// Internal listing payload; the JS wrapper constructs the public DirEntry instances.
fn grantDirRead(g: *FsGrant, call: *Call, dir: DirHandle) !v8.Value {
    try g.readable();
    var list = call.array();
    var iterator = (try g.dir(dir.ref)).iterate();
    while (try iterator.next()) |entry| {
        const object = eu.v.object(call.isolate);
        try call.set(object, "name", entry.name);
        try call.set(object, "kind", kindCode(entry.kind));
        _ = object.setIntegrityLevel(call.ctx, .Frozen) orelse return error.JavaScriptException;
        try list.push(object.value);
    }
    _ = list.array.object.setIntegrityLevel(call.ctx, .Frozen) orelse return error.JavaScriptException;
    return list.finish();
}

fn grantDirCreateDir(g: *FsGrant, dir: DirHandle, path: EntryPath) !void {
    return createDir(g, dir.ref, path);
}

fn grantDirCreateDirPath(g: *FsGrant, dir: DirHandle, path: SubPath) !void {
    return createDirPath(g, dir.ref, path);
}

fn grantDirDeleteFile(g: *FsGrant, dir: DirHandle, path: EntryPath) !void {
    return deleteFile(g, dir.ref, path);
}

fn grantDirDeleteDir(g: *FsGrant, dir: DirHandle, path: SubPath) !void {
    return deleteDir(g, dir.ref, path);
}

fn grantDirDeleteTree(g: *FsGrant, dir: DirHandle, path: SubPath) !void {
    return deleteTree(g, dir.ref, path);
}

fn grantDirRename(g: *FsGrant, dir: DirHandle, old_path: SubPath, new_dir: DirHandle, new_path: SubPath) !void {
    return rename(g, dir.ref, old_path, new_dir.ref, new_path);
}

fn grantFileClose(g: *FsGrant, fs: u32, id: u32) !void {
    return close(g, .{ .fs = fs, .id = id });
}

fn grantFileStat(g: *FsGrant, call: *Call, file: FileHandle) !v8.Value {
    return statValue(call, try fileStat(g, file.ref));
}

fn grantFileReadAll(g: *FsGrant, call: *Call, file: FileHandle, options: ReadOptions) !v8.Value {
    return readAll(g, call, file.ref, options.limit);
}

fn grantFileRead(g: *FsGrant, file: FileHandle, buffer: Bytes) !usize {
    return fileRead(g, file.ref, buffer.data);
}

fn grantFilePread(g: *FsGrant, file: FileHandle, buffer: Bytes, offset: u64) !usize {
    return filePread(g, file.ref, buffer.data, offset);
}

fn grantFileWriteAll(g: *FsGrant, file: FileHandle, bytes: Bytes) !void {
    return writeAll(g, file.ref, bytes.data);
}

fn grantFileWrite(g: *FsGrant, file: FileHandle, bytes: Bytes) !usize {
    return fileWrite(g, file.ref, bytes.data);
}

fn grantFilePwriteAll(g: *FsGrant, file: FileHandle, bytes: Bytes, offset: u64) !void {
    return filePwriteAll(g, file.ref, bytes.data, offset);
}

/// Sync writes copy (the call blocks) and have no move variant: there is nothing to hand over.
fn grantFileWriteMoveAll(_: *FsGrant, _: FileHandle, _: Bytes) !void {
    return error.Unsupported;
}

fn grantFileWriteMove(_: *FsGrant, _: FileHandle, _: Bytes) !void {
    return error.Unsupported;
}

fn grantFilePwriteMoveAll(_: *FsGrant, _: FileHandle, _: Bytes) !void {
    return error.Unsupported;
}

fn grantFileSetLength(g: *FsGrant, file: FileHandle, length: u64) !void {
    return fileSetLength(g, file.ref, length);
}

fn grantFileSync(g: *FsGrant, fs: u32, id: u32) !void {
    return fileSync(g, .{ .fs = fs, .id = id });
}
