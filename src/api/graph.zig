//! The module graph: import pipelines and the natives behind `api.graph`.
//!
//! An `ImportHandler` of `origine:@std/graph/import` is flattened by the glue into a JSON spec and
//! registered here as a `Handler`: ordered resolver layers, hooks, a maker and a cache. Every
//! element is either a host descriptor (run here, natively) or a JS function. A handler with no
//! function in it is `native`: the whole pipeline runs in Zig (`context.zig` plugs it into a
//! scope's resolver and loader) and never enters JS. Otherwise the glue's JS driver runs the
//! chain in the creating realm and asks this file to run the native elements one by one
//! (`layer`, `hook`, `transform`, `readSource`). Both paths use the same step functions.
//!
//! Authority is not in the descriptors: file reads go through the graph's fs grant, and
//! `origine:` modules are served only by the `origine` hook, within the allowlist of the realm
//! that created the handler.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const binding = @import("binding.zig");
const Call = binding.Call;
const errno = @import("errno.zig");
const fs_api = @import("fs.zig");
const host_mod = @import("host.zig");
const Host = host_mod.Host;
const ScopeState = host_mod.ScopeState;
const import_map = @import("../managed/import_map.zig");
const module_types = @import("../managed/module_types.zig");
const init_loader = @import("init_loader.zig");
const init_cache = @import("init_cache.zig");
const json_module = @import("json_module.zig");
const oxc = @import("transform/oxc.zig");
const transformer_api = @import("transform/transformer.zig");
const sys = @import("../managed/sys.zig");

const Error = errno.Error;

comptime {
    @setEvalBranchQuota(200_000);
    errno.requireBinding(graphCreate);
    errno.requireBinding(handler);
    errno.requireBinding(layer);
    errno.requireBinding(hook);
    errno.requireBinding(transform);
    errno.requireBinding(readSource);
    errno.requireBinding(compileRequests);
    errno.requireBinding(bind);
    errno.requireBinding(asyncFs);
    errno.requireBinding(utf8);
    errno.requireBinding(sourceHash);
    errno.requireBinding(jsonModule);
    errno.requireBinding(pipelineResolve);
    errno.requireBinding(pipelineLoad);
}

// ---- std allowlist ---------------------------------------------------------

/// The `origine:@std/*` modules an `origine` hook serves (names without `origine:@std/`).
/// `include` and `exclude` are exclusive; null `include` with null `exclude` allows all.
pub const StdFilter = struct {
    include: ?[]const []const u8 = null,
    exclude: ?[]const []const u8 = null,

    pub fn allows(self: StdFilter, name: []const u8) bool {
        if (self.include) |list| {
            for (list) |item| if (std.mem.eql(u8, item, name)) return true;
            return false;
        }
        if (self.exclude) |list| for (list) |item| if (std.mem.eql(u8, item, name)) return false;
        return true;
    }

    /// Whether every module `self` allows is allowed by `ceiling` too (a hook can only narrow).
    /// A list-wise check: an `exclude` filter is within `ceiling` only if `ceiling` is unrestricted
    /// or excludes at least what... it is conservative: `exclude` fits only an unrestricted ceiling.
    pub fn within(self: StdFilter, ceiling: ?StdFilter) bool {
        const limit = ceiling orelse return true;
        if (limit.include == null and limit.exclude == null) return true;
        if (self.include) |list| {
            for (list) |item| if (!limit.allows(item)) return false;
            return true;
        }
        // `self` allows everything but its exclusions: only inside a ceiling that excludes at least
        // those and nothing else would be needed; an exclude-style ceiling is compared by superset.
        const own = self.exclude orelse return false;
        const theirs = limit.exclude orelse return false;
        for (theirs) |item| {
            var found = false;
            for (own) |mine| if (std.mem.eql(u8, mine, item)) {
                found = true;
                break;
            };
            if (!found) return false;
        }
        return true;
    }
};

fn duplicateList(alloc: std.mem.Allocator, list: []const []const u8) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, list.len);
    for (list, out) |item, *slot| slot.* = try alloc.dupe(u8, item);
    return out;
}

// ---- transformers ----------------------------------------------------------

