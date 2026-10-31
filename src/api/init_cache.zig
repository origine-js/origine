//! The files of the global cache (`cache_dir.zig` decides where it is and how big it may grow):
//! init snapshots and V8 code caches, named by a hash of what they were made from, so any number of
//! projects, processes and isolates share one directory.
//!
//! - **Code cache** `<hash>.v8-code-cache`: the hash covers the runtime fingerprint (`engineKey`: V8
//!   build and flags, this executable, the embedded modules), whether it is a module or a host glue
//!   script, and the exact source text. Identical sources share a file, whatever their path.
//! - **Init snapshot** `<hash>.v8-snapshot`: the hash covers the fingerprint, the init specifier and
//!   the working directory (module ids in the snapshot are relative to it). The header holds a key
//!   without the working directory, and the table of every module of the graph with its source hash:
//!   a changed source makes the file stale and the new snapshot replaces it under the same name.
//!
//! A file is valid when (0) its first word (`meta`: layout version, features such as LZ4, parity)
//! is one this build can read, (1) its header holds the key, and (2) the sources it was made from
//! still hash as recorded. A file that fails validation, or that V8 rejects, is deleted on the spot;
//! a file nobody reads ages out through `cache_dir.evict`. Everything here is best effort: a cache
//! that cannot be read or written is the same as no cache.
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

const cache_dir = @import("cache_dir.zig");

pub const extension = cache_dir.snapshot_extension[1..];
/// Bump when the file layout or the meaning of the key changes.
const format_version = 3;

/// `-Duser_snapshot=compressed` / `-Duser_codecache=compressed`: new files are stored LZ4-packed
/// (lib/lz4). Every file says how it is stored (`meta`), so a build reads either kind as long as it
/// links the LZ4 decoder, which only a build with one of the options does; any other build
/// rejects a packed file as a miss.
const snapshot_compressed = config.user_snapshot_compressed;
const code_cache_compressed = config.user_codecache_compressed;

/// The u32 at the start of every file in the cache, little-endian:
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

