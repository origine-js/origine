//! The `Host`: owner of everything the guest-visible `api` hands out (grants, child
//! scopes, loaders) and driver of the init -> `main(api)` lifecycle.
//!
//! The Zig host owns all authority. Guest code only holds native functions whose V8
//! External data points at a grant or per-scope state record, plus plain descriptors
//! that name things inside one grant. `src/js/glue/` shapes the surface; every native
//! validates its own inputs through typed bindings (binding.zig).
//!
//! Error protocol: each scope owns one native-backed `Uint32Array` (`native.errno`,
//! fetched once by the glue). A failing native writes a non-zero `Errno` into element 0
//! and returns undefined; every native clears it on entry.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const binding = @import("binding.zig");
const func = binding.func;
const env_api = @import("env.zig");
const errno = @import("errno.zig");
const threading_api = @import("threading.zig");
const isolate_api = @import("isolate.zig");
const snapshot_api = @import("snapshot.zig");
pub const ThreadIsolate = @import("thread_isolate.zig").ThreadIsolate;
const fs_api = @import("fs.zig");
const graph_api = @import("graph.zig");
const context_api = @import("context.zig");
const init_loader = @import("init_loader.zig");
const registry = @import("registry.zig");
const origine_modules = @import("std/modules.zig");
const module_api = @import("module.zig");
const transformer_api = @import("transform/transformer.zig");
const transformers = @import("transform/transformers.zig");
const Runtime = @import("../managed/runtime.zig").Runtime;
const Scope = @import("../managed/scope.zig").Scope;
const init_snapshot = @import("../managed/init_snapshot.zig");
const ErrorInfo = @import("../managed/errors.zig").ErrorInfo;

const glue_script = @import("glue.zig");
const io_lib = @import("@io");
const sys = @import("../managed/sys.zig");
const startup_trace = @import("@diagnostics").scope;

// Rust natives (rust/crates/origine_api), linked from liborigine_native. CONTRACT (docs/contracts.md,
// surfaces B and C): the C ABI is rust/crates/origine_api/include/origine_api.h; api_abi.zig holds
// the Zig declarations, checked against it by `just check-contracts`. The semantics are in
// docs/async-host-contract.md.
const abi = @import("api_abi.zig");
const OriginCfg = abi.OriginCfg;
const origine_api_attach_isolate = abi.origine_api_attach_isolate;
const origine_api_detach_isolate = abi.origine_api_detach_isolate;
const origine_api_configure = abi.origine_api_configure;
const origine_api_poll = abi.origine_api_poll;
const origine_api_has_work = abi.origine_api_has_work;
const origine_api_pollable = abi.origine_api_pollable;
const origine_api_wake = abi.origine_api_wake;

/// What the host grants to `fs.requestSync` / `fs.requestAsync`. `root` is borrowed and must
/// outlive the Host.
pub const FsConfig = struct {
    root: sys.Dir,
    write: bool = true,
    sync: bool = true,
    /// Async fs also needs `Config.runtime` (the guest creates its runtimes through `api.io`).
    async: bool = true,
};

/// The ceiling for what `api.io.create` may do. Without it (`Config.runtime == null`) the guest has
/// no `api.io` and no async fs. The Host owns and drives every runtime the guest creates.
pub const RuntimeConfig = struct {
    /// I/O backends `create` may pick (`auto` is always allowed and resolves among these).
    backends: Backends = .all,
    max_runtimes: u32 = 4,
    default_entries: u32 = 256,

    pub const Backends = struct {
        uring: bool = true,
        kqueue: bool = true,
        threaded: bool = true,

        pub const all: Backends = .{};

        /// One bit per `io.Kind` value (1 uring, 2 kqueue, 4 threaded).
        fn mask(self: Backends) u32 {
            var out: u32 = 0;
            if (self.uring) out |= 1 << @backingInt(io_lib.backend.Kind.uring);
            if (self.kqueue) out |= 1 << @backingInt(io_lib.backend.Kind.kqueue_gcd);
            if (self.threaded) out |= 1 << @backingInt(io_lib.backend.Kind.threaded);
            return out;
        }
    };
};

/// How long `settle` blocks in one poll when only native work is pending. V8's default platform
/// cannot report its next delayed-task deadline, so the wait is capped and the platform pumped again.
const platform_poll_ns: i64 = 100 * std.time.ns_per_ms;

/// What a child isolate starts with: the id of the stashed message that is the second argument of its
/// `main` (0: none) and its identity, the number its messages carry as `event.identity` (the first
/// isolate is 0).
pub const ParentLink = struct { data: u64, identity: u32 };

/// What `api.isolate.create` needs from the embedder; without it the guest has no `api.isolate`.
/// Everything is borrowed and must outlive the Host and every isolate it spawned.
pub const IsolateConfig = struct {
    platform: v8.Platform,
    /// Must be safe to use from several threads (the process-wide one is).
    array_buffer_allocator: v8.ArrayBuffer.Allocator,
    engine_snapshot: ?[]align(16) const u8 = null,
    /// Most isolates this Host may create over its lifetime.
    max: u32 = 256,
};

pub const Config = struct {
    /// Enables `api.isolate`.
    isolates: ?IsolateConfig = null,
    /// Set for a Host that runs a child isolate.
    link: ?ParentLink = null,
    args: []const []const u8 = &.{},
    env: []const env_api.Pair = &.{},
    fs: ?FsConfig = null,
    /// Ceiling for `api.io` (async runtimes); null removes `api.io` and the async fs.
    runtime: ?RuntimeConfig = null,
    /// Embedded `origine:` modules the init scope serves. Static storage, borrowed until
    /// `destroy`. Tests substitute their own to exercise module-owned state.
    modules: []const module_api.Module = &origine_modules.all,
    /// Extension-to-transformer map the init scope applies to the sources it loads (TypeScript
    /// and JSX by default; an empty slice disables transformation). Static storage, borrowed
    /// until `destroy`.
    transformers: []const transformer_api.Entry = transformers.defaults,
};

