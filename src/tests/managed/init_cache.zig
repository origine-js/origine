const std = @import("std");
const t = std.testing;
const m = @import("@managed");
const ensureV8 = @import("../support.zig").ensureV8;
const Memory = @import("support.zig").Memory;

const cache = m.Api.init_cache;
const Hash = cache.Hash;

/// Serves a two-module init graph from static sources.
fn load(_: ?*anyopaque, request: m.LoadRequest) !m.LoadResult {
    if (std.mem.eql(u8, request.module_id, "app/init.js")) return .{ .source = "import 'dep.js'; export const x = 1;" };
    if (std.mem.eql(u8, request.module_id, "dep.js")) return .{ .source = "export const y = 2;" };
    return error.NotFound;
}

/// Hashes the ID itself, standing in for the module's file content.
fn hashId(data: ?*anyopaque, id: []const u8) anyerror!?Hash {
    const salt: *const u8 = @ptrCast(@alignCast(data.?));
    var out: Hash = undefined;
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(&.{salt.*});
    hasher.update(id);
    hasher.final(&out);
    return out;
}

test "init cache: the entry path follows the __pycache__ layout and tracks the specifier" {
    const host = try m.Api.Host.create(t.allocator, .{ .io = t.io });
    defer host.destroy();
    ensureV8();
    var nested = try cache.entryFor(t.allocator, t.io, host, "app/init.js");
    defer nested.deinit();
    var bare = try cache.entryFor(t.allocator, t.io, host, "init.js");
    defer bare.deinit();
    var other = try cache.entryFor(t.allocator, t.io, host, "app/other.js");
    defer other.deinit();
    try t.expect(std.mem.startsWith(u8, nested.path, "app/__oricache__/init.js."));
    try t.expect(std.mem.endsWith(u8, nested.path, ".v8-snapshot"));
    try t.expect(std.mem.startsWith(u8, bare.path, "__oricache__/init.js."));
    try t.expect(!std.mem.eql(u8, &nested.key, &bare.key));
    try t.expect(!std.mem.eql(u8, &nested.key, &other.key));
    var again = try cache.entryFor(t.allocator, t.io, host, "app/init.js");
    defer again.deinit();
    try t.expectEqualStrings(nested.path, again.path);
    try t.expectEqualSlices(u8, &nested.key, &again.key);
}

test "init cache: store then load round-trips; every kind of staleness is a miss" {
    ensureV8();
    const host = try m.Api.Host.create(t.allocator, .{ .io = t.io });
    defer host.destroy();
    var entry = try cache.entryFor(t.allocator, t.io, host, "app/init.js");
    defer entry.deinit();
    var salt: u8 = 1;
    const hasher: m.init_snapshot.SourceHasher = .{ .data = &salt, .hash = hashId };
    var label: [128]u8 = undefined;
    var image = try m.init_snapshot.create(t.allocator, .{
        .key = entry.key,
        .identity = cache.identity(&label),
        .scope = .{ .resolver = .{ .resolve = Memory.resolve }, .loader = .{ .load = load } },
        .specifier = "app/init.js",
        .source_hasher = hasher,
    });
    defer image.deinit();

    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var why: cache.Miss = undefined;
    try t.expect(cache.load(t.allocator, t.io, tmp.dir, &entry, hasher, &why) == null);
    try t.expectEqual(cache.Miss.no_file, why);

    // Files of other engines are swept, whatever source they belong to; files of this engine
    // (even of another source) and anything that is not a cache file stay.
    const tag = std.fs.path.basename(entry.path)["init.js.".len..][0..12];
    const keep = try std.fmt.allocPrint(t.allocator, "app/__oricache__/other.js.{s}.v8-snapshot", .{tag});
    defer t.allocator.free(keep);
    try tmp.dir.createDirPath(t.io, "app/__oricache__");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "app/__oricache__/init.js.aaaaaaaaaaaa.v8-snapshot", .data = "old" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "app/__oricache__/other.js.bbbbbbbbbbbb.v8-snapshot", .data = "old" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "app/__oricache__/dep.js.cccccccccccc.v8-code-cache", .data = "old" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "app/__oricache__/notes.txt", .data = "mine" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "app/__oricache__/odd.zzzzzzzzzzzz.v8-snapshot", .data = "not a tag" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = keep, .data = "keep" });
    try cache.store(t.allocator, t.io, tmp.dir, &entry, &image);
    for ([_][]const u8{ "init.js.aaaaaaaaaaaa.v8-snapshot", "other.js.bbbbbbbbbbbb.v8-snapshot", "dep.js.cccccccccccc.v8-code-cache" }) |gone| {
        const path = try std.fmt.allocPrint(t.allocator, "app/__oricache__/{s}", .{gone});
        defer t.allocator.free(path);
        try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, path, .{}));
    }
    _ = try tmp.dir.statFile(t.io, keep, .{});
    _ = try tmp.dir.statFile(t.io, "app/__oricache__/notes.txt", .{});
    _ = try tmp.dir.statFile(t.io, "app/__oricache__/odd.zzzzzzzzzzzz.v8-snapshot", .{});
    // No temporary file is left behind.
    var count: usize = 0;
    var dir = try tmp.dir.openDir(t.io, "app/__oricache__", .{ .iterate = true });
    defer dir.close(t.io);
    var it = dir.iterate();
    while (try it.next(t.io)) |_| count += 1;
    try t.expectEqual(@as(usize, 4), count);

    var hit = cache.load(t.allocator, t.io, tmp.dir, &entry, hasher, null) orelse return error.TestExpectedHit;
    defer hit.deinit();
    try t.expectEqual(image.table.modules.len, hit.table.modules.len);
    try t.expectEqualSlices(u8, image.blob, hit.blob);

    // A changed module (here: a different salt, so every hash differs) is a miss.
    var changed_salt: u8 = 2;
    try t.expect(cache.load(t.allocator, t.io, tmp.dir, &entry, .{ .data = &changed_salt, .hash = hashId }, &why) == null);
    try t.expectEqual(cache.Miss.source_changed, why);
    // A different engine/specifier key is a miss even at the same path.
    var foreign = try cache.entryFor(t.allocator, t.io, host, "app/init.js");
    defer foreign.deinit();
    foreign.key[0] ^= 1;
    try t.expect(cache.load(t.allocator, t.io, tmp.dir, &foreign, hasher, &why) == null);
    try t.expectEqual(cache.Miss.key_changed, why);
    // Truncated and garbage files are misses, not errors.
    try tmp.dir.writeFile(t.io, .{ .sub_path = entry.path, .data = image.bytes[0 .. image.bytes.len / 2] });
    try t.expect(cache.load(t.allocator, t.io, tmp.dir, &entry, hasher, &why) == null);
    try t.expectEqual(cache.Miss.bad_file, why);
    try tmp.dir.writeFile(t.io, .{ .sub_path = entry.path, .data = "not a snapshot" });
    try t.expect(cache.load(t.allocator, t.io, tmp.dir, &entry, hasher, &why) == null);
    try t.expectEqual(cache.Miss.bad_file, why);
}

