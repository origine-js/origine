//! `api.context`: realms (V8 contexts) whose imports run through an `ImportHandler`.
//!
//! A `Context` plugs the handler's pipeline into a scope: its `Resolver` and `Loader` are
//! `resolveAsync` and `load` below. A handler with no JS function in it (`Handler.native`) is
//! answered right here, synchronously, and never enters JS. Otherwise the call goes to the JS
//! driver of the creating realm (src/js/glue/graph.js), which runs the chain and answers with
//! data; its promise is settled through `Runtime.completeResolve` / `completeLoad`, so the child
//! is never waiting inside its own link or evaluate path. The driver waits one microtask before it
//! runs any user function, so none of them runs on the stack of a child's `import()`.
//!
//! The identity table of a context is its scope's `ModuleMap` (a V8 module belongs to one
//! context, so each context has its own). `origine:` modules are served only by the native
//! `origine` hook; the ids it served are recorded in `served`, and a JS answer for an `origine:`
//! id that was not served natively is `PermissionDenied`.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const binding = @import("binding.zig");
const Call = binding.Call;
const errno = @import("errno.zig");
const graph_api = @import("graph.zig");
const Graph = graph_api.Graph;
const Handler = graph_api.Handler;
const StdFilter = graph_api.StdFilter;
const host_mod = @import("host.zig");
const Host = host_mod.Host;
const ScopeState = host_mod.ScopeState;
const init_loader = @import("init_loader.zig");
const init_cache = @import("init_cache.zig");
const module_types = @import("../managed/module_types.zig");
const module_map = @import("../managed/module_map.zig");
const Runtime = @import("../managed/runtime.zig").Runtime;
const Scope = @import("../managed/scope.zig").Scope;
const transformer_api = @import("transform/transformer.zig");
const Blake3 = std.crypto.hash.Blake3;

const Error = errno.Error;

comptime {
    @setEvalBranchQuota(200_000);
    errno.requireBinding(create);
    errno.requireBinding(importSpecifier);
    errno.requireBinding(evaluateSource);
    errno.requireBinding(close);
    errno.requireBinding(tableSize);
    errno.requireBinding(tableDelete);
    errno.requireBinding(tableClear);
    errno.requireBinding(flush);
    errno.requireBinding(cachePut);
    errno.requireBinding(pin);
    errno.requireBinding(unpin);
}

/// What a resolved id was resolved for; the load stage needs it.
const Info = struct { handler: u32, specifier: []u8, referrer: []u8 };

/// A call into the JS driver whose promise has not settled.
const PendingJs = struct {
    context: *Context,
    token: module_types.LoadToken,
    kind: enum { resolve, load },
    id: []u8 = &.{},
    attributes: []module_types.ImportAttribute = &.{},
    handler: u32,
    specifier: []u8 = &.{},
    referrer: []u8 = &.{},
    settled: bool = false,
};

