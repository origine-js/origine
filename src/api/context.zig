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
const sys = @import("../managed/sys.zig");
const eu = @import("@util");
const binding = @import("binding.zig");
const Call = binding.Call;
const errno = @import("errno.zig");
const graph_api = @import("graph.zig");
const fs_api = @import("fs.zig");
const Graph = graph_api.Graph;
const Handler = graph_api.Handler;
const StdFilter = graph_api.StdFilter;
const host_mod = @import("host.zig");
const Host = host_mod.Host;
const ScopeState = host_mod.ScopeState;
const init_loader = @import("init_loader.zig");
const internal = @import("internal.zig");
const glue = @import("glue.zig");
const init_cache = @import("init_cache.zig");
const json_module = @import("json_module.zig");
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
    errno.requireBinding(cacheSize);
    errno.requireBinding(cacheDelete);
    errno.requireBinding(cacheClear);
    errno.requireBinding(flush);
    errno.requireBinding(cachePut);
    errno.requireBinding(pin);
    errno.requireBinding(unpin);
    errno.requireBinding(namespaceOf);
}

/// What a resolved id was resolved for; the load stage needs it.
const Info = struct { handler: u32, specifier: []u8, referrer: []u8 };

/// One element of a handler's pipeline that is not run inline. The first six are JS functions the
/// driver's `step(kind, ...)` (src/js/glue/graph.js) runs, the numbers being the `kind` it receives;
/// `open` and `read` are the two native calls of an async fs read (no user JS runs for them).
const Step = enum(u32) { layer = 0, hook = 1, maker = 2, transform = 3, meta = 4, cacheload = 5, open = 6, read = 7 };

/// A call into the JS driver whose promise has not settled: which element runs and what the chain
/// needs to go on once it answers. A chain keeps its token across steps; only the end completes it.
pub const PendingJs = struct {
    host: *Host,
    /// Null once the context was freed while the call was in flight: the callbacks then only free it.
    context: ?*Context,
    /// The request the chain serves: a resolution for `layer`, a load for every other step.
    token: module_types.LoadToken,
    namespace: u32 = 0,
    referrer_namespace: u32 = 0,
    step: Step,
    /// The layer or hook index, or the index of the transformer function.
    index: u32 = 0,
    /// The handler whose element runs (for `meta`: the handler of the module made).
    handler: u32,
    /// The handler the made module's own imports use, once the maker answered.
    import: u32 = 0,
    id: []u8 = &.{},
    attributes: []module_types.ImportAttribute = &.{},
    specifier: []u8 = &.{},
    referrer: []u8 = &.{},
    /// The source waiting for its `meta` or its code cache (owned).
    text: []u8 = &.{},
    /// An async read: the file once opened, and whether it is a JSON module.
    file: u32 = 0,
    json: bool = false,
    /// The async grant that file is read through.
    grant: u32 = 0,
    settled: bool = false,
    /// A completion callback ran (its sibling never will): nothing refers to it any more.
    fired: bool = false,
};

/// What a chain works on. Borrowed.
const Work = struct {
    handler: u32,
    token: module_types.LoadToken,
    /// The table the module `id` lives in (the `ImportCache` of the handler that resolved it).
    namespace: u32,
    /// The table the importer lives in, for a resolution.
    referrer_namespace: u32 = 0,
    id: []const u8,
    specifier: []const u8,
    referrer: []const u8,
    attributes: []const module_types.ImportAttribute,
};

fn workOf(pending: *const PendingJs) Work {
    return .{ .handler = pending.handler, .token = pending.token, .namespace = pending.namespace, .referrer_namespace = pending.referrer_namespace, .id = pending.id, .specifier = pending.specifier, .referrer = pending.referrer, .attributes = pending.attributes };
}

/// A module this context linked from the context that is its home, instead of loading its own.
const SharedFrom = struct {
    home: u32,
    /// The pin it holds in the home's table, so a `used` table there keeps the module while this one uses it.
    serial: u32,
    namespace: u32,
    id: []u8,
    attributes: []module_types.ImportAttribute,
};

/// A load parked until the home of the module it asked for has evaluated it.
const ShareWait = struct {
    token: module_types.LoadToken,
    namespace: u32,
    id: []u8,
    attributes: []module_types.ImportAttribute,
};

fn dupeAttributes(alloc: std.mem.Allocator, attributes: []const module_types.ImportAttribute) ![]module_types.ImportAttribute {
    const out = try alloc.alloc(module_types.ImportAttribute, attributes.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |item| {
            alloc.free(item.key);
            alloc.free(item.value);
        }
        alloc.free(out);
    }
    for (attributes, out) |item, *slot| {
        const key = try alloc.dupe(u8, item.key);
        errdefer alloc.free(key);
        slot.* = .{ .key = key, .value = try alloc.dupe(u8, item.value) };
        done += 1;
    }
    return out;
}

fn freeAttributes(alloc: std.mem.Allocator, attributes: []module_types.ImportAttribute) void {
    for (attributes) |item| {
        alloc.free(item.key);
        alloc.free(item.value);
    }
    alloc.free(attributes);
}

fn sameAttributes(a: []const module_types.ImportAttribute, b: []const module_types.ImportAttribute) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x.key, y.key) or !std.mem.eql(u8, x.value, y.value)) return false;
    return true;
}

