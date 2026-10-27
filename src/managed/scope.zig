const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const Runtime = @import("runtime.zig").Runtime;
const modules = @import("module_map.zig");
const module_types = @import("module_types.zig");
const import_map = @import("import_map.zig");
const ErrorInfo = @import("errors.zig").ErrorInfo;
const captureException = @import("errors.zig").captureException;
const init_snapshot = @import("init_snapshot.zig");
const startup_trace = @import("@diagnostics").scope;

/// One isolated JS context (global object, module map, capabilities) in a Runtime.
/// Runtime-owned: obtain via `Runtime.createScope`; it is freed by `Runtime.destroy`.
pub const Scope = struct {
    /// Borrows options (and options.import_map) only through return; map entries are
    /// cloned. Callback descriptors are copied but their data pointers remain
    /// host-owned and must stay alive until `Runtime.destroy` returns. Returns a runtime-owned
    /// Scope: never free/copy it, and do not use it once `Runtime.destroy` begins.
    /// With V8_STARTUP_TRACE set, retains only static timing labels in a bounded
    /// thread-local buffer until startup_trace.report; errors retain partial timings.
    /// Errors release persistent handles, cloned maps and partial scope state, and
    /// leave the Runtime unchanged.
    pub fn create(rt: *Runtime, options: Options) !*Scope {
        var timing = startup_trace.begin();
        var session: Runtime.Session = undefined;
        session.init(rt);
        defer session.deinit();
        const isolate = rt.isolate;
        const scope = try rt.allocator.create(Scope);
        errdefer rt.allocator.destroy(scope);
        // A restored init context comes from the runtime's own snapshot blob, which must be the
        // one the table was created for; `Context.fromSnapshot` cannot check that.
        const ctx = if (options.init_snapshot) |table|
            v8.Context.fromSnapshot(isolate, table.context_index, null, rt.queue) orelse return error.InvalidSnapshot
        else
            v8.Context.init(isolate, null, null, rt.queue);
        startup_trace.mark(&timing, "context_create");
        const id = rt.next_scope_id;
        rt.next_scope_id += 1;
        scope.* = .{ .runtime = rt, .id = id, .context = .new(isolate, ctx), .options = options };
        errdefer scope.context.deinit();
        scope.module_map = .init(scope);
        // Entered like Scope.destroy: the map's teardown may reject pending tasks in this context.
        errdefer {
            ctx.enter();
            scope.module_map.deinit();
            ctx.exit();
        }
        if (options.import_map) |provided| {
            if (options.resolver != null) return error.ConflictingResolvers;
            const map = try rt.allocator.create(import_map.ImportMap);
            errdefer rt.allocator.destroy(map);
            map.* = try provided.clone(rt.allocator);
            scope.import_map = map;
            scope.options.resolver = map.resolver();
        }
        errdefer if (scope.import_map) |map| {
            map.deinit();
            rt.allocator.destroy(map);
        };
        // Retain only our independent copy, not the caller's map pointer.
        scope.options.import_map = null;
        ctx.setSecurityToken(eu.v.symbol(isolate, null).name.primitive.value);
        ctx.setAlignedPointerInEmbedderData(1, scope);
        ctx.enter();
        defer ctx.exit();
        ctx.setStackTraceLimit(options.stack_trace_limit);
        var tc_scope: v8.TryCatch = undefined;
        tc_scope.init(isolate);
        defer tc_scope.deinit();
        startup_trace.mark(&timing, "scope_host_setup");
        // A restored context already has the bootstrap helpers; only the helpers'
        // handles and the module map are per-scope Zig state.
        const helpers = if (options.init_snapshot) |table| try scope.restore(ctx, table) else try scope.bootstrap(ctx, &timing);
        scope.hardener = helpers.hardener;
        errdefer scope.hardener.deinit();
        scope.unsupported_prototype = helpers.unsupported_prototype;
        errdefer scope.unsupported_prototype.deinit();
        ctx.allowCodeGenerationFromStrings(false);
        try rt.scopes.append(rt.allocator, scope);
        startup_trace.mark(&timing, "scope_finalize");
        return scope;
    }

    /// Borrows self through a session on the runtime thread. Returns the native
    /// context setting by value; retains no resources and invokes no JavaScript.
    pub fn getStackTraceLimit(self: *Scope) v8.StackTraceLimit {
        var session: Session = undefined;
        session.init(self);
        defer session.deinit();
        return session.ctx.getStackTraceLimit();
    }

    /// Copies limit into the native context on the runtime thread. Enters the
    /// context for the call; retains no caller resources or exception values.
    pub fn setStackTraceLimit(self: *Scope, limit: v8.StackTraceLimit) void {
        var session: Session = undefined;
        session.init(self);
        defer session.deinit();
        session.ctx.setStackTraceLimit(limit);
    }

    /// Picks the bootstrap helpers and the module graph out of a restored context. Requires
    /// ctx entered and a live HandleScope. On error nothing is retained (the module map is
    /// discarded with the scope). Borrows table through return.
    fn restore(self: *Scope, ctx: v8.Context, table: *const init_snapshot.Table) !Helpers {
        const isolate = self.runtime.isolate;
        const hardener = ctx.getDataFromSnapshotOnce(table.hardener_index) orelse return error.InvalidSnapshot;
        const unsupported = ctx.getDataFromSnapshotOnce(table.unsupported_index) orelse return error.InvalidSnapshot;
        const hardener_fn = v8.Function.from_opaque(hardener.handle) orelse return error.InvalidSnapshot;
        const unsupported_fn = v8.Function.from_opaque(unsupported.handle) orelse return error.InvalidSnapshot;
        try self.module_map.restoreModules(table.modules);
        return .{ .hardener = .new(isolate, hardener_fn), .unsupported_prototype = .new(isolate, unsupported_fn) };
    }

    const Helpers = struct {
        hardener: v8.Global.Of(v8.Function),
        unsupported_prototype: v8.Global.Of(v8.Function),
    };

    /// Restores snapshot-prepared helpers, initializing them only without a template.
    /// Requires ctx entered and a live HandleScope. Borrows self/ctx/timing through
    /// return; returns two caller-owned persistent functions, released by Scope.destroy.
    /// Errors retain no persistent handles; helper JS storage remains context-owned.
    fn bootstrap(self: *Scope, ctx: v8.Context, timing: *?i64) !Helpers {
        const isolate = self.runtime.isolate;
        const helper = (try @import("bootstrap.zig").prepare(isolate, ctx, timing)).object;
        const hardener = helper.getIndex(ctx, 0) orelse return error.BootstrapFailed;
        const unsupported = helper.getIndex(ctx, 1) orelse return error.BootstrapFailed;
        const hardener_fn = v8.Function.from_opaque(hardener.data.handle) orelse return error.BootstrapFailed;
        const unsupported_fn = v8.Function.from_opaque(unsupported.data.handle) orelse return error.BootstrapFailed;
        return .{ .hardener = .new(isolate, hardener_fn), .unsupported_prototype = .new(isolate, unsupported_fn) };
    }

    pub const Options = struct {
        /// Copied into the native context at creation. Affects future captures;
        /// guest JavaScript cannot read or change this setting.
        stack_trace_limit: v8.StackTraceLimit = .{ .limited = 10 },
        /// Optional specifier rewriting before module-map lookup. Without a resolver
        /// or import map, specifiers are used unchanged as module-map keys.
        resolver: ?module_types.Resolver = null,
        loader: ?module_types.Loader = null,
        /// Makes module IDs starting with `origine:` (the host's own namespace) usable from
        /// code in this scope: static and dynamic imports, whether the specifier or the
        /// resolved ID carries the prefix. Off by default, in which case such imports
        /// reject no matter what the resolver, import map or loader would have served.
        /// The host decides which scopes get it; guest code cannot change it.
        origine_namespace: bool = false,
        /// Optional hook that populates each module's `import.meta`; the one way to give
        /// specific modules host values that no importer or other module can reach.
        meta: ?module_types.MetaInitializer = null,
        /// Per-scope specifier-to-specifier import map, applied before module-map lookup.
        /// Borrows the map through createScope only; entries are cloned per scope.
        /// Caller may reuse/deinit it afterward. URLNormalizer.data remains host-owned
        /// and must stay alive through Runtime.destroy. Do not mutate a scope's copy.
        import_map: ?*const import_map.ImportMap = null,
        /// Restores the init scope of an `init_snapshot` instead of creating a fresh context.
        /// The Runtime must have been created from that snapshot's blob. Borrowed through
        /// createScope; module IDs, attributes and strings are copied.
        init_snapshot: ?*const init_snapshot.Table = null,
        /// Optional persistence of V8 code caches for this scope's source modules; see
        /// `module_types.CodeCache` and `flushCodeCache`. Callback data is host-owned and must
        /// stay alive until Runtime.destroy returns. V8 only accepts a cache in an isolate
        /// booted from the same startup blob as the one that produced it, so a host that
        /// changes blobs (a rebuilt init snapshot) sees one round of rejected caches, which
        /// are then replaced.
        code_cache: ?module_types.CodeCache = null,
        /// Called when the scope is freed after `Runtime.disposeScope`, with its context entered
        /// and before its module map goes: the host releases what it keeps for the scope. Not
        /// called by `Runtime.destroy`, which hosts tear down first. Callback data is host-owned.
        on_dispose: ?Disposer = null,
    };

    pub const Disposer = struct {
        data: ?*anyopaque = null,
        call: *const fn (data: ?*anyopaque, scope: *Scope) void,
    };

    /// RAII guard that makes a Scope's context current: enters the isolate, opens a
    /// HandleScope, enters the context and installs a TryCatch. Initialize in place
    /// (never copy) and pair with `deinit`:
    /// `var s: Scope.Session = undefined; s.init(scope); defer s.deinit();`
    /// Local handles created under it die with `deinit`. Capture exceptions with
    /// `errdefer s.retainException(error_info)` declared after the `defer`.
    pub const Session = struct {
        runtime_session: Runtime.Session,
        ctx: v8.Context,
        tc_scope: v8.TryCatch,

        /// Borrows scope through the guard's lifetime; scope must outlive it. Cannot fail.
        pub fn init(self: *Session, scope: *const Scope) void {
            self.runtime_session.init(scope.runtime);
            self.ctx = scope.context.deref();
            self.ctx.enter();
            self.tc_scope.init(self.runtime_session.isolate);
        }

        /// Pops the TryCatch, exits the context, then closes the HandleScope and
        /// isolate, in that order. Invalidates all local handles made under the guard.
        pub fn deinit(self: *Session) void {
            self.tc_scope.deinit();
            self.ctx.exit();
            self.runtime_session.deinit();
        }

        /// The isolate entered by this guard; valid until `deinit`.
        pub fn isolate(self: *const Session) v8.Isolate {
            return self.runtime_session.isolate;
        }

        /// Copies the pending TryCatch exception into error_info (caller-owned, see
        /// ErrorInfo) when it is non-null and its slot is empty. Retains nothing else.
        pub fn retainException(self: *const Session, error_info: ?*ErrorInfo) void {
            captureException(self.runtime_session.isolate, &self.tc_scope, error_info);
        }
    };

    runtime: *Runtime,
    id: usize,
    context: v8.Global.Of(v8.Context),
    options: Options,
    hardener: v8.Global.Of(v8.Function) = undefined,
    unsupported_prototype: v8.Global.Of(v8.Function) = undefined,
    /// Owns resolved-specifier/attribute -> V8 module mappings and their load/cache state.
    /// Runtime-owned; use module_map.update/delete/clear/get, never copy or deinit it.
    module_map: modules.ModuleMap = undefined,
    import_map: ?*import_map.ImportMap = null,
    /// Set by `Runtime.disposeScope`. A disposed scope refuses new work (`error.ScopeDisposed`) and is
    /// skipped by the runtime's drivers until it is freed.
    disposed: bool = false,

    pub fn isDisposed(self: *const Scope) bool {
        return self.disposed;
    }

    /// Frees this Scope's module map, persistent handles, cloned import map and the
    /// Scope allocation itself. Called only from Runtime.destroy with the isolate
    /// entered and a live HandleScope; self is invalid afterwards.
    pub fn destroy(self: *Scope) void {
        self.teardown(false);
    }

    /// Frees a scope disposed with `Runtime.disposeScope`, after the host released its resources.
    /// Called only from `Runtime.reap` with the isolate entered and a live HandleScope.
    pub fn reapDisposed(self: *Scope) void {
        self.teardown(true);
    }

    fn teardown(self: *Scope, notify: bool) void {
        const alloc = self.runtime.allocator;
        const ctx = self.context.deref();
        ctx.enter();
        if (notify) if (self.options.on_dispose) |hook| hook.call(hook.data, self);
        self.module_map.deinit();
        // A stray reference into the context (a function another realm kept) must find no scope.
        ctx.setAlignedPointerInEmbedderData(1, null);
        ctx.exit();
        self.hardener.deinit();
        self.unsupported_prototype.deinit();
        if (self.import_map) |map| {
            map.deinit();
            alloc.destroy(map);
        }
        self.context.deinit();
        alloc.destroy(self);
    }

    /// Deep-freeze a supported public graph. Hidden closure/private state is intentionally untouched.
    /// Borrows this-runtime persistent handle without consuming it; freezes its graph
    /// in place. Caller owns the handle and must release it before Runtime.destroy.
    /// error_info follows ErrorInfo ownership; also captures UnsupportedExport exceptions.
    pub fn harden(self: *Scope, value: v8.Global.Of(v8.Value), error_info: ?*ErrorInfo) !void {
        if (error_info) |out| out.deinit();
        if (self.disposed) return error.ScopeDisposed;
        var session: Session = undefined;
        session.init(self);
        defer session.deinit();
        errdefer session.retainException(error_info);
        try self.hardenLocal(value.deref());
    }

    /// Borrows a local handle only through the call. Caller keeps its HandleScope
    /// live and this context entered (e.g. via Scope.Session). Does not retain the
    /// handle; freezes in place. Fails with UnsupportedExport on unsupported graphs.
    pub fn hardenLocal(self: *Scope, value: v8.Value) !void {
        const isolate = self.runtime.isolate;
        const ctx = self.context.deref();
        const validator = v8.Function.init(ctx, supportedExport, eu.v.external(isolate, self.runtime).value.data, 1, .Throw, .HasNoSideEffect);
        _ = self.hardener.deref().call(ctx, eu.v.undefined_value(isolate).value, &.{ value, validator.object.value }) orelse return error.UnsupportedExport;
    }

    /// Borrows origin through this call; V8 copies the UTF-8 bytes. Result uses local
    /// handles: caller needs this isolate entered and a live HandleScope, and must
    /// consume the metadata before that HandleScope ends.
    pub fn scriptOrigin(self: *Scope, origin: []const u8, module: bool) v8.ScriptOrigin {
        const iso = self.runtime.isolate;
        const options = v8.PrimitiveArray.init(iso, 1);
        options.set(iso, 0, eu.v.num_u32(iso, @intCast(self.id)).numeric.primitive);
        return .init(eu.v.str_utf8(iso, origin).name.primitive.value, 0, 0, false, -1, null, false, false, module, options.data);
    }

    /// Stores the V8 code cache of every module that compiled without one through
    /// `Options.code_cache.store`. Call once the scope's code has run, so lazily compiled
    /// functions are included. Enters the context itself; returns the number stored and
    /// retains nothing.
    pub fn flushCodeCache(self: *Scope) usize {
        var session: Session = undefined;
        session.init(self);
        defer session.deinit();
        return self.module_map.flushCodeCache();
    }

    /// Borrows specifier through return, even for pending loads; retained IDs are
    /// copied. Caller may free/reuse input afterward. Returns a caller-owned persistent
    /// promise; deinit it before Runtime.destroy. No input ownership transfer.
    /// error_info follows ErrorInfo ownership for synchronous exceptions only;
    /// ordinary module failures are returned as promise rejections.
    pub fn importModule(self: *Scope, specifier: []const u8, error_info: ?*ErrorInfo) !v8.Global.Of(v8.Promise) {
        return self.importModuleWithAttributes(specifier, &.{}, error_info);
    }

    /// Retire this canonical module ID/attribute set and its cached dependents.
    /// Compatibility entry point for module_map.delete; modifies the same ModuleMap.
    /// Borrows key/attribute array/nested strings through return, including errors.
    /// Caller may free/reuse them afterward. Returns a count, not owned memory.
    pub fn deleteImportCache(self: *Scope, key: module_types.ImportCacheKey) !usize {
        return self.mutateImportCache(.{ .delete = key }, null);
    }

    /// Replace/insert module content for future imports; existing graphs retain their instances.
    /// Compatibility entry point for module_map.update; modifies the same ModuleMap.
    /// Borrows key/attributes/source/export array/names/handles through return,
    /// including errors. Retained strings/handles are independently copied. Caller
    /// may free/reuse inputs and release its handles afterward. No ownership transfer;
    /// all handles must belong to this runtime.
    /// error_info follows ErrorInfo ownership and captures compilation/hardening exceptions.
    pub fn updateImportCache(self: *Scope, key: module_types.ImportCacheKey, content: module_types.Content, error_info: ?*ErrorInfo) !void {
        _ = try self.mutateImportCache(.{ .update = .{ .key = key, .content = content } }, error_info);
    }

    /// Returns a count; no caller-owned memory is freed. Existing references remain valid.
    /// Compatibility entry point for module_map.clear; modifies the same ModuleMap.
    pub fn clearImportCache(self: *Scope) !usize {
        return self.mutateImportCache(.clear, null);
    }

    const CacheMutation = union(enum) {
        delete: module_types.ImportCacheKey,
        update: struct { key: module_types.ImportCacheKey, content: module_types.Content },
        clear,
    };

    /// Applies one cache mutation inside a Session. Borrows operation payloads and
    /// error_info (ErrorInfo ownership rules) through return; retains copies only as
    /// the ModuleMap documents. Returns the retired-entry count (0 for update).
    fn mutateImportCache(self: *Scope, operation: CacheMutation, error_info: ?*ErrorInfo) !usize {
        if (error_info) |out| out.deinit();
        if (self.disposed) return error.ScopeDisposed;
        var session: Session = undefined;
        session.init(self);
        defer session.deinit();
        errdefer session.retainException(error_info);
        return switch (operation) {
            .delete => |key| try self.module_map.deleteCache(key),
            .clear => try self.module_map.clearCache(),
            .update => |update| blk: {
                try self.module_map.updateCache(update.key, update.content, error_info);
                break :blk 0;
            },
        };
    }

    /// Borrows specifier/attributes/nested strings through return, including errors.
    /// Retained metadata is deep-copied, including pending loads. Caller may free/reuse
    /// inputs afterward. Returns a caller-owned persistent promise; deinit it before
    /// Runtime.destroy. No input ownership transfer.
    /// error_info follows ErrorInfo ownership for synchronous exceptions only;
    /// resolution/link/evaluation failures normally reject the returned promise instead.
    pub fn importModuleWithAttributes(self: *Scope, specifier: []const u8, attributes: []const module_types.ImportAttribute, error_info: ?*ErrorInfo) !v8.Global.Of(v8.Promise) {
        if (error_info) |out| out.deinit();
        if (self.disposed) return error.ScopeDisposed;
        var session: Session = undefined;
        session.init(self);
        defer session.deinit();
        errdefer session.retainException(error_info);
        return .new(session.isolate(), try self.module_map.start(specifier, "", attributes));
    }

    /// Borrows name/handle through return. V8 copies name and retains the value;
    /// caller may free name/release its handle afterward. Freezes the graph in place.
    /// Does not consume the caller's handle; it must belong to this runtime.
    /// error_info follows ErrorInfo ownership, including hardening failures.
    pub fn installCapability(self: *Scope, name: []const u8, value: v8.Global.Of(v8.Value), error_info: ?*ErrorInfo) !void {
        if (self.disposed) return error.ScopeDisposed;
        try self.harden(value, error_info);
        var session: Session = undefined;
        session.init(self);
        defer session.deinit();
        errdefer session.retainException(error_info);
        const isolate = session.isolate();
        const ok = session.ctx.getGlobal().defineOwnProperty(session.ctx, eu.v.str_utf8(isolate, name).name, value.deref(), .{ .ReadOnly = true, .DontDelete = true }) orelse return error.JavaScriptException;
        if (!ok) return error.CapabilityInstallationFailed;
    }

    /// Borrows source/origin through return, including errors; V8 copies their bytes.
    /// Caller may free/reuse inputs afterward. No source-rewrite allocation or input
    /// ownership transfer. Returns a caller-owned persistent handle; deinit it before
    /// Runtime.destroy.
    /// error_info follows ErrorInfo ownership; captures syntax errors and thrown
    /// values on JavaScriptException. Pass null to discard the exception value.
    pub fn eval(self: *Scope, source: []const u8, origin: []const u8, error_info: ?*ErrorInfo) !v8.Global.Of(v8.Value) {
        if (error_info) |out| out.deinit();
        if (self.disposed) return error.ScopeDisposed;
        var session: Session = undefined;
        session.init(self);
        defer session.deinit();
        errdefer session.retainException(error_info);
        const isolate = session.isolate();
        const script_origin = self.scriptOrigin(origin, false);
        const script = v8.Script.compile(session.ctx, eu.v.str_utf8(isolate, source), script_origin) orelse return error.JavaScriptException;
        const result = script.run(session.ctx) orelse return error.JavaScriptException;
        return .new(isolate, result);
    }
};

