const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const m = @import("@managed");
const ensureV8 = @import("../support.zig").ensureV8;
const support = @import("support.zig");
const check = support.check;
const Memory = support.Memory;
const exposeModule = support.exposeModule;
const Deferred = support.Deferred;
const expectState = support.expectState;

test "managed step 4: native ESM graphs, cycles, TLA and defining scope" {
    ensureV8();
    var memory: Memory = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const a = try rt.createScope(memory.options());
    const b = try rt.createScope(memory.options());
    try exposeModule(a, "main", "main");
    try exposeModule(b, "main", "main");
    try check(a, "main.answer === 1 && main.origin === 'main'");
    try check(b, "main.answer === 2");
    const loads = memory.loads;
    try exposeModule(a, "main", "again");
    try check(a, "main === again");
    try t.expectEqual(loads, memory.loads);
    try exposeModule(a, "cycle-a", "cycle");
    try check(a, "cycle.read() === 3");
    try exposeModule(a, "await", "awaited");
    try check(a, "awaited.value === 42");
    try exposeModule(a, "dynamic", "dynamic");
    try check(a, "dynamic.value === 1");
    const later = try a.eval("main.later", "test:later", null);
    defer later.deinit();
    try b.installCapability("fromA", later, null);
    try check(b, "globalThis.answer = 0; fromA().then(value => {answer = value}); true");
    rt.pump();
    try check(b, "answer === 1");
    for ([_][]const u8{ "syntax", "throw", "missing-export", "attributes", "absent" }) |id| {
        const promise = try a.importModule(id, null);
        defer promise.deinit();
        rt.pump();
        rt.isolate.enter();
        defer rt.isolate.exit();
        var h_scope: v8.HandleScope = undefined;
        h_scope.init(rt.isolate);
        defer h_scope.deinit();
        try t.expectEqual(v8.Promise.PromiseState.Rejected, promise.deref().state());
    }
}

test "managed: the origine: namespace needs origine_namespace" {
    ensureV8();
    var memory: Memory = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    var enabled_options = memory.options();
    enabled_options.origine_namespace = true;
    const closed = try rt.createScope(memory.options());
    const open = try rt.createScope(enabled_options);
    try exposeModule(open, "origine:mod", "direct");
    try exposeModule(open, "uses-origine", "indirect");
    try check(open, "direct.value === 7 && indirect.value === 7");
    for ([_][]const u8{ "origine:mod", "uses-origine" }) |id| {
        const promise = try closed.importModule(id, null);
        defer promise.deinit();
        rt.pump();
        rt.isolate.enter();
        defer rt.isolate.exit();
        var h_scope: v8.HandleScope = undefined;
        h_scope.init(rt.isolate);
        defer h_scope.deinit();
        try t.expectEqual(v8.Promise.PromiseState.Rejected, promise.deref().state());
    }
    // Dynamic import is gated too.
    try check(closed, "globalThis.gated = 0; import('origine:mod').catch(() => { gated = 1 }); true");
    rt.pump();
    try check(closed, "gated === 1");
}

test "managed step 5: deferred backend, deduplication, cycles and stale tokens" {
    ensureV8();
    var backend: Deferred = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(backend.options());
    const first = try scope.importModule("root", null);
    defer first.deinit();
    const again = try scope.importModule("root", null);
    defer again.deinit();
    try t.expectEqual(@as(usize, 1), backend.count);
    try expectState(rt, first, .Pending);
    try rt.completeLoad(backend.tokens[0], .{ .content = .{ .source = "import {a} from 'a'; import {b} from 'b'; export const value = await Promise.resolve(a() + b); export const root = 7;" } });
    try t.expectEqual(@as(usize, 3), backend.count);
    try rt.completeLoad(backend.tokens[2], .{ .content = .{ .source = "export const b = 2" } });
    rt.pump();
    try expectState(rt, first, .Pending);
    try rt.completeLoad(backend.tokens[1], .{ .content = .{ .source = "import {root} from 'root'; export function a(){return root}" } });
    rt.pump();
    // Calling a() before root initializes throws: cycle loading succeeds, evaluation correctly rejects.
    try expectState(rt, first, .Rejected);
    try expectState(rt, again, .Rejected);
    try t.expectError(error.StaleLoadToken, rt.completeLoad(backend.tokens[1], .{ .failure = error.NotFound }));
    try t.expectError(error.StaleLoadToken, rt.completeLoad(999, .{ .failure = error.NotFound }));
    const failed = try scope.importModule("failed", null);
    defer failed.deinit();
    try rt.completeLoad(backend.tokens[3], .{ .failure = error.NotFound });
    rt.pump();
    try expectState(rt, failed, .Rejected);
    const success = try scope.importModule("success", null);
    defer success.deinit();
    try rt.completeLoad(backend.tokens[4], .{ .content = .{ .source = "export const value = await Promise.resolve(42)" } });
    rt.pump();
    try expectState(rt, success, .Fulfilled);
}

test "managed step 5: teardown cancels pending requests" {
    ensureV8();
    var backend: Deferred = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    const scope = try rt.createScope(backend.options());
    const promise = try scope.importModule("pending", null);
    promise.deinit();
    rt.destroy();
    try t.expectEqual(@as(usize, 1), backend.cancelled);
}

test "managed steps 4-5: synthetic capability exports and asynchronous successful cycles" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const owner = try rt.createScope(.{});
    const value = try owner.eval("({answer:42})", "test:export", null);
    defer value.deinit();
    var exports = [_]m.Export{.{ .name = "cap", .value = value }};
    const Synthetic = struct {
        /// Borrows host callback state through return; state stays live through runtime
        /// teardown. Request ID/attribute bytes retained by this fixture remain runtime-owned
        /// until teardown begins. Returned source uses static or request-allocator storage;
        /// local handles remain in the enclosing HandleScope. Errors transfer no host ownership.
        fn load(data: ?*anyopaque, _: m.LoadRequest) !m.LoadResult {
            const items: *[1]m.Export = @ptrCast(@alignCast(data.?));
            return .{ .exports = items };
        }
    };
    const synthetic = try rt.createScope(.{ .resolver = .{ .resolve = Memory.resolve }, .loader = .{ .data = &exports, .load = Synthetic.load } });
    try exposeModule(synthetic, "capability", "caps");
    try check(synthetic, "caps.cap.answer === 42 && Object.isFrozen(caps.cap)");
    var backend: Deferred = .{};
    const scope = try rt.createScope(backend.options());
    const promise = try scope.importModule("root", null);
    defer promise.deinit();
    try rt.completeLoad(backend.tokens[0], .{ .content = .{ .source = "import {read} from 'child'; export const n = 4; export const value = () => read();" } });
    try rt.completeLoad(backend.tokens[1], .{ .content = .{ .source = "import {n} from 'root'; export function read(){return n}" } });
    rt.pump();
    try expectState(rt, promise, .Fulfilled);
}