pub const TransformerSpec = union(enum) {
    /// A function in the creating realm, the `u32`th of the handler's transformer functions: only
    /// the JS driver can run it.
    js: u32,
    oxc: oxc.Options,
    by_extension: []const struct { ext: []const u8, spec: TransformerSpec },

    pub fn isNative(self: TransformerSpec) bool {
        return switch (self) {
            .js => false,
            .oxc => true,
            .by_extension => |entries| for (entries) |entry| {
                if (!entry.spec.isNative()) break false;
            } else true,
        };
    }

    /// The spec that applies to module `id`: itself, or the entry of a by-extension table with the
    /// longest matching extension (null when none matches, so the source stays as it is).
    pub fn leaf(self: *const TransformerSpec, id: []const u8) ?*const TransformerSpec {
        switch (self.*) {
            .js, .oxc => return self,
            .by_extension => |entries| {
                const path = id[0 .. std.mem.indexOfAny(u8, id, "?#") orelse id.len];
                var best: ?usize = null;
                for (entries, 0..) |entry, index| {
                    if (path.len <= entry.ext.len or !std.mem.endsWith(u8, path, entry.ext)) continue;
                    if (best == null or entry.ext.len > entries[best.?].ext.len) best = index;
                }
                return entries[best orelse return null].spec.leaf(id);
            },
        }
    }

    /// Transforms `source` (module `id`) into `alloc`; the input is returned unchanged when no entry
    /// matches. A `js` spec is never run here (callers check `isNative` or go through the driver).
    pub fn apply(self: *const TransformerSpec, alloc: std.mem.Allocator, id: []const u8, source: []const u8) !transformer_api.Outcome {
        switch (self.*) {
            .js => return error.Unsupported,
            .oxc => |*options| {
                if (!oxc.enabled) return error.Unsupported;
                return oxc.run(@ptrCast(@constCast(options)), .{ .allocator = alloc, .module_id = id, .source = source });
            },
            .by_extension => {
                const found = self.leaf(id) orelse return .{ .source = source };
                return found.apply(alloc, id, source);
            },
        }
    }
};

/// Reads a transformer spec from JSON into `alloc` (kept for the life of the handler).
fn parseTransformer(alloc: std.mem.Allocator, value: std.json.Value) !TransformerSpec {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidInput,
    };
    if (object.get("js")) |index| return .{ .js = switch (index) {
        .integer => |number| std.math.cast(u32, number) orelse return error.InvalidInput,
        else => return error.InvalidInput,
    } };
    const host = switch (object.get("host") orelse return error.InvalidInput) {
        .string => |text| text,
        else => return error.InvalidInput,
    };
    if (std.mem.eql(u8, host, "oxc")) {
        var options: oxc.Options = .{};
        const given = switch (object.get("options") orelse std.json.Value{ .null = {} }) {
            .object => |given| given,
            .null => null,
            else => return error.InvalidInput,
        };
        if (given) |bag| {
            if (bag.get("jsx")) |jsx| options.jsx_runtime = if (jsx == .string and std.mem.eql(u8, jsx.string, "classic")) .classic else .automatic;
            if (bag.get("importSource")) |text| if (text == .string) {
                options.jsx_import_source = try alloc.dupe(u8, text.string);
            };
            if (bag.get("pragma")) |text| if (text == .string) {
                options.jsx_pragma = try alloc.dupe(u8, text.string);
            };
            if (bag.get("pragmaFrag")) |text| if (text == .string) {
                options.jsx_pragma_frag = try alloc.dupe(u8, text.string);
            };
            if (bag.get("development")) |flag| options.jsx_development = flag == .bool and flag.bool;
            if (bag.get("verbatimImports")) |flag| options.verbatim_imports = flag == .bool and flag.bool;
            if (bag.get("inlineSourceMap")) |flag| options.inline_source_map = flag == .bool and flag.bool;
        }
        return .{ .oxc = options };
    }
    if (std.mem.eql(u8, host, "byExtension")) {
        const list = switch (object.get("entries") orelse return error.InvalidInput) {
            .array => |list| list,
            else => return error.InvalidInput,
        };
        const entries = try alloc.alloc(@typeInfo(@FieldType(TransformerSpec, "by_extension")).pointer.child, list.items.len);
        for (list.items, entries) |item, *slot| {
            const pair = switch (item) {
                .array => |pair| pair,
                else => return error.InvalidInput,
            };
            if (pair.items.len != 2 or pair.items[0] != .string) return error.InvalidInput;
            slot.* = .{ .ext = try alloc.dupe(u8, pair.items[0].string), .spec = try parseTransformer(alloc, pair.items[1]) };
        }
        return .{ .by_extension = entries };
    }
    return error.InvalidInput;
}

// ---- handlers --------------------------------------------------------------

pub const Layer = union(enum) {
    relative,
    origine,
    import_map: *import_map.ImportMap,
    js,
};

pub const ReadMode = enum { copy, mmap };

pub const Hook = union(enum) {
    origine: StdFilter,
    fs: ReadMode,
    json,
    js,
};

pub const Maker = union(enum) {
    /// `import` is the handler id the made module's own imports use (0: the handler being run).
    inherit: struct { import: u32, transformer: ?TransformerSpec },
    js,
};

pub const Retain = enum { all, used };

pub const Handler = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    layers: []Layer,
    hooks: []Hook,
    maker: Maker,
    retain: Retain,
    entries: ?usize,
    /// A `meta` function exists (always a JS barrier).
    meta: bool,
    /// No JS function anywhere: the whole pipeline runs natively.
    native: bool,

    pub fn deinit(self: *Handler) void {
        for (self.layers) |item| switch (item) {
            .import_map => |map| {
                map.deinit();
                self.gpa.destroy(map);
            },
            else => {},
        };
        self.arena.deinit();
    }
};

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |text| text,
        else => null,
    };
}

