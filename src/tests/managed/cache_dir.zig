const std = @import("std");
const t = std.testing;
const m = @import("@managed");

const cache_dir = m.Api.cache_dir;
const ns: i128 = std.time.ns_per_s;

test "cache dir: budgets parse with units, fractions and case" {
    try t.expectEqual(@as(?u64, 1288490188), cache_dir.parseBudget("1288490188"));
    try t.expectEqual(@as(?u64, 1200 << 20), cache_dir.parseBudget("1200M"));
    try t.expectEqual(@as(?u64, 1200 << 20), cache_dir.parseBudget("1200 MiB"));
    try t.expectEqual(@as(?u64, 1 << 30), cache_dir.parseBudget("1g"));
    try t.expectEqual(@as(?u64, 512 << 10), cache_dir.parseBudget("512kb"));
    try t.expectEqual(@as(?u64, 1 << 40), cache_dir.parseBudget(" 1 TiB "));
    try t.expectEqual(@as(?u64, 1_610_612_736), cache_dir.parseBudget("1.5G"));
    try t.expectEqual(@as(?u64, 0), cache_dir.parseBudget("0"));
    try t.expectEqual(@as(?u64, 7), cache_dir.parseBudget("7B"));
    for ([_][]const u8{ "", "abc", "-5", "1x", "1.2.3G", "G", "1 GB!", "99999999999999999999T" }) |bad| {
        try t.expectEqual(@as(?u64, null), cache_dir.parseBudget(bad));
    }
}

fn environ(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(t.allocator);
    errdefer map.deinit();
    for (pairs) |pair| try map.put(pair[0], pair[1]);
    return map;
}

test "cache dir: the directory comes from ORIGINE_CACHE_DIR, then XDG_CACHE_HOME, then HOME" {
    {
        var map = try environ(&.{ .{ "ORIGINE_CACHE_DIR", "rel/dir" }, .{ "XDG_CACHE_HOME", "/xdg" }, .{ "HOME", "/home/me" } });
        defer map.deinit();
        const path = (try cache_dir.resolveDirPath(t.allocator, &map)).?;
        defer t.allocator.free(path);
        try t.expectEqualStrings("rel/dir", path);
    }
    {
        var map = try environ(&.{ .{ "XDG_CACHE_HOME", "/xdg" }, .{ "HOME", "/home/me" } });
        defer map.deinit();
        const path = (try cache_dir.resolveDirPath(t.allocator, &map)).?;
        defer t.allocator.free(path);
        try t.expectEqualStrings("/xdg/origine/code_caches", path);
    }
    {
        var map = try environ(&.{ .{ "ORIGINE_CACHE_DIR", "" }, .{ "XDG_CACHE_HOME", "" }, .{ "HOME", "/home/me" } });
        defer map.deinit();
        const path = (try cache_dir.resolveDirPath(t.allocator, &map)).?;
        defer t.allocator.free(path);
        try t.expectEqualStrings("/home/me/.cache/origine/code_caches", path);
    }
    {
        var map = try environ(&.{});
        defer map.deinit();
        try t.expect((try cache_dir.resolveDirPath(t.allocator, &map)) == null);
    }
}

test "cache dir: the switches are independent and a bad budget falls back" {
    var map = try environ(&.{ .{ "ORIGINE_CACHE_DIR", "c" }, .{ "ORIGINE_NO_SNAPSHOT", "1" }, .{ "ORIGINE_CACHE_BUDGET", "nonsense" } });
    defer map.deinit();
    var only_no_snapshot = try cache_dir.settingsFrom(t.allocator, &map);
    defer only_no_snapshot.deinit(t.allocator);
    try t.expect(!only_no_snapshot.snapshot and only_no_snapshot.code);
    try t.expectEqual(cache_dir.default_budget, only_no_snapshot.budget);
    try t.expectEqual(@as(u64, 1200 << 20), cache_dir.default_budget);

    try map.put("ORIGINE_NO_CODE_CACHE", "1");
    _ = map.swapRemove("ORIGINE_NO_SNAPSHOT");
    try map.put("ORIGINE_CACHE_BUDGET", "0");
    var only_no_code = try cache_dir.settingsFrom(t.allocator, &map);
    defer only_no_code.deinit(t.allocator);
    try t.expect(only_no_code.snapshot and !only_no_code.code);
    try t.expectEqual(@as(u64, 0), only_no_code.budget);
}

