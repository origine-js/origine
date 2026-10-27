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
    const host = try m.Api.Host.create(t.allocator, .{});
    defer host.destroy();
    ensureV8();
    var nested = try cache.entryFor(t.allocator, host, "app/init.js");
    defer nested.deinit();
    var bare = try cache.entryFor(t.allocator, host, "init.js");
    defer bare.deinit();
    var other = try cache.entryFor(t.allocator, host, "app/other.js");
    defer other.deinit();
    try t.expect(std.mem.startsWith(u8, nested.path, "app/__oricache__/init.js."));
    try t.expect(std.mem.endsWith(u8, nested.path, ".v8-snapshot"));
    try t.expect(std.mem.startsWith(u8, bare.path, "__oricache__/init.js."));
    try t.expect(!std.mem.eql(u8, &nested.key, &bare.key));
    try t.expect(!std.mem.eql(u8, &nested.key, &other.key));
    var again = try cache.entryFor(t.allocator, host, "app/init.js");
    defer again.deinit();
    try t.expectEqualStrings(nested.path, again.path);
    try t.expectEqualSlices(u8, &nested.key, &again.key);
}

test "init cache: store then load round-trips; every kind of staleness is a miss" {
    ensureV8();
    const host = try m.Api.Host.create(t.allocator, .{});
    defer host.destroy();
    var entry = try cache.entryFor(t.allocator, host, "app/init.js");
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
    try t.expect(cache.load(t.allocator, .{ .handle = tmp.dir.handle }, &entry, hasher, &why) == null);
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
    try cache.store(t.allocator, .{ .handle = tmp.dir.handle }, &entry, &image);
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

    var hit = cache.load(t.allocator, .{ .handle = tmp.dir.handle }, &entry, hasher, null) orelse return error.TestExpectedHit;
    defer hit.deinit();
    try t.expectEqual(image.table.modules.len, hit.table.modules.len);
    try t.expectEqualSlices(u8, image.blob, hit.blob);

    // A changed module (here: a different salt, so every hash differs) is a miss.
    var changed_salt: u8 = 2;
    try t.expect(cache.load(t.allocator, .{ .handle = tmp.dir.handle }, &entry, .{ .data = &changed_salt, .hash = hashId }, &why) == null);
    try t.expectEqual(cache.Miss.source_changed, why);
    // A different engine/specifier key is a miss even at the same path.
    var foreign = try cache.entryFor(t.allocator, host, "app/init.js");
    defer foreign.deinit();
    foreign.key[0] ^= 1;
    try t.expect(cache.load(t.allocator, .{ .handle = tmp.dir.handle }, &foreign, hasher, &why) == null);
    try t.expectEqual(cache.Miss.key_changed, why);
    // Truncated and garbage files (behind a valid meta word) are misses, not errors.
    const no_features = [_]u8{ 0, 0, 0, 0 };
    const truncated = try std.mem.concat(t.allocator, u8, &.{ &no_features, image.bytes[0 .. image.bytes.len / 2] });
    defer t.allocator.free(truncated);
    try tmp.dir.writeFile(t.io, .{ .sub_path = entry.path, .data = truncated });
    try t.expect(cache.load(t.allocator, .{ .handle = tmp.dir.handle }, &entry, hasher, &why) == null);
    try t.expectEqual(cache.Miss.bad_file, why);
    try tmp.dir.writeFile(t.io, .{ .sub_path = entry.path, .data = &no_features ++ "not a snapshot".* });
    try t.expect(cache.load(t.allocator, .{ .handle = tmp.dir.handle }, &entry, hasher, &why) == null);
    try t.expectEqual(cache.Miss.bad_file, why);
    // A loaded image owns stable, aligned bytes even after the file is overwritten
    // and truncated. Restoring V8 must keep working, without a live file or mapping.
    try t.expectEqual(@as(usize, 0), @intFromPtr(hit.blob.ptr) % 16);
    try t.expectEqualSlices(u8, image.blob, hit.blob);
    const rt = try m.Runtime.create(t.allocator, .{ .snapshot = hit.blob });
    defer rt.destroy();
    const options: m.Scope.Options = .{ .resolver = .{ .resolve = Memory.resolve }, .loader = .{ .load = load }, .init_snapshot = &hit.table };
    const scope = try rt.createScope(options);
    try @import("support.zig").exposeModule(scope, "app/init.js", "cached_init");
    try @import("support.zig").check(scope, "cached_init.x === 1");
}