pub const Context = struct {
    host: *Host,
    id: u32,
    /// The realm that created it; its JS driver answers non-native handlers.
    creator: *ScopeState,
    scope: *Scope,
    graph: *Graph,
    import_handler: u32,
    /// `origine:` ids a handler of this context may still reach: the ceiling for handlers
    /// registered by code running inside it. Null: unrestricted. Its lists live in `ceiling_arena`
    /// (or in the handler, which outlives the context).
    ceiling: ?StdFilter = null,
    ceiling_arena: std.heap.ArenaAllocator,
    /// Module id -> id of the handler that answers its own imports. Keys are owned.
    handler_of: std.StringHashMapUnmanaged(u32) = .empty,
    /// `id ++ 0 ++ attributes` -> how it was resolved. Keys and values are owned.
    resolved: std.StringHashMapUnmanaged(Info) = .empty,
    /// Ids the native `origine` hook served. Keys are owned.
    served: std.StringHashMapUnmanaged(void) = .empty,
    /// Module id -> `import.meta` data as JSON. Keys and values are owned.
    meta: std.StringHashMapUnmanaged([]u8) = .empty,
    pendings: std.ArrayList(*PendingJs) = .empty,
    /// The module name `evaluateSource` is importing right now: its specifier bypasses the resolver
    /// (it names a module that was registered, not looked up). Borrowed for the call.
    root: ?[]const u8 = null,
    /// Handles kept until the next bridge call, because a link's exports and module are only
    /// copied once the module map finished compiling (see `link`).
    link_values: std.ArrayList(v8.Global.Of(v8.Value)) = .empty,
    link_modules: std.ArrayList(v8.Global.Of(v8.Module)) = .empty,
    closed: bool = false,

    /// What the `origine` hooks of `h` serve together: the union of their filters, built in `arena`
    /// (the lists it points at are owned by the handler and outlive the context). Nothing when the
    /// handler has none.
    fn ceilingOfHandler(arena: std.mem.Allocator, h: *const Handler) !?StdFilter {
        var result: ?StdFilter = null;
        for (h.hooks) |item| switch (item) {
            .origine => |filter| result = if (result) |so_far| try unionOf(arena, so_far, filter) else filter,
            else => {},
        };
        return result orelse StdFilter{ .include = &.{} };
    }

    /// The filter allowing exactly what `a` or `b` allows. An include list is a set of names, an
    /// exclude list (empty: everything) the complement of one, so the three cases are a union, an
    /// intersection of the excluded sets, and the excluded set minus the included one.
    fn unionOf(arena: std.mem.Allocator, a: StdFilter, b: StdFilter) !StdFilter {
        const a_include = a.include != null;
        const b_include = b.include != null;
        const a_list = a.include orelse a.exclude orelse &[_][]const u8{};
        const b_list = b.include orelse b.exclude orelse &[_][]const u8{};
        var out: std.ArrayList([]const u8) = .empty;
        if (a_include and b_include) {
            for ([_][]const []const u8{ a_list, b_list }) |list| for (list) |name| {
                if (!listHas(out.items, name)) try out.append(arena, name);
            };
            return .{ .include = try out.toOwnedSlice(arena) };
        }
        if (!a_include and !b_include) {
            for (a_list) |name| if (listHas(b_list, name)) try out.append(arena, name);
            return .{ .exclude = try out.toOwnedSlice(arena) };
        }
        const included = if (a_include) a_list else b_list;
        const excluded = if (a_include) b_list else a_list;
        for (excluded) |name| if (!listHas(included, name)) try out.append(arena, name);
        return .{ .exclude = try out.toOwnedSlice(arena) };
    }

    fn listHas(list: []const []const u8, name: []const u8) bool {
        for (list) |item| if (std.mem.eql(u8, item, name)) return true;
        return false;
    }

    fn releaseLinks(self: *Context) void {
        for (self.link_values.items) |value| value.deinit();
        self.link_values.clearRetainingCapacity();
        for (self.link_modules.items) |module| module.deinit();
        self.link_modules.clearRetainingCapacity();
    }

    pub fn deinit(self: *Context) void {
        const alloc = self.host.allocator;
        self.ceiling_arena.deinit();
        self.releaseLinks();
        self.link_values.deinit(alloc);
        self.link_modules.deinit(alloc);
        var it = self.handler_of.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        self.handler_of.deinit(alloc);
        var resolved = self.resolved.iterator();
        while (resolved.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.specifier);
            alloc.free(entry.value_ptr.referrer);
        }
        self.resolved.deinit(alloc);
        var served = self.served.keyIterator();
        while (served.next()) |key| alloc.free(key.*);
        self.served.deinit(alloc);
        var meta = self.meta.iterator();
        while (meta.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.meta.deinit(alloc);
        for (self.pendings.items) |pending| freePending(alloc, pending);
        self.pendings.deinit(alloc);
    }

    fn putOwned(self: *Context, map: anytype, key: []const u8, value: anytype) !void {
        const alloc = self.host.allocator;
        const slot = try map.getOrPut(alloc, key);
        if (slot.found_existing) return;
        errdefer _ = map.remove(key);
        slot.key_ptr.* = try alloc.dupe(u8, key);
        slot.value_ptr.* = value;
    }

    fn setHandler(self: *Context, id: []const u8, handler: u32) !void {
        const alloc = self.host.allocator;
        const slot = try self.handler_of.getOrPut(alloc, id);
        if (!slot.found_existing) slot.key_ptr.* = try alloc.dupe(u8, id);
        slot.value_ptr.* = handler;
    }

    fn setMeta(self: *Context, id: []const u8, json: []const u8) !void {
        const alloc = self.host.allocator;
        const text = try alloc.dupe(u8, json);
        errdefer alloc.free(text);
        const slot = try self.meta.getOrPut(alloc, id);
        if (slot.found_existing) {
            alloc.free(slot.value_ptr.*);
        } else slot.key_ptr.* = try alloc.dupe(u8, id);
        slot.value_ptr.* = text;
    }

    pub fn markServed(self: *Context, id: []const u8) !void {
        if (self.served.contains(id)) return;
        try self.putOwned(&self.served, id, {});
    }

    /// `id` and the attributes joined into one map key (borrowed storage from `alloc`).
    fn infoKey(alloc: std.mem.Allocator, id: []const u8, attributes: []const module_types.ImportAttribute) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(alloc, id);
        for (attributes) |attribute| {
            try out.append(alloc, 0);
            try out.appendSlice(alloc, attribute.key);
            try out.append(alloc, 1);
            try out.appendSlice(alloc, attribute.value);
        }
        return out.toOwnedSlice(alloc);
    }

    fn recordResolved(self: *Context, scratch: std.mem.Allocator, id: []const u8, attributes: []const module_types.ImportAttribute, handler: u32, specifier: []const u8, referrer: []const u8) !void {
        const alloc = self.host.allocator;
        const key = try infoKey(scratch, id, attributes);
        if (self.resolved.contains(key)) return;
        const specifier_copy = try alloc.dupe(u8, specifier);
        errdefer alloc.free(specifier_copy);
        const referrer_copy = try alloc.dupe(u8, referrer);
        errdefer alloc.free(referrer_copy);
        try self.putOwned(&self.resolved, key, Info{ .handler = handler, .specifier = specifier_copy, .referrer = referrer_copy });
    }
};

fn freePending(alloc: std.mem.Allocator, pending: *PendingJs) void {
    alloc.free(pending.id);
    for (pending.attributes) |attribute| {
        alloc.free(attribute.key);
        alloc.free(attribute.value);
    }
    alloc.free(pending.attributes);
    alloc.free(pending.specifier);
    alloc.free(pending.referrer);
    alloc.destroy(pending);
}

fn contextFor(state: *ScopeState, id: u32) !*Context {
    const host = state.host;
    if (id == 0 or id > host.contexts.items.len) return error.BadHandle;
    const found = host.contexts.items[id - 1];
    if (found.creator != state) return error.BadHandle;
    if (found.closed) return error.StaleHandle;
    return found;
}

// ---- the bridge: Resolver, Loader, meta and code cache of a context --------

fn resolveAsync(data: ?*anyopaque, request: module_types.ResolveRequest) anyerror!module_types.ResolveOutcome {
    const self: *Context = @ptrCast(@alignCast(data.?));
    self.releaseLinks();
    const host = self.host;
    if (self.root) |name| if (request.referrer.len == 0 and std.mem.eql(u8, request.specifier, name)) return .{ .id = try request.allocator.dupe(u8, name) };
    const handler_id = self.handler_of.get(request.referrer) orelse self.import_handler;
    const h = try graph_api.handlerFor(host, handler_id);
    if (h.native) {
        const id = (try graph_api.resolveNative(h, request.allocator, request.specifier, request.referrer)) orelse return error.NotFound;
        try self.recordResolved(request.allocator, id, request.import_attributes, handler_id, request.specifier, request.referrer);
        return .{ .id = id };
    }
    return callDriver(self, .resolve, handler_id, request.token, "", request.specifier, request.referrer, request.import_attributes, request.allocator);
}

fn cancel(data: ?*anyopaque, token: module_types.LoadToken) void {
    const self: *Context = @ptrCast(@alignCast(data.?));
    for (self.pendings.items) |pending| if (pending.token == token) {
        pending.settled = true;
    };
}

