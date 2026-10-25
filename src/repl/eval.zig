//! Evaluation and continuation probing for the REPL. Probes only compile; guest
//! code runs exactly once, through `eval`.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const m = @import("@managed");

/// REPL expressions beginning with `{` are object literals when that grammar
/// compiles. Probe only; never retry execution after guest code has run.
pub fn sourceForEval(allocator: std.mem.Allocator, scope: *m.Scope, source: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len != 0 and trimmed[0] == '{') {
        const candidate = if (trimmed[trimmed.len - 1] == ';') trimmed[0 .. trimmed.len - 1] else source;
        const expression = try std.mem.concat(allocator, u8, &.{ "(", candidate, "\n)" });
        if (compiles(scope, expression)) return expression;
        allocator.free(expression);
    }
    return allocator.dupe(u8, source);
}

fn compiles(scope: *m.Scope, source: []const u8) bool {
    var session: m.Scope.Session = undefined;
    session.init(scope);
    defer session.deinit();
    var catcher: v8.TryCatch = undefined;
    catcher.init(session.isolate());
    defer catcher.deinit();
    return v8.Script.compile(session.ctx, eu.v.str_utf8(session.isolate(), source), null) != null;
}

/// Returns a caller-owned result handle; borrows source through return.
pub fn eval(scope: *m.Scope, source: []const u8, info: ?*m.ErrorInfo) !v8.Global.Of(v8.Value) {
    const prepared = try sourceForEval(eu.alloc, scope, source);
    defer eu.alloc.free(prepared);
    return scope.eval(prepared, "app:/shell.js", info);
}

/// Compiles only: probing input never executes guest code. Real syntax errors
/// return false so normal evaluation reports them immediately. V8 owns the grammar.
pub fn incomplete(scope: *m.Scope, source: []const u8) bool {
    const prepared = sourceForEval(eu.alloc, scope, source) catch return false;
    defer eu.alloc.free(prepared);
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '{' and std.mem.eql(u8, prepared, source)) {
        const prefix = std.mem.concat(eu.alloc, u8, &.{ "(", source }) catch return false;
        defer eu.alloc.free(prefix);
        if (incompleteScript(scope, prefix)) return true;
    }
    return incompleteScript(scope, prepared);
}

fn incompleteScript(scope: *m.Scope, source: []const u8) bool {
    var session: m.Scope.Session = undefined;
    session.init(scope);
    defer session.deinit();
    const isolate = session.isolate();
    var catcher: v8.TryCatch = undefined;
    catcher.init(isolate);
    defer catcher.deinit();
    if (v8.Script.compile(session.ctx, eu.v.str_utf8(isolate, source), null) != null) return false;
    if (unexpectedEnd(isolate, &catcher)) return true;
    // V8 reports an unfinished block comment as an invalid token. Retry with a
    // terminator, never with execution, to distinguish it from a real bad token.
    catcher.reset();
    const terminated = std.mem.concat(eu.alloc, u8, &.{ source, "\n*/" }) catch return false;
    defer eu.alloc.free(terminated);
    if (v8.Script.compile(session.ctx, eu.v.str_utf8(isolate, terminated), null) != null) return true;
    return unexpectedEnd(isolate, &catcher);
}

fn unexpectedEnd(isolate: v8.Isolate, catcher: *v8.TryCatch) bool {
    const message = (catcher.getMessage() orelse return false).get();
    var buffer: [256]u8 = undefined;
    if (message.lenUtf8(isolate) > buffer.len) return false;
    const length = message.writeUtf8(isolate, &buffer);
    const text = buffer[0..length];
    return std.mem.endsWith(u8, text, "Unexpected end of input") or std.mem.endsWith(u8, text, "Unterminated template literal");
}