/// Where one init's snapshot lives and what it must match. Owns `name`.
pub const Entry = struct {
    alloc: std.mem.Allocator,
    /// `<32 hex digits>.v8-snapshot`, a file directly in the cache directory.
    name: []const u8,
    /// What the file header must hold: the fingerprint and the init specifier.
    key: Hash,

    pub fn deinit(self: *Entry) void {
        self.alloc.free(self.name);
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

/// `engineKey`, computed once per Host (it hashes every embedded module).
pub fn cachedEngineKey(host: *Host) Hash {
    if (host.engine_key) |known| return known;
    const key = engineKey(host);
    host.engine_key = key;
    return key;
}

/// What the snapshot header records about the engine: the file layout version and a label
/// naming the V8 build and its code-cache format tag. `buffer` backs the label.
pub fn identity(buffer: []u8) managed.init_snapshot.Identity {
    const label = std.fmt.bufPrint(buffer, "v8 {s} cache-tag {x}", .{ v8.V8.getVersion(), v8.ScriptCompiler.cachedDataVersionTag() }) catch buffer[0..0];
    return .{ .format = format_version, .engine = label };
}

/// 32 lowercase hex digits of the start of a digest.
fn hex32(digest: Hash) [32]u8 {
    return std.fmt.bytesToHex(digest[0..16].*, .lower);
}

/// Derives the snapshot entry for `init_specifier` (as the host imports it) run from the working
/// directory `cwd`. Borrows host and specifier through return.
pub fn entryFor(alloc: std.mem.Allocator, host: *Host, init_specifier: []const u8) !Entry {
    var cwd_buffer: [sys.max_path_bytes]u8 = undefined;
    const cwd = if (sys.currentDirPath(&cwd_buffer)) |len| cwd_buffer[0..len] else |_| "";
    return entryWithKey(alloc, cachedEngineKey(host), init_specifier, cwd);
}

/// `entryFor` with a fingerprint the caller already has and an explicit working directory. The
/// header key leaves the directory out (so a snapshot exported from one directory loads in another
/// that has the same sources); the file name has it in, because module ids are relative to it.
/// Borrows init_specifier and cwd through return.
pub fn entryWithKey(alloc: std.mem.Allocator, engine: Hash, init_specifier: []const u8, cwd: []const u8) !Entry {
    var hasher = Blake3.init(.{});
    hasher.update(&engine);
    hasher.update(init_specifier);
    var key: Hash = undefined;
    hasher.final(&key);
    var named = Blake3.init(.{});
    named.update("snapshot\x00");
    named.update(&.{format_version});
    named.update(&key);
    named.update(cwd);
    var digest: Hash = undefined;
    named.final(&digest);
    return .{ .alloc = alloc, .name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ hex32(digest), cache_dir.snapshot_extension }), .key = key };
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

/// Reads and validates the cached snapshot `entry.name` in the cache directory `root`. Returns null
/// on any miss and says why in `why` when given; a file that exists but does not fit (any miss but
/// `no_file`) is deleted, and a hit refreshes the file's use time. Files from another version are
/// rejected, never migrated. Borrows root, entry and hasher through return; the result owns its
/// bytes (release with `Image.deinit`).
pub fn load(alloc: std.mem.Allocator, root: sys.Dir, entry: *const Entry, hasher: managed.init_snapshot.SourceHasher, why: ?*Miss) ?managed.init_snapshot.Image {
    return loadWith(alloc, root, entry, hasher, why, meta.supported);
}

/// `load` for a reader that can read the `meta` features in `can_read`.
pub fn loadWith(alloc: std.mem.Allocator, root: sys.Dir, entry: *const Entry, hasher: managed.init_snapshot.SourceHasher, why: ?*Miss, comptime can_read: u32) ?managed.init_snapshot.Image {
    var label: [128]u8 = undefined;
    const bytes = readSnapshot(alloc, root, entry.name, can_read) catch |err| {
        if (why) |out| out.* = switch (err) {
            error.FileNotFound => .no_file,
            error.UnknownVersion, error.UnsupportedFeature => .format_changed,
            else => .bad_file,
        };
        if (err != error.FileNotFound) cache_dir.deleteQuiet(root, entry.name);
        return null;
    };
    var image = managed.init_snapshot.parse(alloc, bytes, entry.key, identity(&label)) catch |err| {
        alloc.free(bytes);
        cache_dir.deleteQuiet(root, entry.name);
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
        cache_dir.deleteQuiet(root, entry.name);
        if (why) |out| out.* = .source_changed;
        return null;
    }
    touch(root, entry.name);
    return image;
}

/// Reads a regular cache file's snapshot (the bytes after its `meta` word) into one aligned,
/// caller-owned allocation. Borrows root/path through return; closes the file on every path and
/// frees partial reads on failure. The copy remains stable if the cache file is later
/// changed/truncated. Retains the 1 GiB limit and rejects size changes detected during the read.
/// A packed file is expanded and the packed copy released; one that does not expand is
/// `error.Corrupt`.
/// Refreshes the use time of `name` (a hit) when it has been idle for a while. Best effort.
fn touch(root: sys.Dir, name: []const u8) void {
    const file = root.openFile(name, .{}) catch return;
    defer file.close();
    const stat = file.stat() catch return;
    cache_dir.touchIfIdle(file, stat.mtime.nanoseconds, sys.realtimeNs());
}

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

/// Writes the snapshot file `entry.name` into the cache directory `root` atomically (see
/// `cache_dir.writeAtomic`), replacing a stale one. `writer_id` names the writer (the isolate) in the
/// temporary file's name. Borrows everything; the caller keeps the image.
pub fn store(alloc: std.mem.Allocator, root: sys.Dir, entry: *const Entry, image: *const managed.init_snapshot.Image, writer_id: u32) !void {
    return storeWith(alloc, root, entry, image, snapshot_compressed, writer_id);
}

/// `store` that keeps the snapshot LZ4-packed (`compressed`) or as it is. Only a `true`
/// instantiation links the compressor.
pub fn storeWith(alloc: std.mem.Allocator, root: sys.Dir, entry: *const Entry, image: *const managed.init_snapshot.Image, comptime compressed: bool, writer_id: u32) !void {
    const file = if (compressed) blk: {
        const packed_bytes = try lz4_lib.pack(alloc, image.bytes);
        defer alloc.free(packed_bytes);
        break :blk try withMeta(alloc, meta.lz4, packed_bytes);
    } else try withMeta(alloc, 0, image.bytes);
    defer alloc.free(file);
    try cache_dir.writeAtomic(alloc, root, "", entry.name, file, writer_id);
}

// Code cache: one file per distinct source text, `<hash>.v8-code-cache` (see the top of this file).
// Layout: `meta` word, Blake3 of the exact source text, payload length (u32 LE), V8's bytes (the
// header is 40 bytes so they stay 8-aligned), or with the `lz4` feature those bytes LZ4-packed.

pub const code_cache_extension = cache_dir.code_extension[1..];
const code_header_len = meta.len + hash_len + @sizeOf(u32);
comptime {
    std.debug.assert(code_header_len % 8 == 0);
}

/// State behind the `CodeCache` hook for one Host and engine. Keep it at a stable address
/// until `Runtime.destroy` returns.
pub const CodeCacheState = struct {
    host: *Host,
    /// The runtime fingerprint (`engineKey`) every file name covers.
    fp: Hash,
    /// The directory the files live in.
    root: sys.Dir,
    /// A directory inside `root` that holds the files (empty: directly in `root`, the global cache).
    subdir: []const u8 = "",
    owns_subdir: bool = false,
    /// Names the writer (the isolate) in temporary file names; 0 for the first isolate.
    writer_id: u32 = 0,
    /// False stores nothing (a cache budget of 0); files are still read.
    writable: bool = true,
    /// The startup blob the runtime booted from when it is not the engine's own (an init snapshot):
    /// V8 accepts a code cache only from an isolate booted from the same blob, so the name covers it.
    boot: ?Hash = null,

    pub fn init(host: *Host, root: sys.Dir) CodeCacheState {
        return initWithKey(cachedEngineKey(host), host, root);
    }

    /// A state for a `CodeCache.dir` cache: files are `root/<path>/<hash>.v8-code-cache`. `path` is
    /// copied (free it with `deinit`).
    pub fn initIn(host: *Host, root: sys.Dir, path: []const u8) !CodeCacheState {
        var state = init(host, root);
        state.subdir = try host.allocator.dupe(u8, path);
        state.owns_subdir = true;
        return state;
    }

    pub fn deinit(self: *CodeCacheState) void {
        if (self.owns_subdir) self.host.allocator.free(self.subdir);
        self.subdir = "";
        self.owns_subdir = false;
    }

    /// `init` with a fingerprint the caller already has.
    pub fn initWithKey(engine: Hash, host: *Host, root: sys.Dir) CodeCacheState {
        return .{ .host = host, .fp = engine, .root = root, .writer_id = if (host.link) |link| link.identity else 0 };
    }

    /// `[subdir/]<name>` for the file of `request`. Caller frees with `alloc`.
    fn pathOf(self: *const CodeCacheState, alloc: std.mem.Allocator, request: managed.module_types.CodeCacheRequest) ![]u8 {
        const name = codeFileName(self.fp, self.boot, isGlue(request.module_id), request.source);
        if (self.subdir.len == 0) return alloc.dupe(u8, &name);
        return std.fs.path.join(alloc, &.{ self.subdir, &name });
    }

    /// The hook to put into `Scope.Options.code_cache`; borrows self (stable address).
    pub fn hook(self: *CodeCacheState) managed.module_types.CodeCache {
        return .{ .data = self, .load = loadCode, .store = storeCode, .rejected = rejectedCode };
    }
};

/// The digest that names a startup blob in `CodeCacheState.boot`.
pub fn blobDigest(blob: []const u8) Hash {
    var digest: Hash = undefined;
    Blake3.hash(blob, &digest, .{});
    return digest;
}

/// `<32 hex digits>.v8-code-cache` for a source text: the hash covers the fingerprint, the startup blob
/// the runtime booted from (null: the engine's own), whether it is
/// a host glue ES module (V8 hashes the origin options into its own check, so the same text compiled the
/// other way is a different cache) and the exact text.
pub fn codeFileName(fp: Hash, boot: ?Hash, glue_script: bool, source: []const u8) [32 + cache_dir.code_extension.len]u8 {
    var hasher = Blake3.init(.{});
    hasher.update("code\x00");
    hasher.update(&fp);
    hasher.update(&(boot orelse std.mem.zeroes(Hash)));
    hasher.update(&.{@intFromBool(glue_script)});
    hasher.update(source);
    var digest: Hash = undefined;
    hasher.final(&digest);
    var name: [32 + cache_dir.code_extension.len]u8 = undefined;
    @memcpy(name[0..32], &hex32(digest));
    @memcpy(name[32..], cache_dir.code_extension);
    return name;
}

fn isGlue(module_id: []const u8) bool {
    return std.mem.startsWith(u8, module_id, managed.module_types.origine_prefix);
}

fn sourceHash(source: []const u8) Hash {
    var out: Hash = undefined;
    Blake3.hash(source, &out, .{});
    return out;
}

/// Hook `load`: the cached bytes for a module whose source text has a cache file, else null. A file
/// that does not decode (damaged, or another format) is deleted; a hit refreshes the file's use time.
/// Embedded `origine:` modules are not cached on disk. Result lives in request.allocator.
fn loadCode(data: ?*anyopaque, request: managed.module_types.CodeCacheRequest) ?[]const u8 {
    const state: *CodeCacheState = @ptrCast(@alignCast(data.?));
    if (!cacheable(request.module_id)) return null;
    const path = state.pathOf(request.allocator, request) catch return null;
    const file = state.root.openFile(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    if (stat.kind != .file or stat.size >= 1 << 28) return null;
    const size = std.math.cast(usize, stat.size) orelse return null;
    const bytes = request.allocator.alignedAlloc(u8, .@"8", size) catch return null;
    if ((file.readPositionalAll(bytes, 0) catch return null) != size) return null;
    const payload = decodeCode(request.allocator, bytes, request.source, meta.supported) orelse {
        cache_dir.deleteQuiet(state.root, path);
        return null;
    };
    cache_dir.touchIfIdle(file, stat.mtime.nanoseconds, sys.realtimeNs());
    return payload;
}

/// Hook `rejected`: V8 refused the bytes `load` returned (another build or flag set that the
/// fingerprint did not tell apart), so the file can never be used again: delete it. The compile that
/// just ran produces a fresh cache, which `store` writes under the same name.
fn rejectedCode(data: ?*anyopaque, request: managed.module_types.CodeCacheRequest) void {
    const state: *CodeCacheState = @ptrCast(@alignCast(data.?));
    const path = state.pathOf(request.allocator, request) catch return;
    cache_dir.deleteQuiet(state.root, path);
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

/// File-backed modules and each host glue ES module get code caches; the embedded `origine:`
/// ES modules are covered by the init snapshot. Borrows the ID through return; retains nothing.
fn cacheable(module_id: []const u8) bool {
    if (!std.mem.startsWith(u8, module_id, managed.module_types.origine_prefix)) return true;
    inline for (std.enums.values(glue.Module)) |module| {
        if (std.mem.eql(u8, module_id, glue.script(module).cache_id)) return true;
    }
    return false;
}

const glue = @import("glue.zig");

/// Hook `store`: writes the code cache of a module under the name of its source text. Best effort;
/// any failure just means no cache next time.
fn storeCode(data: ?*anyopaque, request: managed.module_types.CodeCacheRequest, bytes: []const u8) void {
    const state: *CodeCacheState = @ptrCast(@alignCast(data.?));
    if (!state.writable or !cacheable(request.module_id)) return;
    const alloc = state.host.allocator;
    const name = codeFileName(state.fp, state.boot, isGlue(request.module_id), request.source);
    const file = encodeCode(alloc, request.source, bytes, code_cache_compressed) catch return;
    defer alloc.free(file);
    cache_dir.writeAtomic(alloc, state.root, state.subdir, &name, file, state.writer_id) catch return;
}
