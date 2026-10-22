//! `api.scope`: child scopes created from guest code.
//!
//! Children are owned by the `Host`; guest code holds small integer ids that only
//! the creating scope can use. A closed child's id goes stale.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const binding = @import("binding.zig");
const Call = binding.Call;
const errno = @import("errno.zig");
const import_map = @import("../managed/import_map.zig");
const Scope = @import("../managed/scope.zig").Scope;
const host_mod = @import("host.zig");
const Host = host_mod.Host;
const ScopeState = host_mod.ScopeState;
const JsLoader = @import("js_loader.zig").JsLoader;

pub const Child = struct {
    scope: *Scope,
    parent: *Scope,
    /// Host-allocator copy of the main specifier; freed by `Host.destroy`.
    main: []u8,
    closed: bool = false,
};

/// In-flight `run()`: the parent-realm promise resolver, settled when the child's
/// main module finishes.
pub const RunState = struct {
    host: *Host,
    resolver: v8.Global.Of(v8.Promise.Resolver),
    done: bool = false,
};

fn childFor(state: *ScopeState, id: u32) !*Child {
    const host = state.host;
    if (id == 0 or id > host.children.items.len) return error.BadHandle;
    const child = &host.children.items[id - 1];
    if (child.parent != state.scope) return error.BadHandle;
    if (child.closed) return error.StaleHandle;
    return child;
}

const Error = errno.Error;

// Scope natives are not fs code: they return the closed binding set and narrow their
// internal errors explicitly. A new native that leaks other errors fails to compile.
comptime {
    errno.requireBinding(create);
    errno.requireBinding(preload);
    errno.requireBinding(run);
    errno.requireBinding(close);
}

/// `create(main, importMapJson?, loader?, transformers?)`: returns the child id.
/// `transformers` is the flat array `[ext, transformer, ext, ...]` (see `JsLoader.setTransformers`)
/// and needs a `loader`.
pub fn create(state: *ScopeState, main: []const u8, map_json: ?[]const u8, loader_fn: ?v8.Function, transformers: ?v8.Object) Error!u32 {
    return createImpl(state, main, map_json, loader_fn, transformers) catch |err| return errno.narrow(err);
}

fn createImpl(state: *ScopeState, main: []const u8, map_json: ?[]const u8, loader_fn: ?v8.Function, transformers: ?v8.Object) !u32 {
    const host = state.host;
    const alloc = host.allocator;
    if (host.in_loader) return error.Unsupported;
    var options: Scope.Options = .{};
    var map: ?import_map.ImportMap = null;
    defer if (map) |*owned| owned.deinit();
    const main_copy = try alloc.dupe(u8, main);
    errdefer alloc.free(main_copy);
    if (map_json) |json| {
        map = try import_map.ImportMap.parseJson(alloc, json, .{ .base_url = "app:/map.json", .urls = import_map.virtual_urls });
        options.import_map = &map.?;
    }
    var loader: ?*JsLoader = null;
    errdefer if (loader) |made| {
        made.deinit();
        alloc.destroy(made);
    };
    if (loader_fn) |function| {
        loader = try alloc.create(JsLoader);
        loader.?.* = .{ .host = host, .parent = state.scope, .function = .new(v8.Isolate.getCurrent(), function) };
        options.loader = loader.?.loader();
    }
    if (transformers) |list| {
        const made = loader orelse return error.InvalidPath;
        const isolate = v8.Isolate.getCurrent();
        try made.setTransformers(isolate.getCurrentContext(), isolate, list);
    }
    try host.children.ensureUnusedCapacity(alloc, 1);
    try host.loaders.ensureUnusedCapacity(alloc, 1);
    const child = try state.scope.runtime.createScope(options);
    host.children.appendAssumeCapacity(.{ .scope = child, .parent = state.scope, .main = main_copy });
    if (loader) |made| host.loaders.appendAssumeCapacity(made);
    loader = null;
    return @intCast(host.children.items.len);
}

/// `preload(id, source, origin, values)`: evaluates `source` (a function expression)
/// in the child and calls it with `values`, hardened (deep-frozen) first.
pub fn preload(state: *ScopeState, id: u32, source: []const u8, origin: []const u8, values: v8.Value) Error!void {
    return preloadImpl(state, id, source, origin, values) catch |err| return errno.narrow(err);
}

