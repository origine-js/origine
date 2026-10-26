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
const init_loader = @import("init_loader.zig");

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
    /// Module preloads only: the scope that owns `resolver`, and the hardened values handed to the
    /// module's default export. Released when the preload settles, or by `Host.destroy`.
    parent: ?*Scope = null,
    values: ?v8.Global.Of(v8.Value) = null,
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
    errno.requireBinding(preloadModule);
    errno.requireBinding(preload);
    errno.requireBinding(run);
    errno.requireBinding(close);
}

/// `create(main, importMapJson?, loader?, transformers?)`: returns the child id.
/// `transformers` is the flat array `[ext, transformer, ext, ...]` (see `JsLoader.setTransformers`)
/// and needs a `loader`.
pub fn create(state: *ScopeState, main: []const u8, map_json: ?[]const u8, loader_fn: ?v8.Function, transformers: ?v8.Object, origine: bool) Error!u32 {
    return createImpl(state, main, map_json, loader_fn, transformers, origine) catch |err| return errno.narrow(err);
}

fn createImpl(state: *ScopeState, main: []const u8, map_json: ?[]const u8, loader_fn: ?v8.Function, transformers: ?v8.Object, origine: bool) !u32 {
    const host = state.host;
    const alloc = host.allocator;
    if (host.in_loader) return error.Unsupported;
    var options: Scope.Options = .{ .on_dispose = host.disposer() };
    if (origine) {
        // The host namespace is the parent's to give away, never to widen.
        if (!state.scope.options.origine_namespace) return error.Unsupported;
        options.origine_namespace = true;
        options.meta = .{ .data = host, .init = init_loader.meta };
    }
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
        const made = loader orelse return error.InvalidInput;
        const isolate = v8.Isolate.getCurrent();
        try made.setTransformers(isolate.getCurrentContext(), isolate, list);
    }
    try host.children.ensureUnusedCapacity(alloc, 1);
    try host.loaders.ensureUnusedCapacity(alloc, 1);
    const child = try state.scope.runtime.createScope(options);
    errdefer state.scope.runtime.disposeScope(child);
    if (origine) {
        // Embedded modules reach their natives through the scope's host record.
        const api = try host.install(child, null);
        api.deinit();
    }
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
    const script = v8.Script.compile(session.ctx, eu.v.str_utf8(isolate, source), child.scope.scriptOrigin(origin, false)) orelse return error.InvalidInput;
    const function = v8.Function.from_opaque((script.run(session.ctx) orelse return error.Unexpected).data.handle) orelse return error.InvalidInput;
    _ = function.call(session.ctx, eu.v.undefined_value(isolate).value, &.{values}) orelse return error.Unexpected;
}

/// `preloadModule(id, name, source, values)`: evaluates `source` as the ES module `name` in the
/// child, then, when `values` is given and the module's default export is a function, calls it
/// with `values` (hardened, deep-frozen, first). Returns a parent-realm promise that settles once
/// the module, and the call's returned promise if any, finished. A failure rejects with a fresh
/// `ModuleError`: child-realm errors never cross.
pub fn preloadModule(state: *ScopeState, call: *Call, id: u32, name: []const u8, source: []const u8, values: v8.Value) Error!v8.Promise {
    return preloadModuleImpl(state, call, id, name, source, values) catch |err| return errno.narrow(err);
}

fn preloadModuleImpl(state: *ScopeState, call: *Call, id: u32, name: []const u8, source: []const u8, values: v8.Value) !v8.Promise {
    const host = state.host;
    const alloc = host.allocator;
    const child = try childFor(state, id);
    const has_values = !values.isUndefined();
    if (has_values) try state.scope.hardenLocal(values);
    const resolver = eu.v.promise_resolver(call.ctx) orelse return error.Unexpected;
    const pending = try alloc.create(RunState);
    errdefer alloc.destroy(pending);
    pending.* = .{ .host = host, .resolver = .new(call.isolate, resolver), .parent = state.scope };
    errdefer pending.resolver.deinit();
    if (has_values) pending.values = .new(call.isolate, values);
    errdefer if (pending.values) |held| held.deinit();
    try host.runs.append(alloc, pending);
    errdefer _ = host.runs.pop();
    try child.scope.updateImportCache(.{ .module_id = name }, .{ .source = source }, null);
    const loading = try child.scope.importModule(name, null);
    defer loading.deinit();
    const data = eu.v.external(call.isolate, pending).value.data;
    var session: Scope.Session = undefined;
    session.init(child.scope);
    defer session.deinit();
    // Created in the child's context so they may touch its namespace object.
    const on_fulfilled = v8.Function.init(session.ctx, preloadLoaded, data, 1, .Throw, .HasSideEffect);
    const on_rejected = v8.Function.init(session.ctx, preloadFailed, data, 1, .Throw, .HasSideEffect);
    _ = loading.deref().then2(session.ctx, on_fulfilled, on_rejected) orelse return error.Unexpected;
    return resolver.getPromise();
}

