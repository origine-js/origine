//! Immutable import-map matching, independent of source storage.
//! URL parsing is injected: use a WHATWG URL implementation for web URL semantics.
const std = @import("std");
const modules = @import("module_types.zig");

pub const URLNormalizer = struct {
    /// Host-owned state, borrowed until ImportMap.deinit returns. Never freed by the map.
    data: ?*anyopaque = null,
    /// Return caller-owned canonical URL bytes allocated with alloc, never input aliases.
    /// Release temporary allocations on success and all allocations on failure.
    /// input/base and alloc are borrowed only during the callback. On success
    /// ownership of the result transfers to the caller, who frees it with alloc.
    /// Never return static/stack storage, freed bytes, or a different alloc's memory.
    normalize: *const fn (data: ?*anyopaque, alloc: std.mem.Allocator, input: []const u8, base: []const u8) anyerror![]const u8,
};
/// All slices are borrowed through init only and independently copied.
/// urls is copied; its data pointer remains borrowed until ImportMap.deinit returns.
pub const Config = struct { base_url: []const u8, urls: URLNormalizer, imports: []const Mapping = &.{}, scopes: []const Scoped = &.{} };
pub const Mapping = struct { key: []const u8, target: ?[]const u8 };
pub const Scoped = struct { prefix: []const u8, mappings: []const Mapping };
pub const ParseOptions = struct { base_url: []const u8, urls: URLNormalizer };

