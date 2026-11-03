//! Borrowing contracts for resolution, loading and module content.
const std = @import("std");
const v8 = @import("@v8");

/// UTF-8 logical module identity. This alias does not imply ownership;
/// the containing request, result, or function documents the slice lifetime.
pub const ModuleId = []const u8;
/// Module IDs with this prefix are the host's namespace; scopes opt in through
/// `Scope.Options.origine_namespace`.
pub const origine_prefix = "origine:";
/// Caller-owned key. Public cache operations borrow it, including nested strings,
/// only until the operation returns; they never take ownership of caller memory.
/// `namespace` names the table the module lives in: a host may keep several side by side in one scope
/// (`Resolver.namespace_of`); 0 is the only one for a scope that does not.
pub const ModuleMapKey = struct { module_id: ModuleId, import_attributes: []const ImportAttribute = &.{}, namespace: u32 = 0 };
/// Compatibility alias. Cache entries are entries in the per-scope ModuleMap.
pub const ImportCacheKey = ModuleMapKey;
/// Borrowed UTF-8 key/value strings; the containing API defines their lifetime.
pub const ImportAttribute = struct { key: []const u8, value: []const u8 };
/// Names a pending load or resolution; unique per runtime.
pub const LoadToken = u64;
pub const ResolveRequest = struct {
    /// Allocate the returned canonical ID here, synchronously on the isolate thread.
    /// This alloc is borrowed for the callback only; never retain it/use off-thread.
    allocator: std.mem.Allocator,
    /// Borrowed entered context, valid only during the callback.
    context: v8.Context,
    scope_id: usize,
    /// Request strings and attributes are borrowed only during the callback.
    specifier: []const u8,
    referrer: ModuleId,
    /// The table `referrer` lives in (see `Resolver.namespace_of`).
    referrer_namespace: u32 = 0,
    import_attributes: []const ImportAttribute = &.{},
    /// Names this request when `Resolver.resolve_async` answers `.pending`; later passed to
    /// `Runtime.completeResolve`. Unique among pending loads and resolutions of the runtime.
    token: LoadToken = 0,
};
/// What an asynchronous resolver answers: the id now, or `.pending` after keeping `request.token`.
pub const ResolveOutcome = union(enum) { id: ModuleId, pending };
pub const Resolver = struct {
    /// Host-owned state, borrowed without destruction; must outlive Runtime.destroy.
    data: ?*anyopaque = null,
    /// Return canonical ID bytes owned by request.allocator, never input aliases.
    /// Release temporaries on success and clean up on failure.
    /// Ownership of the result transfers to the runtime on success. Never return
    /// static/stack bytes, freed storage, or memory from a different alloc.
    /// Not called when `resolve_async` is set.
    resolve: *const fn (data: ?*anyopaque, request: ResolveRequest) anyerror!ModuleId = unsupportedSync,
    /// Optional asynchronous variant, used instead of `resolve`. It either returns the id (as
    /// `resolve` does) or `.pending`, keeping only `request.token` and copies of the request
    /// strings (they are borrowed for the call). The module that asked waits, and so does every
    /// import that depends on it, until `Runtime.completeResolve` settles the token. Like loader
    /// callbacks, it runs on the isolate thread and must not create scopes.
    resolve_async: ?*const fn (data: ?*anyopaque, request: ResolveRequest) anyerror!ResolveOutcome = null,
    /// Called during Runtime.destroy or scope teardown for tokens still pending. `data` is still borrowed.
    cancel: ?*const fn (data: ?*anyopaque, token: LoadToken) void = null,
    /// Which table the modules that `referrer` (in table `referrer_namespace`; the empty id is a root import)
    /// imports live in. The same id imported through two tables is two modules. Without it every
    /// module lives in table 0.
    namespace_of: ?*const fn (data: ?*anyopaque, referrer_namespace: u32, referrer: ModuleId) u32 = null,
};
fn unsupportedSync(_: ?*anyopaque, _: ResolveRequest) anyerror!ModuleId {
    return error.AsyncResolverOnly;
}
/// Borrowed inputs, like `Completion`: nothing is accessed after `completeResolve` returns.
pub const ResolveCompletion = union(enum) {
    /// The canonical id; copied.
    id: ModuleId,
    failure: anyerror,
    exception: v8.Global.Of(v8.Value),
    /// Fails with an `Error` created in the importing module's realm carrying this message.
    message: []const u8,
};
/// name is borrowed UTF-8; value is a borrowed persistent handle from this runtime.
/// The receiving content API copies the name and retains its own handle. `harden` (the default) deep-freezes
/// the value when the module is made, so a native producer cannot hand over a mutable object; a producer that
/// hands over an object it shares on purpose (`ImportHook.exports`) turns it off and the value is used as it is.
pub const Export = struct { name: []const u8, value: v8.Global.Of(v8.Value), harden: bool = true };
/// All slices, nested export names, and handles are borrowed until the receiving
/// updateImportCache/completeLoad call returns (success or error). No ownership is
/// transferred. Source is copied into V8; export names and handles are retained.
/// Source text as an external V8 string: nothing is copied into the V8 heap. `string` is a local handle
/// that owns the memory (its finalizer releases it); `text` is the same bytes, valid while `string` is.
pub const External = struct { text: []const u8, string: v8.String };

