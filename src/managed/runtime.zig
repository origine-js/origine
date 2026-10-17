const std = @import("std");
const v8 = @import("@v8");
const modules = @import("module_map.zig");
const module_types = @import("module_types.zig");
const Scope = @import("scope.zig").Scope;
pub const supported_v8_version = "15.2.124.1";

/// Embedder-side isolate host owning zero or more `Scope`s (isolated contexts).
///
/// # Lifetime and ownership rules
/// - A Runtime lives on the heap at a stable address: `create` returns `*Runtime`
///   and `destroy` releases it. It is never copied, so Scopes may point back at it.
/// - A Scope is owned by its Runtime and dies in `destroy`; never free or copy it.
/// - Every `v8.Global` returned by a Scope method (eval results, promises) and every
///   populated `ErrorInfo` is caller-owned and must be `deinit`ed *before* `destroy`.
/// - Host data pointers inside `Scope.Options` (resolver, loader, URL normalizer) are
///   borrowed and must stay valid until `destroy` returns.
/// - Single-threaded: use a Runtime only from the thread that created it.
/// - Public methods enter the isolate and context themselves. Only `Scope.hardenLocal`
///   and callbacks assume the caller already entered; use `Runtime.Session` /
///   `Scope.Session` to do that safely in embedder code.
pub const Runtime = struct {
    pub const Options = struct {
        /// Whether Atomics.wait may block this isolate's thread. Copied at creation;
        /// Atomics and SharedArrayBuffer remain available when false.
        allow_explicit_blocking_api: bool = false,
        /// Default uses V8's native allocator. zig creates a runtime-owned adapter;
        /// its allocator state must be thread-safe and live through Runtime.destroy.
        /// borrowed leaves native allocator ownership with the caller, who must
        /// retain it until the runtime and all its backing stores have been released.
        array_buffer_allocator: union(enum) {
            default,
            zig: std.mem.Allocator,
            borrowed: v8.ArrayBuffer.Allocator,
        } = .default,
    };

    /// RAII guard that enters the isolate and opens a local HandleScope.
    /// Initialize in place (never copy) and pair with `deinit` on the same thread:
    /// `var s: Runtime.Session = undefined; s.init(rt); defer s.deinit();`
    /// Local V8 handles created while it is live die with `deinit`; convert anything
    /// that must outlive it to a `v8.Global` first.
    pub const Session = struct {
        isolate: v8.Isolate,
        h_scope: v8.HandleScope,

        /// Borrows rt only to read its isolate; retains nothing. Enters the isolate
        /// and opens a HandleScope that stays open until `deinit`. Cannot fail.
        pub fn init(self: *Session, rt: *const Runtime) void {
            self.isolate = rt.isolate;
            self.isolate.enter();
            self.h_scope.init(self.isolate);
        }

        /// Closes the HandleScope (invalidating its local handles) and exits the
        /// isolate. Must run on the thread and in the LIFO order of `init`.
        pub fn deinit(self: *Session) void {
            self.h_scope.deinit();
            self.isolate.exit();
        }
    };

    isolate: v8.Isolate,
    array_buffer_allocator: v8.ArrayBuffer.Allocator,
    owns_array_buffer_allocator: bool,
    /// Borrowed metadata allocator; backs Scopes, module maps and load arenas.
    allocator: std.mem.Allocator,
    scopes: std.ArrayList(*Scope) = .empty,
    queue: v8.MicrotaskQueue,
    next_load_token: module_types.LoadToken = 1,

    /// Borrows alloc (and its state) until `destroy` returns; options are copied.
    /// Returns a heap-allocated, owning Runtime at a stable address; release it with
    /// `destroy`. A zig array-buffer adapter becomes runtime-owned, while a borrowed
    /// allocator stays caller-owned and may outlive the runtime. With an owned
    /// allocator, release all backing stores before `destroy`.
    /// Errors (UnsupportedV8Version, OutOfMemory, adapter failure) retain nothing.
    /// V8 OOM during isolate creation is fatal and does not return. V8 must already
    /// be initialized.
    pub fn create(alloc: std.mem.Allocator, options: Options) !*Runtime {
        try checkV8Version();
        const rt = try alloc.create(Runtime);
        errdefer alloc.destroy(rt);
        const aba = switch (options.array_buffer_allocator) {
            .default => v8.ArrayBuffer.Allocator.initDefault(),
            .zig => |backing_alloc| try v8.ArrayBuffer.Allocator.fromZig(backing_alloc),
            .borrowed => |provided| provided,
        };
        var params = v8.Isolate.CreateParams.init();
        params.array_buffer_allocator = aba;
        params.allow_explicit_blocking_api = options.allow_explicit_blocking_api;
        const isolate = v8.Isolate.init(&params);
        isolate.enter();
        defer isolate.exit();
        isolate.setMicrotasksPolicy(.Explicit);
        isolate.setHostImportModuleDynamicallyCallback(modules.dynamic);
        isolate.setHostImportModuleWithPhaseDynamicallyCallback(modules.dynamicPhase);
        isolate.setHostInitializeImportMetaObjectCallback(modules.importMeta);
        rt.* = .{
            .isolate = isolate,
            .array_buffer_allocator = aba,
            .owns_array_buffer_allocator = options.array_buffer_allocator != .borrowed,
            .allocator = alloc,
            .queue = .init(isolate, .Explicit),
        };
        return rt;
    }

    /// Consumes and frees the Runtime and every Scope it owns; self is invalid after.
    /// Cancels pending loads, rejects pending import promises, and frees runtime-owned
    /// slices, cloned import maps and Scope handles (invalidating borrowed request
    /// bytes). Caller-owned Globals and ErrorInfos must already be released. Never
    /// frees callback data. Disposes the isolate, then releases an owned backing-store
    /// allocator (a borrowed one is untouched). Must run on the creating thread.
    pub fn destroy(self: *Runtime) void {
        const alloc = self.allocator;
        {
            var session: Session = undefined;
            session.init(self);
            defer session.deinit();
            for (self.scopes.items) |scope| scope.destroy();
            self.scopes.deinit(alloc);
            self.queue.deinit();
        }
        self.isolate.deinit();
        if (self.owns_array_buffer_allocator) self.array_buffer_allocator.deinit();
        alloc.destroy(self);
    }

    /// Fails with UnsupportedV8Version unless the linked V8 matches supported_v8_version.
    /// Accepts and returns values; retains no resources.
    fn checkV8Version() !void {
        const version = v8.V8.getVersion();
        var numeric_end: usize = 0;
        while (numeric_end < version.len and (std.ascii.isDigit(version[numeric_end]) or version[numeric_end] == '.')) : (numeric_end += 1) {}
        // V8 appends an embedder suffix (this build uses "-lightpanda").
        if (!std.mem.eql(u8, version[0..numeric_end], supported_v8_version)) return error.UnsupportedV8Version;
    }

    /// Borrows options through return and callback state through destroy; returns a
    /// runtime-owned Scope. Errors clean up partial state and leave self unchanged.
    /// See Scope.create for nested map, handle and tracing lifetime requirements.
    pub fn createScope(self: *Runtime, options: Scope.Options) !*Scope {
        return Scope.create(self, options);
    }

    /// Runs microtask checkpoints and drives pending module loads in every Scope until
    /// no further progress is made. Enters the isolate and each context itself.
    /// Borrows nothing from callers; loader callbacks run synchronously inside and
    /// must not call createScope or destroy. Guest code may queue new import tasks.
    pub fn pump(self: *Runtime) void {
        var session: Session = undefined;
        session.init(self);
        defer session.deinit();
        while (true) {
            self.queue.performCheckpoint(self.isolate);
            var progress = false;
            // Guest execution can create import tasks, but cannot create scopes.
            for (self.scopes.items) |scope| {
                const ctx = scope.context.deref();
                ctx.enter();
                progress = scope.module_map.drive() or progress;
                ctx.exit();
            }
            if (!progress) break;
        }
    }

    /// Drains V8 foreground tasks from the borrowed platform with the isolate entered,
    /// then runs `pump`. The platform must outlive the call; nothing is retained.
    pub fn pumpPlatform(self: *Runtime, platform: v8.Platform) void {
        var session: Session = undefined;
        session.init(self);
        defer session.deinit();
        while (platform.pumpMessageLoop(self.isolate, false)) {}
        self.pump();
    }

    /// Complete on the owning isolate thread, after the loader callback has returned.
    /// Borrows content/nested names/handles through return (including errors).
    /// Accepted strings/handles are copied/retained independently. Caller may free
    /// buffers and release its handles after return. Handles must belong to this runtime.
    /// Fails with StaleLoadToken when no scope has a pending load for token.
    pub fn completeLoad(self: *Runtime, token: module_types.LoadToken, completion: module_types.Completion) !void {
        var session: Session = undefined;
        session.init(self);
        defer session.deinit();
        for (self.scopes.items) |scope| {
            const ctx = scope.context.deref();
            ctx.enter();
            defer ctx.exit();
            if (try scope.module_map.complete(token, completion)) return;
        }
        return error.StaleLoadToken;
    }
};
