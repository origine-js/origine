//! Shared process-lifetime engine for tests; individual tests own their isolates.
const v8 = @import("@v8");
const Engine = @import("@engine").Engine;
pub var engine: Engine = undefined;
var ready = false;

/// Initializes V8 once on the test runner thread, retaining the engine until
/// process exit. Call before creating isolates; no caller storage is retained.
pub fn ensureV8() void {
    if (ready) return;
    // Lets tests force optimization (%OptimizeFunctionOnNextCall) to exercise V8 fast API calls.
    v8.V8.setFlagsFromString("--allow-natives-syntax");
    engine = Engine.init(.{ .thread_pool_size = 0 });
    ready = true;
}
