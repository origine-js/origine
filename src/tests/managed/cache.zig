const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const eu = @import("@util");
const m = @import("@managed");
const ensureV8 = @import("../support.zig").ensureV8;
const support = @import("support.zig");
const check = support.check;
const Memory = support.Memory;
const exposeModule = support.exposeModule;
const Deferred = support.Deferred;
const expectState = support.expectState;
const AttributeBackend = support.AttributeBackend;
const CacheBackend = support.CacheBackend;

test "cache delete and update invalidate dependents while preserving old namespaces" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    var backend: CacheBackend = .{};
    const a = try rt.createScope(backend.options());
    const b = try rt.createScope(backend.options());
    try exposeModule(a, "main", "old");
    try exposeModule(b, "main", "other");
    backend.version = 2;
    try t.expectEqual(@as(usize, 2), try a.deleteImportCache(.{ .module_id = "dep" }));
    try t.expectEqual(@as(usize, 0), try a.deleteImportCache(.{ .module_id = "dep" }));
    try exposeModule(a, "main", "fresh");
    try check(a, "old.value === 1 && fresh.value === 2 && old !== fresh && old.origin() === 'main'");
    try check(b, "other.value === 1");
    const loads = backend.loads;
    try a.updateImportCache(.{ .module_id = "dep" }, .{ .source = "export const value = 99" }, null);
    try exposeModule(a, "main", "updated");
    try check(a, "old.value === 1 && fresh.value === 2 && updated.value === 99");
    try t.expectEqual(loads + 1, backend.loads); // Only main reloads; dep uses replacement content.
    try check(a, "globalThis.latest = 0; old.later().then(x=>{latest=x}); true");
    rt.pump();
    try check(a, "latest === 99");
    try t.expectEqual(@as(usize, 2), try a.clearImportCache());
    try t.expectEqual(@as(usize, 0), try a.clearImportCache());
    try exposeModule(a, "main", "cleared");
    try check(a, "cleared.value === 2 && updated.value === 99");
}

test "cache replacement and eviction distinguish canonical import attributes" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    var backend: AttributeBackend = .{};
    const scope = try rt.createScope(backend.options());
    try exposeModule(scope, "main", "old");
    const attrs = [_]m.ImportAttribute{ .{ .key = "type", .value = "custom" }, .{ .key = "mode", .value = "one" } };
    try scope.updateImportCache(.{ .module_id = "payload", .import_attributes = &attrs }, .{ .source = "export const value = 10" }, null);
    try exposeModule(scope, "main", "updated");
    try check(scope, "old.values[0] === 1 && updated.values[0] === 10 && updated.values[1] === 2");
    try t.expectEqual(@as(usize, 2), backend.payload_loads);
    try t.expectEqual(@as(usize, 2), try scope.deleteImportCache(.{ .module_id = "payload", .import_attributes = &attrs }));
    try exposeModule(scope, "main", "reloaded");
    try check(scope, "reloaded.values[0] === 1 && reloaded.values[1] === 2");
    try t.expectEqual(@as(usize, 3), backend.payload_loads);
}

test "cache updates preserve pending imports and retired synthetic metadata" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    var backend: Deferred = .{};
    const scope = try rt.createScope(backend.options());
    const old = try scope.importModule("module", null);
    defer old.deinit();
    try scope.updateImportCache(.{ .module_id = "module" }, .{ .source = "export const value = 3" }, null);
    const fresh = try scope.importModule("module", null);
    defer fresh.deinit();
    try expectState(rt, fresh, .Fulfilled);
    try expectState(rt, old, .Pending);
    const seven = try scope.eval("7", "test:synthetic", null);
    defer seven.deinit();
    const exports = [_]m.Export{.{ .name = "value", .value = seven }};
    try rt.completeLoad(backend.tokens[0], .{ .content = .{ .exports = &exports } });
    rt.pump();
    try expectState(rt, old, .Fulfilled);
    rt.isolate.enter();
    defer rt.isolate.exit();
    var h_scope: v8.HandleScope = undefined;
    h_scope.init(rt.isolate);
    defer h_scope.deinit();
    const ctx = scope.context.deref();
    ctx.enter();
    defer ctx.exit();
    try t.expectEqual(@as(i32, 7), old.deref().result().toObject(ctx).?.get(ctx, eu.v.str_utf8(rt.isolate, "value").name.primitive.value).?.i32Value(ctx).?);
    try t.expectEqual(@as(i32, 3), fresh.deref().result().toObject(ctx).?.get(ctx, eu.v.str_utf8(rt.isolate, "value").name.primitive.value).?.i32Value(ctx).?);
    const deleted = try scope.importModule("pending-delete", null);
    defer deleted.deinit();
    try t.expectEqual(@as(usize, 1), try scope.deleteImportCache(.{ .module_id = "pending-delete" }));
    const reloaded = try scope.importModule("pending-delete", null);
    defer reloaded.deinit();
    try t.expectEqual(@as(usize, 3), backend.count);
    try rt.completeLoad(backend.tokens[1], .{ .content = .{ .source = "export const old = true" } });
    try rt.completeLoad(backend.tokens[2], .{ .content = .{ .source = "export const old = false" } });
    rt.pump();
    try expectState(rt, deleted, .Fulfilled);
    try expectState(rt, reloaded, .Fulfilled);
    try t.expectError(error.StaleLoadToken, rt.completeLoad(backend.tokens[0], .{ .failure = error.NotFound }));
}

test "cache operations support cycles, cached failures and insertion without loading" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    var backend: Memory = .{};
    const scope = try rt.createScope(backend.options());
    try exposeModule(scope, "cycle-a", "old");
    try scope.updateImportCache(.{ .module_id = "cycle-b" }, .{ .source = "import {a} from 'cycle-a'; export function b(){return a+10}" }, null);
    try exposeModule(scope, "cycle-a", "fresh");
    try check(scope, "old.read() === 3 && fresh.read() === 13");
    try t.expectError(error.JavaScriptException, scope.updateImportCache(.{ .module_id = "inserted" }, .{ .source = "export const =" }, null));
    const failed = try scope.importModule("inserted", null);
    defer failed.deinit();
    try expectState(rt, failed, .Rejected);
    const loads = backend.loads;
    try scope.updateImportCache(.{ .module_id = "inserted" }, .{ .source = "export const value = 42" }, null);
    try exposeModule(scope, "inserted", "inserted");
    try check(scope, "inserted.value === 42");
    try t.expectEqual(loads, backend.loads);
    const missing = try scope.importModule("missing", null);
    defer missing.deinit();
    try expectState(rt, missing, .Rejected);
    try t.expectEqual(@as(usize, 1), try scope.deleteImportCache(.{ .module_id = "missing" }));
}

test "cache mutation is rejected during loader callbacks" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const Backend = struct {
        scope: *m.Scope = undefined,
        /// Borrows host callback state through return; state stays live through runtime
        /// teardown. Request ID/attribute bytes retained by this fixture remain runtime-owned
        /// until teardown begins. Returned source uses static or request-allocator storage;
        /// local handles remain in the enclosing HandleScope. Errors transfer no host ownership.
        fn load(data: ?*anyopaque, _: m.LoadRequest) !m.LoadResult {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            try t.expectError(error.ImportCacheBusy, self.scope.clearImportCache());
            return .{ .source = "export const value = 42" };
        }
    };
    var backend: Backend = .{};
    const scope = try rt.createScope(.{ .resolver = .{ .resolve = Memory.resolve }, .loader = .{ .data = &backend, .load = Backend.load } });
    backend.scope = scope;
    try exposeModule(scope, "main", "module");
    try check(scope, "module.value === 42");
}
