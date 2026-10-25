//! REPL-only V8 helpers. Persistent handles are owned by Helpers and released
//! before its borrowed scope/runtime; no globals are installed in the guest.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const m = @import("@managed");

fn isProxy(info: v8.FunctionCallbackInfo) callconv(.c) void {
    var result = info.retval();
    result.setBool(info.get_arg(0).isProxy());
}

/// Private REPL adapter: reads one validated identifier through V8's script
/// API without enabling guest eval or Function code generation.
fn lookupIdentifier(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const iso = info.isolate();
    var result = info.retval();
    result.setUndefined();
    if (info.length() < 1 or !info.get_arg(0).isString()) return;
    const source = info.get_arg(0).toString(iso.getCurrentContext()) orelse return;
    var bytes: [512]u8 = undefined;
    if (source.lenUtf8(iso) == 0 or source.lenUtf8(iso) > bytes.len) return;
    const n = source.writeUtf8(iso, &bytes);
    for (bytes[0..n], 0..) |ch, i| {
        if (ch != '_' and ch != '$' and !std.ascii.isAlphabetic(ch) and !(i > 0 and std.ascii.isDigit(ch))) return;
    }
    var catcher: v8.TryCatch = undefined;
    catcher.init(iso);
    defer catcher.deinit();
    const ctx = iso.getCurrentContext();
    const script = v8.Script.compile(ctx, source, null) orelse return;
    const value = script.run(ctx) orelse return;
    if (info.length() > 1 and info.get_arg(1).isTrue()) result.setBool(true) else result.set(value);
}

pub const Helpers = struct {
    scope: *m.Scope,
    function: v8.Global.Of(v8.Function),

    pub fn init(scope: *m.Scope) !Helpers {
        const factory = try scope.eval(@embedFile("helpers.js"), "origine:repl/helpers", null);
        defer factory.deinit();
        const isolate = scope.runtime.isolate;
        isolate.enter();
        defer isolate.exit();
        var handles: v8.HandleScope = undefined;
        handles.init(isolate);
        defer handles.deinit();
        const ctx = scope.context.deref();
        ctx.enter();
        defer ctx.exit();
        const proxy = v8.Function.init(ctx, isProxy, null, 1, .Throw, .HasNoSideEffect);
        const lookup = v8.Function.init(ctx, lookupIdentifier, null, 1, .Throw, .HasSideEffect);
        const function = v8.Function.from_opaque(factory.deref().data.handle).?.call(ctx, eu.v.undefined_value(isolate).value, &.{ proxy.object.value, lookup.object.value }) orelse return error.JavaScriptException;
        return .{ .scope = scope, .function = .new(isolate, v8.Function.from_opaque(function.data.handle).?) };
    }

    pub fn deinit(self: Helpers) void {
        self.function.deinit();
    }

    /// Returns a caller-owned formatted string handle; borrows input until return.
    pub fn display(self: Helpers, mode: []const u8, value: v8.Global.Of(v8.Value)) !v8.Global.Of(v8.Value) {
        const isolate = self.scope.runtime.isolate;
        isolate.enter();
        defer isolate.exit();
        var handles: v8.HandleScope = undefined;
        handles.init(isolate);
        defer handles.deinit();
        const ctx = self.scope.context.deref();
        ctx.enter();
        defer ctx.exit();
        var catcher: v8.TryCatch = undefined;
        catcher.init(isolate);
        defer catcher.deinit();
        const result = self.function.deref().call(ctx, eu.v.undefined_value(isolate).value, &.{ eu.v.str_utf8(isolate, mode).name.primitive.value, value.deref() }) orelse return error.JavaScriptException;
        return .new(isolate, result);
    }

    /// Caller-owned handle listing completions for `prefix`.
    pub fn complete(self: Helpers, prefix: []const u8) !v8.Global.Of(v8.Value) {
        return self.displayText("complete", prefix);
    }

    /// Copies completion text into caller-owned storage; no V8 handle escapes.
    pub fn completeText(self: Helpers, allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
        return self.renderText(allocator, "complete", prefix);
    }

    /// Formats `source` in `mode` and copies the text into caller-owned storage.
    pub fn renderText(self: Helpers, allocator: std.mem.Allocator, mode: []const u8, source: []const u8) ![]u8 {
        const result = try self.displayText(mode, source);
        defer result.deinit();
        var session: m.Scope.Session = undefined;
        session.init(self.scope);
        defer session.deinit();
        const text = result.deref().toString(session.ctx) orelse return error.JavaScriptException;
        const bytes = try allocator.alloc(u8, text.lenUtf8(session.isolate()));
        _ = text.writeUtf8(session.isolate(), bytes);
        return bytes;
    }

    /// Records a result (or thrown value) as `_` / `_error`, and successful
    /// sources for lexical completion.
    pub fn remember(self: Helpers, source: []const u8, value: v8.Global.Of(v8.Value), failed: bool) !void {
        const saved = try self.display(if (failed) "error" else "result", value);
        saved.deinit();
        if (failed) return;
        const tracked = try self.displayText("track", source);
        tracked.deinit();
    }

    fn displayText(self: Helpers, mode: []const u8, text: []const u8) !v8.Global.Of(v8.Value) {
        var session: m.Scope.Session = undefined;
        session.init(self.scope);
        defer session.deinit();
        const argument: v8.Global.Of(v8.Value) = .new(session.isolate(), eu.v.str_utf8(session.isolate(), text).name.primitive.value);
        defer argument.deinit();
        return self.display(mode, argument);
    }
};
