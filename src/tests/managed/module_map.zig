const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const m = @import("@managed");
const ensureV8 = @import("../support.zig").ensureV8;
const support = @import("support.zig");
const check = support.check;
const exposeModule = support.exposeModule;
const Deferred = support.Deferred;
const expectState = support.expectState;

test "managed module maps: independent mappings without a resolver or loader" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const a = try rt.createScope(.{});
    const b = try rt.createScope(.{});
    const key: m.ModuleMapKey = .{ .module_id = "same" };
    try a.module_map.update(key, .{ .source = "export const value = 1" }, null);
    try b.module_map.update(key, .{ .source = "export const value = 2" }, null);
    const retained = (try a.module_map.get(key, null)).?;
    defer retained.deinit();
    try exposeModule(a, "same", "first");
    try exposeModule(a, "same", "again");
    try exposeModule(b, "same", "other");
    try check(a, "first === again && first.value === 1");
    try check(b, "other.value === 2");
    try a.module_map.update(key, .{ .source = "export const value = 3" }, null);
    try exposeModule(a, "same", "updated");
    try check(a, "updated !== first && updated.value === 3 && first.value === 1");
    try t.expectEqual(@as(usize, 1), try a.module_map.delete(key));
    try t.expect(try a.module_map.get(key, null) == null);
    try check(b, "other.value === 2");
    // Compatibility operations address the exact same module map.
    try b.updateImportCache(key, .{ .source = "export const value = 4" }, null);
    try exposeModule(b, "same", "replacement");
    try check(b, "replacement.value === 4");
    try t.expectEqual(@as(usize, 1), try b.module_map.clear());
    try t.expect(try b.module_map.get(key, null) == null);
}

test "managed module maps: lookup normalizes attributes and retains native identity" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    const attrs = [_]m.ImportAttribute{ .{ .key = "type", .value = "custom" }, .{ .key = "mode", .value = "one" } };
    const key: m.ModuleMapKey = .{ .module_id = "payload", .import_attributes = &attrs };
    const reordered: m.ModuleMapKey = .{ .module_id = "payload", .import_attributes = &.{ attrs[1], attrs[0] } };
    try scope.module_map.update(key, .{ .source = "export const value = 1" }, null);
    try scope.module_map.update(.{ .module_id = "payload" }, .{ .source = "export const value = 2" }, null);
    const first = (try scope.module_map.get(key, null)).?;
    defer first.deinit();
    const again = (try scope.module_map.get(reordered, null)).?;
    defer again.deinit();
    const plain = (try scope.module_map.get(.{ .module_id = "payload" }, null)).?;
    defer plain.deinit();
    try t.expect(try scope.module_map.get(.{ .module_id = "payload", .import_attributes = &.{.{ .key = "type", .value = "other" }} }, null) == null);
    try t.expectEqual(@as(usize, 1), try scope.module_map.delete(reordered));
    try t.expect(try scope.module_map.get(key, null) == null);
    try t.expectEqual(@as(usize, 1), try scope.module_map.clear());
    // Handles returned by get survive both the local handle scope and map eviction.
    rt.isolate.enter();
    defer rt.isolate.exit();
    var h_scope: v8.HandleScope = undefined;
    h_scope.init(rt.isolate);
    defer h_scope.deinit();
    try t.expect(first.deref().data.eq(again.deref().data));
    try t.expect(!first.deref().data.eq(plain.deref().data));
    try t.expect(first.deref().isSourceTextModule());
}

test "managed module maps: alias imports share a loaded module and lookup never loads" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const Backend = struct {
        loads: usize = 0,
        /// Borrows request/context/state through this callback. Returns a canonical
        /// ID owned by request.allocator; ownership transfers to the runtime on success.
        /// Errors transfer no result storage; input bytes and local handles are not retained.
        fn resolve(_: ?*anyopaque, request: m.ResolveRequest) ![]const u8 {
            return request.allocator.dupe(u8, "canonical");
        }
        /// Borrows host callback state through return; state stays live through runtime
        /// teardown. Request ID/attribute bytes retained by this fixture remain runtime-owned
        /// until teardown begins. Returned source uses static or request-allocator storage;
        /// local handles remain in the enclosing HandleScope. Errors transfer no host ownership.
        fn load(data: ?*anyopaque, request: m.LoadRequest) !m.LoadResult {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            try t.expectEqualStrings("canonical", request.module_id);
            self.loads += 1;
            return .{ .source = "export const value = 1" };
        }
    };
    var backend: Backend = .{};
    const scope = try rt.createScope(.{ .resolver = .{ .resolve = Backend.resolve }, .loader = .{ .data = &backend, .load = Backend.load } });
    try t.expect(try scope.module_map.get(.{ .module_id = "canonical" }, null) == null);
    try t.expectEqual(@as(usize, 0), backend.loads);
    try exposeModule(scope, "alias-a", "first");
    try exposeModule(scope, "alias-b", "second");
    try check(scope, "first === second");
    try t.expectEqual(@as(usize, 1), backend.loads);
    try t.expect(try scope.module_map.get(.{ .module_id = "alias-a" }, null) == null);
    try t.expectEqual(@as(usize, 0), try scope.module_map.delete(.{ .module_id = "alias-a" }));
    try scope.module_map.update(.{ .module_id = "canonical" }, .{ .source = "export const value = 9" }, null);
    try exposeModule(scope, "alias-b", "updated");
    try check(scope, "updated.value === 9 && first.value === 1 && updated !== first");
    try t.expectEqual(@as(usize, 1), backend.loads);
    try t.expectEqual(@as(usize, 1), try scope.module_map.delete(.{ .module_id = "canonical" }));
    try exposeModule(scope, "alias-a", "reloaded");
    try check(scope, "reloaded.value === 1 && reloaded !== first");
    try t.expectEqual(@as(usize, 2), backend.loads);
}