fn load(data: ?*anyopaque, request: module_types.LoadRequest) anyerror!module_types.LoadResult {
    const self: *Context = @ptrCast(@alignCast(data.?));
    self.releaseLinks();
    const host = self.host;
    const key = try Context.infoKey(request.allocator, request.module_id, request.import_attributes);
    const info = self.resolved.get(key) orelse return error.NotFound;
    const h = try graph_api.handlerFor(host, info.handler);
    if (h.native) {
        var served = false;
        const loaded = try graph_api.loadNative(.{ .host = host, .graph = self.graph, .alloc = request.allocator, .served = &served }, h, info.handler, request.module_id, request.import_attributes);
        switch (loaded) {
            .source => |made| {
                if (served) try self.markServed(request.module_id);
                try self.setHandler(request.module_id, made.import);
                return .{ .source = made.source };
            },
            .diagnostics => |text| return .{ .exception = transformer_api.syntaxError(text) },
        }
    }
    const outcome = try callDriver(self, .load, info.handler, request.token, request.module_id, info.specifier, info.referrer, request.import_attributes, request.allocator);
    _ = outcome;
    return .pending;
}

/// Calls the creating realm's JS driver. Returns the resolver answer (`.id` or `.pending`) for
/// `.resolve`; for `.load` it always parks the load (`.pending`) and the answer arrives through a
/// completion. Exceptions the driver throws become the failure of the request.
fn callDriver(self: *Context, kind: enum { resolve, load }, handler_id: u32, token: module_types.LoadToken, id: []const u8, specifier: []const u8, referrer: []const u8, attributes: []const module_types.ImportAttribute, scratch: std.mem.Allocator) !module_types.ResolveOutcome {
    const host = self.host;
    const creator = self.creator;
    if (creator.released) return error.ScopeDisposed;
    host.driver_calls += 1;
    const driver = creator.driver orelse return error.Unsupported;
    const isolate = creator.scope.runtime.isolate;
    const parent_ctx = creator.scope.context.deref();
    parent_ctx.enter();
    defer parent_ctx.exit();
    var h_scope: v8.HandleScope = undefined;
    h_scope.init(isolate);
    defer h_scope.deinit();
    var tc: v8.TryCatch = undefined;
    tc.init(isolate);
    defer tc.deinit();

    const bag = v8.Object.init(isolate);
    for (attributes) |attribute| {
        _ = bag.createDataProperty(parent_ctx, eu.v.str_utf8(isolate, attribute.key).name, binding.string(isolate, attribute.value)) orelse return error.LoaderFailed;
    }
    const number = struct {
        fn of(iso: v8.Isolate, value: u32) v8.Value {
            return eu.v.num_u32(iso, value).numeric.primitive.value;
        }
    }.of;
    const function = switch (kind) {
        .resolve => driver.resolve.deref(),
        .load => driver.load.deref(),
    };
    const result = switch (kind) {
        .resolve => function.call(parent_ctx, eu.v.undefined_value(isolate).value, &.{ number(isolate, handler_id), number(isolate, self.id), binding.string(isolate, specifier), binding.string(isolate, referrer), bag.value }),
        .load => function.call(parent_ctx, eu.v.undefined_value(isolate).value, &.{ number(isolate, handler_id), number(isolate, self.id), number(isolate, self.graph.id), binding.string(isolate, id), bag.value, binding.string(isolate, specifier), binding.string(isolate, referrer) }),
    } orelse return failureOf(parent_ctx, isolate, &tc);

    // A promise (the driver is an async function): park the request until it settles.
    const alloc = host.allocator;
    const pending = try alloc.create(PendingJs);
    errdefer alloc.destroy(pending);
    pending.* = .{ .context = self, .token = token, .kind = if (kind == .resolve) .resolve else .load, .handler = handler_id };
    pending.id = try alloc.dupe(u8, id);
    errdefer alloc.free(pending.id);
    pending.specifier = try alloc.dupe(u8, specifier);
    errdefer alloc.free(pending.specifier);
    pending.referrer = try alloc.dupe(u8, referrer);
    errdefer alloc.free(pending.referrer);
    const copied = try alloc.alloc(module_types.ImportAttribute, attributes.len);
    var done: usize = 0;
    errdefer {
        for (copied[0..done]) |attribute| {
            alloc.free(attribute.key);
            alloc.free(attribute.value);
        }
        alloc.free(copied);
    }
    for (attributes, copied) |attribute, *slot| {
        slot.* = .{ .key = try alloc.dupe(u8, attribute.key), .value = try alloc.dupe(u8, attribute.value) };
        done += 1;
    }
    pending.attributes = copied;
    try self.pendings.append(alloc, pending);
    errdefer _ = self.pendings.pop();
    if (!result.isPromise()) {
        // Settled synchronously: still finished through the same completion path, after the call returns.
        const promise = v8.Promise.from_opaque(Promise.resolved(isolate, parent_ctx, result).data.handle).?;
        try chain(parent_ctx, isolate, promise, pending);
        _ = scratch;
        return .pending;
    }
    try chain(parent_ctx, isolate, v8.Promise.from_opaque(result.data.handle).?, pending);
    return .pending;
}

const Promise = struct {
    /// A promise already resolved with `value`.
    fn resolved(isolate: v8.Isolate, ctx: v8.Context, value: v8.Value) v8.Value {
        _ = isolate;
        const resolver = eu.v.promise_resolver(ctx).?;
        _ = resolver.resolve(ctx, value);
        return resolver.getPromise().object.value;
    }
};

fn chain(parent_ctx: v8.Context, isolate: v8.Isolate, promise: v8.Promise, pending: *PendingJs) !void {
    const external = eu.v.external(isolate, pending).value.data;
    const on_fulfilled = v8.Function.init(parent_ctx, fulfilled, external, 1, .Throw, .HasSideEffect);
    const on_rejected = v8.Function.init(parent_ctx, rejected, external, 1, .Throw, .HasSideEffect);
    _ = promise.then2(parent_ctx, on_fulfilled, on_rejected) orelse return error.LoaderFailed;
}

/// The error a thrown driver exception stands for: its `errno`/`name` when it carries one.
fn failureOf(ctx: v8.Context, isolate: v8.Isolate, tc: *v8.TryCatch) anyerror {
    const exception = tc.getException() orelse return error.LoaderFailed;
    return errorOf(ctx, isolate, exception);
}

