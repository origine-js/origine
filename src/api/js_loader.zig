//! A module `Loader` backed by a JS callback: `loader(moduleId) => source | { source }`
//! (or a promise of either). The callback runs in the creating scope's realm; its
//! result is copied into the child as module source.
const std = @import("std");
const v8 = @import("@v8");
const binding = @import("binding.zig");
const Runtime = @import("../managed/runtime.zig").Runtime;
const Scope = @import("../managed/scope.zig").Scope;
const module_types = @import("../managed/module_types.zig");
const host_mod = @import("host.zig");
const Host = host_mod.Host;

pub const JsLoader = struct {
    host: *Host,
    parent: *Scope,
    function: v8.Global.Of(v8.Function),

    pub fn deinit(self: *JsLoader) void {
        self.function.deinit();
    }

    /// The `Loader` descriptor for `Scope.Options`; borrows self until `Host.destroy`.
    pub fn loader(self: *JsLoader) module_types.Loader {
        return .{ .data = self, .load = load };
    }
};

const Pending = struct { host: *Host, token: module_types.LoadToken };

/// Reads the module source from a loader result: a string, or an object with an
/// own data property `source` that is a string. Copies into `allocator`.
fn sourceOf(ctx: v8.Context, isolate: v8.Isolate, value: v8.Value, allocator: std.mem.Allocator) ![]const u8 {
    var source = value;
    if (!value.isString()) {
        const object = value.toObject(ctx) orelse return error.LoaderFailed;
        const descriptor = object.getOwnPropertyDescriptor(ctx, v8.String.initUtf8(isolate, "source").name) orelse return error.LoaderFailed;
        if (!descriptor.isObject()) return error.LoaderFailed;
        source = (descriptor.toObject(ctx) orelse return error.LoaderFailed).get(ctx, binding.string(isolate, "value")) orelse return error.LoaderFailed;
    }
    if (!source.isString()) return error.LoaderFailed;
    const text = source.toString(ctx) orelse return error.LoaderFailed;
    const buffer = allocator.alloc(u8, text.lenUtf8(isolate)) catch binding.oom();
    return buffer[0..text.writeUtf8(isolate, buffer)];
}

fn load(data: ?*anyopaque, request: module_types.LoadRequest) anyerror!module_types.LoadResult {
    const self: *JsLoader = @ptrCast(@alignCast(data.?));
    const host = self.host;
    const isolate = self.parent.runtime.isolate;
    const parent_ctx = self.parent.context.deref();
    parent_ctx.enter();
    defer parent_ctx.exit();
    host.in_loader = true;
    defer host.in_loader = false;
    var tc: v8.TryCatch = undefined;
    tc.init(isolate);
    defer tc.deinit();
    const result = self.function.deref().call(parent_ctx, v8.Primitive.initUndefined(isolate).value, &.{binding.string(isolate, request.module_id)}) orelse return error.LoaderFailed;
    if (result.isPromise()) {
        const pending = host.allocator.create(Pending) catch binding.oom();
        pending.* = .{ .host = host, .token = request.token };
        const external = v8.External.init(isolate, pending).value.data;
        const on_fulfilled = v8.Function.init(parent_ctx, fulfilled, external, 1, .Throw, .HasSideEffect);
        const on_rejected = v8.Function.init(parent_ctx, rejected, external, 1, .Throw, .HasSideEffect);
        const promise = v8.Promise.from_opaque(result.data.handle).?;
        _ = promise.then2(parent_ctx, on_fulfilled, on_rejected) orelse return error.LoaderFailed;
        return .pending;
    }
    return .{ .source = try sourceOf(parent_ctx, isolate, result, request.allocator) };
}

fn fulfilled(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = binding.externalPointer(Pending, info);
    const host = pending.host;
    defer host.allocator.destroy(pending);
    const isolate = info.isolate();
    const ctx = isolate.getCurrentContext();
    const rt: *Runtime = runtimeOf(ctx) orelse return;
    const source = sourceOf(ctx, isolate, info.get_arg(0), host.allocator) catch {
        rt.completeLoad(pending.token, .{ .failure = error.LoaderFailed }) catch {};
        return;
    };
    defer host.allocator.free(source);
    rt.completeLoad(pending.token, .{ .content = .{ .source = source } }) catch {};
}

fn rejected(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = binding.externalPointer(Pending, info);
    defer pending.host.allocator.destroy(pending);
    const ctx = info.isolate().getCurrentContext();
    const rt: *Runtime = runtimeOf(ctx) orelse return;
    rt.completeLoad(pending.token, .{ .failure = error.LoaderRejected }) catch {};
}

/// Finds the Runtime owning `ctx` via the scope pointer in embedder data slot 1.
fn runtimeOf(ctx: v8.Context) ?*Runtime {
    const scope: *Scope = @ptrCast(@alignCast(ctx.getAlignedPointerFromEmbedderData(1) orelse return null));
    return scope.runtime;
}
