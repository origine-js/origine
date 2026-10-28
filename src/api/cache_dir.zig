//! The global cache directory: where the init snapshots and code caches live, how big it may grow
//! and how files get into and out of it. Policy only (environment, budget, LRU); the formats are
//! `init_cache.zig`'s.
//!
//! Files sit directly in one directory under content-derived names. A writer makes
//! `<name>.<hash of pid, process nonce, writer id, counter>.tmp` beside the final name and renames it
//! into place, so processes and isolates can store the same name at once and a reader sees a whole
//! file or none. Recency is the file's modification time, refreshed when a file is read after being
//! idle for a while; `evict` deletes the least recently used files when the directory is over budget.
const std = @import("std");
const sys = @import("../managed/sys.zig");
const Blake3 = std.crypto.hash.Blake3;

const ns_per_s: i128 = std.time.ns_per_s;

/// 1200 MiB.
pub const default_budget: u64 = 1200 << 20;
/// A file read after being idle this long gets its modification time refreshed (not on every read:
/// a start reads hundreds of files).
pub const touch_after_ns: i128 = 10 * 60 * ns_per_s;
/// `evict` never deletes a file younger than this: a concurrent writer's fresh file stays.
pub const min_age_ns: i128 = 10 * ns_per_s;
/// A temporary file this old belongs to a writer that died.
pub const stale_temporary_ns: i128 = 60 * 60 * ns_per_s;
/// `evict` goes down to this share of the budget, so the next cold run does not scan again.
pub const evict_to_percent: u64 = 90;

pub const snapshot_extension = ".v8-snapshot";
pub const code_extension = ".v8-code-cache";

/// What the environment decided. `dir_path` is owned.
pub const Settings = struct {
    /// Where the cache lives; null when no location could be worked out (the CLI then runs without one).
    dir_path: ?[]u8,
    /// Most bytes the directory may hold. 0 means nothing is ever stored.
    budget: u64,
    /// `ORIGINE_NO_SNAPSHOT` is not set: the init-js snapshot is used.
    snapshot: bool,
    /// `ORIGINE_NO_CODE_CACHE` is not set: V8 code caches (modules and glue) are used.
    code: bool,

    pub fn deinit(self: *Settings, alloc: std.mem.Allocator) void {
        if (self.dir_path) |path| alloc.free(path);
        self.* = undefined;
    }
};

/// Reads `ORIGINE_CACHE_DIR`, `XDG_CACHE_HOME`, `HOME`, `ORIGINE_CACHE_BUDGET`, `ORIGINE_NO_SNAPSHOT`
/// and `ORIGINE_NO_CODE_CACHE`. Borrows `environ` for the call.
pub fn settingsFrom(alloc: std.mem.Allocator, environ: *const std.process.Environ.Map) !Settings {
    const budget = if (environ.get("ORIGINE_CACHE_BUDGET")) |text| parseBudget(text) orelse default_budget else default_budget;
    return .{
        .dir_path = try resolveDirPath(alloc, environ),
        .budget = budget,
        .snapshot = environ.get("ORIGINE_NO_SNAPSHOT") == null,
        .code = environ.get("ORIGINE_NO_CODE_CACHE") == null,
    };
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (text.len == 0) null else text;
}

/// `ORIGINE_CACHE_DIR` as given, else `$XDG_CACHE_HOME/origine/code_caches`, else
/// `$HOME/.cache/origine/code_caches`, else null. The result is owned by the caller.
pub fn resolveDirPath(alloc: std.mem.Allocator, environ: *const std.process.Environ.Map) !?[]u8 {
    if (nonEmpty(environ.get("ORIGINE_CACHE_DIR"))) |dir| return try alloc.dupe(u8, dir);
    if (nonEmpty(environ.get("XDG_CACHE_HOME"))) |base| return try std.fs.path.join(alloc, &.{ base, "origine", "code_caches" });
    if (nonEmpty(environ.get("HOME"))) |home| return try std.fs.path.join(alloc, &.{ home, ".cache", "origine", "code_caches" });
    return null;
}