pub const Content = union(enum) {
    source: []const u8,
    /// Source text V8 reads in place (see `External`).
    external: External,
    exports: []const Export,
    /// A module already instantiated (and usually evaluated) in another context of the same
    /// isolate, linked into this graph as it is: live bindings, the other realm's own objects.
    /// A local handle, retained by the map. Never snapshottable.
    module: v8.Module,
};
pub const LoadRequest = struct {
    /// Runtime-owned arena for result source/exports/names. Do not free result
    /// allocations; use the alloc only synchronously inside this callback.
    /// Do not retain its alloc handle or use it from another thread.
    allocator: std.mem.Allocator,
    /// Borrowed entered context; valid only during the loader callback.
    context: v8.Context,
    scope_id: usize,
    /// Runtime-owned immutable bytes, valid until Runtime.destroy begins.
    module_id: ModuleId,
    /// The table the module lives in (see `Resolver.namespace_of`).
    namespace: u32 = 0,
    token: LoadToken,
    /// Runtime-owned array and nested strings, valid until Runtime.destroy begins.
    import_attributes: []const ImportAttribute,
};
/// Returned slices/names are borrowed and copied/consumed before the enclosing
/// import/update/complete call returns. Use static or request.allocator storage,
/// or host storage kept alive and immutable through that enclosing call.
/// Never return stack memory or memory freed on callback return. Export handles
/// must remain live through the enclosing call; exception is a local handle in
/// request.context and is immediately retained. pending retains no result buffers.
/// Local handles must belong to the enclosing caller's HandleScope; escape values
/// from any nested HandleScope before returning them.
pub const LoadResult = union(enum) { source: []const u8, external: External, exports: []const Export, module: v8.Module, exception: v8.Value, pending };
/// Borrowed inputs: no input is accessed after completeLoad returns, on success or
/// error. Accepted content/exceptions are copied/retained independently. Caller
/// releases its own memory/exception handle. Handles must belong to this runtime.
pub const Completion = union(enum) {
    content: Content,
    failure: anyerror,
    exception: v8.Global.Of(v8.Value),
    /// Fails the load with a `SyntaxError` created in the module's own realm whose message and
    /// stack are this text (for example compiler diagnostics). Borrowed for the call.
    syntax_error: []const u8,
    /// Fails the load with an `Error` created in the module's own realm carrying this message.
    /// Borrowed for the call.
    message: []const u8,
};
pub const Loader = struct {
    /// Host-owned state, borrowed without destruction; must outlive Runtime.destroy.
    data: ?*anyopaque = null,
    /// Synchronous callback in request.context. See LoadRequest/LoadResult for
    /// borrowing rules. For async work return pending, keep only the numeric token
    /// and any needed request bytes (valid until teardown), and use an independently
    /// owned alloc off-thread. Do not retain the local context handle or use
    /// request.allocator off-thread. Results are later borrowed by completeLoad.
    load: *const fn (data: ?*anyopaque, request: LoadRequest) anyerror!LoadResult,
    /// Called during Runtime.destroy for pending tokens. data is still borrowed.
    /// Request bytes for this token remain readable during this callback, then
    /// become invalid as teardown proceeds. No result or ownership is transferred.
    cancel: ?*const fn (data: ?*anyopaque, token: LoadToken) void = null,
    /// Called each time the scope's imports are driven (`Runtime.pump`): a host that parked loads on
    /// something other than I/O (another context's module) completes the ones that can go on now. Returns
    /// whether it completed any.
    poll: ?*const fn (data: ?*anyopaque) bool = null,
};

