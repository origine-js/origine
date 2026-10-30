//! Private ES module graph for API construction; retained factories survive snapshots.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const binding = @import("binding.zig");
pub const context_slot = 3;
pub const full_index = 0;
pub const basic_index = 1;
pub const native_index = 2;
pub const errno_index = 3;
pub const initial_index = 4;
pub const errors_index = 5;
pub const records_index = 6;
pub const Module = enum { common, fs, host, graph, context, isolate, io, net, util, errors, records, errno };
pub const module_count = std.meta.fieldNames(Module).len;
pub const Script = struct { source: []const u8, origin: []const u8, cache_id: []const u8 };
pub fn script(module: Module) Script {
    return switch (module) {
        .common => .{ .source = @embedFile("../js/glue/index.js"), .origin = "engine:api/index.js", .cache_id = "origine:glue.esm.index" },
        .errno => .{ .source = @import("errno.zig").module_source, .origin = "engine:api/errno.js", .cache_id = "origine:glue.esm.errno" },
        inline else => |name| .{ .source = @embedFile("../js/glue/" ++ @tagName(name) ++ ".js"), .origin = "engine:api/" ++ @tagName(name) ++ ".js", .cache_id = "origine:glue.esm." ++ @tagName(name) },
    };
}
pub fn restored(ctx: v8.Context) ?v8.Array {
    if (ctx.getNumberOfEmbedderDataFields() <= context_slot) return null;
    const value = v8.Value.from_opaque(ctx.getEmbedderData(context_slot).handle) orelse return null;
    return if (value.isArray()) v8.Array.from_opaque(value.data.handle) else null;
}
pub const Compiler = struct { data: *anyopaque, compile: *const fn (*anyopaque, Module) anyerror!v8.Module };
const Graph = struct { modules: [module_count]v8.Module };
threadlocal var linking: ?*Graph = null;
fn resolve(_: v8.Context, specifier: v8.String, _: v8.FixedArray, _: v8.Module) callconv(.c) v8.MaybeHandle {
    const graph = linking orelse return null;
    var name: [64]u8 = undefined;
    const length = specifier.lenUtf8(v8.Isolate.getCurrent());
    if (length > name.len) return null;
    const text = name[0..specifier.writeUtf8(v8.Isolate.getCurrent(), &name)];
    inline for (std.enums.values(Module)) |module| {
        const expected = if (module == .common) "./index.js" else "./" ++ @tagName(module) ++ ".js";
        if (std.mem.eql(u8, text, expected)) return graph.modules[@backingInt(module)].data.handle;
    }
    return null;
}
pub fn compile(isolate: v8.Isolate, module: Module) !v8.Module {
    const text = script(module);
    const origin = v8.ScriptOrigin.init(eu.v.str_utf8(isolate, text.origin).name.primitive.value, 0, 0, false, -1, null, false, false, true, null);
    var source: v8.ScriptCompiler.Source = undefined;
    source.init(eu.v.str_utf8(isolate, text.source), &origin, null);
    defer source.deinit();
    return v8.ScriptCompiler.compileModule(isolate, &source, 0, 0) orelse error.JavaScriptException;
}
pub fn factory(isolate: v8.Isolate, ctx: v8.Context, compiler: ?Compiler) !v8.Function {
    var graph: Graph = undefined;
    inline for (std.enums.values(Module)) |module| graph.modules[@backingInt(module)] = if (compiler) |c| try c.compile(c.data, module) else try compile(isolate, module);
    const previous = linking;
    linking = &graph;
    defer linking = previous;
    const entry = graph.modules[0];
    if (!(entry.instantiateModule(ctx, resolve, null) orelse return error.JavaScriptException)) return error.BootstrapFailed;
    const result = entry.evaluate(ctx) orelse return error.JavaScriptException;
    if (result.isPromise() and v8.Promise.from_opaque(result.data.handle).?.state() == .Rejected) return error.JavaScriptException;
    const namespace = (entry.getModuleNamespace() orelse return error.BootstrapFailed).toObject(ctx).?;
    return v8.Function.from_opaque((namespace.get(ctx, binding.string(isolate, "create")) orelse return error.BootstrapFailed).data.handle) orelse error.BootstrapFailed;
}
pub fn initialize(isolate: v8.Isolate, ctx: v8.Context, create: v8.Function) !v8.Array {
    const env: binding.Env = .{ .isolate = isolate, .ctx = ctx };
    const native = eu.v.object(isolate);
    // The cell is ordinary snapshot memory until Host.install rebinds its backing.
    const cell = v8.Uint32Array.init(eu.v.array_buffer(isolate, 4).?, 0, 1).?;
    try binding.set(env, native, "errno", cell.typedArray.arrayBufferView.object.value);
    const made = create.call(ctx, eu.v.undefined_value(isolate).value, &.{native.value}) orelse return error.JavaScriptException;
    const bundle = v8.Array.from_opaque(made.data.handle) orelse return error.BootstrapFailed;
    const buffer = v8.ArrayBuffer.from_opaque(cell.typedArray.arrayBufferView.buffer().?.object.value.data.handle).?;
    buffer.setDetachKey(eu.v.object(isolate).value);
    ctx.setEmbedderData(context_slot, bundle.object.value.data);
    return bundle;
}
pub fn prepare(isolate: v8.Isolate, ctx: v8.Context) !void {
    if (restored(ctx) != null) return;
    _ = try initialize(isolate, ctx, try factory(isolate, ctx, null));
}
