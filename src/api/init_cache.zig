//! On-disk cache of the init snapshot, in the style of `__pycache__`: the snapshot of
//! `dir/init.js` lives in `dir/__oricache__/init.js.<engine>.v8-snapshot`. The first run of
//! an init creates it; later runs reuse it while neither the engine nor any module of the
//! init graph changed. Everything here is best effort: a cache that cannot be read or
//! written (read-only directory, corrupt file) is the same as no cache.
//!
//! A file is valid when (1) its name carries this engine's tag, (2) its header holds the
//! key derived from the engine, the init specifier and the host's embedded modules, and
//! (3) every file-backed module of the graph still hashes as recorded. No mtimes: a
//! checkout or copy that keeps content keeps the cache.
const std = @import("std");
const v8 = @import("@v8");
const managed = struct {
    const init_snapshot = @import("../managed/init_snapshot.zig");
    const module_types = @import("../managed/module_types.zig");
    const runtime = @import("../managed/runtime.zig");
    const Scope = @import("../managed/scope.zig").Scope;
};
const Host = @import("host.zig").Host;
const Blake3 = std.crypto.hash.Blake3;

pub const dir_name = "__oricache__";
pub const extension = "v8-snapshot";
/// Bump when the file layout or the meaning of the key changes.
const format_version = 1;

const hash_len = managed.init_snapshot.hash_len;
pub const Hash = [hash_len]u8;

/// Where one init's snapshot lives and what it must match. Owns `path`.
pub const Entry = struct {
    alloc: std.mem.Allocator,
    /// `dir/__oricache__/name.<engine>.v8-snapshot`, relative to the working directory.
    path: []const u8,
    key: Hash,

    pub fn deinit(self: *Entry) void {
        self.alloc.free(self.path);
        self.* = undefined;
    }
};

/// Hash of everything that decides whether V8 output (a heap snapshot, a code cache) made by
/// another run can be reused: the V8 build and flags, this executable (identity, size and
/// modification time, which stands in for hashing it on every start) and the host's embedded
/// modules. Borrows host through return.
pub fn engineKey(io: std.Io, host: *const Host) Hash {
    var hasher = Blake3.init(.{});
    hasher.update(&.{format_version});
    hasher.update(v8.V8.getVersion());
    hasher.update(std.mem.asBytes(&v8.ScriptCompiler.cachedDataVersionTag()));
    var exe_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (std.process.executablePath(io, &exe_buffer)) |len| {
        const exe = exe_buffer[0..len];
        hasher.update(exe);
        if (std.Io.Dir.cwd().statFile(io, exe, .{})) |stat| {
            hasher.update(std.mem.asBytes(&stat.size));
            hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
        } else |_| {}
    } else |_| {}
    for (host.modules) |module| {
        hasher.update(module.id);
        hasher.update(&.{0});
        hasher.update(module.source);
        hasher.update(&.{0});
    }
    var key: Hash = undefined;
    hasher.final(&key);
    return key;
}

/// What the snapshot header records about the engine: the file layout version and a label
/// naming the V8 build and its code-cache format tag. `buffer` backs the label.
pub fn identity(buffer: []u8) managed.init_snapshot.Identity {
    const label = std.fmt.bufPrint(buffer, "v8 {s} cache-tag {x}", .{ v8.V8.getVersion(), v8.ScriptCompiler.cachedDataVersionTag() }) catch buffer[0..0];
    return .{ .format = format_version, .engine = label };
}

/// The twelve hex digits that name a cache file's engine, taken from an engine or entry key.
fn tagOf(key: Hash) [12]u8 {
    return std.fmt.bytesToHex(key[0..6].*, .lower);
}

/// `dir/__oricache__/name.<tag>.<extension>` for the file at `path` (relative; may have no dir).
fn cachePath(alloc: std.mem.Allocator, path: []const u8, tag: [12]u8, ext: []const u8) ![]u8 {
    const dir = std.fs.path.dirnamePosix(path) orelse "";
    const file = try std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{ std.fs.path.basenamePosix(path), tag, ext });
    defer alloc.free(file);
    if (dir.len == 0) return std.fs.path.join(alloc, &.{ dir_name, file });
    return std.fs.path.join(alloc, &.{ dir, dir_name, file });
}

/// Derives the snapshot entry for `init_specifier` (as the host imports it): the engine key
/// plus the specifier. Borrows host and specifier through return.
pub fn entryFor(alloc: std.mem.Allocator, io: std.Io, host: *const Host, init_specifier: []const u8) !Entry {
    var hasher = Blake3.init(.{});
    const engine = engineKey(io, host);
    hasher.update(&engine);
    hasher.update(init_specifier);
    var key: Hash = undefined;
    hasher.final(&key);
    return .{ .alloc = alloc, .path = try cachePath(alloc, init_specifier, tagOf(engine), extension), .key = key };
}

