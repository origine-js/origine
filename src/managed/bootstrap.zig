//! Host-independent scope helpers, prepared once in each snapshot context.
const v8 = @import("@v8");
const eu = @import("@util");
const startup_trace = @import("@diagnostics").scope;

/// Context slots 1/2 hold host pointers, and slot 3 holds the private API template.
const context_slot = 4;

/// Returns this entered context's helpers as a local handle if already prepared.
/// Borrows context only through return; no persistent handle or host pointer is retained.
fn restored(ctx: v8.Context) ?v8.Array {
    if (ctx.getNumberOfEmbedderDataFields() <= context_slot) return null;
    const value = v8.Value.from_opaque(ctx.getEmbedderData(context_slot).handle) orelse return null;
    if (!value.isArray()) return null;
    return v8.Array.from_opaque(value.data.handle);
}

/// Returns a local [hardener, unsupported-prototype-check] array in the entered realm.
/// The context retains the JS-only helpers; caller keeps the isolate/HandleScope alive.
/// Snapshot contexts prebuild these; the no-snapshot path performs identical initialization.
/// Borrows timing through return; errors retain no host resources or persistent handles.
pub fn prepare(isolate: v8.Isolate, ctx: v8.Context, timing: *?i64) !v8.Array {
    if (restored(ctx)) |helpers| {
        startup_trace.mark(timing, "bootstrap_restore");
        return helpers;
    }
    const script = v8.Script.compile(ctx, eu.v.str_utf8(isolate, @embedFile("../js/bootstrap.js")), null) orelse return error.BootstrapFailed;
    startup_trace.mark(timing, "bootstrap_compile");
    const initializer_value = script.run(ctx) orelse return error.BootstrapFailed;
    const initializer = v8.Function.from_opaque(initializer_value.data.handle) orelse return error.BootstrapFailed;
    const intrinsic_objects = v8.Intrinsics.getObjects(ctx) orelse return error.BootstrapFailed;
    if (intrinsic_objects.len() == 0) return error.BootstrapFailed;
    const unsupported_objects = eu.v.array(isolate, 5);
    inline for (.{ .array_iterator, .string_iterator, .regexp_string_iterator, .iterator_helper, .iterator_wrapper }, 0..) |prototype, index| {
        const object = v8.Intrinsics.getPrototype(ctx, prototype) orelse return error.BootstrapFailed;
        if (!(unsupported_objects.object.setIndex(ctx, index, object.value) orelse return error.BootstrapFailed)) return error.BootstrapFailed;
    }
    const value = initializer.call(ctx, eu.v.undefined_value(isolate).value, &.{ intrinsic_objects.object.value, unsupported_objects.object.value }) orelse return error.BootstrapFailed;
    if (!value.isArray()) return error.BootstrapFailed;
    const helpers = v8.Array.from_opaque(value.data.handle) orelse return error.BootstrapFailed;
    ctx.setEmbedderData(context_slot, helpers.object.value.data);
    startup_trace.mark(timing, "bootstrap_run_harden");
    return helpers;
}
