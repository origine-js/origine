//! The `Host`: owner of everything the guest-visible `api` hands out (grants, child
//! scopes, loaders) and driver of the init -> `main(api)` lifecycle.
//!
//! The Zig host owns all authority. Guest code only holds native functions whose V8
//! External data points at a grant or per-scope state record, plus plain descriptors
//! that name things inside one grant. `src/js/api.js` shapes the surface; every native
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
const origine_modules = @import("origine_modules.zig");
const module_api = @import("module.zig");
const JsLoader = @import("js_loader.zig").JsLoader;
const Runtime = @import("../managed/runtime.zig").Runtime;
const Scope = @import("../managed/scope.zig").Scope;
const ErrorInfo = @import("../managed/errors.zig").ErrorInfo;

const glue_source = @embedFile("../js/api.js");

/// What the host grants to `fs.request`. `root` is borrowed and must outlive the Host.
pub const FsConfig = struct {
    root: std.Io.Dir,
    write: bool = true,
    sync: bool = true,
};

pub const Config = struct {
    io: std.Io,
    args: []const []const u8 = &.{},
    env: []const env_api.Pair = &.{},
    fs: ?FsConfig = null,
    /// Embedded `origine:` modules the init scope serves. Static storage, borrowed until
    /// `destroy`. Tests substitute their own to exercise module-owned state.
    modules: []const module_api.Module = &origine_modules.all,
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
    modules: []const module_api.Module,
    grants: std.ArrayList(*fs_api.FsGrant) = .empty,
    states: std.ArrayList(*ScopeState) = .empty,
    children: std.ArrayList(scope_api.Child) = .empty,
    loaders: std.ArrayList(*JsLoader) = .empty,
    runs: std.ArrayList(*scope_api.RunState) = .empty,
    next_fs_id: u32 = 1,
    /// True while a JS loader callback runs inside Runtime.pump's scope iteration;
    /// creating a scope then would invalidate that iteration.
    in_loader: bool = false,

    /// Borrows config contents until `destroy`. Returns a heap Host at a stable
    /// address. Release all V8 handles it made (`destroy`) before `Runtime.destroy`.
    pub fn create(allocator: std.mem.Allocator, config: Config) !*Host {
        const host = try allocator.create(Host);
        host.* = .{ .allocator = allocator, .io = config.io, .args = config.args, .env = config.env, .fs = config.fs, .modules = config.modules };
        return host;
    }

    /// Closes every handle and frees all host records. Must run before
    /// `Runtime.destroy` (it releases V8 persistent handles).
    pub fn destroy(self: *Host) void {
        const alloc = self.allocator;
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
        try binding.set(env, native, "errno", try errnoArray(isolate, state));
        try binding.set(env, native, "errors", (try errno_api.table(env)).value);
        const script = v8.Script.compile(ctx, v8.String.initUtf8(isolate, glue_source), scope.scriptOrigin("engine:api.js", false)) orelse return error.JavaScriptException;
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
        try settle(rt, platform, loading);
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
            try settle(rt, platform, promise);
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

    fn settle(rt: *Runtime, platform: v8.Platform, promise: v8.Global.Of(v8.Promise)) !void {
        while (true) {
            rt.pumpPlatform(platform);
            var session: Runtime.Session = undefined;
            session.init(rt);
            defer session.deinit();
            if (promise.deref().state() != .Pending) return;
            // pump returned with nothing left to run: the promise can never settle.
            if (!platform.pumpMessageLoop(rt.isolate, false)) return error.Stalled;
        }
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
