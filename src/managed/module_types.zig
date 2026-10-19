//! Borrowing contracts for resolution, loading and module content.
const std = @import("std");
const v8 = @import("@v8");

/// UTF-8 logical module identity. This alias does not imply ownership;
/// the containing request, result, or function documents the slice lifetime.
pub const ModuleId = []const u8;
/// Module IDs with this prefix are the host's namespace; scopes opt in through
/// `Scope.Options.enable_origine_namespace`.
pub const origine_prefix = "origine:";
/// Caller-owned key. Public cache operations borrow it, including nested strings,
/// only until the operation returns; they never take ownership of caller memory.
pub const ModuleMapKey = struct { module_id: ModuleId, import_attributes: []const ImportAttribute = &.{} };
/// Compatibility alias. Cache entries are entries in the per-scope ModuleMap.
pub const ImportCacheKey = ModuleMapKey;
/// Borrowed UTF-8 key/value strings; the containing API defines their lifetime.
pub const ImportAttribute = struct { key: []const u8, value: []const u8 };
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
    import_attributes: []const ImportAttribute = &.{},
};
pub const Resolver = struct {
    /// Host-owned state, borrowed without destruction; must outlive Runtime.destroy.
    data: ?*anyopaque = null,
    /// Return canonical ID bytes owned by request.allocator, never input aliases.
    /// Release temporaries on success and clean up on failure.
    /// Ownership of the result transfers to the runtime on success. Never return
    /// static/stack bytes, freed storage, or memory from a different alloc.
    resolve: *const fn (data: ?*anyopaque, request: ResolveRequest) anyerror!ModuleId,
};
/// name is borrowed UTF-8; value is a borrowed persistent handle from this runtime.
/// The receiving content API copies the name and retains its own handle.
pub const Export = struct { name: []const u8, value: v8.Global.Of(v8.Value) };
/// All slices, nested export names, and handles are borrowed until the receiving
/// updateImportCache/completeLoad call returns (success or error). No ownership is
/// transferred. Source is copied into V8; export names and handles are retained.
pub const Content = union(enum) { source: []const u8, exports: []const Export };
pub const LoadToken = u64;
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
pub const LoadResult = union(enum) { source: []const u8, exports: []const Export, exception: v8.Value, pending };
/// Borrowed inputs: no input is accessed after completeLoad returns, on success or
/// error. Accepted content/exceptions are copied/retained independently. Caller
/// releases its own memory/exception handle. Handles must belong to this runtime.
pub const Completion = union(enum) { content: Content, failure: anyerror, exception: v8.Global.Of(v8.Value) };
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
};

/// Everything `MetaInitializer.init` may touch. All fields are borrowed for the
/// callback only: `context` is the entered context, `module_id` is runtime-owned,
/// and `meta` is V8's fresh `import.meta` object for that module.
pub const MetaRequest = struct {
    context: v8.Context,
    scope_id: usize,
    module_id: ModuleId,
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