/// Where a module another context could hold stands.
const Home = union(enum) {
    none,
    loading,
    failed,
    ready: struct { home: *Context, module: v8.Global.Of(v8.Module) },
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
    /// Module id -> the code cache that keeps its compiled code. Keys are owned.
    code_cache_of: std.StringHashMapUnmanaged(u32) = .empty,
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
    /// Modules of other contexts this one uses, by `ModuleMap.keyOf`. Keys are owned.
    shared_from: std.StringHashMapUnmanaged(SharedFrom) = .empty,
    share_waits: std.ArrayList(ShareWait) = .empty,

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

    fn waitsFor(self: *const Context, key: module_types.ModuleMapKey) bool {
        for (self.share_waits.items) |wait| {
            if (wait.namespace == key.namespace and std.mem.eql(u8, wait.id, key.module_id) and sameAttributes(wait.attributes, key.import_attributes)) return true;
        }
        return false;
    }

    /// The context among the others of this realm that holds the module `key` as its own: the first to have
    /// imported it (lowest id). A context that is itself waiting for it does not count.
    fn findHome(self: *Context, key: module_types.ModuleMapKey) Home {
        var found: Home = .none;
        var best: u32 = std.math.maxInt(u32);
        for (self.host.contexts.values()) |other| {
            if (other == self or other.closed or other.creator != self.creator or other.id >= best) continue;
            if (other.waitsFor(key)) continue;
            switch (other.scope.module_map.shareable(key)) {
                .none => {},
                .loading => {
                    best = other.id;
                    found = .loading;
                },
                // A failed module is not shared: this context tries for itself.
                .failed => {},
                .ready => |module| {
                    if (found == .ready) found.ready.module.deinit();
                    best = other.id;
                    found = .{ .ready = .{ .home = other, .module = module } };
                },
            }
        }
        return found;
    }

    /// Uses the module `key` of `home`: pins it there and remembers where it came from. The handle is kept until the
    /// next bridge call, because the map copies a linked module only once it finishes compiling (see `link`).
    fn adopt(self: *Context, home: *Context, module: v8.Global.Of(v8.Module), key: module_types.ModuleMapKey) !v8.Module {
        const alloc = self.host.allocator;
        try self.link_modules.append(alloc, module);
        const serial = try home.scope.module_map.pinKey(key);
        const table_key = try module_map.ModuleMap.keyOf(alloc, key);
        errdefer alloc.free(table_key);
        const slot = try self.shared_from.getOrPut(alloc, table_key);
        if (slot.found_existing) {
            alloc.free(table_key);
            home.scope.module_map.unpin(serial);
        } else {
            const id = try alloc.dupe(u8, key.module_id);
            errdefer alloc.free(id);
            slot.value_ptr.* = .{ .home = home.id, .serial = serial, .namespace = key.namespace, .id = id, .attributes = try dupeAttributes(alloc, key.import_attributes) };
        }
        return module.deref();
    }

    /// Forgets what this context used from `home`, which is closing: the next import of those modules makes
    /// a module of its own here (and so does everything that imported them).
    fn dropFrom(self: *Context, home: u32) void {
        const alloc = self.host.allocator;
        var keys: std.ArrayList(module_types.ModuleMapKey) = .empty;
        defer keys.deinit(alloc);
        var it = self.shared_from.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.home != home) continue;
            keys.append(alloc, .{ .module_id = entry.value_ptr.id, .import_attributes = entry.value_ptr.attributes, .namespace = entry.value_ptr.namespace }) catch return;
        }
        if (keys.items.len == 0) return;
        _ = self.scope.module_map.dropShared(keys.items) catch {};
        for (keys.items) |key| {
            const table_key = module_map.ModuleMap.keyOf(alloc, key) catch continue;
            defer alloc.free(table_key);
            if (self.shared_from.fetchRemove(table_key)) |removed| {
                alloc.free(removed.key);
                alloc.free(removed.value.id);
                freeAttributes(alloc, removed.value.attributes);
            }
        }
    }

    fn cacheOfHandler(self: *Context, handler: u32) u32 {
        return tableOfHandler(self.host, handler);
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
        var shared = self.shared_from.iterator();
        while (shared.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.id);
            freeAttributes(alloc, entry.value_ptr.attributes);
        }
        self.shared_from.deinit(alloc);
        for (self.share_waits.items) |wait| {
            alloc.free(wait.id);
            freeAttributes(alloc, wait.attributes);
        }
        self.share_waits.deinit(alloc);
        self.link_values.deinit(alloc);
        self.link_modules.deinit(alloc);
        var it = self.handler_of.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        self.handler_of.deinit(alloc);
        var caches = self.code_cache_of.keyIterator();
        while (caches.next()) |key| alloc.free(key.*);
        self.code_cache_of.deinit(alloc);
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
        // A call whose promise has not settled still has callbacks in the creating realm that point at
        // its record: hand it to the host, which frees it when one of them runs.
        for (self.pendings.items) |pending| {
            if (pending.fired) {
                freePending(alloc, pending);
                continue;
            }
            pending.context = null;
            self.host.orphans.append(alloc, pending) catch {};
        }
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

    /// `namespace` and `id` as one map key (storage from `alloc`): the same id in two tables is two modules.
    fn tableKey(alloc: std.mem.Allocator, namespace: u32, id: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "{d}\x00{s}", .{ namespace, id });
    }

    fn handlerOf(self: *Context, scratch: std.mem.Allocator, namespace: u32, id: []const u8) ?u32 {
        const key = tableKey(scratch, namespace, id) catch return null;
        return self.handler_of.get(key);
    }

    fn setHandler(self: *Context, namespace: u32, id: []const u8, handler: u32) !void {
        const alloc = self.host.allocator;
        var buffer: [256]u8 = undefined;
        var fallback = std.heap.FixedBufferAllocator.init(&buffer);
        const probe = tableKey(fallback.allocator(), namespace, id) catch try tableKey(alloc, namespace, id);
        defer if (probe.ptr != &buffer) alloc.free(probe);
        const slot = try self.handler_of.getOrPut(alloc, probe);
        if (!slot.found_existing) slot.key_ptr.* = try alloc.dupe(u8, probe);
        slot.value_ptr.* = handler;
    }

    /// The code cache the module `id` is compiled with (0: none).
    fn setCodeCache(self: *Context, id: []const u8, store: u32) !void {
        const alloc = self.host.allocator;
        const slot = try self.code_cache_of.getOrPut(alloc, id);
        if (!slot.found_existing) {
            slot.key_ptr.* = alloc.dupe(u8, id) catch |err| {
                _ = self.code_cache_of.remove(id);
                return err;
            };
        }
        slot.value_ptr.* = store;
    }

    fn setMeta(self: *Context, namespace: u32, id: []const u8, json: []const u8) !void {
        const alloc = self.host.allocator;
        const text = try alloc.dupe(u8, json);
        errdefer alloc.free(text);
        const key = try tableKey(alloc, namespace, id);
        errdefer alloc.free(key);
        const slot = try self.meta.getOrPut(alloc, key);
        if (slot.found_existing) {
            alloc.free(slot.value_ptr.*);
            alloc.free(key);
        } else slot.key_ptr.* = key;
        slot.value_ptr.* = text;
    }

    pub fn markServed(self: *Context, id: []const u8) !void {
        if (self.served.contains(id)) return;
        try self.putOwned(&self.served, id, {});
    }

    /// `id` and the attributes joined into one map key (borrowed storage from `alloc`).
    fn infoKey(alloc: std.mem.Allocator, namespace: u32, id: []const u8, attributes: []const module_types.ImportAttribute) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.print(alloc, "{d}\x00", .{namespace});
        try out.appendSlice(alloc, id);
        for (attributes) |attribute| {
            try out.append(alloc, 0);
            try out.appendSlice(alloc, attribute.key);
            try out.append(alloc, 1);
            try out.appendSlice(alloc, attribute.value);
        }
        return out.toOwnedSlice(alloc);
    }

    fn recordResolved(self: *Context, scratch: std.mem.Allocator, namespace: u32, id: []const u8, attributes: []const module_types.ImportAttribute, handler: u32, specifier: []const u8, referrer: []const u8) !void {
        const alloc = self.host.allocator;
        const key = try infoKey(scratch, namespace, id, attributes);
        if (self.resolved.contains(key)) return;
        const specifier_copy = try alloc.dupe(u8, specifier);
        errdefer alloc.free(specifier_copy);
        const referrer_copy = try alloc.dupe(u8, referrer);
        errdefer alloc.free(referrer_copy);
        try self.putOwned(&self.resolved, key, Info{ .handler = handler, .specifier = specifier_copy, .referrer = referrer_copy });
    }
};

pub fn freePending(alloc: std.mem.Allocator, pending: *PendingJs) void {
    alloc.free(pending.id);
    for (pending.attributes) |attribute| {
        alloc.free(attribute.key);
        alloc.free(attribute.value);
    }
    alloc.free(pending.attributes);
    alloc.free(pending.specifier);
    alloc.free(pending.referrer);
    alloc.free(pending.text);
    alloc.destroy(pending);
}

/// A completion callback of a call whose context is gone: nothing else refers to it.
fn freeOrphan(pending: *PendingJs) void {
    const host = pending.host;
    for (host.orphans.items, 0..) |item, index| if (item == pending) {
        _ = host.orphans.swapRemove(index);
        break;
    };
    freePending(host.allocator, pending);
}

fn contextFor(state: *ScopeState, id: u32) !*Context {
    const host = state.host;
    const found = host.contexts.get(id) orelse return if (host.contexts.issued(id)) error.StaleHandle else error.BadHandle;
    if (found.creator != state) return error.BadHandle;
    if (found.closed) return error.StaleHandle;
    return found;
}

// ---- the bridge: Resolver, Loader, meta and code cache of a context --------

fn resolveAsync(data: ?*anyopaque, request: module_types.ResolveRequest) anyerror!module_types.ResolveOutcome {
    const self: *Context = @ptrCast(@alignCast(data.?));
    self.releaseLinks();
    if (internal.requested(request.specifier)) {
        if (!self.served.contains(request.referrer) or !internal.trusted(self.host, request.referrer)) return error.PermissionDenied;
        try internal.prepare(self.host, request.scope_id, request.context);
        const handler = self.handlerOf(request.allocator, request.referrer_namespace, request.referrer) orelse self.import_handler;
        const namespace = self.cacheOfHandler(handler);
        try self.recordResolved(request.allocator, namespace, glue.handles_id, request.import_attributes, handler, request.specifier, request.referrer);
        return .{ .id = try request.allocator.dupe(u8, glue.handles_id) };
    }
    if (self.root) |name| if (request.referrer.len == 0 and std.mem.eql(u8, request.specifier, name)) return .{ .id = try request.allocator.dupe(u8, name) };
    const handler_id = self.handlerOf(request.allocator, request.referrer_namespace, request.referrer) orelse self.import_handler;
    const work: Work = .{ .handler = handler_id, .token = request.token, .namespace = self.cacheOfHandler(handler_id), .referrer_namespace = request.referrer_namespace, .id = "", .specifier = request.specifier, .referrer = request.referrer, .attributes = request.import_attributes };
    return switch (try advanceResolve(self, request.allocator, work, 0)) {
        .id => |id| .{ .id = id },
        .parked => .pending,
    };
}

/// The table the modules found through handler `handler` live in.
fn tableOfHandler(host: *Host, handler: u32) u32 {
    const found = host.handlers.get(handler) orelse return 0;
    return found.cache;
}

/// `Scope.Options.shared_released`: this context stopped using a module it linked from its home, so the home
/// may free it (under `retain: 'used'`).
fn sharedReleased(data: ?*anyopaque, key: []const u8) void {
    const self: *Context = @ptrCast(@alignCast(data.?));
    const removed = self.shared_from.fetchRemove(key) orelse return;
    const alloc = self.host.allocator;
    if (self.host.contexts.get(removed.value.home)) |home| {
        if (!home.closed) home.scope.module_map.unpin(removed.value.serial);
    }
    alloc.free(removed.key);
    alloc.free(removed.value.id);
    freeAttributes(alloc, removed.value.attributes);
}

/// `Resolver.namespace_of`: the imports of a module live in the table of the handler that governs them.
fn namespaceOfHook(data: ?*anyopaque, referrer_namespace: u32, referrer: module_types.ModuleId) u32 {
    const self: *Context = @ptrCast(@alignCast(data.?));
    var buffer: [512]u8 = undefined;
    var fallback = std.heap.FixedBufferAllocator.init(&buffer);
    const handler = self.handlerOf(fallback.allocator(), referrer_namespace, referrer) orelse self.import_handler;
    return tableOfHandler(self.host, handler);
}