test "init cache: the meta word carries version, features and parity" {
    const meta = cache.meta;
    // The word is little-endian: version in the low bits, parity in the top bit.
    try t.expectEqual(@as(u32, 0), meta.encode(0));
    try t.expectEqual(@as(u32, 0x8000_0010), meta.encode(meta.lz4)); // one feature bit: parity set
    try t.expectEqual(@as(u32, 0), try meta.decode(meta.encode(0), 0));
    try t.expectEqual(meta.lz4, try meta.decode(meta.encode(meta.lz4), meta.lz4));
    // Any single flipped bit is a damaged word.
    for (0..32) |bit| {
        const damaged = meta.encode(meta.lz4) ^ (@as(u32, 1) << @intCast(bit));
        try t.expectError(error.BadParity, meta.decode(damaged, meta.lz4));
    }
    // A layout version other than 0 is rejected even with valid parity.
    try t.expectError(error.UnknownVersion, meta.decode(0x8000_0001, meta.lz4));
    // A feature the reader lacks, or does not know, is rejected.
    try t.expectError(error.UnsupportedFeature, meta.decode(meta.encode(meta.lz4), 0));
    try t.expectError(error.UnsupportedFeature, meta.decode(meta.encode(1 << 5), meta.lz4));
    // On disk: four bytes, low byte first.
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, meta.encode(meta.lz4), .little);
    try t.expectEqualSlices(u8, &.{ 0x10, 0x00, 0x00, 0x80 }, &bytes);
}

test "init cache: packed snapshot files shrink, read back, and are rejected by readers without LZ4" {
    ensureV8();
    const host = try m.Api.Host.create(t.allocator, .{});
    defer host.destroy();
    var entry = try cache.entryFor(t.allocator, host, "app/init.js");
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
    const root: m.sys.Dir = .{ .handle = tmp.dir.handle };
    var why: cache.Miss = undefined;
    const lz4 = cache.meta.lz4;

    try cache.storeWith(t.allocator, root, &entry, &image, true);
    const stat = try tmp.dir.statFile(t.io, entry.path, .{});
    try t.expect(stat.size < image.bytes.len);
    var hit = cache.loadWith(t.allocator, root, &entry, hasher, null, lz4) orelse return error.TestExpectedHit;
    defer hit.deinit();
    try t.expectEqualSlices(u8, image.blob, hit.blob);
    try t.expectEqual(@as(usize, 0), @intFromPtr(hit.blob.ptr) % 16);
    // A reader built without LZ4 rejects the file safely instead of parsing packed bytes.
    try t.expect(cache.loadWith(t.allocator, root, &entry, hasher, &why, 0) == null);
    try t.expectEqual(cache.Miss.format_changed, why);

    // A raw file says so too: readers with or without LZ4 take it.
    try cache.storeWith(t.allocator, root, &entry, &image, false);
    inline for (.{ lz4, 0 }) |can_read| {
        var raw = cache.loadWith(t.allocator, root, &entry, hasher, null, can_read) orelse return error.TestExpectedHit;
        defer raw.deinit();
        try t.expectEqualSlices(u8, image.blob, raw.blob);
    }

    // A damaged meta word and a layout version this engine does not know are misses.
    const stored = try tmp.dir.readFileAlloc(t.io, entry.path, t.allocator, .unlimited);
    defer t.allocator.free(stored);
    stored[0] ^= 0x20; // a feature bit flips: the parity no longer matches
    try tmp.dir.writeFile(t.io, .{ .sub_path = entry.path, .data = stored });
    try t.expect(cache.loadWith(t.allocator, root, &entry, hasher, &why, lz4) == null);
    try t.expectEqual(cache.Miss.bad_file, why);
    std.mem.writeInt(u32, stored[0..4], 0x8000_0001, .little); // version 1, parity valid
    try tmp.dir.writeFile(t.io, .{ .sub_path = entry.path, .data = stored });
    try t.expect(cache.loadWith(t.allocator, root, &entry, hasher, &why, lz4) == null);
    try t.expectEqual(cache.Miss.format_changed, why);
    // Shorter than the word.
    try tmp.dir.writeFile(t.io, .{ .sub_path = entry.path, .data = "ab" });
    try t.expect(cache.loadWith(t.allocator, root, &entry, hasher, &why, lz4) == null);
    try t.expectEqual(cache.Miss.bad_file, why);
}

