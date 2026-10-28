//! On-disk cache of the init snapshot, in the style of `__pycache__`: the snapshot of
//! `dir/init.js` lives in `dir/__oricache__/init.js.<engine>.v8-snapshot`. The first run of
//! an init creates it; later runs reuse it while neither the engine nor any module of the
//! init graph changed. Everything here is best effort: a cache that cannot be read or
//! written (read-only directory, corrupt file) is the same as no cache.
//!
//! A file is valid when (0) its first word (`meta`: layout version, features such as LZ4, parity)
//! is one this build can read, (1) its name carries this engine's tag, (2) its header holds the
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
const sys = @import("../managed/sys.zig");
const Host = @import("host.zig").Host;
const Blake3 = std.crypto.hash.Blake3;
const lz4_lib = @import("@lz4");
const config = @import("origine_config");

pub const dir_name = "__oricache__";
pub const extension = "v8-snapshot";
/// Bump when the file layout or the meaning of the key changes.
const format_version = 2;

/// `-Duser_snapshot=compressed` / `-Duser_codecache=compressed`: new files are stored LZ4-packed
/// (lib/lz4). Every file says how it is stored (`meta`), so a build reads either kind as long as it
/// links the LZ4 decoder, which only a build with one of the options does; any other build
/// rejects a packed file as a miss.
const snapshot_compressed = config.user_snapshot_compressed;
const code_cache_compressed = config.user_codecache_compressed;

/// The u32 at the start of every file in `__oricache__`, little-endian:
///
///   bits 0..3    layout version, always 0 for now; a reader rejects any other value
///   bits 4..30   features (`lz4`: the payload is an LZ4 pack); a reader rejects a file with a
///                feature it does not know or does not support, instead of misreading the payload
///   bit 31       even parity over the whole word (a flipped bit is always detected)
pub const meta = struct {
    pub const version_mask: u32 = 0x0000_000f;
    pub const feature_mask: u32 = 0x7fff_fff0;
    pub const parity_bit: u32 = 0x8000_0000;
    /// The payload is `lz4.pack` output (a length-prefixed LZ4 block).
    pub const lz4: u32 = 1 << 4;
    /// Bytes the word takes at the start of a file.
    pub const len = @sizeOf(u32);
    /// The features this build can read: LZ4 only when it links the decoder.
    pub const supported: u32 = if (snapshot_compressed or code_cache_compressed) lz4 else 0;

    pub const Error = error{
        /// The version bits are not 0: a layout this engine does not know.
        UnknownVersion,
        /// The parity bit disagrees with the word: a damaged file.
        BadParity,
        /// A feature this engine does not know or was built without.
        UnsupportedFeature,
    };

    /// The word for a file with `features` (only `feature_mask` bits).
    pub fn encode(features: u32) u32 {
        std.debug.assert(features & ~feature_mask == 0);
        return if (@popCount(features) % 2 == 0) features else features | parity_bit;
    }

    /// The features of a file whose first word is `word`, if this reader can read them
    /// (`can_read` is a set of feature bits). Never accepts a damaged or foreign word.
    pub fn decode(word: u32, can_read: u32) Error!u32 {
        if (@popCount(word) % 2 != 0) return error.BadParity;
        if (word & version_mask != 0) return error.UnknownVersion;
        const features = word & feature_mask;
        if (features & ~can_read != 0) return error.UnsupportedFeature;
        return features;
    }

    /// `decode` of the first four bytes of a file.
    pub fn read(bytes: *const [len]u8, can_read: u32) Error!u32 {
        return decode(std.mem.readInt(u32, bytes, .little), can_read);
    }
};

