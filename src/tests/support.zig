//! Shared process-lifetime engine for tests; individual tests own their isolates.
const Engine = @import("@engine").Engine;
pub var engine: Engine = undefined;
var ready = false;

/// Initializes V8 once on the test runner thread, retaining the engine until
/// process exit. Call before creating isolates; no caller storage is retained.
pub fn ensureV8() void {
    if (ready) return;
    engine = Engine.init(.{ .thread_pool_size = 0 });
    ready = true;
}