/// `Scope.Options.table_policy`: what the table `namespace` (an `ImportCache`) does with its modules.
fn tablePolicy(data: ?*anyopaque, namespace: u32) Scope.Policy {
    const host: *Host = @ptrCast(@alignCast(data.?));
    const table = host.caches.get(namespace) orelse return .{};
    return .{ .retain = switch (table.retain) {
        .all => .all,
        .used => .used,
    } };
}

fn cancel(data: ?*anyopaque, token: module_types.LoadToken) void {
    const self: *Context = @ptrCast(@alignCast(data.?));
    var index: usize = 0;
    while (index < self.share_waits.items.len) {
        if (self.share_waits.items[index].token != token) {
            index += 1;
            continue;
        }
        const wait = self.share_waits.swapRemove(index);
        self.host.allocator.free(wait.id);
        freeAttributes(self.host.allocator, wait.attributes);
    }
    for (self.pendings.items) |pending| if (pending.token == token) {
        pending.settled = true;
    };
}

/// `Loader.poll`: completes the loads parked on another context's module that can go on now. Its home
/// evaluated the module (link it), failed (fail the load) or went away (this context becomes the home and loads
/// the module itself).
fn poll(data: ?*anyopaque) bool {
    const self: *Context = @ptrCast(@alignCast(data.?));
    if (self.share_waits.items.len == 0 or self.closed) return false;
    const alloc = self.host.allocator;
    const rt = self.scope.runtime;
    var progress = false;
    // Take the list: what still waits goes back at the end.
    var waits = self.share_waits;
    self.share_waits = .empty;
    defer waits.deinit(alloc);
    for (waits.items) |parked| {
        const wanted: module_types.ModuleMapKey = .{ .module_id = parked.id, .import_attributes = parked.attributes, .namespace = parked.namespace };
        const found = self.findHome(wanted);
        if (found == .loading) {
            self.share_waits.append(alloc, parked) catch {
                alloc.free(parked.id);
                freeAttributes(alloc, parked.attributes);
                rt.completeLoad(parked.token, .{ .failure = error.OutOfMemory }) catch {};
            };
            continue;
        }
        defer {
            alloc.free(parked.id);
            freeAttributes(alloc, parked.attributes);
        }
        progress = true;
        switch (found) {
            .loading => unreachable,
            .failed => unreachable,
            .ready => |home| {
                const module = self.adopt(home.home, home.module, wanted) catch |err| {
                    rt.completeLoad(parked.token, .{ .failure = err }) catch {};
                    continue;
                };
                rt.completeLoad(parked.token, .{ .content = .{ .module = module } }) catch {};
            },
            .none => {
                // The home is gone: load it here.
                var scratch = std.heap.ArenaAllocator.init(alloc);
                defer scratch.deinit();
                const key = Context.infoKey(scratch.allocator(), parked.namespace, parked.id, parked.attributes) catch continue;
                const info = self.resolved.get(key) orelse {
                    rt.completeLoad(parked.token, .{ .failure = error.NotFound }) catch {};
                    continue;
                };
                const work: Work = .{ .handler = info.handler, .token = parked.token, .namespace = parked.namespace, .id = parked.id, .specifier = info.specifier, .referrer = info.referrer, .attributes = parked.attributes };
                const outcome = advanceHooks(self, scratch.allocator(), work, 0) catch |err| {
                    rt.completeLoad(parked.token, .{ .failure = err }) catch {};
                    continue;
                };
                switch (outcome) {
                    .parked => {},
                    .done => |completion| rt.completeLoad(parked.token, completion) catch {},
                }
            },
        }
    }
    return progress;
}

fn load(data: ?*anyopaque, request: module_types.LoadRequest) anyerror!module_types.LoadResult {
    const self: *Context = @ptrCast(@alignCast(data.?));
    self.releaseLinks();
    const key = try Context.infoKey(request.allocator, request.namespace, request.module_id, request.import_attributes);
    const info = self.resolved.get(key) orelse return error.NotFound;
    if (internal.requested(request.module_id)) return error.NotFound;
    // A module the host did not write can be the one another context already has: contexts that use the same
    // `ImportCache` share its modules. The first to import an id is its home.
    if (!std.mem.startsWith(u8, request.module_id, module_types.origine_prefix)) {
        const wanted: module_types.ModuleMapKey = .{ .module_id = request.module_id, .import_attributes = request.import_attributes, .namespace = request.namespace };
        switch (self.findHome(wanted)) {
            .none => {},
            .failed => unreachable,
            .loading => {
                const alloc = self.host.allocator;
                const id = try alloc.dupe(u8, request.module_id);
                errdefer alloc.free(id);
                const attributes = try dupeAttributes(alloc, request.import_attributes);
                errdefer freeAttributes(alloc, attributes);
                try self.share_waits.append(alloc, .{ .token = request.token, .namespace = request.namespace, .id = id, .attributes = attributes });
                return .pending;
            },
            .ready => |found| return .{ .module = try self.adopt(found.home, found.module, wanted) },
        }
    }
    const work: Work = .{ .handler = info.handler, .token = request.token, .namespace = request.namespace, .id = request.module_id, .specifier = info.specifier, .referrer = info.referrer, .attributes = request.import_attributes };
    switch (try advanceHooks(self, request.allocator, work, 0)) {
        .parked => return .pending,
        .done => |completion| return switch (completion) {
            .content => |content| switch (content) {
                .source => |text| .{ .source = text },
                .external => |external| .{ .external = external },
                .exports => |exports| .{ .exports = exports },
                .module => |module| .{ .module = module },
            },
            .syntax_error => |text| .{ .exception = transformer_api.syntaxError(text) },
            else => error.InvalidData,
        },
    }
}

// ---- the chain: native elements run here, JS elements park the request ------
//
// A handler's resolver layers, hooks, maker and transformer run in order. A host element runs
// right here, whatever the elements around it are. A JS element parks the request (`park`): the
// driver runs just that function in the creating realm, and when its promise settles the chain goes
// on from the next element (`fulfilled`), with the same token, until it completes the request.

const ResolveAdvance = union(enum) { id: []const u8, parked };
const LoadAdvance = union(enum) { done: module_types.Completion, parked };

/// Runs the resolver layers of `work.handler` from index `from`. The id is allocated from `scratch`.
fn advanceResolve(self: *Context, scratch: std.mem.Allocator, work: Work, from: usize) !ResolveAdvance {
    const h = try graph_api.handlerFor(self.host, work.handler);
    var index = from;
    while (index < h.layers.len) : (index += 1) {
        if (h.layers[index] == .js) {
            try park(self, .layer, work, index, 0, "");
            return .parked;
        }
        if (try graph_api.layerStep(h, index, scratch, work.specifier, work.referrer)) |id| {
            try self.recordResolved(scratch, work.namespace, id, work.attributes, work.handler, work.specifier, work.referrer);
            return .{ .id = id };
        }
    }
    return error.NotFound;
}

/// Runs the hooks of `work.handler` from index `from` until one supplies the source, then the maker.
fn advanceHooks(self: *Context, scratch: std.mem.Allocator, work: Work, from: usize) !LoadAdvance {
    const h = try graph_api.handlerFor(self.host, work.handler);
    var index = from;
    while (index < h.hooks.len) : (index += 1) {
        if (h.hooks[index] == .js) {
            try park(self, .hook, work, index, 0, "");
            return .parked;
        }
        var served = false;
        switch (try graph_api.hookStep(h, index, .{ .host = self.host, .alloc = scratch, .served = &served }, work.id, work.attributes)) {
            .next => {},
            .source => |text| {
                if (served) try self.markServed(work.id);
                return supplied(self, scratch, work, text);
            },
            .mapped => |mapped| return suppliedMapped(self, scratch, work, mapped),
            .read => |read| {
                try startRead(self, work, read.json, read.grant, if (read.skip_missing) @intCast(index) else no_skip);
                return .parked;
            },
        }
    }
    return error.NotFound;
}

/// A hook's `read: 'mmap'`: the chain runs on the mapped bytes, and when they come out as the module's final
/// text V8 gets them in place, as an external string that owns the map. Anything that made other text
/// (a transformer) or keeps its own copy (a step in JS) is done with the map by the time this returns.
fn suppliedMapped(self: *Context, scratch: std.mem.Allocator, work: Work, mapped: sys.File.MemoryMap) !LoadAdvance {
    var map = mapped;
    const advance = supplied(self, scratch, work, map.memory) catch |err| {
        map.destroy();
        return err;
    };
    const final = advance == .done and advance.done == .content and advance.done.content == .source and advance.done.content.source.ptr == map.memory.ptr;
    if (!final) {
        map.destroy();
        return advance;
    }
    // A snapshot cannot hold an external string.
    const rt = self.scope.runtime;
    if (rt.in_creator) return .{ .done = .{ .content = .{ .source = try graph_api.copyMapped(&map, scratch) } } };
    const string = v8.String.newExternalOneByte(rt.isolate, map.memory.ptr, @intCast(map.memory.len), releaseMapped) orelse {
        map.destroy();
        return error.OutOfMemory;
    };
    self.host.mapped_sources += 1;
    return .{ .done = .{ .content = .{ .external = .{ .text = map.memory, .string = string } } } };
}