/// A size in bytes: digits with an optional fraction and a unit, `K`, `M`, `G` or `T` (all powers of
/// 1024), optionally followed by `i` and/or `B`, in any case: `1200M`, `1.2GiB`, `512 kb`, `1288490188`.
/// Null for anything else.
pub fn parseBudget(text: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    var split: usize = 0;
    while (split < trimmed.len and (std.ascii.isDigit(trimmed[split]) or trimmed[split] == '.')) split += 1;
    if (split == 0) return null;
    const number = std.fmt.parseFloat(f64, trimmed[0..split]) catch return null;
    var unit_buffer: [4]u8 = undefined;
    const unit_text = std.mem.trim(u8, trimmed[split..], " \t");
    if (unit_text.len > unit_buffer.len) return null;
    const unit = std.ascii.lowerString(&unit_buffer, unit_text);
    const shift: u6 = blk: {
        const units = [_]struct { name: []const u8, shift: u6 }{
            .{ .name = "", .shift = 0 },     .{ .name = "b", .shift = 0 },
            .{ .name = "k", .shift = 10 },   .{ .name = "kb", .shift = 10 },
            .{ .name = "kib", .shift = 10 }, .{ .name = "m", .shift = 20 },
            .{ .name = "mb", .shift = 20 },  .{ .name = "mib", .shift = 20 },
            .{ .name = "g", .shift = 30 },   .{ .name = "gb", .shift = 30 },
            .{ .name = "gib", .shift = 30 }, .{ .name = "t", .shift = 40 },
            .{ .name = "tb", .shift = 40 },  .{ .name = "tib", .shift = 40 },
        };
        for (units) |candidate| if (std.mem.eql(u8, unit, candidate.name)) break :blk candidate.shift;
        return null;
    };
    const bytes = number * @as(f64, @floatFromInt(@as(u64, 1) << shift));
    if (!std.math.isFinite(bytes) or bytes >= 9.0e18) return null;
    return @intFromFloat(bytes);
}

/// Opens (creating it when missing) the cache directory at `path`, relative to the working directory
/// or absolute. Null when it cannot be created or opened: the caller runs without a cache.
pub fn openDir(path: []const u8) ?sys.Dir {
    const cwd = sys.Dir.cwd();
    cwd.createDirPath(path) catch return null;
    return cwd.openDir(path, .{ .iterate = true }) catch null;
}

// ---- writing --------------------------------------------------------------------------------

var temporary_counter: std.atomic.Value(u32) = .init(0);
var nonce_state: std.atomic.Value(u64) = .init(0);
/// Bytes this process stored; `evict` only runs when something was.
var stored_bytes: std.atomic.Value(u64) = .init(0);

/// A number that differs between processes even when pids repeat: computed once per process.
fn processNonce() u64 {
    const known = nonce_state.load(.acquire);
    if (known != 0) return known;
    var hasher = Blake3.init(.{});
    const now = sys.realtimeNs();
    hasher.update(std.mem.asBytes(&now));
    const pid = std.c.getpid();
    hasher.update(std.mem.asBytes(&pid));
    hasher.update(std.mem.asBytes(&@intFromPtr(&nonce_state)));
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const value = std.mem.readInt(u64, digest[0..8], .little) | 1;
    return if (nonce_state.cmpxchgStrong(0, value, .acq_rel, .acquire)) |winner| winner else value;
}

/// The temporary name for a write of `final` by `writer_id` (the isolate: 0 for the first): the
/// final name, 16 hex digits of a hash of the pid, the process nonce, the writer and a counter, `.tmp`.
/// Caller frees with `alloc`.
pub fn temporaryName(alloc: std.mem.Allocator, final: []const u8, writer_id: u32) ![]u8 {
    var hasher = Blake3.init(.{});
    const pid = std.c.getpid();
    const nonce = processNonce();
    const counter = temporary_counter.fetchAdd(1, .monotonic);
    hasher.update(std.mem.asBytes(&pid));
    hasher.update(std.mem.asBytes(&nonce));
    hasher.update(std.mem.asBytes(&writer_id));
    hasher.update(std.mem.asBytes(&counter));
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const suffix = std.fmt.bytesToHex(digest[0..8].*, .lower);
    return std.fmt.allocPrint(alloc, "{s}.{s}.tmp", .{ final, suffix });
}