/// Hashes what a module ID is read from: the raw bytes of the file in the working
/// directory. Embedded `origine:` modules are covered by the key and return null.
/// Matches `managed.init_snapshot.SourceHasher`. `data` is the `*Host`.
pub fn hashSource(data: ?*anyopaque, id: []const u8) anyerror!?Hash {
    if (std.mem.startsWith(u8, id, managed.module_types.origine_prefix)) return null;
    const host: *Host = @ptrCast(@alignCast(data.?));
    const file = try std.Io.Dir.cwd().openFile(host.io, id, .{});
    defer file.close(host.io);
    var hasher = Blake3.init(.{});
    var buffer: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(host.io, &buffer, offset);
        if (n == 0) break;
        hasher.update(buffer[0..n]);
        offset += n;
    }
    var out: Hash = undefined;
    hasher.final(&out);
    return out;
}

pub fn sourceHasher(host: *Host) managed.init_snapshot.SourceHasher {
    return .{ .data = host, .hash = hashSource };
}

/// Why `load` found nothing usable.
pub const Miss = enum {
    no_file,
    /// Unreadable, truncated or not a snapshot file.
    bad_file,
    /// Written with another file layout version.
    format_changed,
    /// Written for another V8 build or code-cache format.
    engine_changed,
    /// Same engine, but another executable, init path or embedded module set.
    key_changed,
    /// A module of the graph changed or disappeared.
    source_changed,
};

/// Reads and validates the cached snapshot under `root` (the directory `entry.path` is
/// relative to; the working directory in the CLI). Returns null on any miss and says why in
/// `why` when given; files from another version are rejected, never migrated. Borrows root,
/// entry and hasher through return; the result owns its bytes (release with `Image.deinit`).
pub fn load(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, entry: *const Entry, hasher: managed.init_snapshot.SourceHasher, why: ?*Miss) ?managed.init_snapshot.Image {
    var label: [128]u8 = undefined;
    const bytes = root.readFileAllocOptions(io, entry.path, alloc, .limited(1 << 30), managed.init_snapshot.alignment, null) catch |err| {
        if (why) |out| out.* = if (err == error.FileNotFound) .no_file else .bad_file;
        return null;
    };
    var image = managed.init_snapshot.parse(alloc, bytes, entry.key, identity(&label)) catch |err| {
        alloc.free(bytes);
        if (why) |out| out.* = switch (err) {
            error.FormatMismatch => .format_changed,
            error.EngineMismatch => .engine_changed,
            error.KeyMismatch => .key_changed,
            else => .bad_file,
        };
        return null;
    };
    if (!image.sourcesUnchanged(hasher)) {
        image.deinit();
        if (why) |out| out.* = .source_changed;
        return null;
    }
    return image;
}

/// Writes the snapshot file under `root` atomically (temporary file in the same directory,
/// then rename) so a concurrent or interrupted run never sees a partial file. Creates
/// `__oricache__` on demand. Borrows everything; the caller keeps the image.
pub fn store(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, entry: *const Entry, image: *const managed.init_snapshot.Image) !void {
    try writeAtomic(alloc, io, root, entry.path, image.bytes);
    sweepStale(io, root, entry.path);
}

/// Deletes every cache file in the directory of `current_path` that another engine made:
/// `name.<tag>.v8-snapshot` and `name.<tag>.v8-code-cache` whose 12-hex-digit tag differs
/// from the one in `current_path`. Files of other sources are swept too, so rebuilding or
/// upgrading origine does not leave caches that can never be read again. Anything else in the
/// directory is left alone. Best effort; borrows root and path for the call.
fn sweepStale(io: std.Io, root: std.Io.Dir, current_path: []const u8) void {
    const dir_path = std.fs.path.dirname(current_path) orelse return;
    const current_tag = tagOfName(std.fs.path.basename(current_path)) orelse return;
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return) |item| {
        if (item.kind != .file) continue;
        const tag = tagOfName(item.name) orelse continue;
        if (std.mem.eql(u8, tag, current_tag)) continue;
        dir.deleteFile(io, item.name) catch {};
    }
}

/// The engine tag of a cache file name (`name.<12 hex>.<known extension>`), or null for any
/// other name.
fn tagOfName(name: []const u8) ?[]const u8 {
    inline for (.{ extension, code_cache_extension }) |ext| {
        if (std.mem.endsWith(u8, name, "." ++ ext)) {
            const stem = name[0 .. name.len - ext.len - 1];
            if (stem.len < 14 or stem[stem.len - 13] != '.') return null;
            const tag = stem[stem.len - 12 ..];
            for (tag) |c| if (!std.ascii.isHex(c)) return null;
            return tag;
        }
    }
    return null;
}