fn writeAged(dir: m.sys.Dir, tmp: *t.TmpDir, name: []const u8, size: usize, mtime_ns: i128) !void {
    const data = try t.allocator.alloc(u8, size);
    defer t.allocator.free(data);
    @memset(data, 'x');
    try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = data });
    const file = try dir.openFile(name, .{ .mode = .read_write });
    defer file.close();
    try file.setTimes(mtime_ns, mtime_ns);
}

fn exists(tmp: *t.TmpDir, name: []const u8) bool {
    _ = tmp.dir.statFile(t.io, name, .{}) catch return false;
    return true;
}

test "cache dir: eviction drops the least recently used files down to 90% of the budget" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir: m.sys.Dir = .{ .handle = tmp.dir.handle };
    const now: i128 = 1_000_000 * ns;
    // Oldest first: a, b, c, d (100 bytes each); `fresh` is under the minimum age.
    try writeAged(dir, &tmp, "a.v8-code-cache", 100, now - 400 * ns);
    try writeAged(dir, &tmp, "b.v8-snapshot", 100, now - 300 * ns);
    try writeAged(dir, &tmp, "c.v8-code-cache", 100, now - 200 * ns);
    try writeAged(dir, &tmp, "d.v8-code-cache", 100, now - 100 * ns);
    try writeAged(dir, &tmp, "fresh.v8-code-cache", 100, now - 2 * ns);
    // Not cache files: never counted and never deleted.
    try writeAged(dir, &tmp, "README", 1000, now - 900 * ns);
    try writeAged(dir, &tmp, "old.txt", 1000, now - 900 * ns);

    // Within the budget: nothing happens.
    var stats = try cache_dir.evict(t.allocator, dir, 500, now);
    try t.expectEqual(@as(usize, 5), stats.files);
    try t.expectEqual(@as(u64, 500), stats.bytes);
    try t.expectEqual(@as(usize, 0), stats.deleted);

    // Budget 400: over by one file; goes down to 90% = 360 bytes, so two files, the two oldest.
    stats = try cache_dir.evict(t.allocator, dir, 400, now);
    try t.expectEqual(@as(usize, 2), stats.deleted);
    try t.expectEqual(@as(u64, 200), stats.freed);
    try t.expect(!exists(&tmp, "a.v8-code-cache"));
    try t.expect(!exists(&tmp, "b.v8-snapshot"));
    try t.expect(exists(&tmp, "c.v8-code-cache") and exists(&tmp, "d.v8-code-cache") and exists(&tmp, "fresh.v8-code-cache"));
    try t.expect(exists(&tmp, "README") and exists(&tmp, "old.txt"));

    // A budget of 0 deletes everything old enough, but never a file younger than the minimum age.
    stats = try cache_dir.evict(t.allocator, dir, 0, now);
    try t.expect(!exists(&tmp, "c.v8-code-cache") and !exists(&tmp, "d.v8-code-cache"));
    try t.expect(exists(&tmp, "fresh.v8-code-cache"));
    try t.expect(exists(&tmp, "README"));
}