test "managed module maps: pending and failed lookups recover through replacement" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    var backend: Deferred = .{};
    const scope = try rt.createScope(backend.options());
    const key: m.ModuleMapKey = .{ .module_id = "pending" };
    const pending = try scope.importModule("pending", null);
    defer pending.deinit();
    try t.expect(try scope.module_map.get(key, null) == null);
    try t.expectEqual(@as(usize, 1), backend.count);
    try rt.completeLoad(backend.tokens[0], .{ .failure = error.NotFound });
    rt.pump();
    try expectState(rt, pending, .Rejected);
    try t.expectError(error.JavaScriptException, scope.module_map.get(key, null));
    try scope.module_map.update(key, .{ .source = "export const value = 42" }, null);
    const recovered = (try scope.module_map.get(key, null)).?;
    defer recovered.deinit();
    try exposeModule(scope, "pending", "recovered");
    try check(scope, "recovered.value === 42");
    try t.expectEqual(@as(usize, 1), backend.count);
    try t.expectError(error.JavaScriptException, scope.module_map.update(key, .{ .source = "export const =" }, null));
    try t.expectError(error.JavaScriptException, scope.module_map.get(key, null));
    try t.expectEqual(@as(usize, 1), try scope.module_map.delete(key));
    try t.expect(try scope.module_map.get(key, null) == null);
    try check(scope, "recovered.value === 42");
}

test "managed module maps: import rewriting precedes static and dynamic lookup" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    var import_map_1 = try m.ImportMap.parseJson(t.allocator, "{\"imports\":{\"root\":\"app:/main.js\",\"dep\":\"app:/one.js\"}}", .{ .base_url = "app:/map.json", .urls = m.virtual_urls });
    defer import_map_1.deinit();
    const a = try rt.createScope(.{ .import_map = &import_map_1 });
    var import_map_2 = try m.ImportMap.parseJson(t.allocator, "{\"imports\":{\"root\":\"app:/main.js\",\"dep\":\"app:/two.js\"}}", .{ .base_url = "app:/map.json", .urls = m.virtual_urls });
    defer import_map_2.deinit();
    const b = try rt.createScope(.{ .import_map = &import_map_2 });
    try a.module_map.update(.{ .module_id = "app:/one.js" }, .{ .source = "export const value = 1" }, null);
    try b.module_map.update(.{ .module_id = "app:/two.js" }, .{ .source = "export const value = 2" }, null);
    const source = "import {value} from 'dep'; export {value}; export async function later(){return (await import('dep')).value}";
    for ([_]*m.Scope{ a, b }) |scope| {
        try scope.module_map.update(.{ .module_id = "app:/main.js" }, .{ .source = source }, null);
        try t.expect(try scope.module_map.get(.{ .module_id = "dep" }, null) == null);
        const module = (try scope.module_map.get(.{ .module_id = "app:/main.js" }, null)).?;
        module.deinit();
        try exposeModule(scope, "root", "main");
        try check(scope, "globalThis.laterValue = 0; main.later().then(v => { laterValue = v }); true");
    }
    rt.pump();
    try check(a, "main.value === 1 && laterValue === 1");
    try check(b, "main.value === 2 && laterValue === 2");
    try t.expectEqual(@as(usize, 2), try a.module_map.delete(.{ .module_id = "app:/one.js" }));
    try t.expect(try a.module_map.get(.{ .module_id = "app:/main.js" }, null) == null);
    const unaffected = (try b.module_map.get(.{ .module_id = "app:/main.js" }, null)).?;
    unaffected.deinit();
    try check(a, "main.value === 1");
}