/// Writes `data` to `path` under `root` atomically (a temporary file beside it, then rename),
/// creating the directory on demand. The pid keeps concurrent writers from sharing a temporary.
fn writeAtomic(alloc: std.mem.Allocator, io: std.Io, root: std.Io.Dir, path: []const u8, data: []const u8) !void {
    try root.createDirPath(io, std.fs.path.dirname(path).?);
    const temporary = try std.fmt.allocPrint(alloc, "{s}.{d}.tmp", .{ path, std.c.getpid() });
    defer alloc.free(temporary);
    errdefer root.deleteFile(io, temporary) catch {};
    try root.writeFile(io, .{ .sub_path = temporary, .data = data });
    try root.rename(temporary, root, path, io);
}

// Code cache: one file per source module, `dir/__oricache__/name.<tag>.v8-code-cache`.
// Layout: magic, Blake3 of the exact source text, payload length (u64 LE), V8's bytes (8-aligned).

pub const code_cache_extension = "v8-code-cache";
const code_magic = "ORICODE\x01";
const code_header_len = code_magic.len + hash_len + 8;
comptime {
    std.debug.assert(code_header_len % 8 == 0);
}

/// State behind the `CodeCache` hook for one Host and engine. Keep it at a stable address
/// until `Runtime.destroy` returns.
pub const CodeCacheState = struct {
    host: *Host,
    tag: [12]u8,
    root: std.Io.Dir,

    pub fn init(io: std.Io, host: *Host, root: std.Io.Dir) CodeCacheState {
        return .{ .host = host, .tag = tagOf(engineKey(io, host)), .root = root };
    }

    /// The hook to put into `Scope.Options.code_cache`; borrows self (stable address).
    pub fn hook(self: *CodeCacheState) managed.module_types.CodeCache {
        return .{ .data = self, .load = loadCode, .store = storeCode };
    }
};

fn sourceHash(source: []const u8) Hash {
    var out: Hash = undefined;
    Blake3.hash(source, &out, .{});
    return out;
}

/// Hook `load`: the cached bytes for a file-backed module whose current source hashes as it
/// did when the cache was written, else null. Embedded `origine:` modules are not cached on
/// disk. Result lives in request.allocator.
fn loadCode(data: ?*anyopaque, request: managed.module_types.CodeCacheRequest) ?[]const u8 {
    const state: *CodeCacheState = @ptrCast(@alignCast(data.?));
    if (std.mem.startsWith(u8, request.module_id, managed.module_types.origine_prefix)) return null;
    const path = cachePath(request.allocator, request.module_id, state.tag, code_cache_extension) catch return null;
    const bytes = state.root.readFileAllocOptions(state.host.io, path, request.allocator, .limited(1 << 28), .@"8", null) catch return null;
    if (bytes.len <= code_header_len or !std.mem.eql(u8, bytes[0..code_magic.len], code_magic)) return null;
    const stored = bytes[code_magic.len..][0..hash_len];
    if (!std.mem.eql(u8, stored, &sourceHash(request.source))) return null;
    const length = std.mem.readInt(u64, bytes[code_magic.len + hash_len ..][0..8], .little);
    if (length != bytes.len - code_header_len) return null;
    return bytes[code_header_len..];
}

/// Hook `store`: writes the code cache of a file-backed module next to its source. Best
/// effort; any failure just means no cache next time.
fn storeCode(data: ?*anyopaque, request: managed.module_types.CodeCacheRequest, bytes: []const u8) void {
    const state: *CodeCacheState = @ptrCast(@alignCast(data.?));
    if (std.mem.startsWith(u8, request.module_id, managed.module_types.origine_prefix)) return;
    const alloc = state.host.allocator;
    const path = cachePath(alloc, request.module_id, state.tag, code_cache_extension) catch return;
    defer alloc.free(path);
    const file = alloc.alloc(u8, code_header_len + bytes.len) catch return;
    defer alloc.free(file);
    @memcpy(file[0..code_magic.len], code_magic);
    @memcpy(file[code_magic.len..][0..hash_len], &sourceHash(request.source));
    std.mem.writeInt(u64, file[code_magic.len + hash_len ..][0..8], bytes.len, .little);
    @memcpy(file[code_header_len..], bytes);
    writeAtomic(alloc, state.host.io, state.root, path, file) catch return;
    sweepStale(state.host.io, state.root, path);
}

