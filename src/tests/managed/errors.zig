const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const m = @import("@managed");
const ensureV8 = @import("../support.zig").ensureV8;
const support = @import("support.zig");
const check = support.check;
const sameRetainedValue = support.sameRetainedValue;
const expectState = support.expectState;

test "error info: eval retains thrown identity, syntax errors and undefined" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    const marker = try scope.eval("globalThis.marker = {value: 42}; marker", "test:marker", null);
    defer marker.deinit();
    var error_info: m.ErrorInfo = .{};
    defer error_info.deinit();
    try t.expectError(error.JavaScriptException, scope.eval("throw marker", "test:throw", &error_info));
    try sameRetainedValue(rt, error_info.exception.?, marker);
    const success = try scope.eval("42", "test:success", &error_info);
    defer success.deinit();
    try t.expect(error_info.exception == null);
    try t.expectError(error.JavaScriptException, scope.eval("throw undefined", "test:undefined", &error_info));
    const undefined_value = try scope.eval("undefined", "test:undefined-value", null);
    defer undefined_value.deinit();
    try sameRetainedValue(rt, error_info.exception.?, undefined_value);
    try t.expectError(error.JavaScriptException, scope.eval("const =", "test:syntax", &error_info));
    rt.isolate.enter();
    defer rt.isolate.exit();
    var h_scope: v8.HandleScope = undefined;
    h_scope.init(rt.isolate);
    defer h_scope.deinit();
    const ctx = scope.context.deref();
    ctx.enter();
    defer ctx.exit();
    try t.expect(error_info.exception.?.deref().isNativeError());
    try t.expect(ctx.getGlobal().set(ctx, v8.String.initUtf8(rt.isolate, "syntaxError").name.primitive.value, error_info.exception.?.deref()).?);
    try check(scope, "syntaxError.name === 'SyntaxError'");
}

test "error info: hardening and capability installation preserve caught errors" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    const proxy = try scope.eval("new Proxy({}, {})", "test:proxy", null);
    defer proxy.deinit();
    var error_info: m.ErrorInfo = .{};
    defer error_info.deinit();
    try t.expectError(error.UnsupportedExport, scope.harden(proxy, &error_info));
    try t.expect(error_info.exception != null);
    try t.expectError(error.UnsupportedExport, scope.installCapability("proxy", proxy, &error_info));
    try t.expect(error_info.exception != null);
    const record = try scope.eval("({value: 42})", "test:record", null);
    defer record.deinit();
    try scope.installCapability("record", record, &error_info);
    try t.expect(error_info.exception == null);
    try check(scope, "record.value === 42 && typeof proxy === 'undefined'");
}

test "error info: module-map compilation failures and promise rejections" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    const key: m.ModuleMapKey = .{ .module_id = "module" };
    var error_info: m.ErrorInfo = .{};
    defer error_info.deinit();
    try t.expectError(error.JavaScriptException, scope.updateImportCache(key, .{ .source = "export const =" }, &error_info));
    try t.expect(error_info.exception != null);
    var cached_error_info: m.ErrorInfo = .{};
    defer cached_error_info.deinit();
    try t.expectError(error.JavaScriptException, scope.module_map.get(key, &cached_error_info));
    try sameRetainedValue(rt, error_info.exception.?, cached_error_info.exception.?);
    const rejected = try scope.importModule("module", &error_info);
    defer rejected.deinit();
    try t.expect(error_info.exception == null);
    try expectState(rt, rejected, .Rejected);
    try scope.module_map.update(key, .{ .source = "export const value = 42" }, &error_info);
    try t.expect(error_info.exception == null);
    const recovered = try scope.importModuleWithAttributes("module", &.{}, &error_info);
    defer recovered.deinit();
    rt.pump();
    try expectState(rt, recovered, .Fulfilled);
    try t.expect(error_info.exception == null);
    try t.expectError(error.JavaScriptException, scope.module_map.update(key, .{ .source = "export const =" }, &error_info));
    try t.expect(error_info.exception != null);
}