fn errorOf(ctx: v8.Context, isolate: v8.Isolate, exception: v8.Value) anyerror {
    const object = exception.toObject(ctx) orelse return error.ImportRejected;
    const name = object.get(ctx, binding.string(isolate, "name")) orelse return error.ImportRejected;
    if (!name.isString()) return error.ImportRejected;
    var buffer: [32]u8 = undefined;
    const text = name.toString(ctx) orelse return error.ImportRejected;
    if (text.lenUtf8(isolate) > buffer.len) return error.ImportRejected;
    const bytes = buffer[0..text.writeUtf8(isolate, &buffer)];
    if (std.mem.eql(u8, bytes, "NotFound")) return error.NotFound;
    if (std.mem.eql(u8, bytes, "PermissionDenied")) return error.PermissionDenied;
    if (std.mem.eql(u8, bytes, "InvalidInput")) return error.InvalidInput;
    if (std.mem.eql(u8, bytes, "InvalidData")) return error.InvalidData;
    if (std.mem.eql(u8, bytes, "Unsupported")) return error.Unsupported;
    return error.ImportRejected;
}

fn stringOf(ctx: v8.Context, isolate: v8.Isolate, alloc: std.mem.Allocator, object: v8.Object, name: []const u8) !?[]u8 {
    const value = object.get(ctx, binding.string(isolate, name)) orelse return null;
    if (!value.isString()) return null;
    const text = value.toString(ctx) orelse return null;
    const buffer = try alloc.alloc(u8, text.lenUtf8(isolate));
    return buffer[0..text.writeUtf8(isolate, buffer)];
}

fn numberOf(ctx: v8.Context, isolate: v8.Isolate, object: v8.Object, name: []const u8) ?u32 {
    const value = object.get(ctx, binding.string(isolate, name)) orelse return null;
    if (!value.isNumber()) return null;
    return value.u32Value(ctx);
}

/// Forgets a settled call into the driver and frees it; its other callback can never run.
fn retire(self: *Context, pending: *PendingJs) void {
    for (self.pendings.items, 0..) |item, index| if (item == pending) {
        _ = self.pendings.swapRemove(index);
        break;
    };
    freePending(self.host.allocator, pending);
}

fn fulfilled(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = binding.externalPointer(PendingJs, info);
    const self = pending.context;
    if (pending.settled or self.closed) return;
    pending.settled = true;
    defer retire(self, pending);
    const host = self.host;
    const isolate = info.isolate();
    const ctx = isolate.getCurrentContext();
    const rt = self.scope.runtime;
    var scratch = std.heap.ArenaAllocator.init(host.allocator);
    defer scratch.deinit();
    const alloc = scratch.allocator();
    switch (pending.kind) {
        .resolve => {
            const value = info.get_arg(0);
            const id = idOf(ctx, isolate, alloc, value) catch {
                rt.completeResolve(pending.token, .{ .failure = error.InvalidData }) catch {};
                return;
            };
            self.recordResolved(alloc, id, pending.attributes, pending.handler, pending.specifier, pending.referrer) catch {};
            rt.completeResolve(pending.token, .{ .id = id }) catch {};
        },
        .load => {
            const reply = readReply(self, ctx, isolate, alloc, pending.id, info.get_arg(0)) catch |err| {
                rt.completeLoad(pending.token, .{ .failure = err }) catch {};
                return;
            };
            rt.completeLoad(pending.token, reply) catch {};
        },
    }
}

fn rejected(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = binding.externalPointer(PendingJs, info);
    const self = pending.context;
    if (pending.settled or self.closed) return;
    pending.settled = true;
    defer retire(self, pending);
    const isolate = info.isolate();
    const ctx = isolate.getCurrentContext();
    var scratch = std.heap.ArenaAllocator.init(self.host.allocator);
    defer scratch.deinit();
    const alloc = scratch.allocator();
    const rt = self.scope.runtime;
    // An ImportError code keeps its kind; anything else reaches the module as an `Error` with its message.
    const known = errorOf(ctx, isolate, info.get_arg(0));
    if (known != error.ImportRejected) {
        switch (pending.kind) {
            .resolve => rt.completeResolve(pending.token, .{ .failure = known }) catch {},
            .load => rt.completeLoad(pending.token, .{ .failure = known }) catch {},
        }
        return;
    }
    const text = messageOf(ctx, isolate, alloc, info.get_arg(0)) catch "import rejected";
    switch (pending.kind) {
        .resolve => rt.completeResolve(pending.token, .{ .message = text }) catch {},
        .load => rt.completeLoad(pending.token, .{ .message = text }) catch {},
    }
}

/// `name: message` of a thrown value, for a failure that is not one of the closed ImportError kinds.
fn messageOf(ctx: v8.Context, isolate: v8.Isolate, alloc: std.mem.Allocator, value: v8.Value) ![]const u8 {
    const object = value.toObject(ctx) orelse return "import rejected";
    const message = (try stringOf(ctx, isolate, alloc, object, "message")) orelse "";
    const name = (try stringOf(ctx, isolate, alloc, object, "name")) orelse "Error";
    return std.fmt.allocPrint(alloc, "{s}: {s}", .{ name, message });
}

/// A resolver reply: the id string, or an object with a string `id`.
fn idOf(ctx: v8.Context, isolate: v8.Isolate, alloc: std.mem.Allocator, value: v8.Value) ![]u8 {
    if (value.isString()) {
        const text = value.toString(ctx) orelse return error.InvalidData;
        const buffer = try alloc.alloc(u8, text.lenUtf8(isolate));
        return buffer[0..text.writeUtf8(isolate, buffer)];
    }
    const object = value.toObject(ctx) orelse return error.InvalidData;
    return (try stringOf(ctx, isolate, alloc, object, "id")) orelse error.InvalidData;
}