pub const ImportMap = struct {
    arena: std.heap.ArenaAllocator,
    base_url: []const u8,
    urls: URLNormalizer,
    imports: []const Mapping = &.{},
    scopes: []const Scoped = &.{},

    /// Construct from typed entries; normalizes and copies all slices through return.
    /// Borrows alloc/state and urls.data through deinit. Returns an owning map:
    /// deinit once; do not copy it, and do not move it after publishing resolver().
    pub fn init(alloc: std.mem.Allocator, config: Config) !ImportMap {
        var self: ImportMap = .{ .arena = .init(alloc), .base_url = undefined, .urls = config.urls };
        errdefer self.deinit();
        self.base_url = try self.url(config.base_url, "");
        self.imports = try self.copyMappings(config.imports);
        const scopes = try self.arena.allocator().alloc(Scoped, config.scopes.len);
        for (config.scopes, 0..) |scope, i| {
            scopes[i] = .{ .prefix = try self.url(scope.prefix, self.base_url), .mappings = try self.copyMappings(scope.mappings) };
            for (scopes[0..i]) |prior| if (std.mem.eql(u8, prior.prefix, scopes[i].prefix)) return error.DuplicateNormalizedScope;
        }
        std.mem.sort(Scoped, scopes, {}, struct {
            /// Borrows scope prefixes through comparison; returns a copied boolean and
            /// retains no resources.
            fn less(_: void, a: Scoped, b: Scoped) bool {
                return a.prefix.len > b.prefix.len;
            }
        }.less);
        self.scopes = scopes;
        return self;
    }

    /// Optional JSON adapter. Borrows json/options slices through return and copies
    /// parsed data. Returned map is caller-owned; deinit once. urls.data and alloc
    /// state must remain alive through deinit, as for init.
    pub fn parseJson(alloc: std.mem.Allocator, json: []const u8, config: ParseOptions) !ImportMap {
        var self: ImportMap = .{ .arena = .init(alloc), .base_url = undefined, .urls = config.urls };
        errdefer self.deinit();
        const arena_alloc = self.arena.allocator();
        self.base_url = try self.url(config.base_url, "");
        const parsed = try std.json.parseFromSlice(std.json.Value, arena_alloc, json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidImportMap;
        if (parsed.value.object.get("imports")) |imports| self.imports = try self.parseMappings(imports);
        if (parsed.value.object.get("scopes")) |scopes| {
            if (scopes != .object) return error.InvalidImportMap;
            const items = try arena_alloc.alloc(Scoped, scopes.object.count());
            var it = scopes.object.iterator();
            var i: usize = 0;
            while (it.next()) |item| : (i += 1) {
                items[i] = .{ .prefix = try self.url(item.key_ptr.*, self.base_url), .mappings = try self.parseMappings(item.value_ptr.*) };
                for (items[0..i]) |prior| if (std.mem.eql(u8, prior.prefix, items[i].prefix)) return error.DuplicateNormalizedScope;
            }
            std.mem.sort(Scoped, items, {}, struct {
                /// Borrows scope prefixes through comparison; returns a copied boolean and
                /// retains no resources.
                fn less(_: void, a: Scoped, b: Scoped) bool {
                    return a.prefix.len > b.prefix.len;
                }
            }.less);
            self.scopes = items;
        }
        return self;
    }
    /// Independent owning copy of map data. Borrows self through return; the copy
    /// retains the same host-owned URLNormalizer.data until its own deinit.
    pub fn clone(self: *const ImportMap, alloc: std.mem.Allocator) !ImportMap {
        var copy: ImportMap = .{ .arena = .init(alloc), .base_url = undefined, .urls = self.urls };
        errdefer copy.deinit();
        const arena_alloc = copy.arena.allocator();
        copy.base_url = try arena_alloc.dupe(u8, self.base_url);
        copy.imports = try copy.cloneMappings(self.imports);
        const scopes = try arena_alloc.alloc(Scoped, self.scopes.len);
        for (self.scopes, 0..) |scope, i| {
            scopes[i] = .{ .prefix = try arena_alloc.dupe(u8, scope.prefix), .mappings = try copy.cloneMappings(scope.mappings) };
        }
        copy.scopes = scopes;
        return copy;
    }
    /// Borrows raw and nested strings through return; copies them into self.arena.
    /// Result and partial allocations on error remain map-owned until deinit.
    fn cloneMappings(self: *ImportMap, raw: []const Mapping) ![]const Mapping {
        const alloc = self.arena.allocator();
        const mappings = try alloc.alloc(Mapping, raw.len);
        for (raw, 0..) |item, i| mappings[i] = .{
            .key = try alloc.dupe(u8, item.key),
            .target = if (item.target) |target| try alloc.dupe(u8, target) else null,
        };
        return mappings;
    }
    /// Borrows raw and nested strings through return; returns normalized mappings
    /// owned by self.arena until deinit. Partial allocations on error remain arena-owned.
    fn copyMappings(self: *ImportMap, raw: []const Mapping) ![]const Mapping {
        const mappings = try self.arena.allocator().alloc(Mapping, raw.len);
        for (raw, 0..) |item, i| {
            if (item.key.len == 0) return error.InvalidImportMap;
            const key = if (urlLike(item.key)) try self.url(item.key, self.base_url) else try self.arena.allocator().dupe(u8, item.key);
            const target = if (item.target) |value| blk: {
                if (!urlLike(value)) return error.InvalidImportMapTarget;
                break :blk try self.url(value, self.base_url);
            } else null;
            if (std.mem.endsWith(u8, key, "/")) if (target) |value| {
                if (!std.mem.endsWith(u8, value, "/")) return error.InvalidImportMapPrefix;
            };
            for (mappings[0..i]) |prior| if (std.mem.eql(u8, prior.key, key)) return error.DuplicateNormalizedKey;
            mappings[i] = .{ .key = key, .target = target };
        }
        return mappings;
    }
    /// Frees map-owned allocations, not original config or host normalizer state.
    /// Invalidates resolver() descriptors. Caller-owned resolve() results remain valid.
    pub fn deinit(self: *ImportMap) void {
        self.arena.deinit();
    }
    /// Returns a non-owning descriptor pointing at self. Keep self at this address
    /// and alive until all consumers (including a Runtime) have been deinitialized.
    pub fn resolver(self: *ImportMap) modules.Resolver {
        return .{ .data = self, .resolve = callback };
    }
    /// Borrows stable map state/request bytes through return; returns canonical
    /// bytes owned by request.allocator, transferred to the runtime on success.
    /// Resolution errors transfer nothing; no local V8 handle is retained.
    fn callback(data: ?*anyopaque, request: modules.ResolveRequest) ![]const u8 {
        const self: *ImportMap = @ptrCast(@alignCast(data.?));
        return self.resolve(request.allocator, request.specifier, request.referrer);
    }
    /// Borrows input/base and host normalizer state through return; returns bytes
    /// owned by self.arena until deinit. Normalizer errors transfer no caller resources;
    /// partial arena allocations remain owned by the map.
    fn url(self: *ImportMap, input: []const u8, base: []const u8) ![]const u8 {
        const alloc = self.arena.child_allocator;
        const normalized = try self.urls.normalize(self.urls.data, alloc, input, base);
        defer alloc.free(normalized);
        return self.arena.allocator().dupe(u8, normalized);
    }
    /// Borrows JSON objects and nested strings through return; returns mappings
    /// owned by self.arena until deinit. Errors leave partial allocations arena-owned.
    fn parseMappings(self: *ImportMap, object: std.json.Value) ![]const Mapping {
        if (object != .object) return error.InvalidImportMap;
        const alloc = self.arena.allocator();
        const mappings = try alloc.alloc(Mapping, object.object.count());
        var it = object.object.iterator();
        var i: usize = 0;
        while (it.next()) |item| : (i += 1) {
            const raw_key = item.key_ptr.*;
            if (raw_key.len == 0) return error.InvalidImportMap;
            const key = if (urlLike(raw_key)) try self.url(raw_key, self.base_url) else try alloc.dupe(u8, raw_key);
            const target: ?[]const u8 = switch (item.value_ptr.*) {
                .null => null,
                .string => |value| blk: {
                    if (!urlLike(value)) return error.InvalidImportMapTarget;
                    break :blk try self.url(value, self.base_url);
                },
                else => return error.InvalidImportMapTarget,
            };
            if (std.mem.endsWith(u8, key, "/")) if (target) |value| {
                if (!std.mem.endsWith(u8, value, "/")) return error.InvalidImportMapPrefix;
            };
            for (mappings[0..i]) |prior| if (std.mem.eql(u8, prior.key, key)) return error.DuplicateNormalizedKey;
            mappings[i] = .{ .key = key, .target = target };
        }
        return mappings;
    }
    /// Borrows mappings/specifier and alloc through return; returned bytes are
    /// allocated with alloc and the caller releases them. Temporary buffers stay
    /// with alloc; errors transfer no result ownership.
    fn match(self: *ImportMap, alloc: std.mem.Allocator, mappings: []const Mapping, specifier: []const u8) !?[]const u8 {
        var best: ?Mapping = null;
        for (mappings) |mapping| {
            if (std.mem.eql(u8, mapping.key, specifier)) return mapping.target orelse error.BlockedImport;
            if (std.mem.endsWith(u8, mapping.key, "/") and std.mem.startsWith(u8, specifier, mapping.key)) {
                if (best == null or mapping.key.len > best.?.key.len) best = mapping;
            }
        }
        if (best) |mapping| {
            const target = mapping.target orelse return error.BlockedImport;
            const remainder = specifier[mapping.key.len..];
            const combined = try std.mem.concat(alloc, u8, &.{ target, remainder });
            const resolved = try self.urls.normalize(self.urls.data, alloc, combined, self.base_url);
            if (!std.mem.startsWith(u8, resolved, target)) return error.ImportMapBacktracking;
            return resolved;
        }
        return null;
    }
    /// Returns caller-owned bytes. Resolving never grows the immutable map arena.
    /// Borrows specifier/referrer only through return. On success, free the result
    /// with alloc; it aliases neither inputs nor map state and outlives map.deinit.
    /// On error no result ownership transfers. Temporary allocations are released.
    pub fn resolve(self: *ImportMap, alloc: std.mem.Allocator, specifier: []const u8, referrer: []const u8) ![]const u8 {
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        return alloc.dupe(u8, try self.resolveTemporary(scratch.allocator(), specifier, referrer));
    }
    /// Borrows map/input slices and alloc through return. Returned data aliases
    /// an input only for an unchanged bare specifier; alloc owns normalized or
    /// resolved results, and the enclosing scratch arena releases them.
    fn resolveTemporary(self: *ImportMap, alloc: std.mem.Allocator, specifier: []const u8, referrer: []const u8) ![]const u8 {
        const base = if (referrer.len == 0) self.base_url else try self.urls.normalize(self.urls.data, alloc, referrer, self.base_url);
        const normalized = if (urlLike(specifier)) try self.urls.normalize(self.urls.data, alloc, specifier, base) else specifier;
        for (self.scopes) |scope| {
            if (std.mem.eql(u8, scope.prefix, base) or (std.mem.endsWith(u8, scope.prefix, "/") and std.mem.startsWith(u8, base, scope.prefix))) {
                if (try self.match(alloc, scope.mappings, normalized)) |value| return value;
            }
        }
        if (try self.match(alloc, self.imports, normalized)) |value| return value;
        if (urlLike(specifier)) return normalized;
        return error.UnmappedSpecifier;
    }
};
/// Borrows immutable bytes through return; returns a copied boolean and
/// retains no resources.
fn urlLike(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "/") or std.mem.startsWith(u8, value, "./") or std.mem.startsWith(u8, value, "../") or hasScheme(value);
}
/// Borrows immutable bytes through return; returns a copied boolean and
/// retains no resources.
fn hasScheme(value: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, value, ':') orelse return false;
    if (end == 0 or !std.ascii.isAlphabetic(value[0])) return false;
    for (value[1..end]) |c| if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    return true;
}