test "cache dir: equal ages evict by name, and abandoned temporary files are swept" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir: m.sys.Dir = .{ .handle = tmp.dir.handle };
    const now: i128 = 1_000_000 * ns;
    try writeAged(dir, &tmp, "b.v8-code-cache", 100, now - 100 * ns);
    try writeAged(dir, &tmp, "a.v8-code-cache", 100, now - 100 * ns);
    try writeAged(dir, &tmp, "writer.dead.tmp", 10, now - 2 * 3600 * ns);
    try writeAged(dir, &tmp, "writer.alive.tmp", 10, now - 5 * ns);
    _ = try cache_dir.evict(t.allocator, dir, 190, now);
    try t.expect(!exists(&tmp, "a.v8-code-cache"));
    try t.expect(exists(&tmp, "b.v8-code-cache"));
    try t.expect(!exists(&tmp, "writer.dead.tmp"));
    try t.expect(exists(&tmp, "writer.alive.tmp"));
}

test "cache dir: a read refreshes a file's use time only after it has been idle" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir: m.sys.Dir = .{ .handle = tmp.dir.handle };
    const now = m.sys.realtimeNs();
    try writeAged(dir, &tmp, "idle", 1, now - 3 * cache_dir.touch_after_ns);
    try writeAged(dir, &tmp, "recent", 1, now - 5 * ns);
    for ([_][]const u8{ "idle", "recent" }) |name| {
        const file = try dir.openFile(name, .{ .mode = .read_write });
        defer file.close();
        const before = (try file.stat()).mtime.nanoseconds;
        cache_dir.touchIfIdle(file, before, now);
        const after = (try file.stat()).mtime.nanoseconds;
        if (std.mem.eql(u8, name, "idle")) {
            try t.expect(after > before and after >= now - ns);
        } else {
            try t.expectEqual(before, after);
        }
    }
}

fn nameMany(out: *std.ArrayList([]u8), writer_id: u32) void {
    for (0..100) |_| {
        const name = cache_dir.temporaryName(t.allocator, "abc.v8-code-cache", writer_id) catch return;
        out.append(t.allocator, name) catch return;
    }
}

test "cache dir: temporary names never repeat across threads and writers" {
    var lists: [4]std.ArrayList([]u8) = @splat(.empty);
    defer for (&lists) |*list| {
        for (list.items) |name| t.allocator.free(name);
        list.deinit(t.allocator);
    };
    var threads: [4]std.Thread = undefined;
    // Two threads share a writer id on purpose: the counter keeps them apart.
    for (&threads, 0..) |*thread, index| thread.* = try std.Thread.spawn(.{}, nameMany, .{ &lists[index], @as(u32, @intCast(index / 2)) });
    for (threads) |thread| thread.join();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(t.allocator);
    for (lists) |list| {
        try t.expectEqual(@as(usize, 100), list.items.len);
        for (list.items) |name| {
            try t.expect(std.mem.startsWith(u8, name, "abc.v8-code-cache."));
            try t.expect(std.mem.endsWith(u8, name, ".tmp"));
            try t.expectEqual(@as(usize, "abc.v8-code-cache.".len + 16 + ".tmp".len), name.len);
            try t.expect(!(try seen.getOrPut(t.allocator, name)).found_existing);
        }
    }
}

test "cache dir: writing is atomic, creates the subdirectory, and counts what was stored" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir: m.sys.Dir = .{ .handle = tmp.dir.handle };
    cache_dir.resetStored();
    try t.expect(!cache_dir.wroteSomething());
    try cache_dir.writeAtomic(t.allocator, dir, "sub", "x.v8-code-cache", "hello", 3);
    try t.expect(cache_dir.wroteSomething());
    const written = try tmp.dir.readFileAlloc(t.io, "sub/x.v8-code-cache", t.allocator, .unlimited);
    defer t.allocator.free(written);
    try t.expectEqualStrings("hello", written);
    cache_dir.deleteQuiet(dir, "sub/x.v8-code-cache");
    cache_dir.deleteQuiet(dir, "sub/x.v8-code-cache");
    try t.expect(!exists(&tmp, "sub/x.v8-code-cache"));
    cache_dir.resetStored();
}