/// Everything `MetaInitializer.init` may touch. All fields are borrowed for the
/// callback only: `context` is the entered context, `module_id` is runtime-owned,
/// and `meta` is V8's fresh `import.meta` object for that module.
pub const MetaRequest = struct {
    context: v8.Context,
    scope_id: usize,
    module_id: ModuleId,
    /// The table the module lives in (see `Resolver.namespace_of`).
    namespace: u32 = 0,
    meta: v8.Object,
};
/// Optional host hook that adds properties to a module's `import.meta` the first
/// time the module reads it (after the engine's own `url`). Synchronous, on the
/// isolate thread, inside a live HandleScope; it cannot fail the import, so a host
/// that cannot populate `meta` simply leaves it without the property.
pub const MetaInitializer = struct {
    /// Host-owned state, borrowed without destruction; must outlive Runtime.destroy.
    data: ?*anyopaque = null,
    /// Must not retain `request` or any handle in it after returning.
    init: *const fn (data: ?*anyopaque, request: MetaRequest) void,
};

/// What a `CodeCache` hook is asked about: one module's compile.
pub const CodeCacheRequest = struct {
    /// Runtime-owned arena for the returned bytes of `load`; valid until Runtime.destroy
    /// begins. Not used by `store`.
    allocator: std.mem.Allocator,
    module_id: ModuleId,
    /// Exactly the text V8 compiles (after any transformation). Borrowed for the call.
    source: []const u8,
};
/// Optional persistence of V8 code caches, keyed by module ID and exact source text. The
/// runtime asks `load` before compiling a source module and, when `Scope.flushCodeCache`
/// runs, hands every module that compiled without a usable cache to `store`. V8 rejects
/// caches from another build or flag set by itself; whether the cache matches `source`
/// is the hook's job (V8 only compares the length).
pub const CodeCache = struct {
    /// Host-owned state, borrowed without destruction; must outlive Runtime.destroy.
    data: ?*anyopaque = null,
    /// Cached bytes for this module or null. Synchronous, on the isolate thread. Bytes must
    /// be 8-byte aligned and live in request.allocator (they are borrowed until the compile
    /// returns).
    load: *const fn (data: ?*anyopaque, request: CodeCacheRequest) ?[]const u8,
    /// Persists freshly produced bytes (borrowed for the call). Best effort: failures are
    /// the hook's to swallow.
    store: *const fn (data: ?*anyopaque, request: CodeCacheRequest, bytes: []const u8) void,
    /// Called when V8 refuses the bytes `load` returned for `request` (they were made by another
    /// build or flag set): the hook may discard them. The module is compiled without them and its
    /// fresh cache goes to `store`.
    rejected: ?*const fn (data: ?*anyopaque, request: CodeCacheRequest) void = null,
    /// Whether a module compiled without a usable cache is worth keeping for `store` (its source is
    /// held until `flushCodeCache`). Null: every module is.
    keeps: ?*const fn (data: ?*anyopaque, module_id: ModuleId) bool = null,
};