/// Turns the load answer of the JS driver into the content to complete the load with. Records what
/// the context keeps about the module (its handler, `import.meta` data) and refuses to let a JS
/// answer serve an `origine:` id the native provider did not.
fn readReply(self: *Context, ctx: v8.Context, isolate: v8.Isolate, alloc: std.mem.Allocator, id: []const u8, value: v8.Value) !module_types.Completion {
    const object = value.toObject(ctx) orelse return error.InvalidData;
    const kind = (try stringOf(ctx, isolate, alloc, object, "kind")) orelse return error.InvalidData;
    if (std.mem.eql(u8, kind, "source")) {
        if (std.mem.startsWith(u8, id, module_types.origine_prefix) and !self.served.contains(id)) return error.PermissionDenied;
        const source = (try stringOf(ctx, isolate, alloc, object, "source")) orelse return error.InvalidData;
        if (numberOf(ctx, isolate, object, "handler")) |handler| try self.setHandler(id, handler);
        if (try stringOf(ctx, isolate, alloc, object, "meta")) |json| try self.setMeta(id, json);
        return .{ .content = .{ .source = source } };
    }
    if (std.mem.eql(u8, kind, "link")) {
        if (std.mem.startsWith(u8, id, module_types.origine_prefix)) return error.PermissionDenied;
        const other_id = numberOf(ctx, isolate, object, "context") orelse return error.InvalidData;
        const name = (try stringOf(ctx, isolate, alloc, object, "name")) orelse return error.InvalidData;
        const mode = (try stringOf(ctx, isolate, alloc, object, "mode")) orelse return error.InvalidData;
        return .{ .content = try link(self, other_id, name, std.mem.eql(u8, mode, "shared"), alloc) };
    }
    return error.InvalidData;
}

/// The content that makes the module `name` of context `other_id` available to `self`: the module
/// itself (`shared`: live bindings, the other realm's objects), or a synthetic module of its
/// exports (hardened by the module map). Handles stay in `self.link_*` until the next bridge call.
fn link(self: *Context, other_id: u32, name: []const u8, shared: bool, alloc: std.mem.Allocator) !module_types.Content {
    const host = self.host;
    if (other_id == 0 or other_id > host.contexts.items.len) return error.BadHandle;
    const other = host.contexts.items[other_id - 1];
    if (other.closed or other.creator != self.creator) return error.BadHandle;
    const isolate = self.scope.runtime.isolate;
    const held = (try other.scope.module_map.get(.{ .module_id = name }, null)) orelse return error.NotFound;
    errdefer held.deinit();
    try self.link_modules.append(host.allocator, held);
    const module = held.deref();
    if (shared or other == self) return .{ .module = module };
    const other_ctx = other.scope.context.deref();
    other_ctx.enter();
    defer other_ctx.exit();
    const namespace = (module.getModuleNamespace() orelse return error.InvalidData).toObject(other_ctx) orelse return error.InvalidData;
    const names = namespace.getOwnPropertyNames(other_ctx, .{ .OnlyEnumerable = true, .SkipSymbols = true }, .ConvertToString) orelse return error.InvalidData;
    const exports = try alloc.alloc(module_types.Export, names.len());
    var count: usize = 0;
    var index: u32 = 0;
    while (index < names.len()) : (index += 1) {
        const key = names.object.getIndex(other_ctx, index) orelse continue;
        if (!key.isString()) continue;
        const text = key.toString(other_ctx) orelse continue;
        const buffer = try alloc.alloc(u8, text.lenUtf8(isolate));
        const bytes = buffer[0..text.writeUtf8(isolate, buffer)];
        const value = namespace.get(other_ctx, key) orelse return error.InvalidData;
        const retained: v8.Global.Of(v8.Value) = .new(isolate, value);
        try self.link_values.append(host.allocator, retained);
        exports[count] = .{ .name = bytes, .value = retained };
        count += 1;
    }
    return .{ .exports = exports[0..count] };
}

fn metaHook(data: ?*anyopaque, request: module_types.MetaRequest) void {
    const self: *Context = @ptrCast(@alignCast(data.?));
    if (self.meta.get(request.module_id)) |json| applyJson(self, request, json);
    if (self.served.contains(request.module_id)) init_loader.meta(self.host, request);
}

/// Copies the top-level properties of the JSON object `json` onto `import.meta`.
fn applyJson(self: *Context, request: module_types.MetaRequest, json: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, self.host.allocator, json, .{}) catch return;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return,
    };
    const isolate = self.scope.runtime.isolate;
    var it = object.iterator();
    while (it.next()) |entry| {
        const value = jsonToV8(isolate, request.context, entry.value_ptr.*) orelse continue;
        _ = request.meta.createDataProperty(request.context, eu.v.str_utf8(isolate, entry.key_ptr.*).name, value);
    }
}

fn jsonToV8(isolate: v8.Isolate, ctx: v8.Context, value: std.json.Value) ?v8.Value {
    switch (value) {
        .null => return eu.v.null_value(isolate).value,
        .bool => |flag| return eu.v.boolean(isolate, flag).primitive.value,
        .integer => |number| return eu.v.num_f64(isolate, @floatFromInt(number)).numeric.primitive.value,
        .float => |number| return eu.v.num_f64(isolate, number).numeric.primitive.value,
        .number_string => return null,
        .string => |text| return binding.string(isolate, text),
        .array => |list| {
            const array = eu.v.array(isolate, 0);
            for (list.items, 0..) |item, index| {
                const converted = jsonToV8(isolate, ctx, item) orelse eu.v.undefined_value(isolate).value;
                _ = array.object.setIndex(ctx, @intCast(index), converted);
            }
            return array.object.value;
        },
        .object => |object| {
            const out = eu.v.object(isolate);
            var it = object.iterator();
            while (it.next()) |entry| {
                const converted = jsonToV8(isolate, ctx, entry.value_ptr.*) orelse continue;
                _ = out.createDataProperty(ctx, eu.v.str_utf8(isolate, entry.key_ptr.*).name, converted);
            }
            return out.value;
        },
    }
}

fn sourceHash(source: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Blake3.hash(source, &out, .{});
    return out;
}

fn cacheLoad(data: ?*anyopaque, request: module_types.CodeCacheRequest) ?[]const u8 {
    const self: *Context = @ptrCast(@alignCast(data.?));
    const graph = self.graph;
    if (std.mem.startsWith(u8, request.module_id, module_types.origine_prefix)) return null;
    if (graph.lookup(request.allocator, request.module_id, sourceHash(request.source))) |bytes| {
        // The module map needs 8-aligned bytes that live in the request allocator.
        const copy = request.allocator.alignedAlloc(u8, .@"8", bytes.len) catch return null;
        @memcpy(copy, bytes);
        return copy;
    }
    if (graph.dir_state) |*state| {
        const hook = state.hook();
        if (hook.load(hook.data, request)) |bytes| return bytes;
    }
    return null;
}