test "init cache: code cache files encode and decode in both kinds; readers without LZ4 reject packed ones" {
    const source = "export const answer = 42;";
    var bytes: [4096]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i / 3);
    const lz4 = cache.meta.lz4;
    inline for (.{ false, true }) |compressed| {
        const file = try cache.encodeCode(t.allocator, source, &bytes, compressed);
        defer t.allocator.free(file);
        if (compressed) try t.expect(file.len < bytes.len);
        const expected_features: u32 = if (compressed) lz4 else 0;
        try t.expectEqual(cache.meta.encode(expected_features), std.mem.readInt(u32, file[0..4], .little));

        // Each decode takes ownership of an 8-aligned copy.
        const wrong_source = try t.allocator.alignedAlloc(u8, .@"8", file.len);
        defer t.allocator.free(wrong_source);
        @memcpy(wrong_source, file);
        try t.expect(cache.decodeCode(t.allocator, wrong_source, "export const answer = 43;", lz4) == null);
        if (compressed) {
            const no_lz4 = try t.allocator.alignedAlloc(u8, .@"8", file.len);
            defer t.allocator.free(no_lz4);
            @memcpy(no_lz4, file);
            try t.expect(cache.decodeCode(t.allocator, no_lz4, source, 0) == null);
        }
        const aligned = try t.allocator.alignedAlloc(u8, .@"8", file.len);
        @memcpy(aligned, file);
        const decoded = cache.decodeCode(t.allocator, aligned, source, lz4) orelse return error.TestExpectedHit;
        defer if (compressed) t.allocator.free(@as([]align(16) const u8, @alignCast(decoded))) else t.allocator.free(aligned);
        try t.expectEqualSlices(u8, &bytes, decoded);
        try t.expectEqual(@as(usize, 0), @intFromPtr(decoded.ptr) % 8);
    }
}

test "init cache: code caches are stored beside the source and only served for identical text" {
    ensureV8();
    const host = try m.Api.Host.create(t.allocator, .{});
    defer host.destroy();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state = cache.CodeCacheState.init(host, .{ .handle = tmp.dir.handle });
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

fn resolved(referrer: []const u8, specifier: []const u8) ![]const u8 {
    return m.Api.init_loader.resolve(null, .{
        .allocator = t.allocator,
        .context = undefined,
        .scope_id = 0,
        .specifier = specifier,
        .referrer = referrer,
    });
}

test "relative specifiers keep the root of an absolute referrer" {
    const abs = try resolved("/p/init.js", "./dep.js");
    defer t.allocator.free(abs);
    try t.expectEqualStrings("/p/dep.js", abs);
    const up = try resolved("/p/q/init.js", "../dep.js");
    defer t.allocator.free(up);
    try t.expectEqualStrings("/p/dep.js", up);
    const rel = try resolved("app/init.js", "./dep.js");
    defer t.allocator.free(rel);
    try t.expectEqualStrings("app/dep.js", rel);
}