/// The finalizer of an external string made from a map.
fn releaseMapped(data: [*c]u8, length: usize) callconv(.c) void {
    var map: sys.File.MemoryMap = .{ .memory = @alignCast(data[0..length]), .mapped = true };
    map.destroy();
}

/// The source of `work.id` is known: the maker decides which recipe options apply. The host's own
/// modules skip it: they reach the context as the host wrote them.
fn supplied(self: *Context, scratch: std.mem.Allocator, work: Work, text: []const u8) !LoadAdvance {
    if (std.mem.startsWith(u8, work.id, module_types.origine_prefix)) {
        try self.setHandler(work.namespace, work.id, work.handler);
        return .{ .done = .{ .content = .{ .source = text } } };
    }
    const h = try graph_api.handlerFor(self.host, work.handler);
    switch (h.maker) {
        .js => {
            try park(self, .maker, work, 0, 0, text);
            return .parked;
        },
        .inherit => |inherit| {
            const import = if (inherit.import != 0) inherit.import else work.handler;
            const spec = inherit.transformer orelse return made(self, scratch, work, text, import, null);
            const leaf = spec.leaf(work.id) orelse return made(self, scratch, work, text, import, null);
            switch (leaf.*) {
                .js => |index| {
                    try park(self, .transform, work, index, import, text);
                    return .parked;
                },
                else => switch (try leaf.apply(scratch, work.id, text)) {
                    .source => |out| return made(self, scratch, work, out, import, null),
                    .diagnostics => |diagnostics| return .{ .done = .{ .syntax_error = diagnostics } },
                },
            }
        },
    }
}

/// The module is made: remember which handler answers its imports, then ask for its `import.meta`.
fn made(self: *Context, scratch: std.mem.Allocator, work: Work, text: []const u8, import: u32, code_cache: ?u32) !LoadAdvance {
    _ = scratch;
    try self.setHandler(work.namespace, work.id, import);
    // The recipe's cache wins over the default of the handler that made the module.
    const store = if (code_cache) |chosen| (if (chosen == graph_api.no_code_cache) 0 else chosen) else (try graph_api.handlerFor(self.host, work.handler)).code_cache;
    try self.setCodeCache(work.id, store);
    const h = try graph_api.handlerFor(self.host, import);
    if (h.meta) {
        var meta_work = work;
        meta_work.handler = import;
        try park(self, .meta, meta_work, 0, import, text);
        return .parked;
    }
    return finish(self, work, text);
}

/// The source V8 will compile is final: a `custom` code cache gets to load what it kept for this exact
/// text (its answer lands in the graph, where the compile finds it), then the load completes.
fn finish(self: *Context, work: Work, text: []const u8) !LoadAdvance {
    if (!std.mem.startsWith(u8, work.id, module_types.origine_prefix)) {
        if (graph_api.codeCacheFor(self.host, self.code_cache_of.get(work.id) orelse 0)) |store| if (store.kind == .custom) {
            try park(self, .cacheload, work, 0, 0, text);
            return .parked;
        };
    }
    return .{ .done = .{ .content = .{ .source = text } } };
}

/// Calls the creating realm's JS driver for one element and parks the request on its promise.
/// `text` is the source a maker or transformer gets (and the one a `meta` step keeps). An exception
/// the call throws becomes the failure of the request.
fn park(self: *Context, step: Step, work: Work, index: usize, import: u32, text: []const u8) !void {
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
    for (work.attributes) |attribute| {
        _ = bag.createDataProperty(parent_ctx, eu.v.str_utf8(isolate, attribute.key).name, binding.string(isolate, attribute.value)) orelse return error.LoaderFailed;
    }
    const function = driver.step.deref();
    const undef = eu.v.undefined_value(isolate).value;
    const kind = numValue(isolate, @backingInt(step));
    const result = switch (step) {
        .layer => function.call(parent_ctx, undef, &.{ kind, numValue(isolate, work.handler), numValue(isolate, self.id), numValue(isolate, index), binding.string(isolate, work.specifier), binding.string(isolate, work.referrer), bag.value }),
        .hook => function.call(parent_ctx, undef, &.{ kind, numValue(isolate, work.handler), numValue(isolate, self.id), numValue(isolate, index), binding.string(isolate, work.id), bag.value, binding.string(isolate, work.specifier), binding.string(isolate, work.referrer) }),
        .maker => function.call(parent_ctx, undef, &.{ kind, numValue(isolate, work.handler), numValue(isolate, self.id), binding.string(isolate, work.id), binding.string(isolate, text) }),
        .transform => function.call(parent_ctx, undef, &.{ kind, numValue(isolate, work.handler), numValue(isolate, index), binding.string(isolate, work.id), binding.string(isolate, text) }),
        .meta => function.call(parent_ctx, undef, &.{ kind, numValue(isolate, work.handler), binding.string(isolate, work.id) }),
        .cacheload => blk: {
            const hex = std.fmt.bytesToHex(sourceHash(text), .lower);
            break :blk function.call(parent_ctx, undef, &.{ kind, numValue(isolate, self.code_cache_of.get(work.id) orelse 0), binding.string(isolate, work.id), binding.string(isolate, &hex), binding.string(isolate, text) });
        },
        .open, .read => unreachable,
    } orelse return failureOf(parent_ctx, isolate, &tc);
    try track(self, parent_ctx, isolate, result, step, work, index, import, text, 0, false, 0);
}

fn numValue(isolate: v8.Isolate, value: usize) v8.Value {
    return eu.v.num_u32(isolate, @intCast(value)).numeric.primitive.value;
}

/// Records the call whose answer is `result` (a promise, or a plain value finished through the same
/// path after the call returns) and chains the completion callbacks. Requires the creating realm's
/// context entered and a live HandleScope.
fn track(self: *Context, parent_ctx: v8.Context, isolate: v8.Isolate, result: v8.Value, step: Step, work: Work, index: usize, import: u32, text: []const u8, file: u32, json: bool, grant: u32) !void {
    const alloc = self.host.allocator;
    const pending = try alloc.create(PendingJs);
    errdefer alloc.destroy(pending);
    pending.* = .{ .host = self.host, .context = self, .token = work.token, .namespace = work.namespace, .referrer_namespace = work.referrer_namespace, .step = step, .index = @intCast(index), .handler = work.handler, .import = import, .file = file, .json = json, .grant = grant };
    pending.id = try alloc.dupe(u8, work.id);
    errdefer alloc.free(pending.id);
    pending.specifier = try alloc.dupe(u8, work.specifier);
    errdefer alloc.free(pending.specifier);
    pending.referrer = try alloc.dupe(u8, work.referrer);
    errdefer alloc.free(pending.referrer);
    if (step == .meta or step == .cacheload) pending.text = try alloc.dupe(u8, text);
    errdefer alloc.free(pending.text);
    const copied = try alloc.alloc(module_types.ImportAttribute, work.attributes.len);
    var done: usize = 0;
    errdefer {
        for (copied[0..done]) |attribute| {
            alloc.free(attribute.key);
            alloc.free(attribute.value);
        }
        alloc.free(copied);
    }
    for (work.attributes, copied) |attribute, *slot| {
        slot.* = .{ .key = try alloc.dupe(u8, attribute.key), .value = try alloc.dupe(u8, attribute.value) };
        done += 1;
    }
    pending.attributes = copied;
    try self.pendings.append(alloc, pending);
    errdefer _ = self.pendings.pop();
    const promise = if (result.isPromise()) v8.Promise.from_opaque(result.data.handle).? else v8.Promise.from_opaque(Promise.resolved(isolate, parent_ctx, result).data.handle).?;
    try chain(parent_ctx, isolate, promise, pending);
}

// ---- reading through an async fs grant ---------------------------------------
//
// The graph holds the Rust natives that read a file of the grant (open, read all, close); the chain
// calls them itself and parks on their promises, so the read runs on the grant's io runtime and no
// user JS is involved. `open` answers the file, `read` its bytes.

/// The `hook` of a read with nothing to pass to: a missing file is the import's failure.
const no_skip = std.math.maxInt(u32);

/// Starts reading the file `work.id` of the async grant `grant`, which a hook or an accepted import
/// named; `json` wraps it as a JSON module. A missing file goes on after the hook numbered `hook` (`missing: 'skip'`).
fn startRead(self: *Context, work: Work, json: bool, grant: u32, hook: u32) !void {
    const async_fs = self.graph.async_ops orelse return error.PermissionDenied;
    const creator = self.creator;
    if (creator.released) return error.ScopeDisposed;
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
    const undef = eu.v.undefined_value(isolate).value;
    // dir 0 is the grant's root, open bits 0 read only.
    const result = async_fs.open.deref().call(parent_ctx, undef, &.{ numValue(isolate, grant), numValue(isolate, 0), binding.string(isolate, work.id), numValue(isolate, 0) }) orelse return failureOf(parent_ctx, isolate, &tc);
    try track(self, parent_ctx, isolate, result, .open, work, hook, 0, "", 0, json, grant);
}