fn cacheStore(data: ?*anyopaque, request: module_types.CodeCacheRequest, bytes: []const u8) void {
    const self: *Context = @ptrCast(@alignCast(data.?));
    const graph = self.graph;
    if (std.mem.startsWith(u8, request.module_id, module_types.origine_prefix)) return;
    const hash = sourceHash(request.source);
    graph.remember(request.module_id, hash, bytes);
    switch (graph.kind) {
        .none => {},
        .memory => {},
        .dir => if (graph.dir_state) |*state| {
            const hook = state.hook();
            hook.store(hook.data, request, bytes);
        },
        .custom => {
            const alloc = graph.host.allocator;
            const id = alloc.dupe(u8, request.module_id) catch return;
            const copy = alloc.dupe(u8, bytes) catch {
                alloc.free(id);
                return;
            };
            graph.fresh.append(alloc, .{ .id = id, .hash = hash, .bytes = copy }) catch {
                alloc.free(id);
                alloc.free(copy);
            };
        },
    }
}

fn onDispose(data: ?*anyopaque, scope: *Scope) void {
    const host: *Host = @ptrCast(@alignCast(data.?));
    for (host.contexts.items) |ctx| if (ctx.scope == scope) {
        ctx.closed = true;
    };
}

// ---- natives ---------------------------------------------------------------

/// `create(importHandler, graph)`: a realm whose imports run through `importHandler` with the
/// authority of `graph`. Returns the context id.
pub fn create(state: *ScopeState, import_handler: u32, graph_id: u32) Error!u32 {
    return createImpl(state, import_handler, graph_id) catch |err| return errno.narrow(err);
}

fn createImpl(state: *ScopeState, import_handler: u32, graph_id: u32) !u32 {
    const host = state.host;
    const alloc = host.allocator;
    const h = try graph_api.handlerFor(host, import_handler);
    const graph = try graph_api.graphFor(host, graph_id);
    if (!h.native and state.driver == null) return error.Unsupported;
    try host.contexts.ensureUnusedCapacity(alloc, 1);
    const context = try alloc.create(Context);
    errdefer alloc.destroy(context);
    context.* = .{
        .host = host,
        .id = @intCast(host.contexts.items.len + 1),
        .creator = state,
        .scope = undefined,
        .graph = graph,
        .import_handler = import_handler,
        .ceiling_arena = .init(alloc),
    };
    errdefer context.deinit();
    context.ceiling = try Context.ceilingOfHandler(context.ceiling_arena.allocator(), h);
    var options: Scope.Options = .{
        .origine_namespace = true,
        .resolver = .{ .data = context, .resolve_async = resolveAsync, .cancel = cancel },
        .loader = .{ .data = context, .load = load },
        .meta = .{ .data = context, .init = metaHook },
        .on_dispose = host.disposer(),
        .retain = switch (h.retain) {
            .all => .all,
            .used => .used,
        },
        .table_limit = h.entries,
    };
    if (graph.kind != .none) options.code_cache = .{ .data = context, .load = cacheLoad, .store = cacheStore };
    const scope = try state.scope.runtime.createScope(options);
    errdefer state.scope.runtime.disposeScope(scope);
    context.scope = scope;
    _ = try host.attach(scope);
    host.contexts.appendAssumeCapacity(context);
    return context.id;
}

/// One import in flight: settled with the module's id (a string of the parent's realm) once it
/// has been evaluated, or rejected with a fresh `ModuleError`.
pub const ImportState = struct {
    host: *Host,
    context: *Context,
    resolver: v8.Global.Of(v8.Promise.Resolver),
    done: bool = false,
};

fn settleOk(pending: *ImportState, isolate: v8.Isolate, id: ?[]const u8) void {
    if (pending.done) return;
    pending.done = true;
    defer pending.resolver.deinit();
    const parent = pending.context.creator.scope.context.deref();
    const value = if (id) |text| binding.string(isolate, text) else eu.v.undefined_value(isolate).value;
    _ = pending.resolver.deref().resolve(parent, value);
}

fn settleFail(pending: *ImportState, isolate: v8.Isolate, reason: v8.Value, child_ctx: v8.Context) void {
    if (pending.done) return;
    pending.done = true;
    defer pending.resolver.deinit();
    const parent = pending.context.creator.scope.context.deref();
    const message = if (reason.toDetailString(child_ctx)) |text| text.name.primitive.value else binding.string(isolate, "module evaluation failed");
    const env: binding.Env = .{ .isolate = isolate, .ctx = parent };
    const failure = binding.encode(env, {}, .{
        .errno = @backingInt(errno.Errno.Unexpected),
        .name = "ModuleError",
        .message = message,
    }) catch {
        _ = pending.resolver.deref().reject(parent, message);
        return;
    };
    _ = pending.resolver.deref().reject(parent, failure);
}

fn importFulfilled(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = binding.externalPointer(ImportState, info);
    const isolate = info.isolate();
    const ctx = isolate.getCurrentContext();
    _ = ctx;
    const id = pending.context.scope.module_map.idOfNamespace(info.get_arg(0));
    settleOk(pending, isolate, id);
}

fn importRejected(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = binding.externalPointer(ImportState, info);
    const isolate = info.isolate();
    settleFail(pending, isolate, info.get_arg(0), isolate.getCurrentContext());
}

fn startImport(call: *Call, state: *ScopeState, context: *Context, promise: v8.Global.Of(v8.Promise)) !v8.Promise {
    defer promise.deinit();
    const host = state.host;
    const alloc = host.allocator;
    const resolver = eu.v.promise_resolver(call.ctx) orelse return error.Unexpected;
    const pending = try alloc.create(ImportState);
    errdefer alloc.destroy(pending);
    pending.* = .{ .host = host, .context = context, .resolver = .new(call.isolate, resolver) };
    errdefer pending.resolver.deinit();
    try host.imports.append(alloc, pending);
    errdefer _ = host.imports.pop();
    const data = eu.v.external(call.isolate, pending).value.data;
    var session: Scope.Session = undefined;
    session.init(context.scope);
    defer session.deinit();
    const on_fulfilled = v8.Function.init(session.ctx, importFulfilled, data, 1, .Throw, .HasSideEffect);
    const on_rejected = v8.Function.init(session.ctx, importRejected, data, 1, .Throw, .HasSideEffect);
    _ = promise.deref().then2(session.ctx, on_fulfilled, on_rejected) orelse return error.Unexpected;
    return resolver.getPromise();
}

