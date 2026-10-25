//! The guest-side glue that builds the `api` object, assembled from `src/js/glue/`.
//!
//! Snapshots prebuild the API and capability surfaces without host authority. Starts
//! without one use separately cached scripts and initialize capabilities on demand.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const errno_api = @import("errno.zig");

/// A JS-only template in context embedder data, serialized with both snapshot kinds.
/// Slots 1 and 2 belong to Scope and its native rebinder.
pub const context_slot = 3;
pub const full_index = 0;
pub const basic_index = 1;
pub const native_index = 2;
pub const errno_index = 3;
const prepare_index = 4;

/// Borrows the entered context; returns its private template as a local handle, if present.
pub fn restored(ctx: v8.Context) ?v8.Array {
    if (ctx.getNumberOfEmbedderDataFields() <= context_slot) return null;
    const value = v8.Value.from_opaque(ctx.getEmbedderData(context_slot).handle) orelse return null;
    if (!value.isArray()) return null;
    return v8.Array.from_opaque(value.data.handle);
}

/// Calls a compiled common factory in the entered context and stores its JS-only template.
/// Local handles belong to the caller's HandleScope; the context retains the bundle.
pub fn initialize(isolate: v8.Isolate, ctx: v8.Context, factory: v8.Function) !v8.Array {
    const errors = try errno_api.table(.{ .isolate = isolate, .ctx = ctx });
    const result = factory.call(ctx, eu.v.undefined_value(isolate).value, &.{errors.value}) orelse return error.JavaScriptException;
    const bundle = v8.Array.from_opaque(result.data.handle) orelse return error.BootstrapFailed;
    const errno_value = bundle.object.getIndex(ctx, errno_index) orelse return error.BootstrapFailed;
    const view = v8.ArrayBufferView.from_opaque(errno_value.data.handle) orelse return error.BootstrapFailed;
    const backing = view.buffer() orelse return error.BootstrapFailed;
    const buffer = v8.ArrayBuffer.from_opaque(backing.object.value.data.handle) orelse return error.BootstrapFailed;
    buffer.setDetachKey(eu.v.object(isolate).value);
    ctx.setEmbedderData(context_slot, bundle.object.value.data);
    return bundle;
}

/// Prebuilds API objects, methods and network classes in an entered snapshot context.
/// Retains only JS objects in context embedder data; no native callbacks or host pointers.
/// Local handles expire with the caller's HandleScope. Repeated calls reuse the template.
pub fn prepare(isolate: v8.Isolate, ctx: v8.Context) !void {
    if (restored(ctx) != null) return;
    const common = try evaluate(isolate, ctx, .common);
    const bundle = try initialize(isolate, ctx, common);
    const prepare_value = bundle.object.getIndex(ctx, prepare_index) orelse return error.BootstrapFailed;
    const prepare_fn = v8.Function.from_opaque(prepare_value.data.handle) orelse return error.BootstrapFailed;
    inline for (std.enums.values(Module)) |module| {
        if (module != .common) {
            const factory = try evaluate(isolate, ctx, module);
            _ = prepare_fn.call(ctx, eu.v.undefined_value(isolate).value, &.{ eu.v.str_utf8(isolate, @tagName(module)).name.primitive.value, factory.object.value }) orelse return error.JavaScriptException;
        }
    }
}

/// Evaluates trusted glue during snapshot creation; returns a factory local to the caller's
/// HandleScope in the entered context. Retains no host state or code-cache handles.
fn evaluate(isolate: v8.Isolate, ctx: v8.Context, module: Module) !v8.Function {
    const text = script(module);
    const compiled = v8.Script.compile(ctx, eu.v.str_utf8(isolate, text.source), null) orelse return error.JavaScriptException;
    const value = compiled.run(ctx) orelse return error.JavaScriptException;
    return v8.Function.from_opaque(value.data.handle) orelse error.BootstrapFailed;
}

pub const Module = enum { common, fs, env, scope, io, net };
pub const module_count = std.meta.fieldNames(Module).len;

/// A script's static source, origin and code-cache identity; retains no resources.
pub const Script = struct { source: []const u8, origin: []const u8, cache_id: []const u8 };

/// Returns static script text and identity; borrows nothing and transfers no ownership.
pub fn script(module: Module) Script {
    return switch (module) {
        .common => .{ .source = source, .origin = origin, .cache_id = cache_id },
        inline else => |name| .{
            .source = comptime "'use strict';\n(" ++ part(@embedFile("../js/glue/" ++ @tagName(name) ++ ".js")) ++ ")",
            .origin = "engine:api/" ++ @tagName(name) ++ ".js",
            .cache_id = "origine:glue." ++ @tagName(name),
        },
    };
}

/// Script origin reported in stack traces.
pub const origin = "engine:api.js";

/// Module ID the glue's V8 code cache is stored under (see `Host.flushGlueCache`).
pub const cache_id = "origine:glue";

/// A glue part as a bare expression: the formatter ends each file with `;`, which would not
/// parse inside the parentheses `source` puts around it.
fn part(comptime text: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
    return if (trimmed.len != 0 and trimmed[trimmed.len - 1] == ';') trimmed[0 .. trimmed.len - 1] else trimmed;
}

pub const source = std.fmt.comptimePrint(
    \\(errors) => {{
    \\  'use strict';
    \\  const native = {{}};
    \\  const util = ({[util]s})({{ errno: new Uint32Array(1), errors }});
    \\  return ({[index]s})(native, util);
    \\}}
, .{
    .util = part(@embedFile("../js/glue/util.js")),
    .index = part(@embedFile("../js/glue/index.js")),
});