/// The file is open: asks for all of its bytes.
fn continueRead(self: *Context, work: Work, pending: *PendingJs, value: v8.Value, ctx: v8.Context) !void {
    const async_fs = self.graph.async_ops orelse return error.PermissionDenied;
    const grant = pending.grant;
    const file = value.u32Value(ctx) orelse return error.InvalidData;
    const creator = self.creator;
    if (creator.released) return error.ScopeDisposed;
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
    const undef = eu.v.undefined_value(isolate).value;
    // The whole file: the program that named the grant checks sizes.
    const limit = eu.v.num_f64(isolate, 9007199254740991).numeric.primitive.value;
    const result = async_fs.read_all.deref().call(parent_ctx, undef, &.{ numValue(isolate, grant), numValue(isolate, file), limit }) orelse {
        closeFile(self, grant, file);
        return failureOf(parent_ctx, isolate, &tc);
    };
    track(self, parent_ctx, isolate, result, .read, work, 0, 0, "", file, pending.json, grant) catch |err| {
        closeFile(self, grant, file);
        return err;
    };
}

/// Closes a file the chain opened; the answer is of no interest.
fn closeFile(self: *Context, grant: u32, file: u32) void {
    const async_fs = self.graph.async_ops orelse return;
    const creator = self.creator;
    if (creator.released) return;
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
    const undef = eu.v.undefined_value(isolate).value;
    const result = async_fs.close.deref().call(parent_ctx, undef, &.{ numValue(isolate, grant), numValue(isolate, file) }) orelse return;
    // A failed close would be an unhandled rejection; swallow it with a handler that does nothing.
    if (result.isPromise()) {
        const promise = v8.Promise.from_opaque(result.data.handle).?;
        const nothing = v8.Function.init(parent_ctx, ignore, null, 1, .Throw, .HasSideEffect);
        _ = promise.then2(parent_ctx, nothing, nothing);
    }
}

fn ignore(info: v8.FunctionCallbackInfo) callconv(.c) void {
    _ = info;
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
    if (std.mem.eql(u8, bytes, "NotADirectory")) return error.NotADirectory;
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
    pending.fired = true;
    const self = pending.context orelse return freeOrphan(pending);
    if (pending.settled or self.closed) return;
    pending.settled = true;
    defer retire(self, pending);
    const isolate = info.isolate();
    const ctx = isolate.getCurrentContext();
    const rt = self.scope.runtime;
    var scratch = std.heap.ArenaAllocator.init(self.host.allocator);
    defer scratch.deinit();
    resume_(self, scratch.allocator(), ctx, isolate, pending, info.get_arg(0)) catch |err| {
        if (pending.step == .layer) rt.completeResolve(pending.token, .{ .failure = err }) catch {} else rt.completeLoad(pending.token, .{ .failure = err }) catch {};
    };
}

/// The answer of the element `pending` ran: goes on with the chain, which parks again or completes.
fn resume_(self: *Context, alloc: std.mem.Allocator, ctx: v8.Context, isolate: v8.Isolate, pending: *PendingJs, value: v8.Value) !void {
    const rt = self.scope.runtime;
    const work = workOf(pending);
    if (pending.step == .layer) {
        if (value.isUndefined() or value.isNull()) {
            switch (try advanceResolve(self, alloc, work, pending.index + 1)) {
                .id => |id| try rt.completeResolve(pending.token, .{ .id = id }),
                .parked => {},
            }
            return;
        }
        const id = try idOf(ctx, isolate, alloc, value);
        try self.recordResolved(alloc, work.namespace, id, work.attributes, work.handler, work.specifier, work.referrer);
        try rt.completeResolve(pending.token, .{ .id = id });
        return;
    }
    if (pending.step == .open) {
        try continueRead(self, work, pending, value, ctx);
        return;
    }
    const advance: LoadAdvance = switch (pending.step) {
        .layer, .open => unreachable,
        .read => blk: {
            // The bytes of the file; the grant's file is closed whatever happens next.
            defer closeFile(self, pending.grant, pending.file);
            const bytes = binding.viewBytes(value) orelse return error.InvalidData;
            const text = try alloc.dupe(u8, bytes);
            const source = if (pending.json) try json_module.wrap(alloc, text) else text;
            break :blk try supplied(self, alloc, work, source);
        },
        .hook => try resumeHook(self, alloc, ctx, isolate, pending, work, value),
        .maker => blk: {
            const object = value.toObject(ctx) orelse return error.InvalidData;
            const text = (try stringOf(ctx, isolate, alloc, object, "text")) orelse return error.InvalidData;
            const handler = numberOf(ctx, isolate, object, "handler") orelse return error.InvalidData;
            break :blk try made(self, alloc, work, text, handler, null);
        },
        .transform => blk: {
            if (!value.isString()) return error.InvalidData;
            const text = try stringValue(ctx, isolate, alloc, value);
            break :blk try made(self, alloc, work, text, pending.import, null);
        },
        .meta => blk: {
            if (value.isString()) try self.setMeta(work.namespace, work.id, try stringValue(ctx, isolate, alloc, value));
            break :blk try finish(self, work, pending.text);
        },
        .cacheload => .{ .done = .{ .content = .{ .source = pending.text } } },
    };
    switch (advance) {
        .done => |completion| try rt.completeLoad(pending.token, completion),
        .parked => {},
    }
}

/// What a JS hook answered: `{ kind: 'next' | 'accept' | 'provide' | 'final' | 'link', ... }`. No JS
/// answer supplies an `origine:` id; the host's own provider is the only way to one.
fn resumeHook(self: *Context, alloc: std.mem.Allocator, ctx: v8.Context, isolate: v8.Isolate, pending: *PendingJs, work: Work, value: v8.Value) !LoadAdvance {
    const object = value.toObject(ctx) orelse return error.InvalidData;
    const kind = (try stringOf(ctx, isolate, alloc, object, "kind")) orelse return error.InvalidData;
    if (std.mem.eql(u8, kind, "next")) return advanceHooks(self, alloc, work, pending.index + 1);
    if (std.mem.startsWith(u8, work.id, module_types.origine_prefix)) return error.PermissionDenied;
    if (std.mem.eql(u8, kind, "accept")) {
        // The grant the hook named in `ImportHook.accept({ fs })`, checked again here: a sync one of the
        // creating realm that can read, or one of its async grants.
        const grant_id = numberOf(ctx, isolate, object, "fs") orelse return error.InvalidData;
        const is_async = (numberOf(ctx, isolate, object, "fsAsync") orelse 0) != 0;
        switch (try graph_api.resolveSource(self.creator, .{ .named = .{ .is_async = is_async, .id = grant_id } })) {
            .async => |id| {
                try startRead(self, work, false, id, no_skip);
                return .parked;
            },
            .sync => |grant| {
                const text = try graph_api.acceptStep(.{ .host = self.host, .alloc = alloc }, grant, work.id);
                return supplied(self, alloc, work, text);
            },
            .named => unreachable,
        }
    }
    if (std.mem.eql(u8, kind, "provide")) {
        const text = (try stringOf(ctx, isolate, alloc, object, "source")) orelse return error.InvalidData;
        return supplied(self, alloc, work, text);
    }
    if (std.mem.eql(u8, kind, "final")) {
        // A recipe: final, so the maker is skipped, and its own handler answers its imports.
        const text = (try stringOf(ctx, isolate, alloc, object, "source")) orelse return error.InvalidData;
        const handler = numberOf(ctx, isolate, object, "handler") orelse return error.InvalidData;
        return made(self, alloc, work, text, handler, numberOf(ctx, isolate, object, "codeCache"));
    }
    if (std.mem.eql(u8, kind, "exports")) {
        // A synthetic module of the values the hook handed over: neither copied nor frozen here.
        const given = object.get(ctx, binding.string(isolate, "exports")) orelse return error.InvalidData;
        if (!given.isObject()) return error.InvalidData;
        return .{ .done = .{ .content = try linkExports(self, ctx, isolate, given.toObject(ctx).?, alloc) } };
    }
    if (std.mem.eql(u8, kind, "link")) {
        const other_id = numberOf(ctx, isolate, object, "context") orelse return error.InvalidData;
        const name = (try stringOf(ctx, isolate, alloc, object, "name")) orelse return error.InvalidData;
        return .{ .done = .{ .content = try link(self, other_id, name) } };
    }
    return error.InvalidData;
}