/// Per-scope native state. The guest's errno array lives in sandbox memory (V8 refuses
/// external backing stores), so `errno_cell` points into an ArrayBuffer kept alive by
/// `errno_buffer` until `Host.destroy`. Before `install` binds the template's array it points at
/// `errno_local`, which must therefore stay at a stable address.
/// What a native may still use once its scope has been disposed: the host allocator and the
/// errno cell, nothing that disposal released. Lives inside `ScopeState`, which outlives the
/// scope's V8 context (other realms may keep that context, and the natives bound to it, alive).
pub const ScopeCore = struct {
    gpa: std.mem.Allocator,
    errno_cell: *u32,

    pub fn errnoCell(self: *ScopeCore) *u32 {
        return self.errno_cell;
    }
    pub fn allocator(self: *ScopeCore) std.mem.Allocator {
        return self.gpa;
    }
};

pub const ScopeState = struct {
    host: *Host,
    scope: *Scope,
    errno_local: u32 = 0,
    shared: ScopeCore = undefined,
    /// True once `Host.release` took the scope's resources back. `scope` dangles from then on:
    /// only `core` may be used.
    released: bool = false,
    /// Persistent handle pinning the errno array's buffer; released by `Host.destroy`.
    errno_buffer: ?v8.Global.Of(v8.ArrayBuffer) = null,
    /// Per-scope state of modules with `bindings`, created on first use; torn down by
    /// `Host.destroy` in reverse creation order.
    module_states: std.ArrayList(ModuleState) = .empty,
    /// How natives built for a snapshot find this record again (embedder-data slot
    /// `binding.rebinder_slot` of the scope's context points here).
    rebinder: binding.Rebinder = undefined,
    /// While the scope is being evaluated for a snapshot: module natives are built over
    /// static markers, not over this record's address.
    snapshotting: bool = false,
    /// The JS driver of the module graph (src/js/glue/graph.js) that answers non-native import
    /// handlers for the contexts this realm creates. Set by `native.graph.bind`.
    driver: ?Driver = null,

    // Binding State protocol (see binding.zig).
    pub const Core = ScopeCore;
    pub fn core(self: *ScopeState) *ScopeCore {
        return &self.shared;
    }
    pub fn isDetached(self: *const ScopeState) bool {
        return self.released;
    }
    pub fn errnoCell(self: *ScopeState) *u32 {
        return self.shared.errno_cell;
    }
    pub fn allocator(self: *ScopeState) std.mem.Allocator {
        return self.host.allocator;
    }

    /// The state `module`'s bindings (it must have some) keep for this scope, created on first request. Owned
    /// by this record until `Host.destroy`; valid until then. Fails if `create` does.
    pub fn moduleState(self: *ScopeState, module: module_api.Module) !*anyopaque {
        const bindings = module.bindings.?;
        for (self.module_states.items) |owned| {
            if (std.mem.eql(u8, owned.id, module.id)) return owned.ptr;
        }
        try self.module_states.ensureUnusedCapacity(self.host.allocator, 1);
        const ptr = try bindings.create(self);
        self.module_states.appendAssumeCapacity(.{ .id = module.id, .bindings = bindings, .ptr = ptr });
        return ptr;
    }
};

pub const Driver = struct { step: v8.Global.Of(v8.Function) };

const ModuleState = struct { id: []const u8, bindings: module_api.Bindings, ptr: *anyopaque };