/// Settles a module preload: resolves, or rejects with a `ModuleError` carrying `reason`'s text.
/// Runs in the child's context; builds every value it hands to the parent in the parent's.
fn preloadSettle(pending: *RunState, isolate: v8.Isolate, reason: ?v8.Value) void {
    if (pending.done) return;
    pending.done = true;
    defer pending.resolver.deinit();
    defer if (pending.values) |held| {
        held.deinit();
        pending.values = null;
    };
    const parent_ctx = pending.parent.?.context.deref();
    const failed = reason orelse {
        _ = pending.resolver.deref().resolve(parent_ctx, eu.v.undefined_value(isolate).value);
        return;
    };
    const child_ctx = isolate.getCurrentContext();
    const message = if (failed.toDetailString(child_ctx)) |text| text.name.primitive.value else binding.string(isolate, "module evaluation failed");
    const env: binding.Env = .{ .isolate = isolate, .ctx = parent_ctx };
    const failure = binding.encode(env, {}, .{
        .errno = @backingInt(errno.Errno.Unexpected),
        .name = "ModuleError",
        .message = message,
    }) catch {
        _ = pending.resolver.deref().reject(parent_ctx, message);
        return;
    };
    _ = pending.resolver.deref().reject(parent_ctx, failure);
}

fn preloadLoaded(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = binding.externalPointer(RunState, info);
    if (pending.done) return;
    const isolate = info.isolate();
    const ctx = isolate.getCurrentContext();
    var catcher: v8.TryCatch = undefined;
    catcher.init(isolate);
    defer catcher.deinit();
    const held = pending.values orelse return preloadSettle(pending, isolate, null);
    const namespace = info.get_arg(0).toObject(ctx) orelse return preloadSettle(pending, isolate, null);
    const entry = namespace.get(ctx, binding.string(isolate, "default")) orelse return preloadSettle(pending, isolate, catcher.getException());
    const function = v8.Function.from_opaque(entry.data.handle) orelse return preloadSettle(pending, isolate, null);
    const result = function.call(ctx, eu.v.undefined_value(isolate).value, &.{held.deref()}) orelse
        return preloadSettle(pending, isolate, catcher.getException() orelse binding.string(isolate, "preload threw"));
    if (result.isPromise()) {
        // An async default export: the preload ends when its promise does.
        const promise = v8.Promise.from_opaque(result.data.handle).?;
        const data = eu.v.external(isolate, pending).value.data;
        const on_done = v8.Function.init(ctx, preloadDone, data, 1, .Throw, .HasSideEffect);
        const on_failed = v8.Function.init(ctx, preloadFailed, data, 1, .Throw, .HasSideEffect);
        _ = promise.then2(ctx, on_done, on_failed) orelse preloadSettle(pending, isolate, binding.string(isolate, "preload failed"));
        return;
    }
    preloadSettle(pending, isolate, null);
}

fn preloadDone(info: v8.FunctionCallbackInfo) callconv(.c) void {
    preloadSettle(binding.externalPointer(RunState, info), info.isolate(), null);
}

fn preloadFailed(info: v8.FunctionCallbackInfo) callconv(.c) void {
    preloadSettle(binding.externalPointer(RunState, info), info.isolate(), info.get_arg(0));
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

/// `close(id)`: revokes the handle and disposes the child and, first, its own children. The
/// V8 context and the host state are freed at the runtime's next safe point
/// (`Runtime.disposeScope`); a function another realm kept from the child stays callable but
/// finds no scope.
pub fn close(state: *ScopeState, id: u32) Error!void {
    const child = childFor(state, id) catch |err| return errno.narrow(err);
    closeChild(state.host, child);
}

fn closeChild(host: *Host, child: *Child) void {
    if (child.closed) return;
    child.closed = true;
    for (host.children.items) |*other| {
        if (!other.closed and other.parent == child.scope) closeChild(host, other);
    }
    child.scope.runtime.disposeScope(child.scope);
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
        .errno = @backingInt(errno.Errno.Unexpected),
        .name = "ModuleError",
        .message = message,
    }) catch {
        // Could not build the error object: reject with the bare message instead.
        _ = pending.resolver.deref().reject(ctx, message);
        return;
    };
    _ = pending.resolver.deref().reject(ctx, failure);
}