fn rejected(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = binding.externalPointer(PendingJs, info);
    pending.fired = true;
    const self = pending.context orelse return freeOrphan(pending);
    if (pending.settled or self.closed) return;
    pending.settled = true;
    defer retire(self, pending);
    if (pending.step == .read) closeFile(self, pending.grant, pending.file);
    // A code cache that fails to load is a miss, not a reason to fail the import.
    if (pending.step == .cacheload) {
        self.scope.runtime.completeLoad(pending.token, .{ .content = .{ .source = pending.text } }) catch {};
        return;
    }
    const isolate = info.isolate();
    const ctx = isolate.getCurrentContext();
    var scratch = std.heap.ArenaAllocator.init(self.host.allocator);
    defer scratch.deinit();
    const alloc = scratch.allocator();
    const rt = self.scope.runtime;
    // An ImportError code keeps its kind; anything else reaches the module as an `Error` with its message.
    const known = errorOf(ctx, isolate, info.get_arg(0));
    // `missing: 'skip'`: the file is not in this provider's root, so the next hook gets its turn.
    if (pending.step == .open and pending.index != no_skip and graph_api.absent(known)) {
        const advance = advanceHooks(self, alloc, workOf(pending), pending.index + 1) catch |err| {
            rt.completeLoad(pending.token, .{ .failure = err }) catch {};
            return;
        };
        switch (advance) {
            .done => |completion| rt.completeLoad(pending.token, completion) catch {},
            .parked => {},
        }
        return;
    }
    if (known != error.ImportRejected) {
        if (pending.step == .layer) rt.completeResolve(pending.token, .{ .failure = known }) catch {} else rt.completeLoad(pending.token, .{ .failure = known }) catch {};
        return;
    }
    const text = messageOf(ctx, isolate, alloc, info.get_arg(0)) catch "import rejected";
    if (pending.step == .layer) rt.completeResolve(pending.token, .{ .message = text }) catch {} else rt.completeLoad(pending.token, .{ .message = text }) catch {};
}

/// `name: message` of a thrown value, for a failure that is not one of the closed ImportError kinds.
fn messageOf(ctx: v8.Context, isolate: v8.Isolate, alloc: std.mem.Allocator, value: v8.Value) ![]const u8 {
    const object = value.toObject(ctx) orelse return "import rejected";
    const message = (try stringOf(ctx, isolate, alloc, object, "message")) orelse "";
    const name = (try stringOf(ctx, isolate, alloc, object, "name")) orelse "Error";
    return std.fmt.allocPrint(alloc, "{s}: {s}", .{ name, message });
}

fn stringValue(ctx: v8.Context, isolate: v8.Isolate, alloc: std.mem.Allocator, value: v8.Value) ![]u8 {
    const text = value.toString(ctx) orelse return error.InvalidData;
    const buffer = try alloc.alloc(u8, text.lenUtf8(isolate));
    return buffer[0..text.writeUtf8(isolate, buffer)];
}

/// A resolver reply: the id string, or an object with a string `id`.
fn idOf(ctx: v8.Context, isolate: v8.Isolate, alloc: std.mem.Allocator, value: v8.Value) ![]u8 {
    if (value.isString()) return stringValue(ctx, isolate, alloc, value);
    const object = value.toObject(ctx) orelse return error.InvalidData;
    return (try stringOf(ctx, isolate, alloc, object, "id")) orelse error.InvalidData;
}

/// The content that makes the module `name` of context `other_id` available to `self` as it is: the
/// module itself (live bindings, the other realm's objects; an alias in the same context). Nothing is
/// copied or frozen. Handles stay in `self.link_*` until the next bridge call.
fn link(self: *Context, other_id: u32, name: []const u8) !module_types.Content {
    const host = self.host;
    const other = host.contexts.get(other_id) orelse return error.BadHandle;
    if (other.closed or other.creator != self.creator) return error.BadHandle;
    const held = (try other.scope.module_map.getAny(name)) orelse return error.NotFound;
    errdefer held.deinit();
    try self.link_modules.append(host.allocator, held);
    const module = held.deref();
    // Only an evaluated module can be linked into another context: V8 aborts on the namespace of one
    // that is not instantiated, and a module that is not yet instantiated would be instantiated by
    // the importer, in the wrong context.
    if (module.getStatus() != 4) return error.InvalidInput;
    return .{ .module = module };
}

/// The exports of a synthetic module: the own enumerable properties of `exports_object`, which the
/// creating realm built (nothing is copied or frozen here). Handles stay in
/// `self.link_values` until the next bridge call. Requires the creating realm's `ctx` entered.
fn linkExports(self: *Context, ctx: v8.Context, isolate: v8.Isolate, exports_object: v8.Object, alloc: std.mem.Allocator) !module_types.Content {
    const names = exports_object.getOwnPropertyNames(ctx, .{ .OnlyEnumerable = true, .SkipSymbols = true }, .ConvertToString) orelse return error.InvalidData;
    const exports = try alloc.alloc(module_types.Export, names.len());
    var count: usize = 0;
    var index: u32 = 0;
    while (index < names.len()) : (index += 1) {
        const key = names.object.getIndex(ctx, index) orelse continue;
        if (!key.isString()) continue;
        const bytes = try stringValue(ctx, isolate, alloc, key);
        const value = exports_object.get(ctx, key) orelse return error.InvalidData;
        const retained: v8.Global.Of(v8.Value) = .new(isolate, value);
        try self.link_values.append(self.host.allocator, retained);
        exports[count] = .{ .name = bytes, .value = retained, .harden = false };
        count += 1;
    }
    return .{ .exports = exports[0..count] };
}

/// `namespaceOf(context, name)`: the namespace object of the evaluated module `name` of a context
/// this realm created, for the glue to read (a foreign object: never kept).
pub fn namespaceOf(state: *ScopeState, id: u32, name: []const u8) Error!v8.Value {
    return namespaceImpl(state, id, name) catch |err| return errno.narrow(err);
}

fn namespaceImpl(state: *ScopeState, id: u32, name: []const u8) !v8.Value {
    const context = try contextFor(state, id);
    const held = (try context.scope.module_map.getAny(name)) orelse return error.NotFound;
    defer held.deinit();
    const module = held.deref();
    // V8 aborts on the namespace of a module that is not instantiated; only an evaluated one is shared.
    if (module.getStatus() != 4) return error.InvalidInput;
    return module.getModuleNamespace() orelse error.InvalidData;
}