/// Writes `data` as `subdir/name` (or `name` when `subdir` is empty) under `dir`: a uniquely named
/// temporary file beside it, then an atomic rename; creates `subdir` on demand. Counts the bytes
/// towards `wroteSomething`. Borrows everything.
pub fn writeAtomic(alloc: std.mem.Allocator, dir: sys.Dir, subdir: []const u8, name: []const u8, data: []const u8, writer_id: u32) !void {
    if (subdir.len != 0) try dir.createDirPath(subdir);
    const final = if (subdir.len == 0) try alloc.dupe(u8, name) else try std.fs.path.join(alloc, &.{ subdir, name });
    defer alloc.free(final);
    const temporary = try temporaryName(alloc, final, writer_id);
    defer alloc.free(temporary);
    errdefer dir.deleteFile(temporary) catch {};
    try dir.writeFile(.{ .sub_path = temporary, .data = data });
    try dir.rename(temporary, dir, final);
    _ = stored_bytes.fetchAdd(data.len, .monotonic);
}

/// Whether this process stored anything since `resetStored`.
pub fn wroteSomething() bool {
    return stored_bytes.load(.monotonic) != 0;
}

pub fn resetStored() void {
    stored_bytes.store(0, .monotonic);
}

/// Deletes `path` under `dir`, ignoring failure (a cache file that is gone is what was wanted).
pub fn deleteQuiet(dir: sys.Dir, path: []const u8) void {
    dir.deleteFile(path) catch {};
}

/// Marks a file as used now if it was last used `touch_after_ns` ago or more. Best effort.
pub fn touchIfIdle(file: sys.File, mtime_ns: i128, now_ns: i128) void {
    if (now_ns - mtime_ns < touch_after_ns) return;
    file.setTimes(now_ns, now_ns) catch {};
}

// ---- eviction -------------------------------------------------------------------------------

pub const EvictStats = struct {
    /// Cache files found and their size.
    files: usize = 0,
    bytes: u64 = 0,
    /// Files deleted (cache files over budget, abandoned temporary files) and the cache bytes freed.
    deleted: usize = 0,
    freed: u64 = 0,
};

const Candidate = struct {
    name: []u8,
    size: u64,
    mtime_ns: i128,

    fn older(_: void, a: Candidate, b: Candidate) bool {
        if (a.mtime_ns != b.mtime_ns) return a.mtime_ns < b.mtime_ns;
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

fn endsWith(name: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, name, suffix);
}

/// Brings the cache files of `dir` (`*.v8-snapshot`, `*.v8-code-cache`) down to 90% of `budget` bytes
/// when they hold more, deleting the least recently used first (oldest modification time, then name),
/// never one younger than `min_age_ns`. Also deletes temporary files older than `stale_temporary_ns`.
/// Any other file is left alone and not counted. Races with other processes are harmless: a file that
/// is already gone is skipped. `now_ns` is the current wall-clock time (a parameter for tests).
pub fn evict(alloc: std.mem.Allocator, dir: sys.Dir, budget: u64, now_ns: i128) !EvictStats {
    var stats: EvictStats = .{};
    var found: std.ArrayList(Candidate) = .empty;
    defer {
        for (found.items) |item| alloc.free(item.name);
        found.deinit(alloc);
    }
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const is_cache = endsWith(entry.name, snapshot_extension) or endsWith(entry.name, code_extension);
        const is_temporary = endsWith(entry.name, ".tmp");
        if (!is_cache and !is_temporary) continue;
        const stat = dir.statFile(entry.name, .{}) catch continue;
        const mtime: i128 = stat.mtime.nanoseconds;
        if (is_temporary) {
            if (now_ns - mtime >= stale_temporary_ns) deleteQuiet(dir, entry.name);
            continue;
        }
        try found.append(alloc, .{ .name = try alloc.dupe(u8, entry.name), .size = stat.size, .mtime_ns = mtime });
        stats.files += 1;
        stats.bytes += stat.size;
    }
    if (stats.bytes <= budget) return stats;
    std.mem.sort(Candidate, found.items, {}, Candidate.older);
    const target: u64 = @intCast(@as(u128, budget) * evict_to_percent / 100);
    var remaining = stats.bytes;
    for (found.items) |item| {
        if (remaining <= target) break;
        // Sorted by age: everything after this is younger still.
        if (now_ns - item.mtime_ns < min_age_ns) break;
        dir.deleteFile(item.name) catch continue;
        remaining -= item.size;
        stats.deleted += 1;
        stats.freed += item.size;
    }
    return stats;
}
