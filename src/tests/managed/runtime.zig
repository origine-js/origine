const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const m = @import("@managed");
const ensureV8 = @import("../support.zig").ensureV8;
const support = @import("support.zig");
const check = support.check;
const exposeModule = support.exposeModule;
const AttributeBackend = support.AttributeBackend;

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
    try t.expect(bc.getGlobal().set(bc, v8.String.initUtf8(rt.isolate, "foreign").name.primitive.value, ac.getGlobal().value).?);
    try t.expectError(error.JavaScriptException, b.eval("foreign.local", "test:foreign", null));
    const obj = retained.deref().toObject(ac).?;
    try t.expectEqual(@as(i32, 42), obj.get(ac, v8.String.initUtf8(rt.isolate, "answer").name.primitive.value).?.i32Value(ac).?);
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
    _ = v8.Script.compile(session.ctx, v8.String.initUtf8(session.isolate(), "throw 1"), null).?.run(session.ctx);
    var info: m.ErrorInfo = .{};
    defer info.deinit();
    session.retainException(&info);
    try t.expect(info.exception != null);
}
