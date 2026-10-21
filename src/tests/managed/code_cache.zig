const std = @import("std");
const t = std.testing;
const m = @import("@managed");
const ensureV8 = @import("../support.zig").ensureV8;
const check = @import("support.zig").check;
const exposeModule = @import("support.zig").exposeModule;
const Memory = @import("support.zig").Memory;

/// An in-memory code cache: remembers the last stored bytes and the source they belong to.
const Store = struct {
    alloc: std.mem.Allocator,
    bytes: ?[]u8 = null,
    source: ?[]u8 = null,
    loads: usize = 0,
    hits: usize = 0,
    stores: usize = 0,
    /// Serve the cached bytes even for different source, as a hook that does not verify would.
    careless: bool = false,

    fn deinit(self: *Store) void {
        if (self.bytes) |bytes| self.alloc.free(bytes);
        if (self.source) |source| self.alloc.free(source);
    }
    /// Hook `load`; borrows state and request for the call.
    fn load(data: ?*anyopaque, request: m.CodeCacheRequest) ?[]const u8 {
        const self: *Store = @ptrCast(@alignCast(data.?));
        self.loads += 1;
        const bytes = self.bytes orelse return null;
        if (!self.careless and !std.mem.eql(u8, self.source.?, request.source)) return null;
        self.hits += 1;
        // V8 wants 8-byte-aligned data that outlives the compile.
        const copy = request.allocator.alignedAlloc(u8, .@"8", bytes.len) catch return null;
        @memcpy(copy, bytes);
        return copy;
    }
    /// Hook `store`; copies the bytes and the source.
    fn put(data: ?*anyopaque, request: m.CodeCacheRequest, bytes: []const u8) void {
        const self: *Store = @ptrCast(@alignCast(data.?));
        self.deinit();
        self.bytes = self.alloc.dupe(u8, bytes) catch return;
        self.source = self.alloc.dupe(u8, request.source) catch return;
        self.stores += 1;
    }
    fn hook(self: *Store) m.CodeCache {
        return .{ .data = self, .load = load, .store = put };
    }
};

/// Serves one module whose source can be varied between runs.
const One = struct {
    source: []const u8,
    fn load(data: ?*anyopaque, request: m.LoadRequest) !m.LoadResult {
        const self: *One = @ptrCast(@alignCast(data.?));
        if (std.mem.eql(u8, request.module_id, "app")) return .{ .source = self.source };
        return error.NotFound;
    }
    fn options(self: *One, store: *Store) m.Scope.Options {
        return .{ .resolver = .{ .resolve = Memory.resolve }, .loader = .{ .data = self, .load = load }, .code_cache = store.hook() };
    }
};

/// Imports "app" in a fresh runtime, runs it and flushes; returns how many caches were stored.
fn runOnce(source: []const u8, store: *Store) !usize {
    return runOnceIn(source, store, null);
}

/// `runOnce` in a runtime booted from `snapshot`.
fn runOnceIn(source: []const u8, store: *Store, snapshot: ?[]align(16) const u8) !usize {
    var one: One = .{ .source = source };
    const rt = try m.Runtime.create(t.allocator, .{ .snapshot = snapshot });
    defer rt.destroy();
    const scope = try rt.createScope(one.options(store));
    try exposeModule(scope, "app", "ns");
    try check(scope, "ns.run(3) === 6 && ns.extra === 'x'");
    return scope.flushCodeCache();
}

const app = "export const extra = 'x'; export function run(n) { let t = 0; for (let i = 0; i < n; i++) t += i; return t * 2; }";

test "code cache: produced after the first run, consumed by the next, rejected when the source differs" {
    ensureV8();
    var store: Store = .{ .alloc = t.allocator };
    defer store.deinit();
    // First run: nothing to load, one cache produced after the module ran.
    try t.expectEqual(@as(usize, 1), try runOnce(app, &store));
    try t.expectEqual(@as(usize, 1), store.loads);
    try t.expectEqual(@as(usize, 0), store.hits);
    try t.expect(store.bytes.?.len > 0);
    // Same source: the cache is served and accepted, so there is nothing new to store.
    try t.expectEqual(@as(usize, 0), try runOnce(app, &store));
    try t.expectEqual(@as(usize, 1), store.hits);
    try t.expectEqual(@as(usize, 1), store.stores);
    // Different source, hook declines: compiles from scratch and stores a fresh cache.
    const edited = app ++ " ";
    try t.expectEqual(@as(usize, 1), try runOnce(edited, &store));
    try t.expectEqual(@as(usize, 2), store.stores);
    try t.expectEqualStrings(edited, store.source.?);
    // A careless hook serves the stale bytes for different-length source: V8 refuses them, the
    // module still works, and a new cache is stored.
    store.careless = true;
    const longer = app ++ "  ";
    try t.expectEqual(@as(usize, 1), try runOnce(longer, &store));
    try t.expectEqual(@as(usize, 3), store.stores);
    // flushing twice stores nothing the second time.
    var one: One = .{ .source = app };
    store.careless = false;
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(one.options(&store));
    try exposeModule(scope, "app", "ns");
    _ = scope.flushCodeCache();
    try t.expectEqual(@as(usize, 0), scope.flushCodeCache());
}