fn metaHook(data: ?*anyopaque, request: module_types.MetaRequest) void {
    const self: *Context = @ptrCast(@alignCast(data.?));
    var key_buffer: [512]u8 = undefined;
    var key_alloc = std.heap.FixedBufferAllocator.init(&key_buffer);
    if (Context.tableKey(key_alloc.allocator(), request.namespace, request.module_id)) |key| {
        if (self.meta.get(key)) |json| applyJson(self, request, json);
    } else |_| {}
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

fn storeOf(self: *Context, module_id: []const u8) ?*graph_api.CodeCacheStore {
    return graph_api.codeCacheFor(self.host, self.code_cache_of.get(module_id) orelse return null);
}

fn cacheKeeps(data: ?*anyopaque, module_id: []const u8) bool {
    const self: *Context = @ptrCast(@alignCast(data.?));
    if (std.mem.startsWith(u8, module_id, module_types.origine_prefix)) return false;
    return storeOf(self, module_id) != null;
}

fn cacheLoad(data: ?*anyopaque, request: module_types.CodeCacheRequest) ?[]const u8 {
    const self: *Context = @ptrCast(@alignCast(data.?));
    if (std.mem.startsWith(u8, request.module_id, module_types.origine_prefix)) return null;
    const store = storeOf(self, request.module_id) orelse return null;
    if (store.lookup(request.allocator, request.module_id, sourceHash(request.source))) |bytes| {
        // The module map needs 8-aligned bytes that live in the request allocator.
        const copy = request.allocator.alignedAlloc(u8, .@"8", bytes.len) catch return null;
        @memcpy(copy, bytes);
        return copy;
    }
    if (store.dir_state) |*state| {
        const hook = state.hook();
        if (hook.load(hook.data, request)) |bytes| return bytes;
    }
    return null;
}

fn cacheStore(data: ?*anyopaque, request: module_types.CodeCacheRequest, bytes: []const u8) void {
    const self: *Context = @ptrCast(@alignCast(data.?));
    if (std.mem.startsWith(u8, request.module_id, module_types.origine_prefix)) return;
    const store = storeOf(self, request.module_id) orelse return;
    const hash = sourceHash(request.source);
    if (store.remember(request.module_id, hash, bytes)) store.stored += 1;
    switch (store.kind) {
        .memory => {},
        .dir => if (store.dir_state) |*state| {
            const hook = state.hook();
            hook.store(hook.data, request, bytes);
        },
        .custom => {
            // The blob a custom store keeps starts with the hash of the source the cache was made for,
            // so one returned for another text is recognised and ignored (V8 only compares lengths).
            const alloc = store.host.allocator;
            const id = alloc.dupe(u8, request.module_id) catch return;
            const copy = alloc.alloc(u8, hash.len + bytes.len) catch {
                alloc.free(id);
                return;
            };
            @memcpy(copy[0..hash.len], &hash);
            @memcpy(copy[hash.len..], bytes);
            store.fresh.append(alloc, .{ .id = id, .hash = hash, .bytes = copy }) catch {
                alloc.free(id);
                alloc.free(copy);
            };
        },
    }
}

/// Frees a context whose scope was freed. Records that callbacks can still reach outlive it: an
/// import in flight (its promise rejects as the scope's pending loads do) loses its context pointer, and
/// the calls into the JS driver whose promises are open are handed to the host (`Context.deinit`).
pub fn free(host: *Host, context: *Context) void {
    const alloc = host.allocator;
    for (host.imports.items) |pending| if (pending.context == context) {
        pending.context = null;
    };
    const graph = context.graph;
    host.contexts.remove(context.id);
    context.deinit();
    alloc.destroy(context);
    graph_api.releaseGraph(host, graph);
    graph_api.sweepHandlers(host);
}

// ---- natives ---------------------------------------------------------------

/// `create(importHandler, graph, codeGeneration)`: a realm whose imports run through `importHandler` with the
/// authority of `graph`; `codeGeneration` lets it compile strings (`eval`, `new Function`). Returns the context id.
pub fn create(state: *ScopeState, import_handler: u32, graph_id: u32, code_generation: bool) Error!u32 {
    return createImpl(state, import_handler, graph_id, code_generation) catch |err| return errno.narrow(err);
}

fn createImpl(state: *ScopeState, import_handler: u32, graph_id: u32, code_generation: bool) !u32 {
    const host = state.host;
    const alloc = host.allocator;
    const h = try graph_api.handlerFor(host, import_handler);
    const graph = try graph_api.graphFor(host, graph_id);
    if (!h.native and state.driver == null) return error.Unsupported;
    try host.contexts.map.ensureUnusedCapacity(alloc, 1);
    const context = try alloc.create(Context);
    errdefer alloc.destroy(context);
    context.* = .{
        .host = host,
        .id = try host.contexts.issue(),
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
        .code_generation = code_generation,
        .resolver = .{ .data = context, .resolve_async = resolveAsync, .cancel = cancel, .namespace_of = namespaceOfHook },
        .loader = .{ .data = context, .load = load, .poll = poll },
        .meta = .{ .data = context, .init = metaHook },
        .on_dispose = host.disposer(),
        .on_freed = host.freer(),
        .table_policy = .{ .data = host, .call = tablePolicy },
        .shared_released = .{ .data = context, .call = sharedReleased },
    };
    options.code_cache = .{ .data = context, .load = cacheLoad, .store = cacheStore, .keeps = cacheKeeps };
    const scope = try state.scope.runtime.createScope(options);
    errdefer state.scope.runtime.disposeScope(scope);
    context.scope = scope;
    _ = try host.attach(scope);
    host.contexts.put(alloc, context.id, context) catch unreachable;
    return context.id;
}

/// One import in flight: settled with the module's id (a string of the parent's realm) once it
/// has been evaluated, or rejected with a fresh `ModuleError`.
pub const ImportState = struct {
    host: *Host,
    /// Null once the context was freed: a callback that still runs (the scope's pending loads reject
    /// when it is freed) settles the promise and frees the record.
    context: ?*Context,
    creator: *ScopeState,
    resolver: v8.Global.Of(v8.Promise.Resolver),
    done: bool = false,
    /// What the import was for, as the caller named it (a specifier, or the module name of an
    /// evaluated source): the `subject` of the `ModuleError` it can reject with. Owned.
    subject: []const u8 = "",
};

/// The rejection value of a failed import or preload: `{ errno, name: 'ModuleError', message, subject, os }`,
/// which `glue/errors.js` turns into a `ModuleError`. `errno` is the one the child's error carries as an own
/// data property (a hook's `ImportHook.reject(ImportError.PermissionDenied)`), else `Unexpected`; nothing else of
/// the child's error crosses, only its text.
fn failureValue(env: binding.Env, child_ctx: v8.Context, reason: v8.Value, subject: []const u8) !v8.Value {
    const message = if (reason.toDetailString(child_ctx)) |text| text.name.primitive.value else binding.string(env.isolate, "module evaluation failed");
    // The module that failed, and the one that imported it, when the module map knows them; else what the call was for.
    const undef = eu.v.undefined_value(env.isolate).value;
    const asked = if (subject.len == 0) undef else binding.string(env.isolate, subject);
    return binding.encode(env, {}, .{
        .errno = causeErrno(env.isolate, child_ctx, reason),
        .name = "ModuleError",
        .message = message,
        .subject = stampOf(env.isolate, child_ctx, reason, module_map.failed_module_key) orelse asked,
        .os = @as(?u32, null),
        .referrer = stampOf(env.isolate, child_ctx, reason, module_map.failed_referrer_key) orelse undef,
    });
}

/// The string the module map stamped on a failure under `name`, if any.
fn stampOf(isolate: v8.Isolate, child_ctx: v8.Context, reason: v8.Value, comptime name: []const u8) ?v8.Value {
    if (!reason.isObject() or reason.isProxy()) return null;
    const object = reason.toObject(child_ctx) orelse return null;
    const value = object.getPrivate(child_ctx, v8.Private.forApi(isolate, v8.String.initUtf8(isolate, name))) orelse return null;
    return if (value.isString()) value else null;
}

/// The `errno` an error of the child realm stands for, else `Unexpected`: the own data property `errno` (a
/// hook's `ImportHook.reject(ImportError.PermissionDenied)`), or, for an error the module map made from a Zig error,
/// the own data property `message` read as the error's name (`FileNotFound` is `NotFound`). A proxy or an
/// accessor is not read: the child's code does not run for it.
fn causeErrno(isolate: v8.Isolate, child_ctx: v8.Context, reason: v8.Value) u32 {
    const fallback: u32 = @backingInt(errno.Errno.Unexpected);
    if (!reason.isObject() or reason.isProxy()) return fallback;
    const object = reason.toObject(child_ctx) orelse return fallback;
    if (ownData(isolate, child_ctx, object, "errno")) |value| {
        if (!value.isUint32()) return fallback;
        const code = value.u32Value(child_ctx) orelse return fallback;
        return if (code != 0 and std.enums.fromInt(errno.Errno, code) != null) code else fallback;
    }
    const text = ownData(isolate, child_ctx, object, "message") orelse return fallback;
    if (!text.isString()) return fallback;
    const string = text.toString(child_ctx) orelse return fallback;
    var buffer: [64]u8 = undefined;
    if (string.lenUtf8(isolate) > buffer.len) return fallback;
    const name = buffer[0..string.writeUtf8(isolate, &buffer)];
    const code = errno.ofName(name) orelse return fallback;
    return @backingInt(code);
}

/// The value of the own data property `key` of `object`, if it has one.
fn ownData(isolate: v8.Isolate, ctx: v8.Context, object: v8.Object, comptime key: []const u8) ?v8.Value {
    const descriptor = object.getOwnPropertyDescriptor(ctx, eu.v.str_utf8(isolate, key).name) orelse return null;
    if (!descriptor.isObject()) return null;
    return (descriptor.toObject(ctx) orelse return null).get(ctx, binding.string(isolate, "value"));
}

fn settleOk(pending: *ImportState, isolate: v8.Isolate, id: ?[]const u8) void {
    if (pending.done) return;
    pending.done = true;
    defer pending.resolver.deinit();
    const parent = pending.creator.scope.context.deref();
    const value = if (id) |text| binding.string(isolate, text) else eu.v.undefined_value(isolate).value;
    _ = pending.resolver.deref().resolve(parent, value);
}

fn settleFail(pending: *ImportState, isolate: v8.Isolate, reason: v8.Value, child_ctx: v8.Context) void {
    if (pending.done) return;
    pending.done = true;
    defer pending.resolver.deinit();
    const parent = pending.creator.scope.context.deref();
    const env: binding.Env = .{ .isolate = isolate, .ctx = parent };
    const failure = failureValue(env, child_ctx, reason, pending.subject) catch {
        _ = pending.resolver.deref().reject(parent, binding.string(isolate, "module evaluation failed"));
        return;
    };
    _ = pending.resolver.deref().reject(parent, failure);
}

/// Forgets a settled import and frees it: the promise settled once, so its other callback never runs.
fn freeImport(pending: *ImportState) void {
    const host = pending.host;
    for (host.imports.items, 0..) |item, index| if (item == pending) {
        _ = host.imports.swapRemove(index);
        break;
    };
    host.allocator.free(pending.subject);
    host.allocator.destroy(pending);
}

fn importFulfilled(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = binding.externalPointer(ImportState, info);
    const isolate = info.isolate();
    if (pending.context) |context| {
        settleOk(pending, isolate, context.scope.module_map.idOfNamespace(info.get_arg(0)));
    } else {
        settleFail(pending, isolate, binding.string(isolate, "the context was closed"), isolate.getCurrentContext());
    }
    freeImport(pending);
}

fn importRejected(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const pending = binding.externalPointer(ImportState, info);
    const isolate = info.isolate();
    settleFail(pending, isolate, info.get_arg(0), isolate.getCurrentContext());
    freeImport(pending);
}

fn startImport(call: *Call, state: *ScopeState, context: *Context, promise: v8.Global.Of(v8.Promise), subject: []const u8) !v8.Promise {
    defer promise.deinit();
    const host = state.host;
    const alloc = host.allocator;
    const resolver = eu.v.promise_resolver(call.ctx) orelse return error.Unexpected;
    const pending = try alloc.create(ImportState);
    errdefer alloc.destroy(pending);
    const owned_subject = try alloc.dupe(u8, subject);
    errdefer alloc.free(owned_subject);
    pending.* = .{ .host = host, .context = context, .creator = state, .resolver = .new(call.isolate, resolver), .subject = owned_subject };
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
    const promise = try context.scope.importIn(context.cacheOfHandler(context.import_handler), specifier, try attributesOf(call, attributes), null);
    return startImport(call, state, context, promise, specifier);
}

/// `evaluateSource(context, name, source, handler, metaJson)`: registers `source` as the module
/// `name` of the context (its own imports go through `handler`) and evaluates it. A parent-realm
/// promise of `name`. `name` must not be taken in this context's table.
pub fn evaluateSource(state: *ScopeState, call: *Call, id: u32, name: []const u8, source: []const u8, handler: u32, meta: []const u8, code_cache: u32) Error!v8.Promise {
    return evaluateImpl(state, call, id, name, source, handler, meta, code_cache) catch |err| return errno.narrow(err);
}

fn evaluateImpl(state: *ScopeState, call: *Call, id: u32, name: []const u8, source: []const u8, handler: u32, meta: []const u8, code_cache: u32) !v8.Promise {
    const context = try contextFor(state, id);
    const governing = try graph_api.handlerFor(state.host, handler);
    if (name.len == 0 or std.mem.startsWith(u8, name, module_types.origine_prefix)) return error.InvalidInput;
    // The module lives in the table of the handler that governs its imports.
    const table = context.cacheOfHandler(handler);
    if (try context.scope.module_map.get(.{ .module_id = name, .namespace = table }, null)) |existing| {
        existing.deinit();
        return error.InvalidInput;
    }
    // The handler is known before the source compiles: compiling resolves the module's imports through it.
    try context.setHandler(table, name, handler);
    // The recipe's cache (0: it names none) wins over the default of the handler that governs the module.
    try context.setCodeCache(name, if (code_cache == 0) governing.code_cache else if (code_cache == graph_api.no_code_cache) 0 else code_cache);
    if (meta.len != 0) try context.setMeta(table, name, meta);
    try context.scope.updateImportCache(.{ .module_id = name, .namespace = table }, .{ .source = source }, null);
    context.root = name;
    defer context.root = null;
    const promise = try context.scope.importIn(table, name, &.{}, null);
    return startImport(call, state, context, promise, name);
}

/// `close(context)`: disposes the realm. Its pending imports reject and its handles go stale.
pub fn close(state: *ScopeState, id: u32) Error!void {
    const context = contextFor(state, id) catch |err| return errno.narrow(err);
    closeContext(state.host, context);
}

pub fn closeContext(host: *Host, context: *Context) void {
    if (context.closed) return;
    context.closed = true;
    // The modules it is the home of are gone with it: whoever used them makes its own next time.
    for (host.contexts.values()) |other| {
        if (other != context and !other.closed) other.dropFrom(context.id);
    }
    for (host.contexts.values()) |other| {
        if (!other.closed and other.creator.scope == context.scope) closeContext(host, other);
    }
    context.scope.runtime.disposeScope(context.scope);
}

/// `cacheSize(cache)`: how many modules the table `cache` holds, in the contexts this realm created.
pub fn cacheSize(state: *ScopeState, cache: u32) Error!u32 {
    var count: usize = 0;
    for (state.host.contexts.values()) |context| {
        if (context.closed or context.creator != state) continue;
        count += context.scope.module_map.countNamespace(cache);
    }
    return @intCast(count);
}

/// `cacheDelete(cache, id)`: forgets the module `id` (and what imported it) in the table `cache` of every
/// context this realm created, so the next import of it makes a new one. Returns how many entries it dropped.
pub fn cacheDelete(state: *ScopeState, cache: u32, module_id: []const u8) Error!u32 {
    var count: usize = 0;
    for (state.host.contexts.values()) |context| {
        if (context.closed or context.creator != state) continue;
        count += context.scope.deleteImportCache(.{ .module_id = module_id, .namespace = cache }) catch |err| return errno.narrow(err);
    }
    return @intCast(count);
}

/// `cacheClear(cache)`: forgets every module of the table `cache` in every context this realm created.
pub fn cacheClear(state: *ScopeState, cache: u32) Error!u32 {
    var count: usize = 0;
    for (state.host.contexts.values()) |context| {
        if (context.closed or context.creator != state) continue;
        count += context.scope.clearImportNamespace(cache) catch |err| return errno.narrow(err);
    }
    return @intCast(count);
}

/// `flush(cache)`: asks every live context of this realm to hand over the code caches of modules that
/// compiled without one, and returns what `cache` stored: `[count, [id, hashHex, bytes]...]`, the
/// entries being the ones a `custom` cache has to persist (a `dir` cache wrote its files, a `memory`
/// cache kept them). `count` is how many modules `cache` stored since its last flush.
pub fn flush(state: *ScopeState, call: *Call, cache_id: u32) Error!v8.Value {
    return flushImpl(state, call, cache_id) catch |err| return errno.narrow(err);
}

fn flushImpl(state: *ScopeState, call: *Call, cache_id: u32) !v8.Value {
    const host = state.host;
    const store = graph_api.codeCacheFor(host, cache_id) orelse return error.StaleHandle;
    if (store.owner != state) return error.BadHandle;
    for (host.contexts.values()) |context| {
        if (context.closed or context.creator != state) continue;
        _ = context.scope.flushCodeCache();
    }
    var out = call.array();
    try out.push(@as(f64, @floatFromInt(store.stored)));
    store.stored = 0;
    for (store.fresh.items) |item| {
        var entry = call.array();
        try entry.push(item.id);
        const hex = std.fmt.bytesToHex(item.hash, .lower);
        try entry.push(@as([]const u8, &hex));
        try entry.push(try call.bytesValue(item.bytes));
        try out.push(entry.finish());
        host.allocator.free(item.id);
        host.allocator.free(item.bytes);
    }
    store.fresh.clearRetainingCapacity();
    return out.finish();
}

/// `cachePut(cache, id, hashHex, blob)`: hands a cache a blob a `custom` store loaded: its first 32
/// bytes are the hash of the source it was made for, which must be `hashHex` (otherwise it is ignored),
/// then V8's bytes.
pub fn cachePut(state: *ScopeState, cache_id: u32, id: []const u8, hash_hex: []const u8, bytes: []u8) Error!void {
    const store = graph_api.codeCacheFor(state.host, cache_id) orelse return error.StaleHandle;
    var hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&hash, hash_hex) catch return error.InvalidInput;
    // A blob made for another source text is a miss, not an error.
    if (bytes.len <= hash.len or !std.mem.eql(u8, bytes[0..hash.len], &hash)) return;
    _ = store.remember(id, hash, bytes[hash.len..]);
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
    /// The module name of the preload (`preload:<index>`): the `subject` of the `ModuleError` it can reject with. Owned.
    subject: []const u8 = "",
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
    const owned_subject = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_subject);
    pending.* = .{ .host = host, .resolver = .new(call.isolate, resolver), .parent = state.scope, .subject = owned_subject };
    errdefer pending.resolver.deinit();
    if (has_values) pending.values = .new(call.isolate, values);
    errdefer if (pending.values) |held| held.deinit();
    try host.preloads.append(alloc, pending);
    errdefer _ = host.preloads.pop();
    const table = context.cacheOfHandler(context.import_handler);
    try context.scope.updateImportCache(.{ .module_id = name, .namespace = table }, .{ .source = source }, null);
    context.root = name;
    defer context.root = null;
    const loading = try context.scope.importIn(table, name, &.{}, null);
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
    // Settled once: no callback refers to it afterwards.
    defer {
        const host = pending.host;
        for (host.preloads.items, 0..) |item, index| if (item == pending) {
            _ = host.preloads.swapRemove(index);
            break;
        };
        host.allocator.free(pending.subject);
        host.allocator.destroy(pending);
    }
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
    const env: binding.Env = .{ .isolate = isolate, .ctx = parent_ctx };
    const failure = failureValue(env, child_ctx, failed, pending.subject) catch {
        _ = pending.resolver.deref().reject(parent_ctx, binding.string(isolate, "module evaluation failed"));
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