pub const Host = struct {
    allocator: std.mem.Allocator,
    args: []const []const u8,
    env: []const env_api.Pair,
    fs: ?FsConfig,
    runtime: ?RuntimeConfig,
    modules: []const module_api.Module,
    transformers: transformer_api.Registry,
    grants: std.ArrayList(*fs_api.FsGrant) = .empty,
    /// Async grants stamped for a realm (`fs.brand`); the Rust runtime owns the grants themselves.
    async_grants: std.ArrayList(fs_api.AsyncGrant) = .empty,
    states: std.ArrayList(*ScopeState) = .empty,
    /// The module graph: graphs, registered import handlers, contexts and their imports in flight.
    /// Ids are never reused (`registry.zig`). A context is freed with its scope, a handler when no live
    /// context can reach it, a graph once it is closed and none of its contexts is left; `destroy`
    /// frees the rest.
    graphs: registry.Registry(graph_api.Graph) = .{},
    handlers: registry.Registry(graph_api.Handler) = .{},
    contexts: registry.Registry(context_api.Context) = .{},
    imports: std.ArrayList(*context_api.ImportState) = .empty,
    /// Calls into the JS driver whose context was freed before the promise settled; each is freed by
    /// its callback, or by `destroy` when the promise never settles.
    orphans: std.ArrayList(*context_api.PendingJs) = .empty,
    /// Ids of handlers freed since the JS side last asked (`graph.handlersFreed`).
    freed_handlers: std.ArrayList(u32) = .empty,
    preloads: std.ArrayList(*context_api.PreloadState) = .empty,
    /// How many times a context called into the JS driver of the module graph. A handler with no JS
    /// function in it never does (tests assert it).
    driver_calls: usize = 0,
    next_fs_id: u32 = 1,
    isolates: ?IsolateConfig = null,
    link: ?ParentLink = null,
    /// Snapshots the guest made or loaded, by id (index + 1); `null` once closed. Released by `destroy`.
    snapshots: std.ArrayList(?*snapshot_api.Record) = .empty,
    /// Isolates this Host created, in id order (id = index + 1); terminated and joined by `destroy`.
    children: std.ArrayList(*ThreadIsolate) = .empty,
    /// The isolate the Rust API is attached to on first Rust capability access; detached by `destroy`.
    rust_isolate: ?v8.Isolate = null,
    /// Set by an owner on another thread to end `settle` with `error.Terminated`.
    stop: ?*const std.atomic.Value(bool) = null,
    /// Only scripts actually loaded are retained; flush after execution to include lazy code.
    glue_unbound: [glue_script.module_count]?v8.Global.Of(v8.UnboundScript) = @splat(null),

    /// Borrows config contents until `destroy`. Returns a heap Host at a stable
    /// address. Release all V8 handles it made (`destroy`) before `Runtime.destroy`.
    pub fn create(allocator: std.mem.Allocator, config: Config) !*Host {
        const host = try allocator.create(Host);
        host.* = .{ .allocator = allocator, .args = config.args, .env = config.env, .fs = config.fs, .runtime = config.runtime, .modules = config.modules, .transformers = .{ .entries = config.transformers }, .isolates = config.isolates, .link = config.link };
        return host;
    }

    /// Closes every handle and frees all host records. Must run before
    /// `Runtime.destroy` (it releases V8 persistent handles).
    pub fn destroy(self: *Host) void {
        const alloc = self.allocator;
        for (self.children.items) |child| {
            child.terminate();
            _ = child.join();
            child.destroy();
        }
        self.children.deinit(alloc);
        for (self.snapshots.items) |item| if (item) |rec| rec.release();
        self.snapshots.deinit(alloc);
        if (self.rust_isolate) |isolate| origine_api_detach_isolate(isolate.handle);
        for (self.grants.items) |grant| {
            grant.deinit();
            alloc.destroy(grant);
        }
        self.grants.deinit(alloc);
        self.async_grants.deinit(alloc);
        for (self.states.items) |state| self.releaseState(state);
        self.states.deinit(alloc);
        for (self.imports.items) |pending| {
            if (!pending.done) pending.resolver.deinit();
            alloc.destroy(pending);
        }
        self.imports.deinit(alloc);
        for (self.preloads.items) |pending| {
            if (!pending.done) pending.resolver.deinit();
            if (pending.values) |held| held.deinit();
            alloc.destroy(pending);
        }
        self.preloads.deinit(alloc);
        for (self.contexts.values()) |context| {
            context.deinit();
            alloc.destroy(context);
        }
        self.contexts.deinit(alloc);
        for (self.orphans.items) |pending| context_api.freePending(alloc, pending);
        self.orphans.deinit(alloc);
        for (self.handlers.values()) |item| {
            item.deinit();
            alloc.destroy(item);
        }
        self.handlers.deinit(alloc);
        self.freed_handlers.deinit(alloc);
        for (self.graphs.values()) |item| {
            item.deinit();
            alloc.destroy(item);
        }
        self.graphs.deinit(alloc);
        for (self.glue_unbound) |pending| if (pending) |script| script.deinit();
        alloc.destroy(self);
    }

    /// Stores code caches of loaded glue scripts that compiled without an accepted cache.
    /// Call after the glue and its users run; best effort, releasing retained scripts even
    /// without a hook. Borrows scope on its isolate thread; retains no new handles or bytes.
    pub fn flushGlueCache(self: *Host, scope: *Scope) void {
        var session: Scope.Session = undefined;
        session.init(scope);
        defer session.deinit();
        for (&self.glue_unbound, 0..) |*slot, index| {
            const pending = slot.* orelse continue;
            slot.* = null;
            defer pending.deinit();
            const hook = scope.options.code_cache orelse continue;
            const cache = pending.deref().createCodeCache() orelse continue;
            defer cache.deinit();
            const bytes = v8.ScriptCompiler.CachedData.bytes(cache.handle);
            if (bytes.len == 0) continue;
            const script = glue_script.script(@fromBackingInt(@intCast(index)));
            hook.store(hook.data, .{ .allocator = self.allocator, .module_id = script.cache_id, .source = script.source }, bytes);
        }
    }

    /// Installs one namespace of the Rust registry whose requirements the configuration meets.
    /// Borrows state/native in the entered realm; callbacks retain state until host teardown.
    /// Nothing about the natives is written on the Zig side: names, callbacks and side effects all
    /// come from the `#[native(...)]` attributes in rust/crates/origine_api.
    fn installRustNatives(self: *Host, env: binding.Env, native: v8.Object, state: *ScopeState, wanted: []const u8) !void {
        const has_runtime = self.runtime != null;
        const has_async_fs = has_runtime and self.fs != null and self.fs.?.async;
        var namespace_object: ?v8.Object = null;
        var index: usize = 0;
        const count = abi.origine_api_natives_count();
        while (index < count) : (index += 1) {
            var entry: abi.Native = undefined;
            if (abi.origine_api_natives_get(index, &entry) != 0) return error.BadNativeRegistry;
            const needs = std.enums.fromInt(abi.Needs, entry.needs) orelse return error.BadNativeRegistry;
            const side_effect: binding.SideEffect = switch (std.enums.fromInt(abi.SideEffect, entry.side_effect) orelse return error.BadNativeRegistry) {
                .none => .none,
                .receiver => .receiver,
                .any => .any,
            };
            const available = switch (needs) {
                .none => true,
                .runtime => has_runtime,
                .async_fs => has_async_fs,
            };
            if (!available) continue;
            const path = std.mem.span(entry.path);
            const dot = std.mem.indexOfScalar(u8, path, '.') orelse return error.BadNativeRegistry;
            const namespace = path[0..dot];
            if (!std.mem.eql(u8, namespace, wanted)) continue;
            const object = namespace_object orelse blk: {
                const created = eu.v.object(env.isolate);
                try binding.set(env, native, namespace, created);
                namespace_object = created;
                break :blk created;
            };
            const function = binding.rawDynamic(env, state, @ptrCast(entry.callback), side_effect);
            try binding.set(env, object, path[dot + 1 ..], function.object.value);
        }
    }

    /// Attaches the Rust API to the isolate on first need. Failures leave it detached and retryable.
    fn ensureRust(self: *Host, env: binding.Env) !void {
        if (self.rust_isolate != null) return;
        if (!origine_api_attach_isolate(env.isolate.handle)) return error.BootstrapFailed;
        self.rust_isolate = env.isolate;
        self.configureRust(env.isolate);
    }

    /// `native.threading.attach(native)`: installs `native.channel` into the glue's native table. Done
    /// on the first use of a channel so that `api.host` alone never attaches the Rust API.
    fn attachChannels(state: *ScopeState, call: *binding.Call, native: v8.Object) errno.Error!void {
        const env = call.env();
        state.host.ensureRust(env) catch |err| return errno.narrow(err);
        state.host.installRustNatives(env, native, state, "channel") catch |err| return errno.narrow(err);
    }

    /// Hands the embedder's ceiling to the Rust side (right after attach).
    fn configureRust(self: *Host, isolate: v8.Isolate) void {
        const runtime = self.runtime orelse RuntimeConfig{ .max_runtimes = 0 };
        const cfg: OriginCfg = .{
            .max_runtimes = runtime.max_runtimes,
            .backends_mask = runtime.backends.mask(),
            .default_entries = runtime.default_entries,
            .fs_root_fd = if (self.fs) |config| @intCast(config.root.handle) else -1,
            .fs_write = if (self.fs) |config| @intFromBool(config.write) else 0,
            .fs_async = if (self.fs != null and self.runtime != null and self.fs.?.async) 1 else 0,
        };
        origine_api_configure(isolate.handle, &cfg);
    }

    /// Resolver and loader for the init scope: serves the `origine:@std/*` modules and
    /// reads other modules from the process working directory. Borrows self.
    pub fn initOptions(self: *Host) Scope.Options {
        return .{
            .origine_namespace = true,
            .resolver = .{ .data = self, .resolve = init_loader.resolve },
            .loader = .{ .data = self, .load = init_loader.load },
            .meta = .{ .data = self, .init = init_loader.meta },
            .on_dispose = self.disposer(),
        };
    }

    /// The `origine:` modules code running in `scope` may serve to others: the allowlist of its
    /// context, nothing for a scope without the namespace, everything for the init scope.
    pub fn ceilingOf(self: *Host, scope: *Scope) ?graph_api.StdFilter {
        for (self.contexts.values()) |context| if (context.scope == scope) return context.ceiling;
        if (!scope.options.origine_namespace) return .{ .include = &.{} };
        return null;
    }

    /// The `Scope.Options.on_dispose` hook for scopes of this host.
    pub fn disposer(self: *Host) Scope.Disposer {
        return .{ .data = self, .call = onDispose };
    }

    /// The `Scope.Options.on_freed` hook of a context's scope: its record goes with it.
    pub fn freer(self: *Host) Scope.Disposer {
        return .{ .data = self, .call = onFreed };
    }

    fn onFreed(data: ?*anyopaque, scope: *Scope) void {
        const self: *Host = @ptrCast(@alignCast(data.?));
        for (self.contexts.values()) |context| if (context.scope == scope) {
            context_api.free(self, context);
            return;
        };
    }

    /// Runs while a disposed scope is freed: releases its host state and its JS loader.
    fn onDispose(data: ?*anyopaque, scope: *Scope) void {
        const self: *Host = @ptrCast(@alignCast(data.?));
        self.release(scope);
        for (self.contexts.values()) |context| if (context.scope == scope) {
            context.closed = true;
        };
    }

    /// Creates `scope`'s native-state record and makes it reachable from the scope's context
    /// (module natives built for a snapshot resolve their state through it). Owned by the
    /// Host until `detach` or `destroy`. Borrows scope, which must outlive the record.
    pub fn attach(self: *Host, scope: *Scope) !*ScopeState {
        const state = try self.allocator.create(ScopeState);
        errdefer self.allocator.destroy(state);
        state.* = .{ .host = self, .scope = scope };
        state.shared = .{ .gpa = self.allocator, .errno_cell = &state.errno_local };
        state.rebinder = .{ .owner = state, .resolve = resolveModuleState };
        try self.states.append(self.allocator, state);
        var session: Scope.Session = undefined;
        session.init(scope);
        defer session.deinit();
        session.ctx.setAlignedPointerInEmbedderData(binding.rebinder_slot, &state.rebinder);
        return state;
    }

    /// Releases `scope`'s record: tears down its module states, clears the context slot (it is
    /// process memory, which a snapshot must not capture) and frees it. No-op for a scope that
    /// was never attached. Call with the scope's isolate alive, before `Runtime.destroy`.
    pub fn detach(self: *Host, scope: *Scope) void {
        for (self.states.items, 0..) |state, index| {
            // A released record's `scope` dangles (the address may name a newer scope).
            if (state.released or state.scope != scope) continue;
            var session: Scope.Session = undefined;
            session.init(scope);
            defer session.deinit();
            session.ctx.setAlignedPointerInEmbedderData(binding.rebinder_slot, null);
            self.releaseState(state);
            _ = self.states.swapRemove(index);
            return;
        }
    }

    /// Takes back everything `scope`'s guest was given: module states, fs grants and the errno
    /// buffer. The record itself stays, marked released, until `Host.destroy`: natives bound to the
    /// scope's context can outlive the scope (another realm may hold a function from it), and they
    /// reach this record through V8 external data. Called by `Runtime.disposeScope`'s teardown,
    /// before the context goes; no-op for a scope that was never attached or is already released.
    pub fn release(self: *Host, scope: *Scope) void {
        for (self.states.items) |state| {
            if (state.released or state.scope != scope) continue;
            var session: Scope.Session = undefined;
            session.init(scope);
            defer session.deinit();
            session.ctx.setAlignedPointerInEmbedderData(binding.rebinder_slot, null);
            var remaining = state.module_states.items.len;
            while (remaining > 0) : (remaining -= 1) {
                const owned = state.module_states.items[remaining - 1];
                owned.bindings.release(state, owned.ptr);
            }
            for (self.grants.items) |grant| if (grant.owner == state) grant.deinit();
            // Its graphs go with the realm that could name them; contexts still using one keep it until they are freed.
            var index: usize = 0;
            while (index < self.graphs.values().len) {
                const owned = self.graphs.values()[index];
                if (owned.owner != state) {
                    index += 1;
                    continue;
                }
                owned.closed = true;
                const before = self.graphs.count();
                graph_api.releaseGraph(self, owned);
                if (self.graphs.count() == before) index += 1;
            }
            // The cell may live in the buffer being released: keep its value and move home.
            state.errno_local = state.shared.errno_cell.*;
            state.shared.errno_cell = &state.errno_local;
            if (state.errno_buffer) |buffer| buffer.deinit();
            state.errno_buffer = null;
            state.released = true;
            return;
        }
    }

    /// Tears down one record: module states in reverse creation order, then its handles.
    fn releaseState(self: *Host, state: *ScopeState) void {
        const alloc = self.allocator;
        var remaining = state.module_states.items.len;
        while (remaining > 0) : (remaining -= 1) {
            const owned = state.module_states.items[remaining - 1];
            owned.bindings.destroy(state, owned.ptr);
        }
        state.module_states.deinit(alloc);
        if (state.driver) |driver| driver.step.deinit();
        if (state.errno_buffer) |buffer| buffer.deinit();
        alloc.destroy(state);
    }

    /// `Rebinder.resolve` for `ScopeState`: the state object module `index`'s natives take.
    fn resolveModuleState(owner: *anyopaque, index: usize) ?*anyopaque {
        const state: *ScopeState = @ptrCast(@alignCast(owner));
        if (index >= state.host.modules.len or state.host.modules[index].bindings == null) return null;
        return state.moduleState(state.host.modules[index]) catch null;
    }

    /// The external-reference table a startup snapshot with this host's module natives needs, at
    /// creation and again when restoring: managed's own references, the rebind markers, then the
    /// callbacks of every module with bindings. Null-terminated, for
    /// `CreateParams.external_references`. Caller owns the slice (free with `alloc`) and must keep
    /// it alive as long as any isolate made with it.
    pub fn externalReferences(self: *const Host, alloc: std.mem.Allocator) ![]?*const anyopaque {
        var list: std.ArrayList(?*const anyopaque) = .empty;
        errdefer list.deinit(alloc);
        try list.appendSlice(alloc, &init_snapshot.base_references);
        const markers = binding.rebindMarkers();
        for (markers) |marker| try list.append(alloc, marker);
        for (self.modules) |module| {
            const bindings = module.bindings orelse continue;
            for (bindings.callbacks) |callback| {
                const address: *const anyopaque = @ptrCast(callback);
                if (std.mem.indexOfScalar(?*const anyopaque, list.items, address) == null) try list.append(alloc, address);
            }
        }
        try list.append(alloc, null);
        return list.toOwnedSlice(alloc);
    }

    /// `init_snapshot.CreateOptions.hooks` for this host: the evaluation scope gets a record
    /// (module natives work while the init runs, built over markers) and loses it again before
    /// the heap is serialized. Borrows self.
    pub fn snapshotHooks(self: *Host) init_snapshot.Hooks {
        return .{ .data = self, .attach = snapshotAttach, .detach = snapshotDetach };
    }

    fn snapshotAttach(data: ?*anyopaque, scope: *Scope) anyerror!void {
        const self: *Host = @ptrCast(@alignCast(data.?));
        (try self.attach(scope)).snapshotting = true;
    }

    fn snapshotDetach(data: ?*anyopaque, scope: *Scope) void {
        const self: *Host = @ptrCast(@alignCast(data.?));
        self.detach(scope);
    }

    /// Binds per-scope native state to its prebuilt API template (cached-script fallback
    /// when absent). Returns a caller-owned handle; release before Runtime.destroy.
    /// Borrows scope through return; its realm retains natives until teardown.
    /// Error details follow ErrorInfo ownership. No guest export validation is needed.
    pub fn install(self: *Host, scope: *Scope, error_info: ?*ErrorInfo) !v8.Global.Of(v8.Value) {
        var timing = startup_trace.begin();
        const state = try self.attach(scope);
        var session: Scope.Session = undefined;
        session.init(scope);
        defer session.deinit();
        errdefer session.retainException(error_info);
        const isolate = session.isolate();
        const ctx = session.ctx;
        const env: binding.Env = .{ .isolate = isolate, .ctx = ctx };
        startup_trace.mark(&timing, "api_attach");
        const bundle = glue_script.restored(ctx) orelse try glue_script.initialize(isolate, ctx, try self.compileGlue(scope, .common));
        startup_trace.mark(&timing, "api_restore_template");
        const native_value = bundle.object.getIndex(ctx, glue_script.native_index) orelse return error.BootstrapFailed;
        const native = native_value.toObject(ctx) orelse return error.BootstrapFailed;
        const load = binding.rawDynamic(env, state, binding.native(ScopeState, loadCapability), .any);
        try binding.set(env, native, "load", load.object.value);
        const errno_value = bundle.object.getIndex(ctx, glue_script.errno_index) orelse return error.BootstrapFailed;
        try bindErrno(state, errno_value);
        const api = bundle.object.getIndex(ctx, if (self.runtime != null) glue_script.full_index else glue_script.basic_index) orelse return error.BootstrapFailed;
        startup_trace.mark(&timing, "api_bind_state");
        return .new(isolate, api);
    }

    /// Compiles/evaluates one glue expression in scope's entered realm. Returns a local
    /// factory handle; retains an unbound script until flush/destroy only on a cache miss.
    /// Borrows scope and cache bytes through compilation; errors transfer no caller ownership.
    fn compileGlue(self: *Host, scope: *Scope, module: glue_script.Module) !v8.Function {
        var timing = if (module == .common) startup_trace.begin() else null;
        const isolate = scope.runtime.isolate;
        const ctx = scope.context.deref();
        const text = glue_script.script(module);
        const hook = scope.options.code_cache;
        var cache_arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer cache_arena.deinit();
        const cached_bytes = if (hook) |h| h.load(h.data, .{ .allocator = cache_arena.allocator(), .module_id = text.cache_id, .source = text.source }) else null;
        startup_trace.mark(&timing, "api_glue_cache_read");
        // The Source owns the CachedData object it is given (not the bytes).
        const cache_object = if (cached_bytes) |bytes| v8.ScriptCompiler.CachedData.init(bytes.ptr, @intCast(bytes.len)) else null;
        const origin = scope.scriptOrigin(text.origin, false);
        var source: v8.ScriptCompiler.Source = undefined;
        source.init(eu.v.str_utf8(isolate, text.source), &origin, cache_object);
        defer source.deinit();
        const script = v8.ScriptCompiler.compile(ctx, &source, if (cache_object != null) 1 else 0, 0) orelse return error.JavaScriptException;
        const accepted = cache_object != null and !v8.ScriptCompiler.CachedData.rejected(source.getCachedData().?);
        const slot = &self.glue_unbound[@backingInt(module)];
        if (hook != null and !accepted and slot.* == null) {
            if (script.getUnboundScript()) |unbound| slot.* = .new(isolate, unbound);
        }
        startup_trace.mark(&timing, "api_glue_compile");
        const factory = v8.Function.from_opaque((script.run(ctx) orelse return error.JavaScriptException).data.handle) orelse return error.BootstrapFailed;
        startup_trace.mark(&timing, "api_glue_evaluate");
        return factory;
    }

    /// First-access callback: binds only this capability's natives to the private template.
    /// Borrows local arguments; installed callbacks retain scope-owned state until teardown.
    /// Returns a local JS factory only for the no-snapshot fallback, otherwise undefined.
    /// Failures leave the getter retryable; never validates/freezes the prebuilt public graph.
    fn loadCapability(state: *ScopeState, call: *binding.Call, name: []const u8, native: v8.Object, needs_factory: bool) !v8.Value {
        const module = std.meta.stringToEnum(glue_script.Module, name) orelse return error.InvalidInput;
        const host = state.host;
        const env = call.env();
        const part = switch (module) {
            .common => return error.InvalidInput,
            .host => try call.object(ScopeState, state, .{
                .env = .{
                    .args = func(env_api.args, .{ .side_effect = .none }),
                    .get = func(env_api.get, .{ .side_effect = .none }),
                    .list = func(env_api.list, .{ .side_effect = .none }),
                },
                .threading = .{
                    .parallelism = func(threading_api.parallelism, .{ .side_effect = .none }),
                    .attach = func(attachChannels, .{ .side_effect = .any }),
                    .identity = func(threading_api.identity, .{ .side_effect = .none }),
                },
                .snapshot = .{
                    .create = func(snapshot_api.create, .{ .side_effect = .any }),
                    .fromRaw = func(snapshot_api.fromRaw, .{ .side_effect = .any }),
                    .fromFile = func(snapshot_api.fromFile, .{ .side_effect = .any }),
                    .blob = func(snapshot_api.blob, .{ .side_effect = .any }),
                    .file = func(snapshot_api.file, .{ .side_effect = .any }),
                    .init = func(snapshot_api.initOf, .{ .side_effect = .any }),
                    .close = func(snapshot_api.close, .{ .side_effect = .any }),
                },
            }),
            .fs => try call.object(ScopeState, state, .{
                .fsRequest = func(fs_api.request, .{ .side_effect = .any }),
                .fsBrand = func(fs_api.brand, .{ .side_effect = .any }),
            }),
            .graph, .context => blk: {
                const object = try call.object(ScopeState, state, .{
                    .graph = .{
                        .create = func(graph_api.graphCreate, .{ .side_effect = .any }),
                        .close = func(graph_api.graphClose, .{ .side_effect = .any }),
                        .handler = func(graph_api.handler, .{ .side_effect = .any }),
                        .layer = func(graph_api.layer, .{ .side_effect = .any }),
                        .hook = func(graph_api.hook, .{ .side_effect = .any }),
                        .transform = func(graph_api.transform, .{ .side_effect = .any }),
                        .readSource = func(graph_api.readSource, .{ .side_effect = .any }),
                        .compileRequests = func(graph_api.compileRequests, .{ .side_effect = .any }),
                        .bind = func(graph_api.bind, .{ .side_effect = .any }),
                        .asyncFs = func(graph_api.asyncFs, .{ .side_effect = .any }),
                        .utf8 = func(graph_api.utf8, .{ .side_effect = .any }),
                        .sourceHash = func(graph_api.sourceHash, .{ .side_effect = .any }),
                        .jsonModule = func(graph_api.jsonModule, .{ .side_effect = .any }),
                        .pipelineResolve = func(graph_api.pipelineResolve, .{ .side_effect = .any }),
                        .pipelineLoad = func(graph_api.pipelineLoad, .{ .side_effect = .any }),
                        .handlerPin = func(graph_api.handlerPin, .{ .side_effect = .any }),
                        .handlerUnpin = func(graph_api.handlerUnpin, .{ .side_effect = .any }),
                        .handlersFreed = func(graph_api.handlersFreed, .{ .side_effect = .any }),
                    },
                    .context = .{
                        .create = func(context_api.create, .{ .side_effect = .any }),
                        .importSpecifier = func(context_api.importSpecifier, .{ .side_effect = .any }),
                        .evaluateSource = func(context_api.evaluateSource, .{ .side_effect = .any }),
                        .close = func(context_api.close, .{ .side_effect = .any }),
                        .tableSize = func(context_api.tableSize, .{ .side_effect = .any }),
                        .tableDelete = func(context_api.tableDelete, .{ .side_effect = .any }),
                        .tableClear = func(context_api.tableClear, .{ .side_effect = .any }),
                        .flush = func(context_api.flush, .{ .side_effect = .any }),
                        .cachePut = func(context_api.cachePut, .{ .side_effect = .any }),
                        .pin = func(context_api.pin, .{ .side_effect = .any }),
                        .unpin = func(context_api.unpin, .{ .side_effect = .any }),
                        .namespaceOf = func(context_api.namespaceOf, .{ .side_effect = .any }),
                        .preload = func(context_api.preloadScript, .{ .side_effect = .any }),
                        .preloadModule = func(context_api.preloadModule, .{ .side_effect = .any }),
                    },
                });
                // The two capabilities share one set of natives; install it once.
                const present = native.get(env.ctx, binding.string(env.isolate, "graph")) orelse return error.JavaScriptException;
                if (present.isUndefined()) {
                    inline for (.{ "graph", "context" }) |property| {
                        const value = object.get(env.ctx, binding.string(env.isolate, property)) orelse return error.JavaScriptException;
                        try binding.set(env, native, property, value);
                    }
                }
                break :blk object;
            },
            .isolate => blk: {
                if (host.isolates == null) return error.PermissionDenied;
                break :blk try call.object(ScopeState, state, .{
                    .isolate = .{
                        .spawn = func(isolate_api.spawn, .{ .side_effect = .any }),
                        .terminate = func(isolate_api.terminate, .{ .side_effect = .any }),
                        .outcome = func(isolate_api.outcome, .{ .side_effect = .any }),
                        .failure = func(isolate_api.failure, .{ .side_effect = .any }),
                        .link = func(isolate_api.link, .{ .side_effect = .none }),
                    },
                });
            },
            .io, .net => eu.v.object(env.isolate),
        };
        const keys: []const []const u8 = switch (module) {
            .host => &.{ "env", "threading", "snapshot" },
            .isolate => &.{"isolate"},
            .fs => &.{ "fsRequest", "fsBrand" },
            else => &.{},
        };
        for (keys) |property| {
            const value = part.get(env.ctx, binding.string(env.isolate, property)) orelse return error.JavaScriptException;
            try binding.set(env, native, property, value);
        }
        const rust_namespace: ?[]const u8 = switch (module) {
            .fs => if (host.runtime != null and host.fs != null and host.fs.?.async) "fsAsync" else null,
            .io, .net => if (host.runtime != null) name else return error.PermissionDenied,
            else => null,
        };
        if (rust_namespace) |namespace| {
            try host.ensureRust(env);
            try host.installRustNatives(env, native, state, namespace);
        }
        return if (needs_factory) (try host.compileGlue(state.scope, module)).object.value else eu.v.undefined_value(env.isolate).value;
    }

    /// The value the glue keeps for `main`'s second argument; needs the entered context and a live HandleScope.
    fn initialData(self: *Host, isolate: v8.Isolate, ctx: v8.Context) !v8.Value {
        _ = self;
        const bundle = glue_script.restored(ctx) orelse return error.BootstrapFailed;
        const initial_value = bundle.object.getIndex(ctx, glue_script.initial_index) orelse return error.BootstrapFailed;
        const initial = v8.Function.from_opaque(initial_value.data.handle) orelse return error.BootstrapFailed;
        const undefined_value = eu.v.undefined_value(isolate).value;
        return initial.call(ctx, undefined_value, &.{}) orelse error.InitFailed;
    }

    /// Lifecycle driver: evaluates `init_specifier` as a module in `scope` (which
    /// must have been created with `initOptions`), then calls its exported `main`
    /// with the root `api` and pumps until it settles. Returns error.InitFailed or
    /// error.MainFailed with the rejection/exception in `error_info`.
    pub fn run(self: *Host, scope: *Scope, platform: v8.Platform, init_specifier: []const u8, error_info: ?*ErrorInfo) !void {
        var timing = startup_trace.begin();
        const rt = scope.runtime;
        const api = try self.install(scope, error_info);
        defer api.deinit();
        startup_trace.mark(&timing, "host_api_install");
        const loading = try scope.importModule(init_specifier, error_info);
        defer loading.deinit();
        try self.settle(rt, platform, loading);
        startup_trace.mark(&timing, "host_module_import");
        const main_result = blk: {
            var session: Scope.Session = undefined;
            session.init(scope);
            defer session.deinit();
            const promise = loading.deref();
            if (promise.state() == .Rejected) {
                if (error_info) |out| if (out.exception == null) {
                    out.exception = .new(session.isolate(), promise.result());
                };
                return error.InitFailed;
            }
            const namespace = promise.result().toObject(session.ctx) orelse return error.InitFailed;
            const main_value = namespace.get(session.ctx, binding.string(session.isolate(), "main")) orelse return error.InitFailed;
            const main_fn = v8.Function.from_opaque(main_value.data.handle) orelse return error.MainMissing;
            errdefer session.retainException(error_info);
            // The second argument is what the creating isolate passed to `api.isolate.create` (undefined in the first).
            const data = if (self.link != null) try self.initialData(session.isolate(), session.ctx) else eu.v.undefined_value(session.isolate()).value;
            const result = main_fn.call(session.ctx, eu.v.undefined_value(session.isolate()).value, &.{ api.deref(), data }) orelse return error.MainFailed;
            break :blk v8.Global.Of(v8.Value).new(session.isolate(), result);
        };
        defer main_result.deinit();
        startup_trace.mark(&timing, "host_main_call");
        var wrapper: ?v8.Global.Of(v8.Promise) = null;
        defer if (wrapper) |w| w.deinit();
        {
            var session: Scope.Session = undefined;
            session.init(scope);
            defer session.deinit();
            const value = main_result.deref();
            if (value.isPromise()) wrapper = .new(session.isolate(), v8.Promise.from_opaque(value.data.handle).?);
        }
        if (wrapper) |promise| {
            try self.settle(rt, platform, promise);
            var session: Scope.Session = undefined;
            session.init(scope);
            defer session.deinit();
            if (promise.deref().state() == .Rejected) {
                if (error_info) |out| if (out.exception == null) {
                    out.exception = .new(session.isolate(), promise.deref().result());
                };
                return error.MainFailed;
            }
        } else rt.pumpPlatform(platform);
        startup_trace.mark(&timing, "host_main_settle");
    }

    /// Drives the platform, the microtask queue and every I/O runtime until `promise` settles.
    /// Fails with `Stalled` when it is pending and nothing can still make progress.
    pub fn settle(self: *Host, rt: *Runtime, platform: v8.Platform, promise: v8.Global.Of(v8.Promise)) !void {
        while (true) {
            if (self.stop) |flag| if (flag.load(.acquire)) return error.Terminated;
            rt.pumpPlatform(platform);
            {
                var session: Runtime.Session = undefined;
                session.init(rt);
                defer session.deinit();
                if (promise.deref().state() != .Pending) return;
            }
            if (!self.hasWork()) {
                // Nothing native is pending: only a platform task can still settle the promise.
                var session: Runtime.Session = undefined;
                session.init(rt);
                defer session.deinit();
                if (!platform.pumpMessageLoop(rt.isolate, false)) return error.Stalled;
                continue;
            }
            _ = try self.pollNative(rt, true, platform_poll_ns);
        }
    }

    /// True while any runtime has live tasks or operations.
    pub fn hasWork(self: *Host) bool {
        const isolate = self.rust_isolate orelse return false;
        return origine_api_has_work(isolate.handle) != 0;
    }

    /// For embedders with their own event loop: one fd that becomes readable when `poll` would make
    /// progress, or null (no runtime yet). Register it with your loop and call `poll` when it fires.
    pub fn pollable(self: *Host) ?std.posix.fd_t {
        const isolate = self.rust_isolate orelse return null;
        const fd = origine_api_pollable(isolate.handle);
        return if (fd < 0) null else @intCast(fd);
    }

    /// Ticks the ready runtimes once without waiting (completions settle their promises, then
    /// microtasks run). Returns the number of live tasks and operations left.
    pub fn poll(self: *Host, rt: *Runtime) !usize {
        return self.pollNative(rt, false, 0);
    }

    /// Thread-safe: interrupts a blocking poll (for example a platform task or the embedder
    /// has new work).
    pub fn wake(self: *Host) void {
        if (self.rust_isolate) |isolate| origine_api_wake(isolate.handle);
    }

    fn pollNative(self: *Host, rt: *Runtime, block: bool, timeout_ns: i64) !usize {
        const isolate = self.rust_isolate orelse return 0;
        const live = blk: {
            var session: Runtime.Session = undefined;
            session.init(rt);
            defer session.deinit();
            break :blk origine_api_poll(isolate.handle, @intFromBool(block), timeout_ns);
        };
        rt.pump();
        if (live < 0) return error.IoPollFailed;
        return @intCast(live);
    }
};

/// Pins the template's non-detachable errno buffer until Host.destroy and borrows its
/// storage for state.errno_cell. Requires the entered realm and a live HandleScope.
/// The template contains no host pointers; each restored context has its own buffer.
fn bindErrno(state: *ScopeState, value: v8.Value) !void {
    if (!value.isUint32Array()) return error.BootstrapFailed;
    const view = v8.ArrayBufferView.from_opaque(value.data.handle) orelse return error.BootstrapFailed;
    const backing = view.buffer() orelse return error.BootstrapFailed;
    const buffer = v8.ArrayBuffer.from_opaque(backing.object.value.data.handle) orelse return error.BootstrapFailed;
    const cell: *u32 = @ptrCast(@alignCast(buffer.data() orelse binding.oom()));
    cell.* = state.errno_local;
    state.shared.errno_cell = cell;
    state.errno_buffer = .new(state.scope.runtime.isolate, buffer);
}
