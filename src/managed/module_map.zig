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
const Entry = struct {
    cache_key: []const u8,
    cached: bool = true,
    id: ModuleId,
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
    /// Source copy kept until `flushCodeCache` for a module compiled without a usable code
    /// cache. Null once flushed, for modules that consumed a cache, and without a hook.
    cache_source: ?[]const u8 = null,
};
const Task = struct {
    root: *Entry,
    resolver: v8.Global.Of(v8.Promise.Resolver),
    settled: bool = false,
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
        const encoded = try cacheKey(scratch.allocator(), key.module_id, attributes);
        const entry = self.entries.get(encoded) orelse return null;
        if (entry.failure) |failure| {
            if (error_info) |out| out.exception = .new(iso, failure.deref());
            return error.JavaScriptException;
        }
        const module = entry.module orelse return null;
        return .new(iso, module.deref());
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
            if (entry.module) |value| value.deinit();
            if (entry.failure) |value| value.deinit();
            if (entry.evaluation) |value| value.deinit();
            for (entry.exports) |exp| exp.value.deinit();
            entry.dependencies.deinit(self.scope.runtime.allocator);
        }
        for (self.tasks.items) |task| {
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
    fn resolve(self: *ModuleMap, alloc: std.mem.Allocator, specifier: []const u8, referrer: []const u8, attributes: []const ImportAttribute) ![]const u8 {
        const enabled = self.scope.options.enable_origine_namespace;
        if (!enabled and std.mem.startsWith(u8, specifier, origine_prefix)) return error.OrigineNamespaceDisabled;
        const resolver = self.scope.options.resolver orelse return alloc.dupe(u8, specifier);
        const id = try resolver.resolve(resolver.data, .{ .allocator = alloc, .context = self.ctx(), .scope_id = self.scope.id, .specifier = specifier, .referrer = referrer, .import_attributes = attributes });
        if (!enabled and std.mem.startsWith(u8, id, origine_prefix)) return error.OrigineNamespaceDisabled;
        return id;
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
    fn cacheKey(alloc: std.mem.Allocator, id: []const u8, attributes: []const ImportAttribute) ![]const u8 {
        // Length framing makes IDs and attribute pairs unambiguous.
        var size = try componentSize(id);
        for (attributes) |attr| {
            size = try std.math.add(usize, size, try componentSize(attr.key));
            size = try std.math.add(usize, size, try componentSize(attr.value));
        }
        const key = try alloc.alloc(u8, size);
        errdefer alloc.free(key);
        var written = (std.fmt.bufPrint(key, "{d}:{s}", .{ id.len, id }) catch unreachable).len;
        for (attributes) |attr| written += (std.fmt.bufPrint(key[written..], "{d}:{s}{d}:{s}", .{ attr.key.len, attr.key, attr.value.len, attr.value }) catch unreachable).len;
        std.debug.assert(written == key.len);
        return key;
    }
    /// Borrows id/attributes/key through return and copies them into map-owned
    /// storage. Returns an Entry owned by this ModuleMap; callers do not free it.
    /// Partial allocations on error remain map-owned until ModuleMap.deinit.
    fn allocEntry(self: *ModuleMap, id: []const u8, attributes: []const ImportAttribute, key: []const u8) !*Entry {
        const alloc = self.scope.runtime.allocator;
        try self.entries.ensureUnusedCapacity(alloc, 1);
        try self.all_entries.ensureUnusedCapacity(alloc, 1);
        const entry = try self.arenaAllocator().create(Entry);
        const owned_attributes = try self.arenaAllocator().alloc(ImportAttribute, attributes.len);
        for (attributes, owned_attributes) |attribute, *item| item.* = .{
            .key = try self.arenaAllocator().dupe(u8, attribute.key),
            .value = try self.arenaAllocator().dupe(u8, attribute.value),
        };
        entry.* = .{ .id = try self.arenaAllocator().dupe(u8, id), .attributes = owned_attributes, .cache_key = try self.arenaAllocator().dupe(u8, key) };
        self.all_entries.appendAssumeCapacity(entry);
        return entry;
    }
    /// Borrows id, attributes, and alloc through return. Returns an Entry owned
    /// by this ModuleMap; caller-owned temporary key storage remains with alloc.
    fn fetch(self: *ModuleMap, alloc: std.mem.Allocator, id: []const u8, attributes: []const ImportAttribute) anyerror!*Entry {
        const key = try cacheKey(alloc, id, attributes);
        if (self.entries.get(key)) |entry| return entry;
        const entry = try self.allocEntry(id, attributes, key);
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
        switch (try loader.load(loader.data, .{ .allocator = self.arenaAllocator(), .context = self.ctx(), .scope_id = self.scope.id, .module_id = entry.id, .token = token, .import_attributes = entry.attributes })) {
            .source => |source| try self.compile(entry, .{ .source = source }),
            .exports => |exports| try self.compile(entry, .{ .exports = exports }),
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
                if (self.scope.options.code_cache != null and !accepted) entry.cache_source = try self.arenaAllocator().dupe(u8, text);
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
                    const id = try self.resolve(alloc, specifier, entry.id, attributes);
                    const dependency = try self.fetch(alloc, id, attributes);
                    entry.dependencies.appendAssumeCapacity(.{ .specifier = try self.arenaAllocator().dupe(u8, specifier), .attributes = dependency.attributes, .entry = dependency });
                }
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
        entry.preparing = false;
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
            if (entry.failure != null or entry.pending != null or entry.preparing or entry.exports.len != 0) return error.NotSnapshottable;
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
            const key = try cacheKey(scratch.allocator(), module.id, module.attributes);
            entry.* = try self.allocEntry(module.id, module.attributes, key);
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
        var scratch = std.heap.ArenaAllocator.init(self.scope.runtime.allocator);
        defer scratch.deinit();
        const alloc = scratch.allocator();
        const attributes = normalizeAttributes(alloc, raw_attributes) catch |err| return self.rejected(self.errorValue(err));
        return self.startNormalized(alloc, specifier, referrer, attributes);
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
    fn startNormalized(self: *ModuleMap, alloc: std.mem.Allocator, specifier: []const u8, referrer: []const u8, attributes: []const ImportAttribute) !v8.Promise {
        self.preparing_depth += 1;
        defer self.preparing_depth -= 1;
        const resolver = eu.v.promise_resolver(self.ctx()) orelse return error.JavaScriptException;
        const promise = resolver.getPromise();
        var tc_scope: v8.TryCatch = undefined;
        tc_scope.init(self.isolate());
        defer tc_scope.deinit();
        const id = self.resolve(alloc, specifier, referrer, attributes) catch |err| {
            _ = resolver.reject(self.ctx(), tc_scope.getException() orelse self.errorValue(err));
            return promise;
        };
        const root = self.fetch(alloc, id, attributes) catch |err| {
            _ = resolver.reject(self.ctx(), tc_scope.getException() orelse self.errorValue(err));
            return promise;
        };
        const retained = v8.Global.Of(v8.Promise.Resolver).new(self.isolate(), resolver);
        errdefer retained.deinit();
        try self.tasks.append(self.scope.runtime.allocator, .{ .root = root, .resolver = retained });
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
        const encoded = try cacheKey(scratch.allocator(), key.module_id, attributes);
        const target = self.entries.get(encoded) orelse return 0;
        return self.invalidate(target);
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
    pub fn clearCache(self: *ModuleMap) !usize {
        if (self.driving or self.preparing_depth != 0) return error.ImportCacheBusy;
        const count = self.entries.count();
        self.entries.clearRetainingCapacity();
        for (self.all_entries.items) |entry| entry.cached = false;
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
        const encoded = try cacheKey(scratch.allocator(), key.module_id, attributes);
        const old = self.entries.get(encoded);
        // Reserve before invalidation so allocation failure leaves the old lookup intact.
        const replacement = try self.allocEntry(key.module_id, attributes, encoded);
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
        var index: usize = 0;
        // Evaluation can synchronously trigger more dynamic imports and grow tasks.
        while (index < self.tasks.items.len) : (index += 1) {
            if (self.tasks.items[index].settled) continue;
            const root = self.tasks.items[index].root;
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
        return progress;
    }
};

/// Borrows a local managed context through return; returns its runtime-owned
/// Scope pointer, valid until Runtime.destroy begins. Requires a context created
/// by Runtime.createScope, entered isolate and a live HandleScope.
pub fn fromContext(ctx: v8.Context) *Scope {
    return @ptrCast(@alignCast(ctx.getAlignedPointerFromEmbedderData(1).?));
}
/// Borrows local callback handles through return in the entered context;
/// V8 copies the module URL into meta, then the scope's meta hook (if any) adds its
/// properties. Retains no host storage or handles.
pub fn importMeta(ctx: v8.Context, module: v8.Module, meta: v8.Object) callconv(.c) void {
    const scope = fromContext(ctx);
    const entry = scope.module_map.find(module) orelse return;
    _ = meta.createDataProperty(ctx, eu.v.str_utf8(scope.runtime.isolate, "url").name, eu.v.str_utf8(scope.runtime.isolate, entry.id).name.primitive.value);
    if (scope.options.meta) |hook| hook.init(hook.data, .{ .context = ctx, .scope_id = scope.id, .module_id = entry.id, .meta = meta });
}
/// Borrows callback locals in the entered context through return; scratch
/// allocations are released on success/error. Returns a local module handle
/// from map-owned state, valid in the enclosing HandleScope; transfers no ownership.
fn resolveStatic(ctx: v8.Context, specifier: v8.String, attributes: v8.FixedArray, referrer: v8.Module) callconv(.c) v8.MaybeHandle {
    const scope = fromContext(ctx);
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
    const scope = fromContext(ctx);
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
    const scope = fromContext(ctx);
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
    return registry.startNormalized(alloc, text, referrer, parsed);
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
    const scope = fromContext(ctx);
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
