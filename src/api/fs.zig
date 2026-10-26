//! `api.fs`: grants over a host directory and the typed natives behind them.
//!
//! A `FsGrant` owns directory/file handles; guest code only holds descriptors
//! (`{ fs, id }` pairs) that name entries in one grant, and native functions bound
//! to that grant. Argument types below (`DirRef`, `Path`, ...) validate at the
//! binding boundary, so the ops only see checked values.
const std = @import("std");
const v8 = @import("@v8");
const binding = @import("binding.zig");
const init_cache = @import("init_cache.zig");
const func = binding.func;
const Call = binding.Call;
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
/// the OS's own), absolute paths, `..` components and the engine's `__oricache__` directories
/// (snapshots and code caches are trusted by V8, so a guest must not be able to plant them).
/// Lexical only: symlinks inside the root are not resolved here, so following one can leave the
/// root (docs/api-design.md). The Rust twin is `clean` in rust/crates/origine_api_fs.
fn cleanPath(path: []const u8) !void {
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

fn kindCode(kind: std.Io.File.Kind) u32 {
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
    root: std.Io.Dir,
    /// The grant's access (`api.fs.requestSync({ access })`): 'r' reads, 'w' writes, 'rw' both.
    /// Handles are read/write natively, so a write-only grant is enforced here: see `readable`.
    read: bool,
    write: bool,
    files: std.ArrayList(?std.Io.File) = .empty,
    dirs: std.ArrayList(?std.Io.Dir) = .empty,

    // Binding State protocol (see binding.zig).
    pub fn errnoCell(self: *FsGrant) *u32 {
        return self.owner.errnoCell();
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
        const handle_io = self.io();
        for (self.files.items) |slot| if (slot) |opened| opened.close(handle_io);
        for (self.dirs.items) |slot| if (slot) |opened| opened.close(handle_io);
        self.root.close(handle_io);
        self.files.deinit(self.host.allocator);
        self.dirs.deinit(self.host.allocator);
    }

    fn io(self: *FsGrant) std.Io {
        return self.host.io;
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
    fn dir(self: *FsGrant, ref: DirRef) !std.Io.Dir {
        if (ref.fs == 0 and ref.id == 0) return self.root;
        if (ref.fs != self.id) return error.BadHandle;
        if (ref.id == 0) return self.root;
        if (ref.id > self.dirs.items.len) return error.BadHandle;
        return self.dirs.items[ref.id - 1] orelse error.BadHandle;
    }

    fn file(self: *FsGrant, ref: FileRef) !std.Io.File {
        if (ref.fs != self.id or ref.id == 0 or ref.id > self.files.items.len) return error.BadHandle;
        return self.files.items[ref.id - 1] orelse error.BadHandle;
    }

    fn storeFile(self: *FsGrant, value: std.Io.File) !u32 {
        for (self.files.items, 0..) |slot, index| if (slot == null) {
            self.files.items[index] = value;
            return @intCast(index + 1);
        };
        try self.files.append(self.host.allocator, value);
        return @intCast(self.files.items.len);
    }

    fn storeDir(self: *FsGrant, value: std.Io.Dir) !u32 {
        for (self.dirs.items, 0..) |slot, index| if (slot == null) {
            self.dirs.items[index] = value;
            return @intCast(index + 1);
        };
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
/// subdirectory of it) and returns its ops object. The host config is the ceiling:
/// a read-only host rejects a write request with `PermissionDenied` (it is never silently
/// downgraded), and `sync = false` denies the request. `access` is the bits above; anything else is
/// `InvalidInput`. (Async grants live in the Rust runtime: `native.fsAsync`.)
pub fn request(state: *ScopeState, call: *Call, root: ?Path, access: u32) !v8.Object {
    const host = state.host;
    const alloc = host.allocator;
    if (access == 0 or access > (access_read | access_write)) return error.InvalidInput;
    const config = host.fs orelse return error.PermissionDenied;
    if (!config.sync) return error.PermissionDenied;
    if (access & access_write != 0 and !config.write) return error.PermissionDenied;
    const sub = if (root) |path| path.bytes else "";
    const opened = try config.root.openDir(host.io, if (sub.len == 0) "." else sub, .{ .iterate = true });
    errdefer opened.close(host.io);
    const grant = try alloc.create(FsGrant);
    errdefer alloc.destroy(grant);
    grant.* = .{ .host = host, .owner = state, .id = host.next_fs_id, .root = opened, .read = access & access_read != 0, .write = access & access_write != 0 };
    try host.grants.append(alloc, grant);
    host.next_fs_id += 1;
    const ops = try call.object(FsGrant, grant, .{
        .openFile = func(openFile, .{ .side_effect = .any }),
        .openDir = func(openDir, .{ .side_effect = .any }),
        .stat = func(stat, .{ .side_effect = .none }),
        .symlinkStat = func(symlinkStat, .{ .side_effect = .none }),
        .createDir = func(createDir, .{ .side_effect = .any }),
        .deleteFile = func(deleteFile, .{ .side_effect = .any }),
        .readDir = func(readDir, .{ .side_effect = .none }),
        .readAll = func(readAll, .{ .side_effect = .any }),
        .writeAll = func(writeAll, .{ .side_effect = .any }),
        .close = func(close, .{ .side_effect = .any }),
        .closeDir = func(closeDir, .{ .side_effect = .any }),
        .createDirPath = func(createDirPath, .{ .side_effect = .any }),
        .deleteDir = func(deleteDir, .{ .side_effect = .any }),
        .deleteTree = func(deleteTree, .{ .side_effect = .any }),
        .rename = func(rename, .{ .side_effect = .any }),
        .fileStat = func(fileStat, .{ .side_effect = .none }),
        .fileRead = func(fileRead, .{ .side_effect = .any }),
        .filePread = func(filePread, .{ .side_effect = .none }),
        .fileWrite = func(fileWrite, .{ .side_effect = .any }),
        .filePwriteAll = func(filePwriteAll, .{ .side_effect = .any }),
        .fileSetLength = func(fileSetLength, .{ .side_effect = .any }),
        .fileSync = func(fileSync, .{ .side_effect = .any }),
    });
    try call.set(ops, "id", grant.id);
    return ops;
}

// ---- ops: (state, [call], args...) -> result ---------------------------------

/// Open bits: 1 write, 2 create, 4 truncate, 8 exclusive (src/js/glue/fs.js `OPEN_MODES`).
fn openFile(g: *FsGrant, dir: DirRef, path: EntryPath, bits: u32) !u32 {
    if (bits & 0b1111 != 0) try g.writable() else try g.readable();
    const parent = try g.dir(dir);
    const opened = if (bits & 2 != 0)
        try parent.createFile(g.io(), path.bytes, .{ .read = true, .truncate = bits & 4 != 0, .exclusive = bits & 8 != 0 })
    else
        try parent.openFile(g.io(), path.bytes, .{ .mode = if (bits & 1 != 0) .read_write else .read_only, .allow_directory = false });
    errdefer opened.close(g.io());
    return g.storeFile(opened);
}

fn openDir(g: *FsGrant, dir: DirRef, path: Path) !u32 {
    const parent = try g.dir(dir);
    const opened = try parent.openDir(g.io(), if (path.bytes.len == 0) "." else path.bytes, .{ .iterate = true });
    errdefer opened.close(g.io());
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
    const info = if (path.bytes.len == 0) try parent.stat(g.io()) else parent.statFile(g.io(), path.bytes, .{ .follow_symlinks = follow }) catch |err| switch (err) {
        error.FileNotFound => return missing(g, parent, path.bytes),
        else => |other| return other,
    };
    return .{ kindCode(info.kind), try exactSize(info.size) };
}

/// Zig's `statFile` reports ENOTDIR (a file used as a directory) as `FileNotFound`, while the
/// async backend, like Rust, says `NotADirectory`. On that error path only: when a leading component
/// of `path` exists and is not a directory, report `NotDir` so both backends agree.
fn missing(g: *FsGrant, parent: std.Io.Dir, path: []const u8) error{ NotDir, FileNotFound } {
    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, from, '/')) |slash| {
        from = slash + 1;
        var stop = slash;
        while (stop > 0 and path[stop - 1] == '/') stop -= 1;
        if (stop == 0) continue;
        const info = parent.statFile(g.io(), path[0..stop], .{}) catch continue;
        if (info.kind != .directory) return error.NotDir;
    }
    return error.FileNotFound;
}

fn createDir(g: *FsGrant, dir: DirRef, path: EntryPath) !void {
    try g.writable();
    try (try g.dir(dir)).createDir(g.io(), path.bytes, .default_dir);
}

fn deleteFile(g: *FsGrant, dir: DirRef, path: EntryPath) !void {
    try g.writable();
    try (try g.dir(dir)).deleteFile(g.io(), path.bytes);
}

/// Returns a flat array `[name0, kind0, name1, kind1, ...]`.
fn readDir(g: *FsGrant, call: *Call, dir: DirRef) !v8.Value {
    try g.readable();
    var list = call.array();
    var iterator = (try g.dir(dir)).iterate();
    while (try iterator.next(g.io())) |entry| {
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
        const count = handle.readStreaming(g.io(), &.{buffer[0..want]}) catch |err| switch (err) {
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
    while (offset < data.len) offset += try handle.writeStreaming(g.io(), "", &.{data[offset..]}, 1);
}

fn close(g: *FsGrant, file_ref: FileRef) !void {
    const handle = try g.file(file_ref);
    handle.close(g.io());
    g.files.items[file_ref.id - 1] = null;
}

fn closeDir(g: *FsGrant, dir: DirRef) !void {
    if (dir.id == 0) return error.BadHandle; // the root stays open for the grant's lifetime
    const handle = try g.dir(dir);
    handle.close(g.io());
    g.dirs.items[dir.id - 1] = null;
}

fn createDirPath(g: *FsGrant, dir: DirRef, path: SubPath) !void {
    try g.writable();
    try (try g.dir(dir)).createDirPath(g.io(), path.bytes);
}

fn deleteDir(g: *FsGrant, dir: DirRef, path: SubPath) !void {
    try g.writable();
    try (try g.dir(dir)).deleteDir(g.io(), path.bytes);
}

fn deleteTree(g: *FsGrant, dir: DirRef, path: SubPath) !void {
    try g.writable();
    try (try g.dir(dir)).deleteTree(g.io(), path.bytes);
}

fn rename(g: *FsGrant, dir: DirRef, old_path: SubPath, new_dir: DirRef, new_path: SubPath) !void {
    try g.writable();
    try std.Io.Dir.rename(try g.dir(dir), old_path.bytes, try g.dir(new_dir), new_path.bytes, g.io());
}

fn fileStat(g: *FsGrant, file_ref: FileRef) !Stat {
    try g.readable();
    const info = try (try g.file(file_ref)).stat(g.io());
    return .{ kindCode(info.kind), try exactSize(info.size) };
}

/// Streaming read into the caller's buffer; returns the byte count (0 at end).
fn fileRead(g: *FsGrant, file_ref: FileRef, buffer: []u8) !usize {
    try g.readable();
    const handle = try g.file(file_ref);
    if (buffer.len == 0) return 0;
    return handle.readStreaming(g.io(), &.{buffer}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => err,
    };
}

fn filePread(g: *FsGrant, file_ref: FileRef, buffer: []u8, offset: u64) !usize {
    try g.readable();
    const handle = try g.file(file_ref);
    if (buffer.len == 0) return 0;
    return handle.readPositional(g.io(), &.{buffer}, offset);
}

/// Streaming write that may be partial; returns the byte count written.
fn fileWrite(g: *FsGrant, file_ref: FileRef, data: []u8) !usize {
    try g.writable();
    const handle = try g.file(file_ref);
    if (data.len == 0) return 0;
    return handle.writeStreaming(g.io(), "", &.{data}, 1);
}

fn filePwriteAll(g: *FsGrant, file_ref: FileRef, data: []u8, offset: u64) !void {
    try g.writable();
    try (try g.file(file_ref)).writePositionalAll(g.io(), data, offset);
}

fn fileSetLength(g: *FsGrant, file_ref: FileRef, length: u64) !void {
    try g.writable();
    try (try g.file(file_ref)).setLength(g.io(), length);
}

fn fileSync(g: *FsGrant, file_ref: FileRef) !void {
    try (try g.file(file_ref)).sync(g.io());
}
