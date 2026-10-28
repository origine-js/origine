//! Backend-independent ESM graphs. All callbacks and completions run on the isolate thread.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const Scope = @import("scope.zig").Scope;
const ErrorInfo = @import("errors.zig").ErrorInfo;

const ModuleId = @import("module_types.zig").ModuleId;
const ModuleMapKey = @import("module_types.zig").ModuleMapKey;
const ImportCacheKey = @import("module_types.zig").ImportCacheKey;
const ImportAttribute = @import("module_types.zig").ImportAttribute;
const ResolveRequest = @import("module_types.zig").ResolveRequest;
const Resolver = @import("module_types.zig").Resolver;
const ResolveCompletion = @import("module_types.zig").ResolveCompletion;
const Export = @import("module_types.zig").Export;
const Content = @import("module_types.zig").Content;
const LoadToken = @import("module_types.zig").LoadToken;
const LoadRequest = @import("module_types.zig").LoadRequest;
const LoadResult = @import("module_types.zig").LoadResult;
const Completion = @import("module_types.zig").Completion;
const Loader = @import("module_types.zig").Loader;
const CodeCacheRequest = @import("module_types.zig").CodeCacheRequest;
const origine_prefix = @import("module_types.zig").origine_prefix;
const init_snapshot = @import("init_snapshot.zig");

const Dependency = struct { specifier: []const u8, attributes: []const ImportAttribute, entry: *Entry };
/// A module request whose asynchronous resolution has not settled. Strings are arena-owned.
const Unresolved = struct { specifier: []const u8, attributes: []const ImportAttribute, token: LoadToken };
const Entry = struct {
    cache_key: []const u8,
    cached: bool = true,
    id: ModuleId,
    /// The table the entry lives in (`Resolver.namespace_of`); part of its key.
    namespace: u32 = 0,
    attributes: []const ImportAttribute,
    module: ?v8.Global.Of(v8.Module) = null,
    /// Next entry whose module has the same identity hash (see `ModuleMap.by_identity`).
    identity_next: ?*Entry = null,
    failure: ?v8.Global.Of(v8.Value) = null,
    evaluation: ?v8.Global.Of(v8.Promise) = null,
    dependencies: std.ArrayList(Dependency) = .empty,
    exports: []const Export = &.{},
    preparing: bool = true,
    visited: bool = false,
    pending: ?LoadToken = null,
    /// The module belongs to another context and was linked in as it is (`Content.module`).
    shared: bool = false,
    /// Requests of this module still waiting for an asynchronous resolver. While any is left the
    /// entry stays `preparing`, so no import that depends on it can start linking.
    unresolved: std.ArrayList(Unresolved) = .empty,
    /// Source copy kept until `flushCodeCache` for a module compiled without a usable code
    /// cache (owned by the runtime allocator). Null once flushed, for modules that consumed a
    /// cache, and without a hook.
    cache_source: ?[]const u8 = null,
    /// Holders outside the map that keep this module alive (see `pin`): a pinned module is never
    /// swept, and neither is anything it imports.
    pins: u32 = 0,
    /// Names the entry for `unpin`; assigned when first pinned.
    serial: u32 = 0,
    /// The root of an import that just settled: survives the next sweep so that the host can pin it
    /// once the import's promise reaches it.
    grace: bool = false,
    /// Swept: every handle is released and the entry is out of every index. Its storage stays in
    /// the map's arena until the map is destroyed.
    dead: bool = false,
};
/// The map's view of a resolver answer: the id, or the token to wait for.
const Resolved = union(enum) { id: []const u8, pending: LoadToken };
const Task = struct {
    /// Null while the root specifier itself is still being resolved asynchronously.
    root: ?*Entry,
    resolver: v8.Global.Of(v8.Promise.Resolver),
    settled: bool = false,
    /// The table `root` is fetched into once its resolution settles.
    namespace: u32 = 0,
    /// While `root` is null: the token of its resolution and the request (arena-owned strings).
    root_token: ?LoadToken = null,
    specifier: []const u8 = "",
    attributes: []const ImportAttribute = &.{},
};