fn parseStringList(alloc: std.mem.Allocator, value: ?std.json.Value) !?[]const []const u8 {
    const v = value orelse return null;
    const list = switch (v) {
        .array => |list| list,
        else => return error.InvalidInput,
    };
    const out = try alloc.alloc([]const u8, list.items.len);
    for (list.items, out) |item, *slot| {
        if (item != .string) return error.InvalidInput;
        slot.* = try alloc.dupe(u8, item.string);
    }
    return out;
}

/// Builds a handler from its flattened JSON spec. Everything is validated before it is used; the
/// handler owns copies.
pub fn parseHandler(gpa: std.mem.Allocator, text: []const u8) !*Handler {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return error.InvalidInput;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidInput,
    };
    const result = try gpa.create(Handler);
    errdefer gpa.destroy(result);
    result.* = .{ .gpa = gpa, .arena = .init(gpa), .layers = &.{}, .hooks = &.{}, .maker = .js, .retain = .all, .entries = null, .meta = false, .native = true };
    errdefer result.deinit();
    const alloc = result.arena.allocator();

    const layer_list = switch (root.get("layers") orelse return error.InvalidInput) {
        .array => |list| list,
        else => return error.InvalidInput,
    };
    const layers = try alloc.alloc(Layer, layer_list.items.len);
    var built: usize = 0;
    errdefer for (layers[0..built]) |item| switch (item) {
        .import_map => |map| {
            map.deinit();
            gpa.destroy(map);
        },
        else => {},
    };
    for (layer_list.items, layers) |item, *slot| {
        const object = switch (item) {
            .object => |object| object,
            else => return error.InvalidInput,
        };
        if (object.get("js") != null) {
            slot.* = .js;
            result.native = false;
        } else {
            const host = jsonString(object.get("host")) orelse return error.InvalidInput;
            if (std.mem.eql(u8, host, "relative")) {
                slot.* = .relative;
            } else if (std.mem.eql(u8, host, "origine")) {
                slot.* = .origine;
            } else if (std.mem.eql(u8, host, "importMap")) {
                var map_text: std.Io.Writer.Allocating = .init(gpa);
                defer map_text.deinit();
                var entry: std.json.Value = .{ .object = object };
                // Only `imports` and `scopes` are map data.
                var data: std.json.ObjectMap = .empty;
                defer data.deinit(gpa);
                if (entry.object.get("imports")) |imports| try data.put(gpa, "imports", imports);
                if (entry.object.get("scopes")) |scopes| try data.put(gpa, "scopes", scopes);
                entry = .{ .object = data };
                try std.json.Stringify.value(entry, .{}, &map_text.writer);
                const map = try gpa.create(import_map.ImportMap);
                errdefer gpa.destroy(map);
                map.* = import_map.ImportMap.parseJson(gpa, map_text.written(), .{ .base_url = "app:/map.json", .urls = import_map.virtual_urls }) catch return error.InvalidInput;
                slot.* = .{ .import_map = map };
            } else return error.InvalidInput;
        }
        built += 1;
    }
    result.layers = layers;
    // From here `result.deinit` owns the maps.
    built = 0;

    const hook_list = switch (root.get("hooks") orelse return error.InvalidInput) {
        .array => |list| list,
        else => return error.InvalidInput,
    };
    const hooks = try alloc.alloc(Hook, hook_list.items.len);
    for (hook_list.items, hooks) |item, *slot| {
        const object = switch (item) {
            .object => |object| object,
            else => return error.InvalidInput,
        };
        if (object.get("js") != null) {
            slot.* = .js;
            result.native = false;
            continue;
        }
        const host = jsonString(object.get("host")) orelse return error.InvalidInput;
        if (std.mem.eql(u8, host, "origine")) {
            const std_object = switch (object.get("std") orelse return error.InvalidInput) {
                .object => |std_object| std_object,
                else => return error.InvalidInput,
            };
            slot.* = .{ .origine = .{ .include = try parseStringList(alloc, std_object.get("include")), .exclude = try parseStringList(alloc, std_object.get("exclude")) } };
        } else if (std.mem.eql(u8, host, "fs")) {
            const read = jsonString(object.get("read")) orelse return error.InvalidInput;
            slot.* = .{ .fs = std.meta.stringToEnum(ReadMode, read) orelse return error.InvalidInput };
        } else if (std.mem.eql(u8, host, "json")) {
            slot.* = .json;
        } else return error.InvalidInput;
    }
    result.hooks = hooks;

    const maker_object = switch (root.get("maker") orelse return error.InvalidInput) {
        .object => |object| object,
        else => return error.InvalidInput,
    };
    if (maker_object.get("js") != null) {
        result.maker = .js;
        result.native = false;
    } else {
        const import: u32 = if (maker_object.get("import")) |value| switch (value) {
            .integer => |number| std.math.cast(u32, number) orelse return error.InvalidInput,
            .null => 0,
            else => return error.InvalidInput,
        } else 0;
        var spec: ?TransformerSpec = null;
        if (maker_object.get("transformer")) |value| switch (value) {
            .null => {},
            else => {
                spec = try parseTransformer(alloc, value);
                if (!spec.?.isNative()) result.native = false;
            },
        };
        result.maker = .{ .inherit = .{ .import = import, .transformer = spec } };
    }

    const cache = switch (root.get("cache") orelse return error.InvalidInput) {
        .object => |object| object,
        else => return error.InvalidInput,
    };
    const retain = jsonString(cache.get("retain")) orelse return error.InvalidInput;
    result.retain = std.meta.stringToEnum(Retain, retain) orelse return error.InvalidInput;
    if (cache.get("entries")) |value| switch (value) {
        .integer => |number| result.entries = std.math.cast(usize, number) orelse return error.InvalidInput,
        .null => {},
        else => return error.InvalidInput,
    };
    if (root.get("meta")) |value| {
        result.meta = value == .bool and value.bool;
        if (result.meta) result.native = false;
    }
    return result;
}