test "init cache: code caches are stored beside the source and only served for identical text" {
    ensureV8();
    const host = try m.Api.Host.create(t.allocator, .{ .io = t.io });
    defer host.destroy();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state = cache.CodeCacheState.init(t.io, host, tmp.dir);
    const hook = state.hook();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const request: m.CodeCacheRequest = .{ .allocator = arena.allocator(), .module_id = "app/mod.js", .source = "export const a = 1;" };
    try t.expect(hook.load(hook.data, request) == null);

    try tmp.dir.createDirPath(t.io, "app/__oricache__");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "app/__oricache__/mod.js.aaaaaaaaaaaa.v8-code-cache", .data = "stale" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "app/__oricache__/mod.js.aaaaaaaaaaaa.v8-snapshot", .data = "other engine, other kind" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "app/__oricache__/README", .data = "not a cache file" });
    const payload = "0123456789abcdef";
    hook.store(hook.data, request, payload);
    const path = try std.fmt.allocPrint(t.allocator, "app/__oricache__/mod.js.{s}.v8-code-cache", .{state.tag});
    defer t.allocator.free(path);
    _ = try tmp.dir.statFile(t.io, path, .{});
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "app/__oricache__/mod.js.aaaaaaaaaaaa.v8-code-cache", .{}));
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "app/__oricache__/mod.js.aaaaaaaaaaaa.v8-snapshot", .{}));
    _ = try tmp.dir.statFile(t.io, "app/__oricache__/README", .{});

    const served = hook.load(hook.data, request) orelse return error.TestExpectedHit;
    try t.expectEqualStrings(payload, served);
    try t.expectEqual(@as(usize, 0), @intFromPtr(served.ptr) % 8);
    // Different text (even of the same length) is a miss.
    var changed = request;
    changed.source = "export const a = 2;";
    try t.expect(hook.load(hook.data, changed) == null);
    // A damaged file is a miss.
    const bytes = try tmp.dir.readFileAlloc(t.io, path, t.allocator, .unlimited);
    defer t.allocator.free(bytes);
    try tmp.dir.writeFile(t.io, .{ .sub_path = path, .data = bytes[0 .. bytes.len - 1] });
    try t.expect(hook.load(hook.data, request) == null);
    // Embedded modules are never written.
    var embedded = request;
    embedded.module_id = "origine:@std/io";
    hook.store(hook.data, embedded, payload);
    try t.expect(hook.load(hook.data, embedded) == null);
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, "origine:@std/__oricache__", .{}));
}