/// Per-scope mapping from resolved specifiers and attributes to V8 module instances.
/// Resolution/import-map rewriting runs before this map's lookup. On a miss the
/// loader creates a module and the map caches it. Owned by Scope; never copy/free it.
/// update/delete/clear/get enter the owning context themselves. Internal loader
/// methods require the isolate/context and a live HandleScope already entered.
pub const ModuleMap = struct {
    scope: *Scope,
    arena: std.heap.ArenaAllocator,
    entries: std.StringHashMapUnmanaged(*Entry) = .empty,
    // Retired entries remain available to existing namespaces, linked graphs and pending imports.
    all_entries: std.ArrayList(*Entry) = .empty,
    /// Module identity hash -> chain of entries (`Entry.identity_next`), so `find` is not a scan.
    by_identity: std.AutoHashMapUnmanaged(c_int, *Entry) = .empty,
    tasks: std.ArrayList(Task) = .empty,
    driving: bool = false,
    preparing_depth: usize = 0,
    sweeping: bool = false,
    next_serial: u32 = 0,

    /// Insert/replace a resolved-specifier mapping using source or synthetic exports.
    /// Borrows key/content and all nested slices/handles only through return, on
    /// success or error; retained data is copied. Caller may free inputs afterward.
    /// Invalidates cached dependents; existing module references remain valid.
    /// error_info follows ErrorInfo ownership; captures compilation/hardening errors.
    pub fn update(self: *ModuleMap, key: ModuleMapKey, content: Content, error_info: ?*ErrorInfo) !void {
        try self.scope.updateImportCache(key, content, error_info);
    }

    /// Delete a resolved-specifier mapping and cached dependents. Borrows key and
    /// nested attribute strings only through return. Returns the removed-entry count.
    pub fn delete(self: *ModuleMap, key: ModuleMapKey) !usize {
        return self.scope.deleteImportCache(key);
    }

    /// Remove all active mappings in this scope. Returns their count, not owned memory.
    /// Existing instances and pending imports remain valid; no caller data is freed.
    pub fn clear(self: *ModuleMap) !usize {
        return self.scope.clearImportCache();
    }

    /// Look up a resolved specifier/attribute set without resolving or loading it.
    /// Borrows key/nested strings through return. Returns a caller-owned persistent
    /// V8 module handle: deinit it before Runtime.destroy. Null means absent or still
    /// loading; cached failures return JavaScriptException. Input ownership stays
    /// with the caller; the returned handle independently retains the same module.
    /// error_info follows ErrorInfo ownership; returns the cached failure value
    /// on JavaScriptException. Pass null to discard it.
    pub fn get(self: *ModuleMap, key: ModuleMapKey, error_info: ?*ErrorInfo) !?v8.Global.Of(v8.Module) {
        if (error_info) |out| out.deinit();
        const iso = self.isolate();
        iso.enter();
        defer iso.exit();
        var h_scope: v8.HandleScope = undefined;
        h_scope.init(iso);
        defer h_scope.deinit();
        const context = self.ctx();
        context.enter();
        defer context.exit();
        var scratch = std.heap.ArenaAllocator.init(self.scope.runtime.allocator);
        defer scratch.deinit();
        const attributes = try normalizeAttributes(scratch.allocator(), key.import_attributes);
        const encoded = try cacheKey(scratch.allocator(), key.namespace, key.module_id, attributes);
        const entry = self.entries.get(encoded) orelse return null;
        if (entry.failure) |failure| {
            if (error_info) |out| out.exception = .new(iso, failure.deref());
            return error.JavaScriptException;
        }
        const module = entry.module orelse return null;
        return .new(iso, module.deref());
    }

    /// `get` for a module known by its id alone: the first table that holds it (without attributes). The
    /// module is absent, still loading, or failed as for `get`. Returns a caller-owned persistent handle.
    pub fn getAny(self: *ModuleMap, id: []const u8) !?v8.Global.Of(v8.Module) {
        const entry = for (self.all_entries.items) |candidate| {
            if (candidate.cached and !candidate.dead and candidate.attributes.len == 0 and std.mem.eql(u8, candidate.id, id)) break candidate;
        } else return null;
        return self.get(.{ .module_id = id, .namespace = entry.namespace }, null);
    }

    /// Borrows scope at its stable address until deinit; owns an initially empty
    /// arena backed by the runtime allocator. Caller owns the returned map and must
    /// keep scope/runtime/allocator alive through deinit; allocates nothing yet.
    pub fn init(scope: *Scope) ModuleMap {
        return .{ .scope = scope, .arena = .init(scope.runtime.allocator) };
    }
    /// Consumes map-owned arenas, collections and persistent handles; cancels
    /// pending loads and rejects unresolved promises. Requires entered isolate/context
    /// and live HandleScope; host callback state remains borrowed through return.
    pub fn deinit(self: *ModuleMap) void {
        for (self.all_entries.items) |entry| {
            if (entry.pending) |token| if (self.scope.options.loader) |loader| if (loader.cancel) |cancel| cancel(loader.data, token);
            if (self.scope.options.resolver) |resolver| if (resolver.cancel) |cancel| for (entry.unresolved.items) |request| cancel(resolver.data, request.token);
            entry.unresolved.deinit(self.scope.runtime.allocator);
            if (entry.cache_source) |source| self.scope.runtime.allocator.free(source);
            if (entry.module) |value| value.deinit();
            if (entry.failure) |value| value.deinit();
            if (entry.evaluation) |value| value.deinit();
            for (entry.exports) |exp| exp.value.deinit();
            entry.dependencies.deinit(self.scope.runtime.allocator);
        }
        for (self.tasks.items) |task| {
            if (task.root_token) |token| if (self.scope.options.resolver) |resolver| if (resolver.cancel) |cancel| cancel(resolver.data, token);
            if (!task.settled) _ = task.resolver.deref().reject(self.ctx(), self.errorValue(error.RuntimeClosed));
            task.resolver.deinit();
        }
        self.entries.deinit(self.scope.runtime.allocator);
        self.all_entries.deinit(self.scope.runtime.allocator);
        self.by_identity.deinit(self.scope.runtime.allocator);
        self.tasks.deinit(self.scope.runtime.allocator);
        self.arena.deinit();
    }
    /// Borrows self; returns arena-backed allocator valid until this module map is deinitialized.
    fn arenaAllocator(self: *ModuleMap) std.mem.Allocator {
        return self.arena.allocator();
    }
    /// Borrows self; returns the scope context, valid until Scope.destroy begins.
    /// Dereferencing requires the runtime isolate entered and a live HandleScope.
    fn ctx(self: *ModuleMap) v8.Context {
        return self.scope.context.deref();
    }
    /// Borrows self through return; returns a non-owning isolate handle valid
    /// until Runtime.destroy begins.
    fn isolate(self: *ModuleMap) v8.Isolate {
        return self.scope.runtime.isolate;
    }

    /// Borrows inputs and alloc through the resolver call. The resolver's
    /// contract returns bytes owned by alloc; errors transfer no result storage.
    fn resolve(self: *ModuleMap, alloc: std.mem.Allocator, specifier: []const u8, referrer: []const u8, referrer_namespace: u32, attributes: []const ImportAttribute) !Resolved {
        const enabled = self.scope.options.origine_namespace;
        if (!enabled and std.mem.startsWith(u8, specifier, origine_prefix)) return error.OrigineNamespaceDisabled;
        const resolver = self.scope.options.resolver orelse return .{ .id = try alloc.dupe(u8, specifier) };
        const rt = self.scope.runtime;
        var request: ResolveRequest = .{ .allocator = alloc, .context = self.ctx(), .scope_id = self.scope.id, .specifier = specifier, .referrer = referrer, .referrer_namespace = referrer_namespace, .import_attributes = attributes };
        const resolve_async = resolver.resolve_async orelse {
            const id = try resolver.resolve(resolver.data, request);
            if (!enabled and std.mem.startsWith(u8, id, origine_prefix)) return error.OrigineNamespaceDisabled;
            return .{ .id = id };
        };
        request.token = rt.next_load_token;
        rt.next_load_token = std.math.add(LoadToken, request.token, 1) catch return error.LoadTokenExhausted;
        switch (try resolve_async(resolver.data, request)) {
            .id => |id| {
                if (!enabled and std.mem.startsWith(u8, id, origine_prefix)) return error.OrigineNamespaceDisabled;
                return .{ .id = id };
            },
            .pending => return .{ .pending = request.token },
        }
    }

    /// Borrows entry/exception through return; retains an independent persistent
    /// exception on first failure, released at map deinit. Requires entered isolate
    /// and a live HandleScope; does not consume the local exception.
    fn fail(self: *ModuleMap, entry: *Entry, exception: v8.Value) void {
        if (entry.failure == null) entry.failure = .new(self.isolate(), exception);
        entry.preparing = false;
    }
    /// Accepts a copied error and borrows self through return. Returns a local
    /// exception in the current HandleScope; requires the isolate entered.
    fn errorValue(self: *ModuleMap, err: anyerror) v8.Value {
        return eu.v.err(eu.v.str_utf8(self.isolate(), @errorName(err))).?;
    }

    /// A `SyntaxError` whose message and stack are `text` (borrowed for the call). Returns a
    /// local value in the current HandleScope; requires the isolate and this scope's context
    /// entered.
    fn syntaxErrorValue(self: *ModuleMap, text: []const u8) v8.Value {
        const message = eu.v.str_utf8(self.isolate(), std.mem.trimEnd(u8, text, "\n"));
        const exception = eu.v.syntax_error(message).?;
        if (exception.toObject(self.ctx())) |object| {
            _ = object.createDataProperty(self.ctx(), eu.v.str_utf8(self.isolate(), "stack").name, message.name.primitive.value);
        }
        return exception;
    }

    /// Borrows immutable bytes through return; returns a copied length or
    /// overflow error and retains no resources.
    fn componentSize(bytes: []const u8) !usize {
        var digits: usize = 1;
        var n = bytes.len;
        while (n >= 10) : (n /= 10) digits += 1;
        return std.math.add(usize, bytes.len, digits + 1);
    }
    /// Borrows id/attributes through return; returns an alloc-owned framed key.
    /// Caller frees it with alloc, including when later cache lookup fails.
    fn cacheKey(alloc: std.mem.Allocator, namespace: u32, id: []const u8, attributes: []const ImportAttribute) ![]const u8 {
        // Length framing makes IDs and attribute pairs unambiguous; the table number leads.
        var prefix: [16]u8 = undefined;
        const lead = std.fmt.bufPrint(&prefix, "n{d}.", .{namespace}) catch unreachable;
        var size = try std.math.add(usize, lead.len, try componentSize(id));
        for (attributes) |attr| {
            size = try std.math.add(usize, size, try componentSize(attr.key));
            size = try std.math.add(usize, size, try componentSize(attr.value));
        }
        const key = try alloc.alloc(u8, size);
        errdefer alloc.free(key);
        @memcpy(key[0..lead.len], lead);
        var written = lead.len + (std.fmt.bufPrint(key[lead.len..], "{d}:{s}", .{ id.len, id }) catch unreachable).len;
        for (attributes) |attr| written += (std.fmt.bufPrint(key[written..], "{d}:{s}{d}:{s}", .{ attr.key.len, attr.key, attr.value.len, attr.value }) catch unreachable).len;
        std.debug.assert(written == key.len);
        return key;
    }
    /// Borrows id/attributes/key through return and copies them into map-owned
    /// storage. Returns an Entry owned by this ModuleMap; callers do not free it.
    /// Partial allocations on error remain map-owned until ModuleMap.deinit.
    fn allocEntry(self: *ModuleMap, namespace: u32, id: []const u8, attributes: []const ImportAttribute, key: []const u8) !*Entry {
        const alloc = self.scope.runtime.allocator;
        try self.entries.ensureUnusedCapacity(alloc, 1);
        try self.all_entries.ensureUnusedCapacity(alloc, 1);
        const entry = try self.arenaAllocator().create(Entry);
        const owned_attributes = try self.arenaAllocator().alloc(ImportAttribute, attributes.len);
        for (attributes, owned_attributes) |attribute, *item| item.* = .{
            .key = try self.arenaAllocator().dupe(u8, attribute.key),
            .value = try self.arenaAllocator().dupe(u8, attribute.value),
        };
        entry.* = .{ .namespace = namespace, .id = try self.arenaAllocator().dupe(u8, id), .attributes = owned_attributes, .cache_key = try self.arenaAllocator().dupe(u8, key) };
        self.all_entries.appendAssumeCapacity(entry);
        return entry;
    }
    /// Borrows id, attributes, and alloc through return. Returns an Entry owned
    /// by this ModuleMap; caller-owned temporary key storage remains with alloc.
    fn fetch(self: *ModuleMap, alloc: std.mem.Allocator, namespace: u32, id: []const u8, attributes: []const ImportAttribute) anyerror!*Entry {
        const key = try cacheKey(alloc, namespace, id, attributes);
        if (self.entries.get(key)) |entry| return entry;
        const entry = try self.allocEntry(namespace, id, attributes, key);
        self.entries.putAssumeCapacity(entry.cache_key, entry);
        var tc_scope: v8.TryCatch = undefined;
        tc_scope.init(self.isolate());
        defer tc_scope.deinit();
        self.load(entry) catch |err| self.fail(entry, tc_scope.getException() orelse self.errorValue(err));
        return entry;
    }
    /// Borrows entry through the synchronous loader callback; callback state
    /// is borrowed through runtime teardown. Copies content into map-owned state or
    /// retains a pending numeric token. On error partial entry state remains map-owned
    /// until deinit; requires entered context/isolate and a live HandleScope.
    fn load(self: *ModuleMap, entry: *Entry) !void {
        const loader = self.scope.options.loader orelse return error.NoLoader;
        const rt = self.scope.runtime;
        const token = rt.next_load_token;
        rt.next_load_token = std.math.add(LoadToken, token, 1) catch return error.LoadTokenExhausted;
        switch (try loader.load(loader.data, .{ .allocator = self.arenaAllocator(), .context = self.ctx(), .scope_id = self.scope.id, .module_id = entry.id, .namespace = entry.namespace, .token = token, .import_attributes = entry.attributes })) {
            .source => |source| try self.compile(entry, .{ .source = source }),
            .exports => |exports| try self.compile(entry, .{ .exports = exports }),
            .module => |linked| try self.compile(entry, .{ .module = linked }),
            .pending => entry.pending = token,
            .exception => |exception| self.fail(entry, exception),
        }
    }
    /// Borrows completion and all nested buffers/handles through return only.
    /// Retained content is independently copied; returns whether token was found.
    pub fn complete(self: *ModuleMap, token: LoadToken, completion: Completion) !bool {
        for (self.all_entries.items) |entry| if (entry.pending == token) {
            entry.pending = null;
            var tc_scope: v8.TryCatch = undefined;
            tc_scope.init(self.isolate());
            defer tc_scope.deinit();
            switch (completion) {
                .failure => |err| self.fail(entry, self.errorValue(err)),
                .exception => |exception| self.fail(entry, exception.deref()),
                .syntax_error => |text| self.fail(entry, self.syntaxErrorValue(text)),
                .message => |text| self.fail(entry, eu.v.err(eu.v.str_utf8(self.isolate(), text)).?),
                .content => |content| self.compile(entry, content) catch |err| self.fail(entry, tc_scope.getException() orelse self.errorValue(err)),
            }
            return true;
        };
        return false;
    }
    /// Borrows content and nested names/handles through return; copies source
    /// and retains independent export/module handles in entry until map deinit.
    /// On error partial entry allocations/handles remain map-owned for teardown;
    /// temporary compiler state and host buffers are released. Requires entered
    /// context/isolate and a live HandleScope.
    fn compile(self: *ModuleMap, entry: *Entry, content: Content) anyerror!void {
        self.preparing_depth += 1;
        defer self.preparing_depth -= 1;
        const iso = self.isolate();
        switch (content) {
            .source => |text| {
                var source: v8.ScriptCompiler.Source = undefined;
                var origin = self.scope.scriptOrigin(entry.id, true);
                const cache_request: CodeCacheRequest = .{ .allocator = self.arenaAllocator(), .module_id = entry.id, .source = text };
                const cached = if (self.scope.options.code_cache) |hook| hook.load(hook.data, cache_request) else null;
                // The Source owns the cache object it is given, so it is not released here.
                const cache_object = if (cached) |bytes| v8.ScriptCompiler.CachedData.init(bytes.ptr, @intCast(bytes.len)) else null;
                source.init(eu.v.str_utf8(iso, text), &origin, cache_object);
                defer source.deinit();
                const module = v8.ScriptCompiler.compileModule(iso, &source, if (cache_object != null) 1 else 0, 0) orelse return error.JavaScriptException;
                const accepted = cache_object != null and !v8.ScriptCompiler.CachedData.rejected(source.getCachedData().?);
                if (cache_object != null and !accepted) if (self.scope.options.code_cache) |hook| if (hook.rejected) |discard| discard(hook.data, cache_request);
                if (self.scope.options.code_cache != null and !accepted) entry.cache_source = try self.scope.runtime.allocator.dupe(u8, text);
                entry.module = .new(iso, module);
                try self.indexModule(entry);
                const requests = module.getModuleRequests().?;
                try entry.dependencies.ensureTotalCapacity(self.scope.runtime.allocator, @intCast(requests.len()));
                var index: c_int = 0;
                while (index < requests.len()) : (index += 1) {
                    const request = v8.ModuleRequest.from_opaque(requests.get(index).?.handle).?;
                    if (request.getPhase() != .Evaluation) return error.UnsupportedImport;
                    var scratch = std.heap.ArenaAllocator.init(self.scope.runtime.allocator);
                    defer scratch.deinit();
                    const alloc = scratch.allocator();
                    const attributes = try self.readAttributes(alloc, request.getImportAttributes().?, 3);
                    const specifier = try string(alloc, iso, request.getSpecifier().?);
                    switch (try self.resolve(alloc, specifier, entry.id, entry.namespace, attributes)) {
                        .id => |id| {
                            const dependency = try self.fetch(alloc, self.dependencyNamespace(entry.namespace, entry.id), id, attributes);
                            entry.dependencies.appendAssumeCapacity(.{ .specifier = try self.arenaAllocator().dupe(u8, specifier), .attributes = dependency.attributes, .entry = dependency });
                        },
                        .pending => |token| {
                            const owned_attributes = try self.arenaAllocator().alloc(ImportAttribute, attributes.len);
                            for (attributes, owned_attributes) |attribute, *copy| copy.* = .{ .key = try self.arenaAllocator().dupe(u8, attribute.key), .value = try self.arenaAllocator().dupe(u8, attribute.value) };
                            try entry.unresolved.append(self.scope.runtime.allocator, .{ .specifier = try self.arenaAllocator().dupe(u8, specifier), .attributes = owned_attributes, .token = token });
                        },
                    }
                }
            },
            .module => |linked| {
                entry.module = .new(iso, linked);
                entry.shared = true;
                try self.indexModule(entry);
            },
            .exports => |exports| {
                const owned = try self.arenaAllocator().alloc(Export, exports.len);
                entry.exports = owned[0..0];
                const names = try self.scope.runtime.allocator.alloc(v8.String, exports.len);
                defer self.scope.runtime.allocator.free(names);
                for (exports, 0..) |exp, i| {
                    try self.scope.hardenLocal(exp.value.deref());
                    for (exports[0..i]) |prior| if (std.mem.eql(u8, exp.name, prior.name)) return error.DuplicateExport;
                    owned[i] = .{ .name = try self.arenaAllocator().dupe(u8, exp.name), .value = .new(iso, exp.value.deref()) };
                    entry.exports = owned[0 .. i + 1];
                    names[i] = eu.v.str_utf8(iso, exp.name);
                }
                const module = v8.Module.createSyntheticModule(iso, eu.v.str_utf8(iso, entry.id), names.len, @ptrCast(names.ptr), synthetic) orelse return error.JavaScriptException;
                entry.module = .new(iso, module);
                try self.indexModule(entry);
            },
        }
        entry.preparing = entry.unresolved.items.len != 0;
    }

    /// Settles an asynchronous resolution started by `Resolver.resolve_async`: continues the
    /// module (or root import) that asked, fetching the module it resolved to. Returns whether
    /// `token` was pending here. Borrows the completion through return; requires the entered
    /// context and a live HandleScope. A failure fails the module that asked.
    pub fn completeResolve(self: *ModuleMap, token: LoadToken, completion: ResolveCompletion) !bool {
        var tc_scope: v8.TryCatch = undefined;
        tc_scope.init(self.isolate());
        defer tc_scope.deinit();
        var scratch = std.heap.ArenaAllocator.init(self.scope.runtime.allocator);
        defer scratch.deinit();
        const alloc = scratch.allocator();
        for (self.tasks.items) |*task| {
            if (task.root_token != token) continue;
            task.root_token = null;
            const resolved = self.settledId(alloc, completion) catch |err| {
                task.settled = true;
                _ = task.resolver.deref().reject(self.ctx(), self.settledFailure(completion, &tc_scope, err));
                return true;
            };
            task.root = self.fetch(alloc, task.namespace, resolved, task.attributes) catch |err| {
                task.settled = true;
                _ = task.resolver.deref().reject(self.ctx(), tc_scope.getException() orelse self.errorValue(err));
                return true;
            };
            return true;
        }
        for (self.all_entries.items) |entry| {
            for (entry.unresolved.items, 0..) |request, index| {
                if (request.token != token) continue;
                _ = entry.unresolved.orderedRemove(index);
                const resolved = self.settledId(alloc, completion) catch |err| {
                    self.fail(entry, self.settledFailure(completion, &tc_scope, err));
                    return true;
                };
                const dependency = self.fetch(alloc, self.dependencyNamespace(entry.namespace, entry.id), resolved, request.attributes) catch |err| {
                    self.fail(entry, tc_scope.getException() orelse self.errorValue(err));
                    return true;
                };
                entry.dependencies.append(self.scope.runtime.allocator, .{ .specifier = request.specifier, .attributes = dependency.attributes, .entry = dependency }) catch |err| {
                    self.fail(entry, self.errorValue(err));
                    return true;
                };
                if (entry.unresolved.items.len == 0 and entry.failure == null and entry.module != null) entry.preparing = false;
                return true;
            }
        }
        return false;
    }

    /// The id of a successful completion, copied into `alloc`; the origine-namespace gate applies
    /// to it as to any resolver answer.
    fn settledId(self: *ModuleMap, alloc: std.mem.Allocator, completion: ResolveCompletion) ![]const u8 {
        switch (completion) {
            .id => |id| {
                if (!self.scope.options.origine_namespace and std.mem.startsWith(u8, id, origine_prefix)) return error.OrigineNamespaceDisabled;
                return alloc.dupe(u8, id);
            },
            .failure => |err| return err,
            .exception, .message => return error.ResolverFailed,
        }
    }

    /// The value a failed completion rejects or fails with: the host's exception when it gave one.
    fn settledFailure(self: *ModuleMap, completion: ResolveCompletion, tc_scope: *v8.TryCatch, err: anyerror) v8.Value {
        return switch (completion) {
            .exception => |exception| exception.deref(),
            .message => |text| eu.v.err(eu.v.str_utf8(self.isolate(), text)).?,
            else => tc_scope.getException() orelse self.errorValue(err),
        };
    }

    /// Hands the code cache of every module that compiled without a usable one to the scope's
    /// `code_cache.store`, then forgets it, so each is stored once. Call after the code ran
    /// (lazily compiled functions are only in the cache by then). Requires the entered
    /// context and a live HandleScope; borrows the hook. Returns how many modules it stored.
    pub fn flushCodeCache(self: *ModuleMap) usize {
        const hook = self.scope.options.code_cache orelse return 0;
        var stored: usize = 0;
        for (self.all_entries.items) |entry| {
            const source = entry.cache_source orelse continue;
            defer self.scope.runtime.allocator.free(source);
            entry.cache_source = null;
            const module = (entry.module orelse continue).deref();
            const unbound = module.getUnboundModuleScript() orelse continue;
            const cache = unbound.createCodeCache() orelse continue;
            defer cache.deinit();
            const bytes = v8.ScriptCompiler.CachedData.bytes(cache.handle);
            if (bytes.len == 0) continue;
            hook.store(hook.data, .{ .allocator = self.arenaAllocator(), .module_id = entry.id, .source = source }, bytes);
            stored += 1;
        }
        return stored;
    }

    /// Registers every active module with `creator` as data of the current context and
    /// describes the graph. The map must be idle and hold only settled source modules:
    /// failures, pending loads, synthetic modules and unfinished imports fail with
    /// error.NotSnapshottable. Requires the entered context and a live HandleScope. Result
    /// slices and strings are copied into `alloc`, which the caller owns; source hashes are
    /// left for the host to fill in.
    pub fn snapshotModules(self: *ModuleMap, alloc: std.mem.Allocator, creator: *v8.SnapshotCreator) ![]init_snapshot.Module {
        if (self.tasks.items.len != 0 or self.driving or self.preparing_depth != 0) return error.NotSnapshottable;
        var active: std.ArrayList(*Entry) = .empty;
        defer active.deinit(alloc);
        for (self.all_entries.items) |entry| {
            if (!entry.cached) continue;
            const module = entry.module orelse return error.NotSnapshottable;
            if (entry.failure != null or entry.pending != null or entry.preparing or entry.exports.len != 0 or entry.shared) return error.NotSnapshottable;
            if (!module.deref().isSourceTextModule()) return error.NotSnapshottable;
            try active.append(alloc, entry);
        }
        const modules = try alloc.alloc(init_snapshot.Module, active.items.len);
        for (active.items, modules) |entry, *out| {
            const attributes = try alloc.alloc(ImportAttribute, entry.attributes.len);
            for (entry.attributes, attributes) |attribute, *copy| copy.* = .{ .key = try alloc.dupe(u8, attribute.key), .value = try alloc.dupe(u8, attribute.value) };
            const dependencies = try alloc.alloc(init_snapshot.Dependency, entry.dependencies.items.len);
            for (entry.dependencies.items, dependencies) |dependency, *copy| {
                const target = for (active.items, 0..) |candidate, index| {
                    if (candidate == dependency.entry) break index;
                } else return error.NotSnapshottable;
                copy.* = .{ .specifier = try alloc.dupe(u8, dependency.specifier), .module = @intCast(target) };
            }
            out.* = .{
                .id = try alloc.dupe(u8, entry.id),
                .attributes = attributes,
                .data_index = creator.addDataToContext(self.ctx(), entry.module.?.deref().data),
                .dependencies = dependencies,
            };
        }
        return modules;
    }

    /// Rebuilds the map of a context restored from a snapshot: one settled entry per
    /// described module, backed by the snapshotted `v8.Module`. Imports of those modules
    /// then resolve from the map and evaluate nothing. Call once, on an empty map, with
    /// the restored context entered and a HandleScope live. Borrows `modules` through
    /// return; everything kept is copied. On error the map is partially filled and must
    /// be discarded with its scope.
    pub fn restoreModules(self: *ModuleMap, modules: []const init_snapshot.Module) !void {
        if (self.all_entries.items.len != 0) return error.ImportCacheBusy;
        const alloc = self.scope.runtime.allocator;
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const entries = try scratch.allocator().alloc(*Entry, modules.len);
        for (modules, entries) |module, *entry| {
            const key = try cacheKey(scratch.allocator(), 0, module.id, module.attributes);
            entry.* = try self.allocEntry(0, module.id, module.attributes, key);
            self.entries.putAssumeCapacity(entry.*.cache_key, entry.*);
            const data = self.ctx().getDataFromSnapshotOnce(module.data_index) orelse return error.InvalidSnapshot;
            const restored = v8.Module.from_opaque(data.handle) orelse return error.InvalidSnapshot;
            if (!restored.isSourceTextModule()) return error.InvalidSnapshot;
            entry.*.module = .new(self.isolate(), restored);
            try self.indexModule(entry.*);
            entry.*.preparing = false;
        }
        for (modules, entries) |module, entry| {
            try entry.dependencies.ensureTotalCapacity(alloc, module.dependencies.len);
            for (module.dependencies) |dependency| {
                if (dependency.module >= entries.len) return error.InvalidSnapshot;
                const target = entries[dependency.module];
                entry.dependencies.appendAssumeCapacity(.{ .specifier = try self.arenaAllocator().dupe(u8, dependency.specifier), .attributes = target.attributes, .entry = target });
            }
        }
    }

    /// The id of the cached module whose namespace object is `namespace`, or null. Requires the
    /// entered context and a live HandleScope; the id stays valid until map deinit.
    pub fn idOfNamespace(self: *ModuleMap, namespace: v8.Value) ?[]const u8 {
        for (self.all_entries.items) |entry| {
            if (!entry.cached) continue;
            const module = (entry.module orelse continue).deref();
            if (entry.failure != null or entry.preparing) continue;
            // A module of a graph that failed to link was compiled but never instantiated, and V8
            // aborts the process on the namespace of one that is not (uninstantiated, instantiating
            // or errored).
            const status = module.getStatus();
            if (status < 2 or status == 5) continue;
            const candidate = module.getModuleNamespace() orelse continue;
            if (candidate.strictEquals(namespace)) return entry.id;
        }
        return null;
    }

    /// How many modules the table holds (`delete` and `clear` drop entries from it).
    pub fn cachedCount(self: *const ModuleMap) usize {
        return self.entries.count();
    }

    /// How many modules table `namespace` holds here. A module linked from another context
    /// (`Content.module`) belongs to that context's count.
    pub fn countNamespace(self: *const ModuleMap, namespace: u32) usize {
        var count: usize = 0;
        for (self.all_entries.items) |entry| {
            if (entry.cached and !entry.dead and !entry.shared and entry.namespace == namespace) count += 1;
        }
        return count;
    }

    /// The key of an entry, as `shared_released` reports it. Caller frees it with `alloc`.
    pub fn keyOf(alloc: std.mem.Allocator, key: ModuleMapKey) ![]const u8 {
        const attributes = try normalizeAttributes(alloc, key.import_attributes);
        defer alloc.free(attributes);
        return cacheKey(alloc, key.namespace, key.module_id, attributes);
    }

    /// What another context can take of the module `key` this map holds as its own (not linked from
    /// elsewhere): nothing, a module that is still loading or evaluating, a failed one, or the evaluated
    /// module itself (a handle the caller releases).
    pub const Shareable = union(enum) { none, loading, failed, ready: v8.Global.Of(v8.Module) };

    pub fn shareable(self: *ModuleMap, key: ModuleMapKey) Shareable {
        var scratch = std.heap.ArenaAllocator.init(self.scope.runtime.allocator);
        defer scratch.deinit();
        const attributes = normalizeAttributes(scratch.allocator(), key.import_attributes) catch return .none;
        const encoded = cacheKey(scratch.allocator(), key.namespace, key.module_id, attributes) catch return .none;
        const entry = self.entries.get(encoded) orelse return .none;
        if (entry.shared) return .none;
        if (entry.failure != null) return .failed;
        const module = (entry.module orelse return .loading).deref();
        if (entry.preparing or entry.pending != null or entry.unresolved.items.len != 0) return .loading;
        return switch (module.getStatus()) {
            4 => .{ .ready = .new(self.isolate(), module) },
            5 => .failed,
            else => .loading,
        };
    }

    /// `pin` for the entry `key` names. Returns the serial `unpin` takes, 0 when the table has no such module.
    pub fn pinKey(self: *ModuleMap, key: ModuleMapKey) !u32 {
        var scratch = std.heap.ArenaAllocator.init(self.scope.runtime.allocator);
        defer scratch.deinit();
        const attributes = try normalizeAttributes(scratch.allocator(), key.import_attributes);
        const encoded = try cacheKey(scratch.allocator(), key.namespace, key.module_id, attributes);
        const entry = self.entries.get(encoded) orelse return 0;
        if (entry.serial == 0) {
            self.next_serial += 1;
            entry.serial = self.next_serial;
        }
        entry.pins += 1;
        return entry.serial;
    }

    /// Forgets the entries of table `namespace` that are modules linked from another context (and what
    /// imported them), so the next import makes a module of its own. Returns how many entries it dropped.
    pub fn dropShared(self: *ModuleMap, keys: []const ModuleMapKey) !usize {
        var count: usize = 0;
        for (keys) |key| count += try self.deleteCache(key);
        return count;
    }

    /// Keeps the module `id` (attributes none) alive until `unpin` of the returned serial: a
    /// holder outside the map (a reference handle) pins what it uses. Returns 0 when the table
    /// has no such module. Requires the entered context.
    pub fn pin(self: *ModuleMap, id: []const u8) !u32 {
        // The first table that holds the module (without attributes) under that id.
        const entry = for (self.all_entries.items) |candidate| {
            if (candidate.cached and !candidate.dead and candidate.attributes.len == 0 and std.mem.eql(u8, candidate.id, id)) break candidate;
        } else return 0;
        if (entry.serial == 0) {
            self.next_serial += 1;
            entry.serial = self.next_serial;
        }
        entry.pins += 1;
        return entry.serial;
    }

    /// Drops one pin of the entry `serial` names; an unpinned module the table no longer holds
    /// (or never held, under `retain: used`) is freed at once. Unknown serials are ignored.
    pub fn unpin(self: *ModuleMap, serial: u32) void {
        if (serial == 0) return;
        for (self.all_entries.items) |entry| {
            if (entry.serial != serial or entry.pins == 0) continue;
            entry.pins -= 1;
            break;
        }
        self.sweep();
    }

    /// Frees the modules nothing holds. A module is held while the table keeps it (always with
    /// `retain: all`, never with `retain: used`), while it is pinned, while an import or load is
    /// in flight for it, and while a held module imports it. Evicts the oldest unpinned entries
    /// first when the table is over `Options.table_limit`. A no-op while a callback is running.
    /// Requires the entered context and a live HandleScope.
    pub fn sweep(self: *ModuleMap) void {
        if (self.driving or self.preparing_depth != 0 or self.sweeping) return;
        self.sweeping = true;
        defer self.sweeping = false;
        // Each table over its cap drops its oldest unpinned entries first.
        for (self.all_entries.items) |first| {
            if (!first.cached) continue;
            const limit = self.scope.policyOf(first.namespace).limit orelse continue;
            var cached = self.countNamespace(first.namespace);
            for (self.all_entries.items) |entry| {
                if (cached <= limit) break;
                if (entry.namespace == first.namespace and entry.cached and entry.pins == 0 and !entry.preparing and entry.pending == null) {
                    _ = self.entries.remove(entry.cache_key);
                    entry.cached = false;
                    cached -= 1;
                }
            }
        }
        self.resetVisited();
        for (self.all_entries.items) |entry| {
            const used = self.scope.policyOf(entry.namespace).retain == .used;
            const held = entry.pins != 0 or entry.grace or entry.preparing or entry.pending != null or entry.unresolved.items.len != 0 or (entry.cached and !used);
            if (held) self.mark(entry);
        }
        for (self.tasks.items) |task| if (task.root) |root| self.mark(root);
        var kept: usize = 0;
        for (self.all_entries.items) |entry| {
            if (entry.visited) {
                self.all_entries.items[kept] = entry;
                kept += 1;
                continue;
            }
            self.release(entry);
        }
        self.all_entries.shrinkRetainingCapacity(kept);
        for (self.all_entries.items) |entry| entry.grace = false;
        self.resetVisited();
    }

    fn mark(self: *ModuleMap, entry: *Entry) void {
        if (entry.visited) return;
        entry.visited = true;
        for (entry.dependencies.items) |dependency| self.mark(dependency.entry);
    }

    /// Releases one swept entry: out of the table and the identity index, every handle dropped.
    fn release(self: *ModuleMap, entry: *Entry) void {
        const alloc = self.scope.runtime.allocator;
        if (entry.shared) if (self.scope.options.shared_released) |hook| hook.call(hook.data, entry.cache_key);
        if (entry.cached) {
            _ = self.entries.remove(entry.cache_key);
            entry.cached = false;
        }
        if (entry.module) |module| {
            const hash = module.deref().getIdentityHash();
            if (self.by_identity.getPtr(hash)) |head| {
                if (head.* == entry) {
                    if (entry.identity_next) |next| head.* = next else _ = self.by_identity.remove(hash);
                } else {
                    var cursor = head.*;
                    while (cursor.identity_next) |next| : (cursor = next) {
                        if (next == entry) {
                            cursor.identity_next = entry.identity_next;
                            break;
                        }
                    }
                }
            }
            module.deinit();
            entry.module = null;
        }
        if (entry.failure) |value| value.deinit();
        entry.failure = null;
        if (entry.evaluation) |value| value.deinit();
        entry.evaluation = null;
        for (entry.exports) |exp| exp.value.deinit();
        entry.exports = &.{};
        entry.dependencies.deinit(alloc);
        entry.dependencies = .empty;
        if (entry.cache_source) |source| alloc.free(source);
        entry.cache_source = null;
        entry.unresolved.deinit(alloc);
        entry.unresolved = .empty;
        entry.dead = true;
    }

    /// Adds `entry` (whose module is set) to the identity index. Allocation failure leaves the
    /// entry unindexed, which `find` would then miss, so callers propagate it.
    fn indexModule(self: *ModuleMap, entry: *Entry) !void {
        const hash = entry.module.?.deref().getIdentityHash();
        const slot = try self.by_identity.getOrPut(self.scope.runtime.allocator, hash);
        entry.identity_next = if (slot.found_existing) slot.value_ptr.* else null;
        slot.value_ptr.* = entry;
    }

    /// Borrows self/module through lookup; returns a map-owned entry valid until
    /// map deinit, including retired entries. Requires a live local module handle.
    fn find(self: *ModuleMap, module: v8.Module) ?*Entry {
        var cursor = self.by_identity.get(module.getIdentityHash());
        while (cursor) |entry| : (cursor = entry.identity_next) {
            const stored = entry.module.?.deref();
            // Local handles are distinct slots. Compare module identity, not their addresses.
            if (stored.data.handle == module.data.handle or stored.data.eq(module.data)) return entry;
        }
        return null;
    }

    /// Borrows specifier/referrer/attributes through return; retained entry metadata
    /// is deep-copied. Returns a local promise valid in the caller's HandleScope;
    /// use a persistent Global to keep it after that scope ends.
    pub fn start(self: *ModuleMap, specifier: []const u8, referrer: []const u8, raw_attributes: []const ImportAttribute) !v8.Promise {
        return self.startIn(0, specifier, referrer, raw_attributes);
    }

    /// `start` for a root import (empty `referrer`) into table `namespace`.
    pub fn startIn(self: *ModuleMap, namespace: u32, specifier: []const u8, referrer: []const u8, raw_attributes: []const ImportAttribute) !v8.Promise {
        var scratch = std.heap.ArenaAllocator.init(self.scope.runtime.allocator);
        defer scratch.deinit();
        const alloc = scratch.allocator();
        const attributes = normalizeAttributes(alloc, raw_attributes) catch |err| return self.rejected(self.errorValue(err));
        return self.startNormalized(alloc, namespace, specifier, referrer, attributes);
    }

    /// The table the imports of `referrer` (in table `referrer_namespace`) live in.
    fn dependencyNamespace(self: *ModuleMap, referrer_namespace: u32, referrer: []const u8) u32 {
        const resolver = self.scope.options.resolver orelse return referrer_namespace;
        const hook = resolver.namespace_of orelse return referrer_namespace;
        return hook(resolver.data, referrer_namespace, referrer);
    }

    /// The table of a module known by id only (a dynamic `import()` names its referrer that way): the
    /// first live entry with that id.
    fn namespaceOfId(self: *ModuleMap, id: []const u8) u32 {
        for (self.all_entries.items) |entry| if (!entry.dead and std.mem.eql(u8, entry.id, id)) return entry.namespace;
        return 0;
    }

    /// Borrows exception through return; returns a rejected local promise in
    /// the current HandleScope. Requires entered isolate/context; failure retains
    /// no host resources. V8 retains the rejection value with the promise.
    fn rejected(self: *ModuleMap, exception: v8.Value) !v8.Promise {
        const resolver = eu.v.promise_resolver(self.ctx()) orelse return error.JavaScriptException;
        _ = resolver.reject(self.ctx(), exception);
        return resolver.getPromise();
    }

    /// Borrows request slices and alloc until the synchronous resolution/load
    /// setup returns. Returned Promise is a local handle in the caller's scope.
    fn startNormalized(self: *ModuleMap, alloc: std.mem.Allocator, root_namespace: u32, specifier: []const u8, referrer: []const u8, attributes: []const ImportAttribute) !v8.Promise {
        self.preparing_depth += 1;
        defer self.preparing_depth -= 1;
        const resolver = eu.v.promise_resolver(self.ctx()) orelse return error.JavaScriptException;
        const promise = resolver.getPromise();
        var tc_scope: v8.TryCatch = undefined;
        tc_scope.init(self.isolate());
        defer tc_scope.deinit();
        const referrer_namespace = if (referrer.len == 0) root_namespace else self.namespaceOfId(referrer);
        const target_namespace = if (referrer.len == 0 and root_namespace != 0) root_namespace else self.dependencyNamespace(referrer_namespace, referrer);
        const resolved = self.resolve(alloc, specifier, referrer, referrer_namespace, attributes) catch |err| {
            _ = resolver.reject(self.ctx(), tc_scope.getException() orelse self.errorValue(err));
            return promise;
        };
        switch (resolved) {
            .id => |id| {
                const root = self.fetch(alloc, target_namespace, id, attributes) catch |err| {
                    _ = resolver.reject(self.ctx(), tc_scope.getException() orelse self.errorValue(err));
                    return promise;
                };
                const retained = v8.Global.Of(v8.Promise.Resolver).new(self.isolate(), resolver);
                errdefer retained.deinit();
                try self.tasks.append(self.scope.runtime.allocator, .{ .root = root, .resolver = retained });
            },
            .pending => |token| {
                const retained = v8.Global.Of(v8.Promise.Resolver).new(self.isolate(), resolver);
                errdefer retained.deinit();
                const owned_attributes = try self.arenaAllocator().alloc(ImportAttribute, attributes.len);
                for (attributes, owned_attributes) |attribute, *copy| copy.* = .{ .key = try self.arenaAllocator().dupe(u8, attribute.key), .value = try self.arenaAllocator().dupe(u8, attribute.value) };
                try self.tasks.append(self.scope.runtime.allocator, .{
                    .root = null,
                    .resolver = retained,
                    .namespace = target_namespace,
                    .root_token = token,
                    .specifier = try self.arenaAllocator().dupe(u8, specifier),
                    .attributes = owned_attributes,
                });
            },
        }
        _ = self.drive();
        return promise;
    }

    /// Copies attributes into alloc-owned storage; caller releases the copy with
    /// alloc. Input strings remain borrowed and immutable during the call.
    fn normalizeAttributes(alloc: std.mem.Allocator, attributes: []const ImportAttribute) ![]const ImportAttribute {
        const owned = try alloc.dupe(ImportAttribute, attributes);
        try sortAttributes(owned);
        return owned;
    }

    /// Borrows and reorders the attribute slice and reads nested strings through
    /// return. Transfers no ownership; duplicate-key errors leave the slice sorted.
    fn sortAttributes(attributes: []ImportAttribute) !void {
        std.mem.sort(ImportAttribute, attributes, {}, struct {
            /// Borrows nested strings through comparison; returns a copied boolean and
            /// retains no resources.
            fn less(_: void, a: ImportAttribute, b: ImportAttribute) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.less);
        for (attributes, 0..) |attribute, i| if (i > 0 and std.mem.eql(u8, attribute.key, attributes[i - 1].key)) return error.DuplicateImportAttribute;
    }

    /// Reads V8 strings while the isolate/context and caller HandleScope are
    /// live. Returns alloc-owned copied strings; caller releases them with alloc.
    fn readAttributes(self: *ModuleMap, alloc: std.mem.Allocator, array: v8.FixedArray, stride: c_int) ![]const ImportAttribute {
        if (@mod(array.len(), stride) != 0) return error.InvalidImportAttributes;
        const attributes = try alloc.alloc(ImportAttribute, @intCast(@divExact(array.len(), stride)));
        for (attributes, 0..) |*attribute, i| {
            const index: c_int = @intCast(i * @as(usize, @intCast(stride)));
            const key = v8.String.from_opaque(array.get(index).?.handle) orelse return error.InvalidImportAttributes;
            const value = v8.String.from_opaque(array.get(index + 1).?.handle) orelse return error.InvalidImportAttributes;
            attribute.* = .{ .key = try string(alloc, self.isolate(), key), .value = try string(alloc, self.isolate(), value) };
        }
        try sortAttributes(attributes);
        return attributes;
    }

    /// Borrows self/entry through traversal, updating visited flags. Returns a
    /// local exception aliasing a retained entry failure, valid in the current
    /// HandleScope; requires entered isolate and retains no additional handle.
    fn graphFailure(self: *ModuleMap, entry: *Entry) ?v8.Value {
        if (entry.visited) return null;
        entry.visited = true;
        if (entry.failure) |failure| return failure.deref();
        for (entry.dependencies.items) |dep| if (self.graphFailure(dep.entry)) |failure| return failure;
        return null;
    }
    /// Borrows self through return; mutates entry flags and retains no resources.
    fn resetVisited(self: *ModuleMap) void {
        for (self.all_entries.items) |entry| entry.visited = false;
    }

    /// Canonical IDs, not unresolved specifiers. Retire reverse dependencies too.
    /// Borrows key and its nested slices only through return; copies no caller pointer
    /// into retained state. Returns a count; never frees caller-owned input memory.
    pub fn deleteCache(self: *ModuleMap, key: ImportCacheKey) !usize {
        if (self.driving or self.preparing_depth != 0) return error.ImportCacheBusy;
        var scratch = std.heap.ArenaAllocator.init(self.scope.runtime.allocator);
        defer scratch.deinit();
        const attributes = try normalizeAttributes(scratch.allocator(), key.import_attributes);
        const encoded = try cacheKey(scratch.allocator(), key.namespace, key.module_id, attributes);
        const target = self.entries.get(encoded) orelse return 0;
        const count = self.invalidate(target);
        self.sweep();
        return count;
    }
    /// Borrows target through return; retires dependent cache entries without
    /// freeing their storage/handles, which remain owned by the map until deinit.
    /// Returns a copied count; caller must prevent concurrent/reentrant mutation.
    fn invalidate(self: *ModuleMap, target: *Entry) usize {
        self.resetVisited();
        target.visited = true;
        var changed = true;
        while (changed) {
            changed = false;
            for (self.all_entries.items) |entry| {
                if (!entry.cached or entry.visited) continue;
                for (entry.dependencies.items) |dep| if (dep.entry.visited) {
                    entry.visited = true;
                    changed = true;
                    break;
                };
            }
        }
        var count: usize = 0;
        for (self.all_entries.items) |entry| {
            if (entry.cached and entry.visited) {
                _ = self.entries.remove(entry.cache_key);
                entry.cached = false;
                count += 1;
            }
        }
        return count;
    }
    /// Borrows self through return; removes active mappings, retaining retired
    /// entry storage/handles until map deinit. Errors retain the map unchanged.
    /// Requires the owning runtime thread and no active load/compile callback.
    pub fn clearCache(self: *ModuleMap, namespace: ?u32) !usize {
        if (self.driving or self.preparing_depth != 0) return error.ImportCacheBusy;
        var count: usize = 0;
        for (self.all_entries.items) |entry| {
            if (!entry.cached or (namespace != null and entry.namespace != namespace.?)) continue;
            _ = self.entries.remove(entry.cache_key);
            entry.cached = false;
            count += 1;
        }
        self.sweep();
        return count;
    }
    /// Borrows key/content, nested names and handles through return, including error
    /// returns. Retained metadata/handles are independently copied; no ownership transfer.
    /// error_info must be initialized; previous details are released on entry.
    /// Its exception field owns caught values; deinit the ErrorInfo before Runtime.destroy.
    pub fn updateCache(self: *ModuleMap, key: ImportCacheKey, content: Content, error_info: ?*ErrorInfo) !void {
        if (error_info) |out| out.deinit();
        if (self.driving or self.preparing_depth != 0) return error.ImportCacheBusy;
        var scratch = std.heap.ArenaAllocator.init(self.scope.runtime.allocator);
        defer scratch.deinit();
        const attributes = try normalizeAttributes(scratch.allocator(), key.import_attributes);
        const encoded = try cacheKey(scratch.allocator(), key.namespace, key.module_id, attributes);
        const old = self.entries.get(encoded);
        // Reserve before invalidation so allocation failure leaves the old lookup intact.
        const replacement = try self.allocEntry(key.namespace, key.module_id, attributes, encoded);
        if (old) |entry| _ = self.invalidate(entry);
        self.entries.putAssumeCapacity(replacement.cache_key, replacement);
        var tc_scope: v8.TryCatch = undefined;
        tc_scope.init(self.isolate());
        defer tc_scope.deinit();
        self.compile(replacement, content) catch |err| {
            self.fail(replacement, tc_scope.getException() orelse self.errorValue(err));
            if (error_info) |out| if (tc_scope.getException()) |exception| {
                out.exception = .new(self.isolate(), exception);
            };
            return err;
        };
    }
    /// Borrows self/entry through traversal and mutates visited flags; returns
    /// a copied readiness result and retains no resources.
    fn ready(self: *ModuleMap, entry: *Entry) bool {
        if (entry.preparing) return false;
        if (entry.visited) return true;
        entry.visited = true;
        for (entry.dependencies.items) |dep| if (!self.ready(dep.entry)) return false;
        return true;
    }
    /// Called in this scope's context. Returns whether an import settled.
    pub fn drive(self: *ModuleMap) bool {
        if (self.driving) return false;
        self.driving = true;
        defer self.driving = false;
        var progress = false;
        if (self.scope.options.loader) |loader| if (loader.poll) |poll| {
            if (poll(loader.data)) progress = true;
        };
        var index: usize = 0;
        // Evaluation can synchronously trigger more dynamic imports and grow tasks.
        while (index < self.tasks.items.len) : (index += 1) {
            if (self.tasks.items[index].settled) continue;
            const root = self.tasks.items[index].root orelse continue;
            const resolver = self.tasks.items[index].resolver.deref();
            self.resetVisited();
            if (self.graphFailure(root)) |failure| {
                self.tasks.items[index].settled = true;
                _ = resolver.reject(self.ctx(), failure);
                progress = true;
                continue;
            }
            self.resetVisited();
            if (!self.ready(root)) continue;
            var tc_scope: v8.TryCatch = undefined;
            tc_scope.init(self.isolate());
            defer tc_scope.deinit();
            if (root.evaluation == null) {
                const module = root.module.?.deref();
                if (module.getStatus() == 5) {
                    self.fail(root, module.getException().?);
                    progress = true; // the import promise just settled
                    continue;
                }
                if (module.getStatus() == 0) {
                    if (!(module.instantiateModule(self.ctx(), resolveStatic, null) orelse false)) {
                        self.fail(root, tc_scope.getException() orelse self.errorValue(error.LinkFailed));
                        progress = true;
                        continue;
                    }
                }
                // Guard against re-entrant drive while V8 is evaluating this root.
                self.tasks.items[index].settled = true;
                const result = module.evaluate(self.ctx());
                progress = true;
                self.tasks.items[index].settled = false;
                if (result) |value| {
                    root.evaluation = .new(self.isolate(), v8.Promise.from_opaque(value.data.handle).?);
                } else {
                    self.fail(root, tc_scope.getException() orelse self.errorValue(error.EvaluationFailed));
                    progress = true;
                    continue;
                }
            }
            const evaluation = root.evaluation.?.deref();
            switch (evaluation.state()) {
                .Pending => {},
                .Fulfilled => {
                    self.tasks.items[index].settled = true;
                    root.grace = true;
                    _ = resolver.resolve(self.ctx(), root.module.?.deref().getModuleNamespace().?);
                    progress = true;
                },
                .Rejected => {
                    self.tasks.items[index].settled = true;
                    _ = resolver.reject(self.ctx(), evaluation.result());
                    progress = true;
                },
            }
        }
        var finished: usize = 0;
        while (finished < self.tasks.items.len) {
            if (self.tasks.items[finished].settled) {
                self.tasks.items[finished].resolver.deinit();
                _ = self.tasks.swapRemove(finished);
            } else finished += 1;
        }
        self.driving = false;
        if (progress) self.sweep();
        self.driving = true;
        return progress;
    }
};

/// Borrows a local managed context through return; returns its runtime-owned
/// Scope pointer, valid until Runtime.destroy begins. Requires a context created
/// by Runtime.createScope, entered isolate and a live HandleScope.
pub fn fromContext(ctx: v8.Context) ?*Scope {
    return @ptrCast(@alignCast(ctx.getAlignedPointerFromEmbedderData(1)));
}
/// A promise rejected with an Error saying the context's scope is gone. Needs no scope, so it
/// works once the scope has been freed and only a stray reference into the context is left.
fn rejectedDisposed(ctx: v8.Context) v8.MaybeHandle {
    const resolver = eu.v.promise_resolver(ctx) orelse return null;
    const isolate = v8.Isolate.getCurrent();
    const reason = eu.v.err(eu.v.str_utf8(isolate, "ScopeDisposed")) orelse return null;
    _ = resolver.reject(ctx, reason);
    return resolver.getPromise().object.value.data.handle;
}
/// Borrows local callback handles through return in the entered context;
/// V8 copies the module URL into meta, then the scope's meta hook (if any) adds its
/// properties. Retains no host storage or handles.
pub fn importMeta(ctx: v8.Context, module: v8.Module, meta: v8.Object) callconv(.c) void {
    const scope = fromContext(ctx) orelse return;
    const entry = scope.module_map.find(module) orelse return;
    _ = meta.createDataProperty(ctx, eu.v.str_utf8(scope.runtime.isolate, "url").name, eu.v.str_utf8(scope.runtime.isolate, entry.id).name.primitive.value);
    if (scope.options.meta) |hook| hook.init(hook.data, .{ .context = ctx, .scope_id = scope.id, .module_id = entry.id, .namespace = entry.namespace, .meta = meta });
}
/// Borrows callback locals in the entered context through return; scratch
/// allocations are released on success/error. Returns a local module handle
/// from map-owned state, valid in the enclosing HandleScope; transfers no ownership.
fn resolveStatic(ctx: v8.Context, specifier: v8.String, attributes: v8.FixedArray, referrer: v8.Module) callconv(.c) v8.MaybeHandle {
    const scope = fromContext(ctx) orelse return null;
    const registry = &scope.module_map;
    const entry = registry.find(referrer) orelse return null;
    var scratch = std.heap.ArenaAllocator.init(scope.runtime.allocator);
    defer scratch.deinit();
    const parsed = registry.readAttributes(scratch.allocator(), attributes, 3) catch return null;
    const text = string(scratch.allocator(), registry.isolate(), specifier) catch return null;
    for (entry.dependencies.items) |dep| if (std.mem.eql(u8, text, dep.specifier) and equalAttributes(parsed, dep.attributes)) {
        return dep.entry.module.?.deref().data.handle;
    };
    return null;
}
/// Borrows callback locals through return; copies export names and installs
/// map-retained values into the V8 module. Returns a local promise or null in
/// the enclosing HandleScope; requires entered context and retains no host inputs.
fn synthetic(ctx: v8.Context, module: v8.Module) callconv(.c) v8.MaybeHandle {
    const scope = fromContext(ctx) orelse return null;
    const entry = scope.module_map.find(module) orelse return null;
    for (entry.exports) |exp| {
        if (!(module.setSyntheticModuleExport(scope.runtime.isolate, eu.v.str_utf8(scope.runtime.isolate, exp.name), exp.value.deref()) orelse false)) return null;
    }
    const resolver = eu.v.promise_resolver(ctx) orelse return null;
    _ = resolver.resolve(ctx, eu.v.undefined_value(scope.runtime.isolate).value);
    return resolver.getPromise().object.value.data.handle;
}
/// Borrows callback locals through synchronous import setup; scratch storage
/// is released before return. Returns a local promise in the enclosing HandleScope;
/// map-owned load/task state persists through settlement or map deinit, including
/// rejection paths. Requires entered isolate/context.
pub fn dynamic(ctx: v8.Context, _: v8.Data, resource: v8.Value, specifier: v8.String, attributes: v8.FixedArray) callconv(.c) v8.MaybeHandle {
    const scope = fromContext(ctx) orelse return rejectedDisposed(ctx);
    if (scope.disposed) return rejectedDisposed(ctx);
    var tc_scope: v8.TryCatch = undefined;
    tc_scope.init(scope.runtime.isolate);
    defer tc_scope.deinit();
    const registry = &scope.module_map;
    var scratch = std.heap.ArenaAllocator.init(scope.runtime.allocator);
    defer scratch.deinit();
    const promise = dynamicStart(registry, scratch.allocator(), resource, specifier, attributes) catch |err| {
        const rejected = registry.rejected(tc_scope.getException() orelse registry.errorValue(err)) catch return null;
        return rejected.object.value.data.handle;
    };
    return promise.object.value.data.handle;
}
/// Borrows local handles and alloc through synchronous startup; caller keeps the
/// isolate entered and a HandleScope live. Returns a local Promise handle there.
fn dynamicStart(registry: *ModuleMap, alloc: std.mem.Allocator, resource: v8.Value, specifier: v8.String, attributes: v8.FixedArray) !v8.Promise {
    const parsed = try registry.readAttributes(alloc, attributes, 2);
    const referrer = if (resource.isString()) try string(alloc, registry.isolate(), v8.String.from_opaque(resource.data.handle).?) else "";
    const text = try string(alloc, registry.isolate(), specifier);
    return registry.startNormalized(alloc, 0, text, referrer, parsed);
}

/// Borrows slices and nested strings through comparison; returns a copied
/// boolean and retains no resources.
fn equalAttributes(a: []const ImportAttribute, b: []const ImportAttribute) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x.key, y.key) or !std.mem.eql(u8, x.value, y.value)) return false;
    return true;
}
/// Borrows callback locals through return; returns a local import/rejection
/// promise in the enclosing HandleScope. Evaluation delegates to dynamic, whose
/// map-owned task state persists; unsupported phases retain no host inputs.
pub fn dynamicPhase(ctx: v8.Context, options: v8.Data, resource: v8.Value, specifier: v8.String, phase: v8.ModuleImportPhase, attributes: v8.FixedArray) callconv(.c) v8.MaybeHandle {
    if (phase == .Evaluation) return dynamic(ctx, options, resource, specifier, attributes);
    const scope = fromContext(ctx) orelse return rejectedDisposed(ctx);
    const promise = scope.module_map.rejected(scope.module_map.errorValue(error.UnsupportedImport)) catch return null;
    return promise.object.value.data.handle;
}
/// Borrows a local V8 string during the call; returns caller-owned UTF-8 bytes.
/// Free the result with alloc. Caller keeps isolate/HandleScope entered.
pub fn string(alloc: std.mem.Allocator, isolate: v8.Isolate, value: v8.String) ![]const u8 {
    const result = try alloc.alloc(u8, value.lenUtf8(isolate));
    _ = value.writeUtf8(isolate, result);
    return result;
}