// ---- graph -----------------------------------------------------------------

/// What a graph does with V8 code caches.
pub const CodeCacheKind = enum { none, memory, dir, custom };

/// The artifacts and authority shared by the contexts that use a graph.
/// The Rust natives that read a file of an async fs grant (`native.fsAsync`: open, read all, close)
/// and the grant's id. Calling them from Zig runs the read on the grant's io runtime; no user JS runs.
pub const AsyncFs = struct {
    id: u32,
    open: v8.Global.Of(v8.Function),
    read_all: v8.Global.Of(v8.Function),
    close: v8.Global.Of(v8.Function),
};

pub const Graph = struct {
    host: *Host,
    id: u32,
    /// The realm that created it (its allowlist bounds the `origine` hooks used with it).
    owner: *ScopeState,
    fs: ?*fs_api.FsGrant = null,
    /// Set instead of `fs` for an async grant.
    async_fs: ?AsyncFs = null,
    kind: CodeCacheKind = .none,
    /// `bytes` cap of the memory cache (0: none).
    cache_bytes: usize = 0,
    /// Code-cache entries of this graph: `id ++ 0 ++ <32 byte hash of the source>` to bytes.
    memory: std.StringHashMapUnmanaged([]u8) = .empty,
    memory_size: usize = 0,
    /// Entries stored since the last `flush` that a `dir` or `custom` cache still has to persist.
    fresh: std.ArrayList(Fresh) = .empty,
    dir_state: ?init_cache.CodeCacheState = null,
    closed: bool = false,

    pub const Fresh = struct { id: []u8, hash: [32]u8, bytes: []u8 };

    pub fn deinit(self: *Graph) void {
        const alloc = self.host.allocator;
        if (self.async_fs) |ops| {
            ops.open.deinit();
            ops.read_all.deinit();
            ops.close.deinit();
        }
        var it = self.memory.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.memory.deinit(alloc);
        for (self.fresh.items) |item| {
            alloc.free(item.id);
            alloc.free(item.bytes);
        }
        self.fresh.deinit(alloc);
    }

    fn key(alloc: std.mem.Allocator, id: []const u8, hash: [32]u8) ![]u8 {
        const out = try alloc.alloc(u8, id.len + 1 + 32);
        @memcpy(out[0..id.len], id);
        out[id.len] = 0;
        @memcpy(out[id.len + 1 ..], &hash);
        return out;
    }

    pub fn lookup(self: *Graph, alloc: std.mem.Allocator, id: []const u8, hash: [32]u8) ?[]u8 {
        const probe = key(alloc, id, hash) catch return null;
        defer alloc.free(probe);
        return self.memory.get(probe);
    }

    pub fn remember(self: *Graph, id: []const u8, hash: [32]u8, bytes: []const u8) void {
        const alloc = self.host.allocator;
        const owned_key = key(alloc, id, hash) catch return;
        const owned_bytes = alloc.dupe(u8, bytes) catch {
            alloc.free(owned_key);
            return;
        };
        if (self.cache_bytes != 0 and self.memory_size + bytes.len > self.cache_bytes) {
            alloc.free(owned_key);
            alloc.free(owned_bytes);
            return;
        }
        const slot = self.memory.getOrPut(alloc, owned_key) catch {
            alloc.free(owned_key);
            alloc.free(owned_bytes);
            return;
        };
        if (slot.found_existing) {
            self.memory_size -= slot.value_ptr.len;
            alloc.free(owned_key);
            alloc.free(slot.value_ptr.*);
        }
        slot.value_ptr.* = owned_bytes;
        self.memory_size += owned_bytes.len;
    }
};

pub fn graphFor(host: *Host, id: u32) !*Graph {
    const found = host.graphs.get(id) orelse return if (host.graphs.issued(id)) error.StaleHandle else error.BadHandle;
    if (found.closed) return error.StaleHandle;
    return found;
}