/// V8 callback for `hardenLocal`. Borrows info and its External data (the stable
/// *Runtime) for the call; the callback state is not retained. Sets the return value
/// to whether the argument belongs to a managed context and is a supported export kind.
fn supportedExport(info: v8.FunctionCallbackInfo) callconv(.c) void {
    const rt: *Runtime = @ptrCast(@alignCast(v8.External.from_opaque(info.data().?.handle).?.pointer()));
    const value = info.get_arg(0);
    var result = info.retval();
    result.setBool(false);
    if (value.isProxy() or value.isExternal() or value.isDate() or value.isRegExp() or
        value.isMap() or value.isSet() or value.isWeakMap() or value.isWeakSet() or
        value.isArrayBuffer() or value.isArrayBufferView() or value.isSharedArrayBuffer() or
        value.isPromise() or value.isGeneratorObject() or value.isMapIterator() or value.isSetIterator() or
        value.isModuleNamespaceObject() or value.isWasmModuleObject() or value.isWasmMemoryObject() or
        value.isArgumentsObject() or value.isNativeError() or value.isBooleanObject() or
        value.isNumberObject() or value.isStringObject() or value.isSymbolObject() or value.isBigIntObject()) return;
    if (value.isObject()) {
        const object = value.toObject(rt.isolate.getCurrentContext()) orelse return;
        const origin = object.getCreationContext() orelse return;
        var managed = false;
        for (rt.scopes.items) |scope| {
            const ctx = scope.context.deref();
            if (ctx.getGlobal().value.strictEquals(value)) return;
            if (ctx.eq(origin)) managed = true;
            const unsupported = scope.unsupported_prototype.deref().call(ctx, eu.v.undefined_value(rt.isolate).value, &.{value}) orelse return;
            if (unsupported.isTrue()) return;
        }
        if (!managed) return;
    }
    result.setBool(true);
}