/// A new file: the `meta` word for `features`, then `payload`. The caller frees it with `alloc`.
fn withMeta(alloc: std.mem.Allocator, features: u32, payload: []const u8) ![]u8 {
    const file = try alloc.alloc(u8, meta.len + payload.len);
    std.mem.writeInt(u32, file[0..meta.len], meta.encode(features), .little);
    @memcpy(file[meta.len..], payload);
    return file;
}

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
pub fn engineKey(host: *const Host) Hash {
    var hasher = Blake3.init(.{});
    hasher.update(&.{format_version});
    hasher.update(v8.V8.getVersion());
    hasher.update(std.mem.asBytes(&v8.ScriptCompiler.cachedDataVersionTag()));
    var exe_buffer: [sys.max_path_bytes]u8 = undefined;
    if (sys.executablePath(&exe_buffer)) |len| {
        const exe = exe_buffer[0..len];
        hasher.update(exe);
        if (sys.Dir.cwd().statFile(exe, .{})) |stat| {
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

/// `__oricache__/<16 hex digits of BLAKE3(module id)>.<tag>.v8-code-cache`: the file of a module of a
/// graph's cache directory. The id only picks the name: a virtual id (`app:/x.js`, `https://...`) or
/// one with `..` in it can neither land outside `__oricache__` nor depend on the working directory.
/// The file itself holds the hash of the source it was made from, which is what makes it valid.
fn flatPath(alloc: std.mem.Allocator, module_id: []const u8, tag: [12]u8) ![]u8 {
    var digest: Hash = undefined;
    Blake3.hash(module_id, &digest, .{});
    const name = std.fmt.bytesToHex(digest[0..8].*, .lower);
    const file = try std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{ name, tag, code_cache_extension });
    defer alloc.free(file);
    return std.fs.path.join(alloc, &.{ dir_name, file });
}

/// Derives the snapshot entry for `init_specifier` (as the host imports it): the engine key
/// plus the specifier. Borrows host and specifier through return.
pub fn entryFor(alloc: std.mem.Allocator, host: *const Host, init_specifier: []const u8) !Entry {
    return entryWithKey(alloc, engineKey(host), init_specifier);
}

/// `entryFor` with an `engineKey` the caller already computed (it hashes every embedded
/// module, so a start computes it once). Borrows init_specifier through return.
pub fn entryWithKey(alloc: std.mem.Allocator, engine: Hash, init_specifier: []const u8) !Entry {
    var hasher = Blake3.init(.{});
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
    _ = data;
    const file = try sys.Dir.cwd().openFile(id, .{});
    defer file.close();
    var hasher = Blake3.init(.{});
    var buffer: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(&buffer, offset);
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
pub fn load(alloc: std.mem.Allocator, root: sys.Dir, entry: *const Entry, hasher: managed.init_snapshot.SourceHasher, why: ?*Miss) ?managed.init_snapshot.Image {
    return loadWith(alloc, root, entry, hasher, why, meta.supported);
}

/// `load` for a reader that can read the `meta` features in `can_read`.
pub fn loadWith(alloc: std.mem.Allocator, root: sys.Dir, entry: *const Entry, hasher: managed.init_snapshot.SourceHasher, why: ?*Miss, comptime can_read: u32) ?managed.init_snapshot.Image {
    var label: [128]u8 = undefined;
    const bytes = readSnapshot(alloc, root, entry.path, can_read) catch |err| {
        if (why) |out| out.* = switch (err) {
            error.FileNotFound => .no_file,
            error.UnknownVersion, error.UnsupportedFeature => .format_changed,
            else => .bad_file,
        };
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

/// Reads a regular cache file's snapshot (the bytes after its `meta` word) into one aligned,
/// caller-owned allocation. Borrows root/path through return; closes the file on every path and
/// frees partial reads on failure. The copy remains stable if the cache file is later
/// changed/truncated. Retains the 1 GiB limit and rejects size changes detected during the read.
/// A packed file is expanded and the packed copy released; one that does not expand is
/// `error.Corrupt`.
fn readSnapshot(alloc: std.mem.Allocator, root: sys.Dir, path: []const u8, comptime can_read: u32) ![]align(16) u8 {
    const file = try root.openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.kind != .file) return error.InvalidSnapshotFile;
    if (stat.size >= 1 << 30) return error.FileTooBig;
    const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    if (size < meta.len) return error.TruncatedFile;
    var word: [meta.len]u8 = undefined;
    if (try file.readPositionalAll(&word, 0) != meta.len) return error.SnapshotFileChanged;
    const features = try meta.read(&word, can_read);
    const bytes = try alloc.alignedAlloc(u8, managed.init_snapshot.alignment, size - meta.len);
    errdefer alloc.free(bytes);
    if (try file.readPositionalAll(bytes, meta.len) != bytes.len) return error.SnapshotFileChanged;
    var extra: [1]u8 = undefined;
    if (try file.readPositionalAll(&extra, stat.size) != 0) return error.SnapshotFileChanged;
    if (features & meta.lz4 == 0) return bytes;
    if (comptime can_read & meta.lz4 != 0) {
        // On failure the errdefer above releases the packed copy; on success it is released here.
        const expanded = try lz4_lib.unpack(alloc, bytes);
        alloc.free(bytes);
        return expanded;
    }
    return error.UnsupportedFeature;
}

/// The bytes of a cache file for `image`, in memory: the `meta` word, then the image (LZ4-packed
/// when `compress`, which needs a build with `-Duser_snapshot=compressed`: `error.Unsupported`
/// otherwise). The same bytes `store` writes. Caller frees with `alloc`; `image` stays the caller's.
pub fn encodeFile(alloc: std.mem.Allocator, image: *const managed.init_snapshot.Image, compress: bool) ![]u8 {
    if (compress) {
        if (comptime !snapshot_compressed) return error.Unsupported;
        const packed_bytes = try lz4_lib.pack(alloc, image.bytes);
        defer alloc.free(packed_bytes);
        return withMeta(alloc, meta.lz4, packed_bytes);
    }
    return withMeta(alloc, 0, image.bytes);
}

/// The snapshot inside the bytes of a cache file (`readSnapshot` for memory): checks the `meta`
/// word, expands a packed payload (`error.UnsupportedFeature` when this build cannot) and returns an
/// aligned copy owned by the caller. Borrows `file` for the call.
pub fn decodeFile(alloc: std.mem.Allocator, file: []const u8) ![]align(16) u8 {
    if (file.len < meta.len) return error.TruncatedFile;
    const features = try meta.read(file[0..meta.len], meta.supported);
    const payload = file[meta.len..];
    if (features & meta.lz4 == 0) {
        const bytes = try alloc.alignedAlloc(u8, managed.init_snapshot.alignment, payload.len);
        @memcpy(bytes, payload);
        return bytes;
    }
    if (comptime meta.supported & meta.lz4 != 0) return lz4_lib.unpack(alloc, payload);
    return error.UnsupportedFeature;
}

/// Writes the snapshot file under `root` atomically (temporary file in the same directory,
/// then rename) so a concurrent or interrupted run never sees a partial file. Creates
/// `__oricache__` on demand. Borrows everything; the caller keeps the image.
pub fn store(alloc: std.mem.Allocator, root: sys.Dir, entry: *const Entry, image: *const managed.init_snapshot.Image) !void {
    return storeWith(alloc, root, entry, image, snapshot_compressed);
}

/// `store` that keeps the snapshot LZ4-packed (`compressed`) or as it is. Only a `true`
/// instantiation links the compressor.
pub fn storeWith(alloc: std.mem.Allocator, root: sys.Dir, entry: *const Entry, image: *const managed.init_snapshot.Image, comptime compressed: bool) !void {
    const file = if (compressed) blk: {
        const packed_bytes = try lz4_lib.pack(alloc, image.bytes);
        defer alloc.free(packed_bytes);
        break :blk try withMeta(alloc, meta.lz4, packed_bytes);
    } else try withMeta(alloc, 0, image.bytes);
    defer alloc.free(file);
    try writeAtomic(alloc, root, entry.path, file);
    sweepStale(root, entry.path);
}

/// Deletes every cache file in the directory of `current_path` that another engine made:
/// `name.<tag>.v8-snapshot` and `name.<tag>.v8-code-cache` whose 12-hex-digit tag differs
/// from the one in `current_path`. Files of other sources are swept too, so rebuilding or
/// upgrading origine does not leave caches that can never be read again. Anything else in the
/// directory is left alone. Best effort; borrows root and path for the call.
fn sweepStale(root: sys.Dir, current_path: []const u8) void {
    const dir_path = std.fs.path.dirname(current_path) orelse return;
    const current_tag = tagOfName(std.fs.path.basename(current_path)) orelse return;
    var dir = root.openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch return) |item| {
        if (item.kind != .file) continue;
        const tag = tagOfName(item.name) orelse continue;
        if (std.mem.eql(u8, tag, current_tag)) continue;
        dir.deleteFile(item.name) catch {};
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
fn writeAtomic(alloc: std.mem.Allocator, root: sys.Dir, path: []const u8, data: []const u8) !void {
    try root.createDirPath(std.fs.path.dirname(path).?);
    const temporary = try std.fmt.allocPrint(alloc, "{s}.{d}.tmp", .{ path, std.c.getpid() });
    defer alloc.free(temporary);
    errdefer root.deleteFile(temporary) catch {};
    try root.writeFile(.{ .sub_path = temporary, .data = data });
    try root.rename(temporary, root, path);
}

// Code cache: one file per source module, `dir/__oricache__/name.<tag>.v8-code-cache`.
// Layout: `meta` word, Blake3 of the exact source text, payload length (u32 LE), V8's bytes (the
// header is 40 bytes so they stay 8-aligned), or with the `lz4` feature those bytes LZ4-packed.

pub const code_cache_extension = "v8-code-cache";
const code_header_len = meta.len + hash_len + @sizeOf(u32);
comptime {
    std.debug.assert(code_header_len % 8 == 0);
}

/// State behind the `CodeCache` hook for one Host and engine. Keep it at a stable address
/// until `Runtime.destroy` returns.
pub const CodeCacheState = struct {
    host: *Host,
    tag: [12]u8,
    root: sys.Dir,
    /// Where a module's cache file goes: `beside` its source (`dir/__oricache__/name.<tag>.<ext>`, for
    /// the files of the init's working directory), or `flat` in `root/__oricache__` under a name made
    /// from the module id, whatever the id looks like (a graph's cache directory, see `flatPath`).
    layout: enum { beside, flat } = .beside,

    pub fn init(host: *Host, root: sys.Dir) CodeCacheState {
        return initWithKey(engineKey(host), host, root);
    }

    /// A state for a graph's cache directory: every file is `root/__oricache__/<id hash>.<tag>.<ext>`.
    pub fn initFlat(host: *Host, root: sys.Dir) CodeCacheState {
        var state = initWithKey(engineKey(host), host, root);
        state.layout = .flat;
        return state;
    }

    /// `init` with an `engineKey` the caller already computed.
    pub fn initWithKey(engine: Hash, host: *Host, root: sys.Dir) CodeCacheState {
        return .{ .host = host, .tag = tagOf(engine), .root = root };
    }

    fn pathOf(self: *const CodeCacheState, alloc: std.mem.Allocator, module_id: []const u8) ![]u8 {
        return switch (self.layout) {
            .beside => cachePath(alloc, module_id, self.tag, code_cache_extension),
            .flat => flatPath(alloc, module_id, self.tag),
        };
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
    if (!cacheable(request.module_id)) return null;
    const path = state.pathOf(request.allocator, request.module_id) catch return null;
    const file = state.root.readFileAllocOptions(path, request.allocator, .limited(1 << 28), .@"8", null) catch return null;
    return decodeCode(request.allocator, file, request.source, meta.supported);
}

/// The code-cache file for `bytes` compiled from `source`: header, then the bytes as they are or
/// (`compressed`) LZ4-packed. The caller frees the result with `alloc`.
pub fn encodeCode(alloc: std.mem.Allocator, source: []const u8, bytes: []const u8, comptime compressed: bool) ![]u8 {
    const payload = if (compressed) try lz4_lib.pack(alloc, bytes) else bytes;
    defer if (compressed) alloc.free(payload);
    const length = std.math.cast(u32, payload.len) orelse return error.FileTooBig;
    const file = try alloc.alloc(u8, code_header_len + payload.len);
    errdefer alloc.free(file);
    std.mem.writeInt(u32, file[0..meta.len], meta.encode(if (compressed) meta.lz4 else 0), .little);
    @memcpy(file[meta.len..][0..hash_len], &sourceHash(source));
    std.mem.writeInt(u32, file[meta.len + hash_len ..][0..@sizeOf(u32)], length, .little);
    @memcpy(file[code_header_len..], payload);
    return file;
}

/// V8's bytes from a code-cache `file` (owned by `alloc`, 8-aligned) as `encodeCode` wrote it,
/// or null when the header, a feature the reader (`can_read`) lacks, the source hash or the
/// payload does not match. Takes `file`: the result is a view into it, or (packed) a new
/// allocation after `file` is released. Result lives in `alloc`.
pub fn decodeCode(alloc: std.mem.Allocator, file: []align(8) u8, source: []const u8, comptime can_read: u32) ?[]const u8 {
    if (file.len < code_header_len) return null;
    const features = meta.read(file[0..meta.len], can_read) catch return null;
    if (!std.mem.eql(u8, file[meta.len..][0..hash_len], &sourceHash(source))) return null;
    const length = std.mem.readInt(u32, file[meta.len + hash_len ..][0..@sizeOf(u32)], .little);
    if (length != file.len - code_header_len) return null;
    const payload = file[code_header_len..];
    if (features & meta.lz4 == 0) return payload;
    if (comptime can_read & meta.lz4 != 0) {
        defer alloc.free(file);
        return lz4_lib.unpack(alloc, payload) catch null;
    }
    return null;
}

/// File-backed modules and each host glue script get code caches; the embedded `origine:`
/// ES modules are covered by the init snapshot. Borrows the ID through return; retains nothing.
fn cacheable(module_id: []const u8) bool {
    if (!std.mem.startsWith(u8, module_id, managed.module_types.origine_prefix)) return true;
    inline for (std.enums.values(glue.Module)) |module| {
        if (std.mem.eql(u8, module_id, glue.script(module).cache_id)) return true;
    }
    return false;
}

const glue = @import("glue.zig");

/// Hook `store`: writes the code cache of a file-backed module next to its source. Best
/// effort; any failure just means no cache next time.
fn storeCode(data: ?*anyopaque, request: managed.module_types.CodeCacheRequest, bytes: []const u8) void {
    const state: *CodeCacheState = @ptrCast(@alignCast(data.?));
    if (!cacheable(request.module_id)) return;
    const alloc = state.host.allocator;
    const path = state.pathOf(alloc, request.module_id) catch return;
    defer alloc.free(path);
    const file = encodeCode(alloc, request.source, bytes, code_cache_compressed) catch return;
    defer alloc.free(file);
    writeAtomic(alloc, state.root, path, file) catch return;
    sweepStale(state.root, path);
}