/// `create(fsId | 0, cacheKind, bytes, cacheFsId | 0)`: a graph. `fsId` is the id of a sync fs grant
/// whose root sources are read from (0: none, so `fs` hooks are `PermissionDenied`). `cacheKind` is
/// 0 none, 1 memory, 2 dir (`cacheFsId` names the grant whose root holds `__oricache__`), 3 custom.
pub fn graphCreate(state: *ScopeState, fs_id: u32, cache_kind: u32, bytes: f64, cache_fs_id: u32) Error!u32 {
    return graphCreateImpl(state, fs_id, cache_kind, bytes, cache_fs_id) catch |err| return errno.narrow(err);
}

fn grantFor(host: *Host, id: u32) !*fs_api.FsGrant {
    for (host.grants.items) |grant| if (grant.id == id and !grant.closed) return grant;
    return error.BadHandle;
}

fn graphCreateImpl(state: *ScopeState, fs_id: u32, cache_kind: u32, bytes: f64, cache_fs_id: u32) !u32 {
    const host = state.host;
    const alloc = host.allocator;
    const kind = std.enums.fromInt(CodeCacheKind, cache_kind) orelse return error.InvalidInput;
    if (!(bytes >= 0) or bytes > 9007199254740991) return error.InvalidInput;
    const created = try alloc.create(Graph);
    errdefer alloc.destroy(created);
    created.* = .{ .host = host, .id = try host.graphs.issue(), .owner = state, .kind = kind, .cache_bytes = @intFromFloat(bytes) };
    if (fs_id != 0) {
        const grant = try grantFor(host, fs_id);
        if (!grant.read) return error.PermissionDenied;
        created.fs = grant;
    }
    if (kind == .dir) {
        const grant = try grantFor(host, cache_fs_id);
        if (!grant.write) return error.PermissionDenied;
        created.dir_state = init_cache.CodeCacheState.initFlat(host, grant.root);
    }
    try host.graphs.put(alloc, created.id, created);
    return created.id;
}

// ---- native steps ----------------------------------------------------------

/// A resolver layer's answer: the id (allocated from the caller's allocator) or a pass.
pub fn layerStep(h: *Handler, index: usize, alloc: std.mem.Allocator, specifier: []const u8, referrer: []const u8) !?[]const u8 {
    switch (h.layers[index]) {
        .js => return error.Unsupported,
        .relative => {
            if (!(std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../"))) return null;
            return try init_loader.resolve(null, .{ .allocator = alloc, .context = undefined, .scope_id = 0, .specifier = specifier, .referrer = referrer });
        },
        .origine => {
            if (!std.mem.startsWith(u8, specifier, module_types.origine_prefix)) return null;
            return try alloc.dupe(u8, specifier);
        },
        .import_map => |map| return map.lookup(alloc, specifier, referrer),
    }
}

/// What a hook answered.
pub const HookResult = union(enum) {
    next,
    /// Source text allocated from the caller's allocator.
    source: []u8,
    /// The graph reads through an async fs grant: the file named by the id has to be read on its io
    /// runtime and then continues as `source` (wrapped as a JSON module when `json`). Only the
    /// context's chain can park for that; the synchronous callers fail `Unsupported`.
    read: struct { json: bool },
};

/// Where a hook runs: the graph (fs grant), the realm's `origine` ceiling, the allocator for
/// results, and `serve` to mark an `origine:` id as served by the host.
pub const HookEnv = struct {
    host: *Host,
    graph: *Graph,
    alloc: std.mem.Allocator,
    /// Ceiling of the realm using the handler; null: unrestricted. Hooks were checked against it
    /// when registered, so this is a second line.
    served: ?*bool = null,
};

fn attributesAsk(attributes: []const module_types.ImportAttribute, key: []const u8, value: []const u8) bool {
    for (attributes) |attribute| if (std.mem.eql(u8, attribute.key, key) and std.mem.eql(u8, attribute.value, value)) return true;
    return false;
}

fn readFromGraph(env: HookEnv, id: []const u8) ![]u8 {
    const grant = env.graph.fs orelse return error.PermissionDenied;
    if (grant.closed) return error.StaleHandle;
    try fs_api.cleanPath(id);
    return grant.root.readFileAlloc(id, env.alloc, .unlimited);
}

pub fn hookStep(h: *Handler, index: usize, env: HookEnv, id: []const u8, attributes: []const module_types.ImportAttribute) !HookResult {
    switch (h.hooks[index]) {
        .js => return error.Unsupported,
        .origine => |filter| {
            if (!std.mem.startsWith(u8, id, module_types.origine_prefix)) return .next;
            const rest = id[module_types.origine_prefix.len..];
            const name = if (std.mem.startsWith(u8, rest, "@std/")) rest["@std/".len..] else rest;
            if (!filter.allows(name)) return error.PermissionDenied;
            for (env.host.modules) |module| {
                if (!std.mem.eql(u8, module.id, id)) continue;
                if (env.served) |flag| flag.* = true;
                return .{ .source = try env.alloc.dupe(u8, module.source) };
            }
            return .next;
        },
        .fs => {
            if (std.mem.startsWith(u8, id, module_types.origine_prefix)) return .next;
            if (attributesAsk(attributes, "type", "json")) return .next;
            if (env.graph.fs == null and env.graph.async_fs != null) return .{ .read = .{ .json = false } };
            return .{ .source = try readFromGraph(env, id) };
        },
        .json => {
            if (!attributesAsk(attributes, "type", "json")) return .next;
            // The namespace is the host's: a file of the graph never serves an `origine:` id.
            if (std.mem.startsWith(u8, id, module_types.origine_prefix)) return .next;
            if (env.graph.fs == null and env.graph.async_fs != null) return .{ .read = .{ .json = true } };
            const text = try readFromGraph(env, id);
            defer env.alloc.free(text);
            return .{ .source = try json_module.wrap(env.alloc, text) };
        },
    }
}

/// The default source for `Import.accept()`: the id read as a file of the graph.
pub fn acceptStep(env: HookEnv, id: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, id, module_types.origine_prefix)) return error.PermissionDenied;
    return readFromGraph(env, id);
}

