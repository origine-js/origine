//! Private ES module graph for API construction; retained factories survive snapshots.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const binding = @import("binding.zig");
const Scope = @import("../managed/scope.zig").Scope;
pub const context_slot = 3;
pub const full_index = 0;
pub const basic_index = 1;
pub const native_index = 2;
pub const errno_index = 3;
pub const initial_index = 4;
pub const errors_index = 5;
/// The private module `handles.js` that glue and embedded std modules share; the module map adopts it.
pub const handles_id = "origine:@internal/handles";
/// Embedder slot of a context whose glue was made for a snapshot: the snapshot data index of the
/// handles module, which the restored scope adopts (a module handle cannot ride in the bundle).
const handles_data_slot = 4;
pub const Module = enum { common, fs, host, graph, context, isolate, io, net, util, errors, handle, handles, errno, @"net/event", @"net/send", @"net/core", @"net/server", @"net/socket", @"graph/data", @"graph/source", @"graph/handlers", @"graph/driver", @"graph/reference" };
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
/// The path of a glue module below `src/js/glue/`; `common` is `index.js`.
fn modulePath(comptime module: Module) []const u8 {
    return if (module == .common) "index.js" else @tagName(module) ++ ".js";
}
/// Resolves `specifier` against the directory of the module that imports it.
fn resolve(_: v8.Context, specifier: v8.String, _: v8.FixedArray, referrer: v8.Module) callconv(.c) v8.MaybeHandle {
    const graph = linking orelse return null;
    var name: [64]u8 = undefined;
    const length = specifier.lenUtf8(v8.Isolate.getCurrent());
    if (length > name.len) return null;
    var rest: []const u8 = name[0..specifier.writeUtf8(v8.Isolate.getCurrent(), &name)];
    const referrer_id = referrer.scriptId();
    var dir: []const u8 = "";
    inline for (std.enums.values(Module)) |module| {
        if (graph.modules[@backingInt(module)].scriptId() == referrer_id) dir = std.fs.path.dirnamePosix(modulePath(module)) orelse "";
    }
    while (true) {
        if (std.mem.startsWith(u8, rest, "./")) {
            rest = rest[2..];
        } else if (std.mem.startsWith(u8, rest, "../")) {
            rest = rest[3..];
            dir = std.fs.path.dirnamePosix(dir) orelse "";
        } else break;
    }
    var joined: [96]u8 = undefined;
    const wanted = if (dir.len == 0) rest else std.fmt.bufPrint(&joined, "{s}/{s}", .{ dir, rest }) catch return null;
    inline for (std.enums.values(Module)) |module| {
        if (std.mem.eql(u8, wanted, modulePath(module))) return graph.modules[@backingInt(module)].data.handle;
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
pub const Built = struct { create: v8.Function, handles: v8.Module };
pub fn factory(isolate: v8.Isolate, ctx: v8.Context, compiler: ?Compiler) !Built {
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
    const create = v8.Function.from_opaque((namespace.get(ctx, binding.string(isolate, "create")) orelse return error.BootstrapFailed).data.handle) orelse return error.BootstrapFailed;
    return .{ .create = create, .handles = graph.modules[@backingInt(Module.handles)] };
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
pub const Options = struct {
    /// The scope that owns `ctx`: its module map adopts the handles module. Null for a context no
    /// scope owns (a snapshot's default context).
    scope: ?*Scope = null,
    compiler: ?Compiler = null,
    /// Set when `ctx` is being snapshotted: the handles module is added as data of the context.
    creator: ?*v8.SnapshotCreator = null,
};
/// The glue bundle of `ctx`, made on first use. Idempotent.
pub fn ensure(isolate: v8.Isolate, ctx: v8.Context, options: Options) !v8.Array {
    if (restored(ctx)) |bundle| {
        if (options.scope) |scope| try adoptRestored(ctx, scope);
        return bundle;
    }
    const built = try factory(isolate, ctx, options.compiler);
    const bundle = try initialize(isolate, ctx, built.create);
    if (options.creator) |creator| {
        const index: u32 = @intCast(creator.addDataToContext(ctx, built.handles.data));
        ctx.setEmbedderData(handles_data_slot, v8.Integer.initFromUnsigned(isolate, index).number.numeric.primitive.value.data);
    }
    if (options.scope) |scope| try scope.module_map.adopt(handles_id, built.handles);
    return bundle;
}
/// A context restored from a snapshot has glue but no module handle: take it from the snapshot data.
fn adoptRestored(ctx: v8.Context, scope: *Scope) !void {
    if (scope.module_map.adopted.contains(handles_id)) return;
    if (ctx.getNumberOfEmbedderDataFields() <= handles_data_slot) return error.BootstrapFailed;
    const slot = v8.Value.from_opaque(ctx.getEmbedderData(handles_data_slot).handle) orelse return error.BootstrapFailed;
    const index = slot.integerValue(ctx) orelse return error.BootstrapFailed;
    const data = ctx.getDataFromSnapshotOnce(@intCast(index)) orelse return error.BootstrapFailed;
    try scope.module_map.adopt(handles_id, v8.Module.from_opaque(data.handle) orelse return error.BootstrapFailed);
}
pub fn prepare(isolate: v8.Isolate, ctx: v8.Context) !void {
    _ = try ensure(isolate, ctx, .{});
}
