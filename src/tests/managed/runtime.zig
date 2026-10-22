const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const eu = @import("@util");
const m = @import("@managed");
const ensureV8 = @import("../support.zig").ensureV8;
const support = @import("support.zig");
const check = support.check;
const exposeModule = support.exposeModule;
const AttributeBackend = support.AttributeBackend;

test "native stack limits are per scope and affect subsequent captures only" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const a = try rt.createScope(.{ .stack_trace_limit = .{ .limited = 2 } });
    const b = try rt.createScope(.{});
    try t.expectEqual(@as(u31, 2), a.getStackTraceLimit().limited);
    try t.expectEqual(@as(u31, 10), b.getStackTraceLimit().limited);
    const setup =
        \\globalThis.capture = function descend(n) { return n ? descend(n - 1) : new Error('capture'); };
        \\globalThis.frames = error => error.stack.split('\n').length - 1;
        \\!Object.hasOwn(Error, 'stackTraceLimit')
    ;
    try check(a, setup);
    try check(b, setup);
    try check(a, "globalThis.saved = capture(24); frames(saved) === 2");
    try check(b, "frames(capture(24)) === 10");
    a.setStackTraceLimit(.unlimited);
    try t.expect(a.getStackTraceLimit() == .unlimited);
    try check(a, "frames(capture(24)) > 20 && frames(saved) === 2");
    a.setStackTraceLimit(.none);
    try t.expect(a.getStackTraceLimit() == .none);
    try check(a, "frames(capture(24)) === 0");
    try check(b, "frames(capture(24)) === 10");
    a.setStackTraceLimit(.{ .limited = 0 });
    try t.expect(a.getStackTraceLimit() == .none);
    a.setStackTraceLimit(.{ .limited = 3 });
    try check(a, "const target = {}; Error.captureStackTrace(target); frames(target) <= 3 && frames(capture(24)) === 3");
}

test "shared memory is available and blocking Atomics.wait is controlled per isolate" {
    ensureV8();
    const disabled = try m.Runtime.create(t.allocator, .{});
    defer disabled.destroy();
    const enabled = try m.Runtime.create(t.allocator, .{ .allow_explicit_blocking_api = true });
    defer enabled.destroy();
    const a = try disabled.createScope(.{});
    const b = try enabled.createScope(.{});
    const c = try enabled.createScope(.{});
    for ([_]*m.Scope{ a, b, c }) |scope| {
        try check(scope,
            \\globalThis.cells = new Int32Array(new SharedArrayBuffer(4));
            \\Atomics.store(cells, 0, 7) === 7 && Atomics.add(cells, 0, 2) === 7 &&
            \\Atomics.load(cells, 0) === 9 && Atomics.notify(cells, 0) === 0 &&
            \\Atomics.waitAsync(cells, 0, 0).value === 'not-equal' &&
            \\Object.isFrozen(Atomics) && Object.isFrozen(SharedArrayBuffer.prototype)
        );
    }
    try t.expectError(error.JavaScriptException, a.eval("Atomics.wait(cells, 0, 9, 0)", "test:wait-disabled", null));
    try check(b, "Atomics.wait(cells, 0, 9, 0) === 'timed-out'");
    try check(c, "Atomics.wait(cells, 0, 0, 0) === 'not-equal'");
    disabled.isolate.setAllowExplicitBlockingApi(true);
    try check(a, "Atomics.wait(cells, 0, 9, 0) === 'timed-out'");
    enabled.isolate.setAllowExplicitBlockingApi(false);
    for ([_]*m.Scope{ b, c }) |scope| {
        try t.expectError(error.JavaScriptException, scope.eval("Atomics.wait(cells, 0, 9, 0)", "test:wait-toggled", null));
    }
    const later = try enabled.createScope(.{});
    try t.expectError(error.JavaScriptException, later.eval("Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 0)", "test:future-context", null));
    try check(a, "Atomics.wait(cells, 0, 9, 0) === 'timed-out'");
}

test "managed step 1: scopes, strict evaluation, persistent handles and context restoration" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const a = try rt.createScope(.{});
    const b = try rt.createScope(.{});
    try check(a, "globalThis.local = 1; local === 1");
    try check(b, "typeof local === 'undefined'");
    try t.expectError(error.JavaScriptException, a.eval("undeclared = 1", "test:strict", null));
    const retained = try a.eval("({ answer: 42 })", "test:retain", null);
    defer retained.deinit();
    rt.isolate.enter();
    defer rt.isolate.exit();
    var h_scope: v8.HandleScope = undefined;
    h_scope.init(rt.isolate);
    defer h_scope.deinit();
    const ac = a.context.deref();
    ac.enter();
    defer ac.exit();
    try check(b, "true");
    try t.expect(rt.isolate.getCurrentContext().eq(ac));
    const bc = b.context.deref();
    try t.expect(!ac.getSecurityToken().?.strictEquals(bc.getSecurityToken().?));
    try t.expect(bc.getGlobal().set(bc, eu.v.str_utf8(rt.isolate, "foreign").name.primitive.value, ac.getGlobal().value).?);
    try t.expectError(error.JavaScriptException, b.eval("foreign.local", "test:foreign", null));
    const obj = retained.deref().toObject(ac).?;
    try t.expectEqual(@as(i32, 42), obj.get(ac, eu.v.str_utf8(rt.isolate, "answer").name.primitive.value).?.i32Value(ac).?);
}

test "strict mode is mandatory by default for scripts, hashbangs and ESM" {
    ensureV8();
    var backend: AttributeBackend = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(backend.options());
    try check(scope, "(function(){return this})() === undefined");
    try check(scope, "#!/usr/bin/env js\n(function(){return this})() === undefined");
    for ([_][]const u8{
        "implicitGlobal = 1",         "with ({}) {}",                                  "function duplicate(a,a){}", "010",
        "Object.freeze({a:1}).a = 2", "#!/usr/bin/env js\nimplicitHashbangGlobal = 1",
    }) |source| try t.expectError(error.JavaScriptException, scope.eval(source, "test:strict", null));
    try exposeModule(scope, "strict", "strictModule");
    try check(scope, "strictModule.strict && strictModule.denied && typeof implicitModuleGlobal === 'undefined'");
    const located = try scope.eval("\n(function located(){})", "test:unchanged-source", null);
    defer located.deinit();
    rt.isolate.enter();
    defer rt.isolate.exit();
    var h_scope: v8.HandleScope = undefined;
    h_scope.init(rt.isolate);
    defer h_scope.deinit();
    try t.expectEqual(@as(c_int, 1), v8.Function.from_opaque(located.deref().data.handle).?.getScriptLineNumber());
}

test "scope session: enters context and captures exceptions through the guard" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    const value = try scope.eval("globalThis.marker = 7", "test:session", null);
    defer value.deinit();
    var session: m.Scope.Session = undefined;
    session.init(scope);
    defer session.deinit();
    try t.expect(session.isolate().getCurrentContext().eq(scope.context.deref()));
    try t.expectEqual(@as(i32, 7), value.deref().i32Value(session.ctx).?);
    _ = v8.Script.compile(session.ctx, eu.v.str_utf8(session.isolate(), "throw 1"), null).?.run(session.ctx);
    var info: m.ErrorInfo = .{};
    defer info.deinit();
    session.retainException(&info);
    try t.expect(info.exception != null);
}
