//! Evaluation for the REPL. What to evaluate (types erased, object literals, top-level await
//! rewritten) is decided by the Rust side (`engine.zig`, `Engine.prepare`); this only runs it.
const std = @import("std");
const m = @import("@managed");
const v8 = @import("@v8");
const eu = @import("@util");

/// Script name given to everything the REPL evaluates; relative imports resolve against the working directory.
pub const origin = "<repl>";

/// Property of the object V8's REPL mode fulfills its wrapper promise with.
const result_key = ".repl_result";

/// Evaluates in V8's REPL mode, as a debugger console does: an input may declare a top-level `let`,
/// `const` or `class` that an earlier input declared (the new binding replaces it), and `const`
/// stays read-only. REPL-mode scripts return a promise of `{ ".repl_result": completion value }`;
/// without top-level `await` it is already settled, and this returns the completion value (or throws
/// the script's exception). Returns a caller-owned result handle; borrows source through return.
/// `info` follows `Scope.eval`: syntax errors and thrown values.
pub fn eval(scope: *m.Scope, source: []const u8, info: ?*m.ErrorInfo) !v8.Global.Of(v8.Value) {
    const wrapped = try scope.evalRepl(source, origin, info);
    defer wrapped.deinit();
    var session: m.Scope.Session = undefined;
    session.init(scope);
    defer session.deinit();
    const isolate = session.isolate();
    const promise = v8.Promise.from_opaque(wrapped.deref().data.handle) orelse return error.UnexpectedResult;
    promise.markAsHandled();
    switch (promise.state()) {
        .Fulfilled => {},
        .Rejected => {
            if (info) |out| {
                out.deinit();
                out.exception = .new(isolate, promise.result());
            }
            return error.JavaScriptException;
        },
        .Pending => return error.UnexpectedResult,
    }
    const object = promise.result().toObject(session.ctx) orelse return error.UnexpectedResult;
    const key = eu.v.str_utf8(isolate, result_key).name.primitive.value;
    const value = object.get(session.ctx, key) orelse return error.JavaScriptException;
    return .new(isolate, value);
}
