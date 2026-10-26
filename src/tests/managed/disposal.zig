//! Scope disposal: `Runtime.disposeScope` marks, `Runtime.reap` frees at the next safe point.
const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const m = @import("@managed");
const ensureV8 = @import("../support.zig").ensureV8;
const support = @import("support.zig");
const check = support.check;
const Memory = support.Memory;
const Deferred = support.Deferred;
const exposeModule = support.exposeModule;

test "disposed scopes are freed at the next entry point and leak nothing" {
    ensureV8();
    var memory: Memory = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const keeper = try rt.createScope(memory.options());
    for (0..50) |_| {
        const scope = try rt.createScope(memory.options());
        try exposeModule(scope, "main", "main");
        try check(scope, "typeof main.answer === 'number'");
        rt.disposeScope(scope);
        try t.expect(scope.isDisposed());
        // Disposal alone frees nothing: the scope is still listed until the next entry point.
        try t.expectEqual(@as(usize, 2), rt.scopes.items.len);
        rt.pump();
        try t.expectEqual(@as(usize, 1), rt.scopes.items.len);
    }
    try check(keeper, "1 + 1 === 2");
    try t.expectEqual(@as(usize, 0), rt.disposed_pending);
}

test "a disposed scope refuses new work and scope ids are not reused" {
    ensureV8();
    var memory: Memory = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const first = try rt.createScope(memory.options());
    const first_id = first.id;
    rt.disposeScope(first);
    rt.disposeScope(first); // idempotent
    try t.expectEqual(@as(usize, 1), rt.disposed_pending);
    try t.expectError(error.ScopeDisposed, first.eval("1", "test:disposed", null));
    try t.expectError(error.ScopeDisposed, first.importModule("main", null));
    const second = try rt.createScope(memory.options());
    try t.expect(second.id != first_id);
    try t.expectEqual(@as(usize, 1), rt.scopes.items.len);
}

test "disposing from inside a loader callback is deferred until the pump ends" {
    ensureV8();
    const Suicide = struct {
        scope: *m.Scope = undefined,
        calls: usize = 0,
        fn resolve(_: ?*anyopaque, request: m.ResolveRequest) ![]const u8 {
            return request.allocator.dupe(u8, request.specifier);
        }
        fn load(data: ?*anyopaque, _: m.LoadRequest) !m.LoadResult {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.calls += 1;
            self.scope.runtime.disposeScope(self.scope);
            return .{ .source = "export const value = 1;" };
        }
    };
    var state: Suicide = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    state.scope = try rt.createScope(.{ .resolver = .{ .resolve = Suicide.resolve }, .loader = .{ .data = &state, .load = Suicide.load } });
    const promise = try state.scope.importModule("main", null);
    promise.deinit();
    rt.pump();
    try t.expectEqual(@as(usize, 1), state.calls);
    // The pump that ran the loader did not free the scope it was driving; the next entry point does.
    rt.pump();
    try t.expectEqual(@as(usize, 0), rt.scopes.items.len);
}

test "pending loads of a disposed scope are cancelled and later completions are stale" {
    ensureV8();
    var deferred: Deferred = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(deferred.options());
    const promise = try scope.importModule("later", null);
    promise.deinit();
    rt.pump();
    try t.expectEqual(@as(usize, 1), deferred.count);
    rt.disposeScope(scope);
    rt.pump();
    try t.expectEqual(@as(usize, 1), deferred.cancelled);
    try t.expectError(error.StaleLoadToken, rt.completeLoad(deferred.tokens[0], .{ .content = .{ .source = "export {}" } }));
}

test "a function that outlives its scope runs but finds no scope for import()" {
    ensureV8();
    var memory: Memory = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const doomed = try rt.createScope(memory.options());
    const survivor = try rt.createScope(memory.options());
    const load = try doomed.eval("(() => import('main'))", "test:zombie", null);
    defer load.deinit();
    const sum = try doomed.eval("(() => 2 + 2)", "test:zombie-sum", null);
    defer sum.deinit();
    rt.disposeScope(doomed);
    rt.pump();
    try t.expectEqual(@as(usize, 1), rt.scopes.items.len);
    var session: m.Scope.Session = undefined;
    session.init(survivor);
    defer session.deinit();
    const undefined_value = v8.Isolate.getCurrent().getCurrentContext().getGlobal().value;
    const total = v8.Function.from_opaque(sum.deref().data.handle).?.call(session.ctx, undefined_value, &.{}).?;
    try t.expectEqual(@as(?u32, 4), total.u32Value(session.ctx));
    const result = v8.Function.from_opaque(load.deref().data.handle).?.call(session.ctx, undefined_value, &.{}).?;
    try t.expect(result.isPromise());
    const promise = v8.Promise.from_opaque(result.data.handle).?;
    try t.expectEqual(v8.Promise.PromiseState.Rejected, promise.state());
}