/// Applies a native maker to `source`: returns the (possibly transformed) text, or the
/// diagnostics of a rejected source. `import` is the handler id the made module's imports use.
pub const Made = union(enum) { ok: struct { source: []u8, import: u32 }, diagnostics: []u8 };

pub fn makerStep(h: *Handler, current: u32, alloc: std.mem.Allocator, id: []const u8, source: []u8) !Made {
    const inherit = switch (h.maker) {
        .js => return error.Unsupported,
        .inherit => |inherit| inherit,
    };
    const import = if (inherit.import != 0) inherit.import else current;
    const spec = inherit.transformer orelse return .{ .ok = .{ .source = source, .import = import } };
    switch (try spec.apply(alloc, id, source)) {
        .source => |text| {
            if (text.ptr != source.ptr) alloc.free(source);
            return .{ .ok = .{ .source = @constCast(text), .import = import } };
        },
        .diagnostics => |text| {
            alloc.free(source);
            return .{ .diagnostics = @constCast(text) };
        },
    }
}

// ---- natives ---------------------------------------------------------------

/// `handler(specJson)`: registers a flattened `ImportHandler`; returns its id. An `origine` hook
/// is `Unsupported` in a realm that cannot serve `origine:` modules, and `PermissionDenied`
/// where it would serve more than the realm's own allowlist.
pub fn handler(state: *ScopeState, spec: []const u8) Error!u32 {
    return handlerImpl(state, spec) catch |err| return errno.narrow(err);
}

fn handlerImpl(state: *ScopeState, spec: []const u8) !u32 {
    const host = state.host;
    const parsed = try parseHandler(host.allocator, spec);
    errdefer {
        parsed.deinit();
        host.allocator.destroy(parsed);
    }
    for (parsed.hooks) |item| switch (item) {
        .origine => |filter| {
            const ceiling = host.ceilingOf(state.scope);
            // A realm that serves no `origine:` module has no namespace to give.
            if (ceiling) |limit| if (limit.include) |list| if (list.len == 0) return error.Unsupported;
            if (!filter.within(ceiling)) return error.PermissionDenied;
        },
        else => {},
    };
    const id = try host.handlers.issue();
    try host.handlers.put(host.allocator, id, parsed);
    return id;
}

pub fn handlerFor(host: *Host, id: u32) !*Handler {
    return host.handlers.get(id) orelse if (host.handlers.issued(id)) error.StaleHandle else error.BadHandle;
}

