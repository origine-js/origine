//! Host transformers as JS values. A host transformer handed to guest code is an ordinary
//! native function `(source, id) => string` that also carries a V8 private symbol; the symbol
//! is invisible to JavaScript, so only a function this module branded can be recognized by
//! `read`, and a guest cannot forge or copy the brand (property copies do not carry private
//! symbols). The private value is an External pointing at the host-owned `Transformer`.
const v8 = @import("@v8");
const eu = @import("@util");
const transformer = @import("transformer.zig");

fn key(isolate: v8.Isolate) v8.Private {
    return v8.Private.forApi(isolate, eu.v.str_utf8(isolate, "origine.transformer"));
}

/// Brands `function` with `handle`, which must outlive every use of the function (host-owned,
/// freed at `Host.destroy`). Needs an entered context. Fails only if V8 refuses the property.
pub fn mark(ctx: v8.Context, isolate: v8.Isolate, function: v8.Function, handle: *const transformer.Transformer) !void {
    const external = eu.v.external(isolate, @constCast(handle)).value;
    const ok = function.object.setPrivate(ctx, key(isolate), external) orelse return error.JavaScriptException;
    if (!ok) return error.JavaScriptException;
}

/// The host transformer behind `value`, or null when `value` is not a branded function.
/// Borrows `value`; the pointer stays valid until `Host.destroy`.
pub fn read(ctx: v8.Context, isolate: v8.Isolate, value: v8.Value) ?*const transformer.Transformer {
    if (!value.isFunction()) return null;
    const object = value.toObject(ctx) orelse return null;
    const marked = object.hasPrivate(ctx, key(isolate)) orelse return null;
    if (!marked) return null;
    const external = object.getPrivate(ctx, key(isolate)) orelse return null;
    if (!external.isExternal()) return null;
    const pointer = v8.External.from_opaque(external.data.handle) orelse return null;
    return @ptrCast(@alignCast(pointer.pointer() orelse return null));
}