fn preloadImpl(state: *ScopeState, id: u32, source: []const u8, origin: []const u8, values: v8.Value) !void {
    const child = try childFor(state, id);
    if (!values.isUndefined()) try state.scope.hardenLocal(values);
    var session: Scope.Session = undefined;
    session.init(child.scope);
    defer session.deinit();
    const isolate = session.isolate();
    const script = v8.Script.compile(session.ctx, eu.v.str_utf8(isolate, source), child.scope.scriptOrigin(origin, false)) orelse return error.InvalidPath;
    const function = v8.Function.from_opaque((script.run(session.ctx) orelse return error.Unexpected).data.handle) orelse return error.InvalidPath;
    _ = function.call(session.ctx, eu.v.undefined_value(isolate).value, &.{values}) orelse return error.Unexpected;
}

/// `run(id)`: imports the child's main module; returns a parent-realm promise that
/// settles when it finishes.
pub fn run(state: *ScopeState, call: *Call, id: u32) Error!v8.Promise {
    return runImpl(state, call, id) catch |err| return errno.narrow(err);
}

fn runImpl(state: *ScopeState, call: *Call, id: u32) !v8.Promise {
    const host = state.host;
    const alloc = host.allocator;
    const child = try childFor(state, id);
    const resolver = eu.v.promise_resolver(call.ctx) orelse return error.Unexpected;
    const pending = try alloc.create(RunState);
    errdefer alloc.destroy(pending);
    pending.* = .{ .host = host, .resolver = .new(call.isolate, resolver) };
    errdefer pending.resolver.deinit();
    try host.runs.append(alloc, pending);
    errdefer _ = host.runs.pop();
    const loading = try child.scope.importModule(child.main, null);
    defer loading.deinit();
    const data = eu.v.external(call.isolate, pending).value.data;
    const on_fulfilled = v8.Function.init(call.ctx, runFulfilled, data, 1, .Throw, .HasSideEffect);
    const on_rejected = v8.Function.init(call.ctx, runRejected, data, 1, .Throw, .HasSideEffect);
    var session: Scope.Session = undefined;
    session.init(child.scope);
    defer session.deinit();
    _ = loading.deref().then2(session.ctx, on_fulfilled, on_rejected) orelse return error.Unexpected;
    return resolver.getPromise();
}

/// `close(id)`: revokes the handle and clears the child's import cache. The V8
/// context lives until `Runtime.destroy`.
pub fn close(state: *ScopeState, id: u32) Error!void {
    const child = childFor(state, id) catch |err| return errno.narrow(err);
    child.closed = true;
    _ = child.scope.clearImportCache() catch {};
}

fn runFulfilled(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = binding.externalPointer(RunState, info);
    if (pending.done) return;
    pending.done = true;
    const isolate = info.isolate();
    _ = pending.resolver.deref().resolve(isolate.getCurrentContext(), eu.v.undefined_value(isolate).value);
    pending.resolver.deinit();
}

fn runRejected(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = binding.externalPointer(RunState, info);
    if (pending.done) return;
    pending.done = true;
    const isolate = info.isolate();
    const ctx = isolate.getCurrentContext();
    const env: binding.Env = .{ .isolate = isolate, .ctx = ctx };
    // Child-realm errors never cross; the parent gets a fresh description.
    const message = if (info.get_arg(0).toDetailString(ctx)) |text| text.name.primitive.value else binding.string(isolate, "module evaluation failed");
    // Released on every path, including the encode failure below, so the parent's promise
    // always settles and the persistent resolver is never leaked.
    defer pending.resolver.deinit();
    const failure = binding.encode(env, {}, .{
        .errno = @intFromEnum(errno.Errno.Unexpected),
        .name = "ModuleError",
        .message = message,
    }) catch {
        // Could not build the error object: reject with the bare message instead.
        _ = pending.resolver.deref().reject(ctx, message);
        return;
    };
    _ = pending.resolver.deref().reject(ctx, failure);
}
