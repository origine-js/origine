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
const binding = @import("binding.zig");
const func = binding.func;
const errno_api = @import("errno.zig");
const env_api = @import("env.zig");
const fs_api = @import("fs.zig");
const scope_api = @import("scope.zig");
const init_loader = @import("init_loader.zig");
const origine_modules = @import("std/modules.zig");
const module_api = @import("module.zig");
const transformer_api = @import("transform/transformer.zig");
const transformers = @import("transform/transformers.zig");
const JsLoader = @import("js_loader.zig").JsLoader;
const Runtime = @import("../managed/runtime.zig").Runtime;
const Scope = @import("../managed/scope.zig").Scope;
const ErrorInfo = @import("../managed/errors.zig").ErrorInfo;

const glue_script = @import("glue.zig");
const io_lib = @import("@io");

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
    root: std.Io.Dir,
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

pub const Config = struct {
    io: std.Io,
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
/// `errno_buffer` until `Host.destroy`. Before `install` builds the array it points at
/// `errno_local`, which must therefore stay at a stable address.
pub const ScopeState = struct {
    host: *Host,
    scope: *Scope,
    errno_local: u32 = 0,
    errno_cell: *u32 = undefined,
    /// Persistent handle pinning the errno array's buffer; released by `Host.destroy`.
    errno_buffer: ?v8.Global.Of(v8.ArrayBuffer) = null,
    /// Per-scope state of modules with `bindings`, created on first use; torn down by
    /// `Host.destroy` in reverse creation order.
    module_states: std.ArrayList(ModuleState) = .empty,

    // Binding State protocol (see binding.zig).
    pub fn errnoCell(self: *ScopeState) *u32 {
        return self.errno_cell;
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

const ModuleState = struct { id: []const u8, bindings: module_api.Bindings, ptr: *anyopaque };

pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    env: []const env_api.Pair,
    fs: ?FsConfig,
    runtime: ?RuntimeConfig,
    modules: []const module_api.Module,
    transformers: transformer_api.Registry,
    grants: std.ArrayList(*fs_api.FsGrant) = .empty,
    states: std.ArrayList(*ScopeState) = .empty,
    children: std.ArrayList(scope_api.Child) = .empty,
    loaders: std.ArrayList(*JsLoader) = .empty,
    runs: std.ArrayList(*scope_api.RunState) = .empty,
    next_fs_id: u32 = 1,
    /// The isolate the Rust API is attached to (first `install`); detached by `destroy`.
    rust_isolate: ?v8.Isolate = null,
    /// True while a JS loader callback runs inside Runtime.pump's scope iteration;
    /// creating a scope then would invalidate that iteration.
    in_loader: bool = false,

    /// Borrows config contents until `destroy`. Returns a heap Host at a stable
    /// address. Release all V8 handles it made (`destroy`) before `Runtime.destroy`.
    pub fn create(allocator: std.mem.Allocator, config: Config) !*Host {
        const host = try allocator.create(Host);
        host.* = .{ .allocator = allocator, .io = config.io, .args = config.args, .env = config.env, .fs = config.fs, .runtime = config.runtime, .modules = config.modules, .transformers = .{ .entries = config.transformers } };
        return host;
    }

    /// Closes every handle and frees all host records. Must run before
    /// `Runtime.destroy` (it releases V8 persistent handles).
    pub fn destroy(self: *Host) void {
        const alloc = self.allocator;
        if (self.rust_isolate) |isolate| origine_api_detach_isolate(isolate.handle);
        for (self.grants.items) |grant| {
            grant.deinit();
            alloc.destroy(grant);
        }
        self.grants.deinit(alloc);
        for (self.states.items) |state| {
            var remaining = state.module_states.items.len;
            while (remaining > 0) : (remaining -= 1) {
                const owned = state.module_states.items[remaining - 1];
                owned.bindings.destroy(state, owned.ptr);
            }
            state.module_states.deinit(alloc);
            if (state.errno_buffer) |buffer| buffer.deinit();
            alloc.destroy(state);
        }
        self.states.deinit(alloc);
        for (self.children.items) |child| alloc.free(child.main);
        self.children.deinit(alloc);
        for (self.loaders.items) |loader| {
            loader.deinit();
            alloc.destroy(loader);
        }
        self.loaders.deinit(alloc);
        for (self.runs.items) |pending| {
            if (!pending.done) pending.resolver.deinit();
            alloc.destroy(pending);
        }
        self.runs.deinit(alloc);
        alloc.destroy(self);
    }

    /// Installs the natives of the Rust registry (`origine_api_natives_*`) whose requirements the
    /// embedder's configuration meets, as `native.<namespace>.<name>` (the registry's `path`s).
    /// Nothing about the natives is written on the Zig side: names, callbacks and side effects all
    /// come from the `#[native(...)]` attributes in rust/crates/origine_api.
    fn installRustNatives(self: *Host, env: binding.Env, native: v8.Object, state: *ScopeState) !void {
        const has_runtime = self.runtime != null;
        const has_async_fs = has_runtime and self.fs != null and self.fs.?.async;
        const Namespace = struct { name: []const u8, object: v8.Object };
        var namespaces: std.ArrayList(Namespace) = .empty;
        defer namespaces.deinit(self.allocator);
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
            const object = for (namespaces.items) |known| {
                if (std.mem.eql(u8, known.name, namespace)) break known.object;
            } else blk: {
                const created = v8.Object.init(env.isolate);
                try namespaces.append(self.allocator, .{ .name = namespace, .object = created });
                try binding.set(env, native, namespace, created);
                break :blk created;
            };
            const function = binding.rawDynamic(env, state, @ptrCast(entry.callback), side_effect);
            try binding.set(env, object, path[dot + 1 ..], function.object.value);
        }
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
            .enable_origine_namespace = true,
            .resolver = .{ .data = self, .resolve = init_loader.resolve },
            .loader = .{ .data = self, .load = init_loader.load },
            .meta = .{ .data = self, .init = init_loader.meta },
        };
    }

    /// Builds the frozen `api` object in `scope`'s realm. Returns a caller-owned
    /// persistent handle (release before Runtime.destroy). Error details follow
    /// ErrorInfo ownership.
    pub fn install(self: *Host, scope: *Scope, error_info: ?*ErrorInfo) !v8.Global.Of(v8.Value) {
        const state = try self.allocator.create(ScopeState);
        errdefer self.allocator.destroy(state);
        state.* = .{ .host = self, .scope = scope };
        state.errno_cell = &state.errno_local;
        try self.states.append(self.allocator, state);
        var session: Scope.Session = undefined;
        session.init(scope);
        defer session.deinit();
        errdefer session.retainException(error_info);
        const isolate = session.isolate();
        const ctx = session.ctx;
        const env: binding.Env = .{ .isolate = isolate, .ctx = ctx };
        if (self.rust_isolate == null) {
            _ = origine_api_attach_isolate(isolate.handle);
            self.rust_isolate = isolate;
            self.configureRust(isolate);
        }
        // The whole native surface in one table: typed Zig functions, nested objects.
        const native = try binding.object(env, ScopeState, state, .{
            .env = .{
                .args = func(env_api.args, .{ .side_effect = .none }),
                .get = func(env_api.get, .{ .side_effect = .none }),
                .list = func(env_api.list, .{ .side_effect = .none }),
            },
            .fsRequest = func(fs_api.request, .{ .side_effect = .any }),
            .scope = .{
                .create = func(scope_api.create, .{ .side_effect = .any }),
                .preload = func(scope_api.preload, .{ .side_effect = .any }),
                .run = func(scope_api.run, .{ .side_effect = .any }),
                .close = func(scope_api.close, .{ .side_effect = .any }),
            },
        });
        try self.installRustNatives(env, native, state);
        try binding.set(env, native, "errno", try errnoArray(isolate, state));
        try binding.set(env, native, "errors", (try errno_api.table(env)).value);
        const script = v8.Script.compile(ctx, v8.String.initUtf8(isolate, glue_script.source), scope.scriptOrigin(glue_script.origin, false)) orelse return error.JavaScriptException;
        const glue = v8.Function.from_opaque((script.run(ctx) orelse return error.JavaScriptException).data.handle) orelse return error.BootstrapFailed;
        const api = glue.call(ctx, v8.Primitive.initUndefined(isolate).value, &.{native.value}) orelse return error.JavaScriptException;
        try scope.hardenLocal(api);
        return .new(isolate, api);
    }

    /// Lifecycle driver: evaluates `init_specifier` as a module in `scope` (which
    /// must have been created with `initOptions`), then calls its exported `main`
    /// with the root `api` and pumps until it settles. Returns error.InitFailed or
    /// error.MainFailed with the rejection/exception in `error_info`.
    pub fn run(self: *Host, scope: *Scope, platform: v8.Platform, init_specifier: []const u8, error_info: ?*ErrorInfo) !void {
        const rt = scope.runtime;
        const api = try self.install(scope, error_info);
        defer api.deinit();
        const loading = try scope.importModule(init_specifier, error_info);
        defer loading.deinit();
        try self.settle(rt, platform, loading);
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
            const result = main_fn.call(session.ctx, v8.Primitive.initUndefined(session.isolate()).value, &.{api.deref()}) orelse return error.MainFailed;
            break :blk v8.Global.Of(v8.Value).new(session.isolate(), result);
        };
        defer main_result.deinit();
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
    }

    /// Drives the platform, the microtask queue and every I/O runtime until `promise` settles.
    /// Fails with `Stalled` when it is pending and nothing can still make progress.
    fn settle(self: *Host, rt: *Runtime, platform: v8.Platform, promise: v8.Global.Of(v8.Promise)) !void {
        while (true) {
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

/// Builds the guest `Uint32Array(1)` over a sandbox-allocated buffer and points
/// `state.errno_cell` at its memory (the V8 sandbox forbids aliasing host memory). Needs
/// an entered context and live handle scope; the result is a local handle. The memory
/// stays valid until `Host.destroy` because `state.errno_buffer` pins the buffer and the
/// buffer is non-detachable (its detach key is a private object). Seeds the cell with
/// the value already written to `errno_local`.
fn errnoArray(isolate: v8.Isolate, state: *ScopeState) !v8.Value {
    const buffer = v8.ArrayBuffer.newWithByteLength(isolate, @sizeOf(u32)) orelse binding.oom();
    const cell: *u32 = @ptrCast(@alignCast(buffer.data() orelse binding.oom()));
    cell.* = state.errno_local;
    state.errno_cell = cell;
    state.errno_buffer = .new(isolate, buffer);
    buffer.setDetachKey(v8.Object.init(isolate).value);
    const array = v8.Uint32Array.init(buffer, 0, 1) orelse binding.oom();
    return array.typedArray.arrayBufferView.object.value;
}