fn attributesOf(call: *Call, json: []const u8) ![]const module_types.ImportAttribute {
    if (json.len == 0) return &.{};
    const parsed = std.json.parseFromSlice(std.json.Value, call.arena, json, .{}) catch return error.InvalidInput;
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidInput,
    };
    const out = call.allocSlice(module_types.ImportAttribute, object.count());
    var it = object.iterator();
    var index: usize = 0;
    while (it.next()) |entry| : (index += 1) {
        if (entry.value_ptr.* != .string) return error.InvalidInput;
        out[index] = .{ .key = entry.key_ptr.*, .value = entry.value_ptr.string };
    }
    return out;
}

/// `importSpecifier(context, specifier, attributesJson)`: imports `specifier` as a script's
/// `import()` would, through the context's own handler. A parent-realm promise of the module id.
pub fn importSpecifier(state: *ScopeState, call: *Call, id: u32, specifier: []const u8, attributes: []const u8) Error!v8.Promise {
    return importImpl(state, call, id, specifier, attributes) catch |err| return errno.narrow(err);
}

fn importImpl(state: *ScopeState, call: *Call, id: u32, specifier: []const u8, attributes: []const u8) !v8.Promise {
    const context = try contextFor(state, id);
    const promise = try context.scope.importModuleWithAttributes(specifier, try attributesOf(call, attributes), null);
    return startImport(call, state, context, promise);
}

/// `evaluateSource(context, name, source, handler, metaJson)`: registers `source` as the module
/// `name` of the context (its own imports go through `handler`) and evaluates it. A parent-realm
/// promise of `name`. `name` must not be taken in this context's table.
pub fn evaluateSource(state: *ScopeState, call: *Call, id: u32, name: []const u8, source: []const u8, handler: u32, meta: []const u8) Error!v8.Promise {
    return evaluateImpl(state, call, id, name, source, handler, meta) catch |err| return errno.narrow(err);
}

fn evaluateImpl(state: *ScopeState, call: *Call, id: u32, name: []const u8, source: []const u8, handler: u32, meta: []const u8) !v8.Promise {
    const context = try contextFor(state, id);
    _ = try graph_api.handlerFor(state.host, handler);
    if (name.len == 0 or std.mem.startsWith(u8, name, module_types.origine_prefix)) return error.InvalidInput;
    if (try context.scope.module_map.get(.{ .module_id = name }, null)) |existing| {
        existing.deinit();
        return error.InvalidInput;
    }
    try context.scope.updateImportCache(.{ .module_id = name }, .{ .source = source }, null);
    try context.setHandler(name, handler);
    if (meta.len != 0) try context.setMeta(name, meta);
    context.root = name;
    defer context.root = null;
    const promise = try context.scope.importModule(name, null);
    return startImport(call, state, context, promise);
}

/// `close(context)`: disposes the realm. Its pending imports reject and its handles go stale.
pub fn close(state: *ScopeState, id: u32) Error!void {
    const context = contextFor(state, id) catch |err| return errno.narrow(err);
    closeContext(state.host, context);
}

pub fn closeContext(host: *Host, context: *Context) void {
    if (context.closed) return;
    context.closed = true;
    for (host.contexts.items) |other| {
        if (!other.closed and other.creator.scope == context.scope) closeContext(host, other);
    }
    context.scope.runtime.disposeScope(context.scope);
}

/// `tableSize(context)`: the modules the context's identity table holds.
pub fn tableSize(state: *ScopeState, id: u32) Error!u32 {
    const context = contextFor(state, id) catch |err| return errno.narrow(err);
    return @intCast(context.scope.module_map.cachedCount());
}

/// `tableDelete(context, id)`: forgets the module `id` (and what imported it) so the next import of
/// it makes a new one. Returns how many entries it dropped.
pub fn tableDelete(state: *ScopeState, id: u32, module_id: []const u8) Error!u32 {
    const context = contextFor(state, id) catch |err| return errno.narrow(err);
    const count = context.scope.deleteImportCache(.{ .module_id = module_id }) catch |err| return errno.narrow(err);
    return @intCast(count);
}

/// `tableClear(context)`: forgets every module of the table.
pub fn tableClear(state: *ScopeState, id: u32) Error!u32 {
    const context = contextFor(state, id) catch |err| return errno.narrow(err);
    const count = context.scope.clearImportCache() catch |err| return errno.narrow(err);
    return @intCast(count);
}

/// `flush(graph)`: asks every live context of the graph to hand over the code caches of modules
/// that compiled without one. Returns `[[id, hashHex, bytes], ...]` for the entries a `custom` cache
/// has to persist (a `dir` cache wrote its files; a `memory` cache kept them); the count of stored
/// modules is the array length plus `stored`.
pub fn flush(state: *ScopeState, call: *Call, graph_id: u32) Error!v8.Value {
    return flushImpl(state, call, graph_id) catch |err| return errno.narrow(err);
}

fn flushImpl(state: *ScopeState, call: *Call, graph_id: u32) !v8.Value {
    const host = state.host;
    const graph = try graph_api.graphFor(host, graph_id);
    var stored: usize = 0;
    for (host.contexts.items) |context| {
        if (context.closed or context.graph != graph) continue;
        stored += context.scope.flushCodeCache();
    }
    var out = call.array();
    try out.push(@as(f64, @floatFromInt(stored)));
    for (graph.fresh.items) |item| {
        var entry = call.array();
        try entry.push(item.id);
        const hex = std.fmt.bytesToHex(item.hash, .lower);
        try entry.push(@as([]const u8, &hex));
        try entry.push(try call.bytesValue(item.bytes));
        try out.push(entry.finish());
        host.allocator.free(item.id);
        host.allocator.free(item.bytes);
    }
    graph.fresh.clearRetainingCapacity();
    return out.finish();
}