/// Strict hierarchical virtual URLs only (e.g. app:/a/b.js). This is deliberately
/// not a browser URL parser. Supply a WHATWG normalizer for HTTP/file/IDNA URLs.
pub const virtual_urls: URLNormalizer = .{ .normalize = normalizeVirtual };
/// Borrows input/base and alloc through return. On success, caller owns the
/// normalized bytes through alloc; all scratch storage is freed on return/error.
fn normalizeVirtual(_: ?*anyopaque, alloc: std.mem.Allocator, input: []const u8, base: []const u8) ![]const u8 {
    for (input) |c| if (c <= 0x20 or c >= 0x7f or c == '\\') return error.InvalidVirtualURL;
    const absolute = if (hasScheme(input)) input else base;
    const uri = std.Uri.parse(absolute) catch return error.InvalidVirtualURL;
    for ([_][]const u8{ "http", "https", "file", "ftp", "ws", "wss" }) |scheme| if (std.ascii.eqlIgnoreCase(uri.scheme, scheme)) return error.RequiresWHATWGNormalizer;
    if (uri.host != null or uri.path.isEmpty() or uri.path.percent_encoded[0] != '/') return error.InvalidVirtualURL;
    // Decode only entire dot segments. Escapes inside filenames/query/fragment
    // retain their identity. Encoded path separators are outside this helper's subset.
    const reference = if (hasScheme(input)) try std.Uri.parse(input) else try std.Uri.parseAfterScheme("", input);
    const path_start = @intFromPtr(reference.path.percent_encoded.ptr) - @intFromPtr(input.ptr);
    const path_end = path_start + reference.path.percent_encoded.len;
    const workspace_len = try std.math.mul(usize, 3, try std.math.add(usize, try std.math.add(usize, input.len, base.len), 16));
    const buffer = try alloc.alloc(u8, workspace_len);
    defer alloc.free(buffer);
    var cleaned_len: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (i >= path_start and i < path_end and (i == path_start or input[i - 1] == '/')) {
            const end = std.mem.indexOfScalarPos(u8, input[0..path_end], i, '/') orelse path_end;
            const segment = input[i..end];
            if (std.ascii.eqlIgnoreCase(segment, "%2e")) {
                buffer[cleaned_len] = '.';
                cleaned_len += 1;
                i = end - 1;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(segment, ".%2e") or std.ascii.eqlIgnoreCase(segment, "%2e.") or std.ascii.eqlIgnoreCase(segment, "%2e%2e")) {
                @memcpy(buffer[cleaned_len..][0..2], "..");
                cleaned_len += 2;
                i = end - 1;
                continue;
            }
        }
        if (input[i] == '%') {
            if (i + 2 >= input.len) return error.InvalidVirtualURL;
            const c = std.fmt.parseInt(u8, input[i + 1 ..][0..2], 16) catch return error.InvalidVirtualURL;
            if (i >= path_start and i < path_end and (c == '/' or c == '\\')) return error.InvalidVirtualURL;
        }
        buffer[cleaned_len] = input[i];
        cleaned_len += 1;
    }
    var rest = buffer;
    const resolved = try std.Uri.resolveInPlace(uri, cleaned_len, &rest);
    const result = try std.fmt.allocPrint(alloc, "{f}", .{resolved});
    // Formatting puts the scheme first; lowercase only that portion.
    for (result[0..resolved.scheme.len]) |*c| c.* = std.ascii.toLower(c.*);
    return result;
}
