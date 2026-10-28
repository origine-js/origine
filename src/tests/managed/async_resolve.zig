//! Asynchronous resolvers (`Resolver.resolve_async` + `Runtime.completeResolve`): a request can be
//! parked while the host decides what it resolves to, for a dependency and for the import's root.
const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const m = @import("@managed");
const ensureV8 = @import("../support.zig").ensureV8;
const support = @import("support.zig");
const check = support.check;
const expectState = support.expectState;

const Backend = struct {
    tokens: [4]m.LoadToken = @splat(0),
    count: usize = 0,
    cancelled: usize = 0,
    loads: usize = 0,

    /// `slow:*` specifiers park; everything else resolves to itself.
    fn resolveAsync(data: ?*anyopaque, request: m.ResolveRequest) anyerror!m.ResolveOutcome {
        const self: *Backend = @ptrCast(@alignCast(data.?));
        if (std.mem.startsWith(u8, request.specifier, "slow:")) {
            self.tokens[self.count] = request.token;
            self.count += 1;
            return .pending;
        }
        return .{ .id = try request.allocator.dupe(u8, request.specifier) };
    }

    fn cancel(data: ?*anyopaque, _: m.LoadToken) void {
        const self: *Backend = @ptrCast(@alignCast(data.?));
        self.cancelled += 1;
    }

    fn load(data: ?*anyopaque, request: m.LoadRequest) anyerror!m.LoadResult {
        const self: *Backend = @ptrCast(@alignCast(data.?));
        self.loads += 1;
        const id = request.module_id;
        if (std.mem.eql(u8, id, "main")) return .{ .source = "import { v } from 'slow:dep'; export const answer = v;" };
        if (std.mem.eql(u8, id, "two")) return .{ .source = "import { v } from 'slow:one'; import { w } from 'slow:two'; export const sum = v + w;" };
        if (std.mem.eql(u8, id, "dep")) return .{ .source = "export const v = 5;" };
        if (std.mem.eql(u8, id, "one")) return .{ .source = "export const v = 1;" };
        if (std.mem.eql(u8, id, "second")) return .{ .source = "export const w = 2;" };
        return error.FileNotFound;
    }

    fn options(self: *Backend) m.Scope.Options {
        return .{
            .resolver = .{ .data = self, .resolve_async = resolveAsync, .cancel = cancel },
            .loader = .{ .data = self, .load = load },
        };
    }
};

test "a dependency parked in the resolver holds its importer back until it settles" {
    ensureV8();
    var backend: Backend = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(backend.options());
    const promise = try scope.importModule("main", null);
    defer promise.deinit();
    rt.pump();
    try t.expectEqual(@as(usize, 1), backend.count);
    try expectState(rt, promise, .Pending);
    // Nothing else ran: `dep` is not even loaded, and pumping again changes nothing.
    try t.expectEqual(@as(usize, 1), backend.loads);
    rt.pump();
    try expectState(rt, promise, .Pending);

    try rt.completeResolve(backend.tokens[0], .{ .id = "dep" });
    rt.pump();
    try expectState(rt, promise, .Fulfilled);
    try support.exposeModule(scope, "main", "main");
    try check(scope, "main.answer === 5");
    // A token settles once.
    try t.expectError(error.StaleLoadToken, rt.completeResolve(backend.tokens[0], .{ .id = "dep" }));
}

test "several parked requests of one module resolve in any order" {
    ensureV8();
    var backend: Backend = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(backend.options());
    const promise = try scope.importModule("two", null);
    defer promise.deinit();
    rt.pump();
    try t.expectEqual(@as(usize, 2), backend.count);
    try rt.completeResolve(backend.tokens[1], .{ .id = "second" });
    rt.pump();
    try expectState(rt, promise, .Pending);
    try rt.completeResolve(backend.tokens[0], .{ .id = "one" });
    rt.pump();
    try expectState(rt, promise, .Fulfilled);
    try support.exposeModule(scope, "two", "two");
    try check(scope, "two.sum === 3");
}

test "the root of an import can be parked, and a failure rejects it" {
    ensureV8();
    var backend: Backend = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(backend.options());
    const first = try scope.importModule("slow:main", null);
    defer first.deinit();
    const second = try scope.importModule("slow:other", null);
    defer second.deinit();
    rt.pump();
    try t.expectEqual(@as(usize, 2), backend.count);
    try rt.completeResolve(backend.tokens[0], .{ .id = "dep" });
    try rt.completeResolve(backend.tokens[1], .{ .failure = error.FileNotFound });
    rt.pump();
    try expectState(rt, first, .Fulfilled);
    try expectState(rt, second, .Rejected);
}

test "a failed resolution fails the module that asked, not the others" {
    ensureV8();
    var backend: Backend = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(backend.options());
    const promise = try scope.importModule("main", null);
    defer promise.deinit();
    rt.pump();
    try rt.completeResolve(backend.tokens[0], .{ .failure = error.FileNotFound });
    rt.pump();
    try expectState(rt, promise, .Rejected);
}

test "tokens still parked when the runtime is destroyed are cancelled" {
    ensureV8();
    var backend: Backend = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    const scope = try rt.createScope(backend.options());
    const dependency = try scope.importModule("main", null);
    const root = try scope.importModule("slow:root", null);
    rt.pump();
    try t.expectEqual(@as(usize, 2), backend.count);
    dependency.deinit();
    root.deinit();
    rt.destroy();
    try t.expectEqual(@as(usize, 2), backend.cancelled);
}