/// `cachePut(graph, id, hashHex, bytes)`: hands a code cache a `custom` store loaded to the graph,
/// valid for the exact source whose hash is `hashHex`.
pub fn cachePut(state: *ScopeState, graph_id: u32, id: []const u8, hash_hex: []const u8, bytes: []u8) Error!void {
    const graph = graph_api.graphFor(state.host, graph_id) catch |err| return errno.narrow(err);
    var hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&hash, hash_hex) catch return error.InvalidInput;
    graph.remember(id, hash, bytes);
}

/// Records that the native `origine` hook served `id` for the context `context_id` of `state`'s
/// realm (a driver call told the hook which context it works for).
pub fn markServedFor(host: *Host, state: *ScopeState, context_id: u32, id: []const u8) void {
    const context = contextFor(state, context_id) catch return;
    context.markServed(id) catch {};
    _ = host;
}

// ---- preloads --------------------------------------------------------------

comptime {
    @setEvalBranchQuota(200_000);
    errno.requireBinding(preloadScript);
    errno.requireBinding(preloadModule);
}

/// `preloadScript(context, source, origin, values)`: evaluates `source` (a function expression) in
/// the context and calls it with `values`, hardened (deep-frozen) first.
pub fn preloadScript(state: *ScopeState, id: u32, source: []const u8, origin: []const u8, values: v8.Value) Error!void {
    return preloadScriptImpl(state, id, source, origin, values) catch |err| return errno.narrow(err);
}

fn preloadScriptImpl(state: *ScopeState, id: u32, source: []const u8, origin: []const u8, values: v8.Value) !void {
    const context = try contextFor(state, id);
    if (!values.isUndefined()) try state.scope.hardenLocal(values);
    var session: Scope.Session = undefined;
    session.init(context.scope);
    defer session.deinit();
    const isolate = session.isolate();
    const script = v8.Script.compile(session.ctx, eu.v.str_utf8(isolate, source), context.scope.scriptOrigin(origin, false)) orelse return error.InvalidInput;
    const function = v8.Function.from_opaque((script.run(session.ctx) orelse return error.Unexpected).data.handle) orelse return error.InvalidInput;
    _ = function.call(session.ctx, eu.v.undefined_value(isolate).value, &.{values}) orelse return error.Unexpected;
}

/// A module preload in flight: the parent-realm promise to settle and the hardened `values` handed to
/// the module's default export.
pub const PreloadState = struct {
    host: *Host,
    resolver: v8.Global.Of(v8.Promise.Resolver),
    done: bool = false,
    parent: *Scope,
    values: ?v8.Global.Of(v8.Value) = null,
};

/// `preloadModule(context, name, source, values)`: evaluates `source` as the module `name`, then, when
/// `values` is given and the default export is a function, calls it with them (hardened first).
/// A parent-realm promise that settles once everything finished; a failure rejects with a fresh
/// `ModuleError`.
pub fn preloadModule(state: *ScopeState, call: *Call, id: u32, name: []const u8, source: []const u8, values: v8.Value) Error!v8.Promise {
    return preloadModuleImpl(state, call, id, name, source, values) catch |err| return errno.narrow(err);
}

fn preloadModuleImpl(state: *ScopeState, call: *Call, id: u32, name: []const u8, source: []const u8, values: v8.Value) !v8.Promise {
    const host = state.host;
    const alloc = host.allocator;
    const context = try contextFor(state, id);
    const has_values = !values.isUndefined();
    if (has_values) try state.scope.hardenLocal(values);
    const resolver = eu.v.promise_resolver(call.ctx) orelse return error.Unexpected;
    const pending = try alloc.create(PreloadState);
    errdefer alloc.destroy(pending);
    pending.* = .{ .host = host, .resolver = .new(call.isolate, resolver), .parent = state.scope };
    errdefer pending.resolver.deinit();
    if (has_values) pending.values = .new(call.isolate, values);
    errdefer if (pending.values) |held| held.deinit();
    try host.preloads.append(alloc, pending);
    errdefer _ = host.preloads.pop();
    try context.scope.updateImportCache(.{ .module_id = name }, .{ .source = source }, null);
    context.root = name;
    defer context.root = null;
    const loading = try context.scope.importModule(name, null);
    defer loading.deinit();
    const data = eu.v.external(call.isolate, pending).value.data;
    var session: Scope.Session = undefined;
    session.init(context.scope);
    defer session.deinit();
    const on_fulfilled = v8.Function.init(session.ctx, preloadLoaded, data, 1, .Throw, .HasSideEffect);
    const on_rejected = v8.Function.init(session.ctx, preloadFailed, data, 1, .Throw, .HasSideEffect);
    _ = loading.deref().then2(session.ctx, on_fulfilled, on_rejected) orelse return error.Unexpected;
    return resolver.getPromise();
}

fn preloadSettle(pending: *PreloadState, isolate: v8.Isolate, reason: ?v8.Value) void {
    if (pending.done) return;
    pending.done = true;
    defer pending.resolver.deinit();
    defer if (pending.values) |held| {
        held.deinit();
        pending.values = null;
    };
    const parent_ctx = pending.parent.context.deref();
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
    const pending = binding.externalPointer(PreloadState, info);
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
    preloadSettle(binding.externalPointer(PreloadState, info), info.isolate(), null);
}

fn preloadFailed(info: v8.FunctionCallbackInfo) callconv(.c) void {
    preloadSettle(binding.externalPointer(PreloadState, info), info.isolate(), info.get_arg(0));
}

/// `pin(context, id)`: keeps the module `id` of the context's table alive while a handle holds it.
/// Returns the serial `unpin` takes (0 when the table has no such module).
pub fn pin(state: *ScopeState, id: u32, module_id: []const u8) Error!u32 {
    const context = contextFor(state, id) catch |err| return errno.narrow(err);
    var session: Scope.Session = undefined;
    session.init(context.scope);
    defer session.deinit();
    return context.scope.module_map.pin(module_id) catch |err| return errno.narrow(err);
}

/// `unpin(context, serial)`: drops one pin; a module nothing else holds is freed.
pub fn unpin(state: *ScopeState, id: u32, serial: u32) Error!void {
    const context = contextFor(state, id) catch |err| return errno.narrow(err);
    if (context.scope.disposed) return;
    var session: Scope.Session = undefined;
    session.init(context.scope);
    defer session.deinit();
    context.scope.module_map.unpin(serial);
}
