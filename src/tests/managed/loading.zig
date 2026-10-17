const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const m = @import("@managed");
const ensureV8 = @import("../support.zig").ensureV8;
const support = @import("support.zig");
const check = support.check;
const Memory = support.Memory;
const exposeModule = support.exposeModule;
const expectState = support.expectState;
const AttributeBackend = support.AttributeBackend;

test "loader receives context and attributes for static, dynamic and host imports" {
    ensureV8();
    var backend: AttributeBackend = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(backend.options());
    try exposeModule(scope, "main", "module");
    try check(scope, "module.values[0] === 1 && module.values[1] === 2");
    try t.expectEqual(@as(usize, 2), backend.payload_loads);
    try check(scope, "globalThis.dynamicValue = 0; import('payload', {with:{type:'custom',mode:'one'}}).then(m=>{dynamicValue=m.value}); true");
    rt.pump();
    try check(scope, "dynamicValue === 1");
    const first = try scope.importModuleWithAttributes("payload", &.{ .{ .key = "type", .value = "custom" }, .{ .key = "mode", .value = "one" } }, null);
    defer first.deinit();
    try expectState(rt, first, .Fulfilled);
    try t.expectEqual(@as(usize, 2), backend.payload_loads);
    try check(scope, "globalThis.dynamicTwo = 0; import('payload', {with:{type:'custom',mode:'new'}}).then(m=>{dynamicTwo=m.value}); true");
    rt.pump();
    try check(scope, "dynamicTwo === 2");
    try t.expectEqual(@as(usize, 3), backend.payload_loads);
    const duplicate = try scope.importModuleWithAttributes("payload", &.{ .{ .key = "type", .value = "one" }, .{ .key = "type", .value = "two" } }, null);
    defer duplicate.deinit();
    try expectState(rt, duplicate, .Rejected);
    try t.expectEqual(@as(usize, 3), backend.payload_loads);
}

test "custom loader and resolver exceptions preserve JavaScript errors" {
    ensureV8();
    var backend: AttributeBackend = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    defer if (backend.custom_error) |exception| exception.deinit();
    const scope = try rt.createScope(backend.options());
    for ([_][]const u8{ "denied", "static-denied", "thrown" }) |id| {
        const promise = try scope.importModule(id, null);
        defer promise.deinit();
        try expectState(rt, promise, .Rejected);
        rt.isolate.enter();
        defer rt.isolate.exit();
        var h_scope: v8.HandleScope = undefined;
        h_scope.init(rt.isolate);
        defer h_scope.deinit();
        try t.expect(promise.deref().result().strictEquals(backend.custom_error.?.deref()));
    }
    try check(scope, "globalThis.loaderError = false; import('denied').catch(e=>{loaderError = e instanceof TypeError && e.code === 'DENIED'}); true");
    rt.pump();
    try check(scope, "loaderError");
    try check(scope, "globalThis.resolverError = false; import('resolve-error').catch(e=>{resolverError = e instanceof TypeError && e.message === 'custom resolver error'}); true");
    rt.pump();
    try check(scope, "resolverError");
}

test "pending loads preserve attributes and accept custom async exceptions" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const Backend = struct {
        token: m.LoadToken = 0,
        attributes: []const m.ImportAttribute = &.{},
        /// Borrows host callback state through return; state stays live through runtime
        /// teardown. Request ID/attribute bytes retained by this fixture remain runtime-owned
        /// until teardown begins. Returned source uses static or request-allocator storage;
        /// local handles remain in the enclosing HandleScope. Errors transfer no host ownership.
        fn load(data: ?*anyopaque, request: m.LoadRequest) !m.LoadResult {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.token = request.token;
            self.attributes = request.import_attributes;
            try t.expect(request.context.eq(v8.Isolate.getCurrent().getCurrentContext()));
            return .pending;
        }
    };
    var backend: Backend = .{};
    const scope = try rt.createScope(.{ .resolver = .{ .resolve = Memory.resolve }, .loader = .{ .data = &backend, .load = Backend.load } });
    var attribute_value = [_]u8{ 'j', 's', 'o', 'n' };
    const promise = try scope.importModuleWithAttributes("pending", &.{.{ .key = "type", .value = &attribute_value }}, null);
    defer promise.deinit();
    @memset(&attribute_value, 'x');
    try t.expectEqualStrings("json", backend.attributes[0].value);
    const exception = try scope.eval("Object.assign(new TypeError('async denial'),{code:'ASYNC'})", "test:async-error", null);
    defer exception.deinit();
    try rt.completeLoad(backend.token, .{ .exception = exception });
    rt.pump();
    try expectState(rt, promise, .Rejected);
    rt.isolate.enter();
    defer rt.isolate.exit();
    var h_scope: v8.HandleScope = undefined;
    h_scope.init(rt.isolate);
    defer h_scope.deinit();
    try t.expect(promise.deref().result().strictEquals(exception.deref()));
}

// Local V8 scopes are released before return; no resources escape.
