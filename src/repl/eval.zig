//! Evaluation for the REPL. What to evaluate (types erased, object literals, top-level await
//! rewritten) is decided by the Rust side (`engine.zig`, `Engine.prepare`); this only runs it.
const std = @import("std");
const m = @import("@managed");
const v8 = @import("@v8");

/// Script name given to everything the REPL evaluates; relative imports resolve against the working directory.
pub const origin = "<repl>";

/// Returns a caller-owned result handle; borrows source through return.
pub fn eval(scope: *m.Scope, source: []const u8, info: ?*m.ErrorInfo) !v8.Global.Of(v8.Value) {
    return scope.eval(source, origin, info);
}