fn attributesOf(call: *Call, json: []const u8) ![]const module_types.ImportAttribute {
    if (json.len == 0) return &.{};
    var parsed = std.json.parseFromSlice(std.json.Value, call.arena, json, .{}) catch return error.InvalidInput;
    _ = &parsed;
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
    std.mem.sort(module_types.ImportAttribute, out, {}, struct {
        fn less(_: void, a: module_types.ImportAttribute, b: module_types.ImportAttribute) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.less);
    return out;
}

/// `layer(handler, index, specifier, referrer)`: the id a native resolver layer gives, or
/// undefined when it passes.
pub fn layer(state: *ScopeState, call: *Call, handler_id: u32, index: u32, specifier: []const u8, referrer: []const u8) Error!?[]const u8 {
    const h = handlerFor(state.host, handler_id) catch |err| return errno.narrow(err);
    if (index >= h.layers.len) return error.InvalidInput;
    return layerStep(h, index, call.arena, specifier, referrer) catch |err| return errno.narrow(err);
}

/// A hook answer for the JS driver: `[]` to pass, or the source text.
const HookReply = struct { source: ?[]const u8 };

/// `hook(handler, index, graph, context, id, attributesJson)`: runs a native hook; undefined passes,
/// a string is the source it supplied. `context` (0: none) is told when an `origine:` module was served.
pub fn hook(state: *ScopeState, call: *Call, handler_id: u32, index: u32, graph_id: u32, context_id: u32, id: []const u8, attributes: []const u8) Error!?[]const u8 {
    return hookImpl(state, call, handler_id, index, graph_id, context_id, id, attributes) catch |err| return errno.narrow(err);
}

fn hookImpl(state: *ScopeState, call: *Call, handler_id: u32, index: u32, graph_id: u32, context_id: u32, id: []const u8, attributes: []const u8) !?[]const u8 {
    const host = state.host;
    const h = try handlerFor(host, handler_id);
    if (index >= h.hooks.len) return error.InvalidInput;
    const graph = try graphFor(host, graph_id);
    var served = false;
    const result = try hookStep(h, index, .{ .host = host, .graph = graph, .alloc = call.arena, .served = &served }, id, try attributesOf(call, attributes));
    if (served and context_id != 0) @import("context.zig").markServedFor(host, state, context_id, id);
    return switch (result) {
        .next => null,
        .source => |text| text,
        .read => error.Unsupported,
    };
}

/// `readSource(graph, path)`: a file of the graph's fs grant, as text.
pub fn readSource(state: *ScopeState, call: *Call, graph_id: u32, path: []const u8) Error![]const u8 {
    const graph = graphFor(state.host, graph_id) catch |err| return errno.narrow(err);
    return readFromGraph(.{ .host = state.host, .graph = graph, .alloc = call.arena }, path) catch |err| return errno.narrow(err);
}

/// `transform(specJson, id, source)`: runs a native transformer; throws a SyntaxError with the
/// diagnostics of a rejected source.
pub fn transform(state: *ScopeState, call: *Call, spec: []const u8, id: []const u8, source: []const u8) Error!?[]const u8 {
    _ = state;
    var parsed = std.json.parseFromSlice(std.json.Value, call.arena, spec, .{}) catch return error.InvalidInput;
    _ = &parsed;
    const tspec = parseTransformer(call.arena, parsed.value) catch return error.InvalidInput;
    if (!tspec.isNative()) return error.InvalidInput;
    const outcome = tspec.apply(call.arena, id, source) catch |err| return errno.narrow(err);
    switch (outcome) {
        .source => |text| return text,
        .diagnostics => |text| {
            _ = call.isolate.throwException(transformer_api.syntaxError(text));
            return error.JavaScriptException;
        },
    }
}

/// `compileRequests(source, name)`: compiles `source` as a module in the calling realm (not
/// instantiated, nothing runs) and lists its static requests as `[specifier, attributes, phase]`.
pub fn compileRequests(state: *ScopeState, call: *Call, source: []const u8, name: []const u8) Error!v8.Value {
    return compileRequestsImpl(state, call, source, name) catch |err| return errno.narrow(err);
}

fn compileRequestsImpl(state: *ScopeState, call: *Call, source: []const u8, name: []const u8) !v8.Value {
    const iso = call.isolate;
    var origin = state.scope.scriptOrigin(name, true);
    var compiled: v8.ScriptCompiler.Source = undefined;
    compiled.init(eu.v.str_utf8(iso, source), &origin, null);
    defer compiled.deinit();
    const module = v8.ScriptCompiler.compileModule(iso, &compiled, 0, 0) orelse return error.JavaScriptException;
    const requests = module.getModuleRequests() orelse return error.Unexpected;
    var out = call.array();
    var index: c_int = 0;
    while (index < requests.len()) : (index += 1) {
        const request = v8.ModuleRequest.from_opaque(requests.get(index).?.handle) orelse return error.Unexpected;
        const specifier = request.getSpecifier() orelse return error.Unexpected;
        const attributes = request.getImportAttributes() orelse return error.Unexpected;
        const bag = eu.v.object(iso);
        var at: c_int = 0;
        while (at + 2 < attributes.len()) : (at += 3) {
            const key = v8.String.from_opaque(attributes.get(at).?.handle) orelse return error.Unexpected;
            const value = v8.String.from_opaque(attributes.get(at + 1).?.handle) orelse return error.Unexpected;
            _ = bag.createDataProperty(call.ctx, key.name, value.name.primitive.value);
        }
        const phase: []const u8 = switch (request.getPhase()) {
            .Evaluation => "evaluation",
            .Source => "source",
            .Defer => "defer",
        };
        var triple = call.array();
        try triple.push(specifier.name.primitive.value);
        try triple.push(bag.value);
        try triple.push(phase);
        try out.push(triple.finish());
    }
    return out.finish();
}

/// `bind(step)`: the JS driver of the calling realm (a function the glue defines: `step(kind, ...)`
/// runs one JS element of a handler, see `context.Step`), kept for the contexts this realm creates.
pub fn bind(state: *ScopeState, step_fn: v8.Function) Error!void {
    const isolate = state.scope.runtime.isolate;
    if (state.driver) |old| old.step.deinit();
    state.driver = .{ .step = .new(isolate, step_fn) };
}

/// `asyncFs(graph, fsId, open, readAll, close)`: makes the graph read through the async fs grant
/// `fsId` with the Rust natives of `native.fsAsync`. The graph must have no sync grant.
pub fn asyncFs(state: *ScopeState, graph_id: u32, fs_id: u32, open_fn: v8.Function, read_fn: v8.Function, close_fn: v8.Function) Error!void {
    const graph = graphFor(state.host, graph_id) catch |err| return errno.narrow(err);
    if (graph.fs != null or graph.async_fs != null) return error.InvalidInput;
    const isolate = state.scope.runtime.isolate;
    graph.async_fs = .{ .id = fs_id, .open = .new(isolate, open_fn), .read_all = .new(isolate, read_fn), .close = .new(isolate, close_fn) };
}

/// `utf8(bytes)`: the text of UTF-8 bytes (invalid sequences become U+FFFD, as V8 decodes them).
pub fn utf8(state: *ScopeState, bytes: []u8) Error![]const u8 {
    _ = state;
    return bytes;
}

/// `sourceHash(text)`: the lowercase hex BLAKE3 digest of `text`, which keys a code cache.
pub fn sourceHash(state: *ScopeState, call: *Call, text: []const u8) Error![]const u8 {
    _ = state;
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const out = call.allocSlice(u8, hex.len);
    @memcpy(out, &hex);
    return out;
}

/// `jsonModule(text)`: the source of an ES module whose default export is the parsed JSON `text`.
pub fn jsonModule(state: *ScopeState, call: *Call, text: []const u8) Error![]const u8 {
    _ = state;
    return json_module.wrap(call.arena, text) catch |err| return errno.narrow(err);
}

/// `pipelineResolve(handler, specifier, referrer)`: the whole native resolution of a `native`
/// handler (undefined when no layer answers). For the JS side's own use of native handlers.
pub fn pipelineResolve(state: *ScopeState, call: *Call, handler_id: u32, specifier: []const u8, referrer: []const u8) Error!?[]const u8 {
    const h = handlerFor(state.host, handler_id) catch |err| return errno.narrow(err);
    if (!h.native) return error.InvalidInput;
    return resolveNative(h, call.arena, specifier, referrer) catch |err| return errno.narrow(err);
}

/// `pipelineLoad(handler, graph, id, attributesJson)`: `{ source, handler, diagnostics }` of the whole
/// native load stage.
pub fn pipelineLoad(state: *ScopeState, call: *Call, handler_id: u32, graph_id: u32, id: []const u8, attributes: []const u8) Error!v8.Value {
    return pipelineLoadImpl(state, call, handler_id, graph_id, id, attributes) catch |err| return errno.narrow(err);
}

fn pipelineLoadImpl(state: *ScopeState, call: *Call, handler_id: u32, graph_id: u32, id: []const u8, attributes: []const u8) !v8.Value {
    const host = state.host;
    const h = try handlerFor(host, handler_id);
    if (!h.native) return error.InvalidInput;
    const graph = try graphFor(host, graph_id);
    const loaded = try loadNative(.{ .host = host, .graph = graph, .alloc = call.arena }, h, handler_id, id, try attributesOf(call, attributes));
    const object = eu.v.object(call.isolate);
    switch (loaded) {
        .source => |item| {
            try call.set(object, "source", item.source);
            try call.set(object, "handler", item.import);
        },
        .diagnostics => |text| try call.set(object, "diagnostics", text),
    }
    return object.value;
}

// ---- the whole native pipeline --------------------------------------------

/// Resolves `specifier` through the layers of a native handler; `null` when none answers.
pub fn resolveNative(h: *Handler, alloc: std.mem.Allocator, specifier: []const u8, referrer: []const u8) !?[]const u8 {
    for (h.layers, 0..) |_, index| {
        if (try layerStep(h, index, alloc, specifier, referrer)) |id| return id;
    }
    return null;
}

pub const Loaded = union(enum) {
    source: struct { source: []u8, import: u32 },
    diagnostics: []u8,
};

/// The load stage of a native handler for the resolved `id`: hooks in order, then the maker.
/// `import` of the result is the handler id the module's own imports use.
pub fn loadNative(env: HookEnv, h: *Handler, handler_id: u32, id: []const u8, attributes: []const module_types.ImportAttribute) !Loaded {
    var supplied: ?[]u8 = null;
    for (h.hooks, 0..) |_, index| {
        switch (try hookStep(h, index, env, id, attributes)) {
            .next => {},
            .source => |text| {
                supplied = text;
                break;
            },
            .read => return error.Unsupported,
        }
    }
    const text = supplied orelse return error.NotFound;
    return switch (try makerStep(h, handler_id, env.alloc, id, text)) {
        .ok => |made| .{ .source = .{ .source = made.source, .import = made.import } },
        .diagnostics => |diagnostics| .{ .diagnostics = diagnostics },
    };
}
