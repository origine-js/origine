const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const m = @import("@managed");
const mimalloc = @import("@mimalloc");
const ensureV8 = @import("../support.zig").ensureV8;

/// Borrows scope/source through evaluation; the temporary V8 handles are released
/// before return. Retains no resources.
pub fn check(scope: *m.Scope, source: []const u8) !void {
    const value = try scope.eval(source, "test:check", null);
    defer value.deinit();
    scope.runtime.isolate.enter();
    defer scope.runtime.isolate.exit();
    var h_scope: v8.HandleScope = undefined;
    h_scope.init(scope.runtime.isolate);
    defer h_scope.deinit();
    try t.expect(value.deref().isTrue());
}

/// Borrows runtime and persistent handles through comparison; enters the
/// isolate and releases temporary local handles on success and assertion failure.
pub fn sameRetainedValue(rt: *m.Runtime, a: v8.Global.Of(v8.Value), b: v8.Global.Of(v8.Value)) !void {
    rt.isolate.enter();
    defer rt.isolate.exit();
    var h_scope: v8.HandleScope = undefined;
    h_scope.init(rt.isolate);
    defer h_scope.deinit();
    try t.expect(a.deref().strictEquals(b.deref()));
}

pub const Memory = struct {
    loads: usize = 0,
    /// Borrows request/context/state through this callback. Returns a canonical
    /// ID owned by request.allocator; ownership transfers to the runtime on success.
    /// Errors transfer no result storage; input bytes and local handles are not retained.
    pub fn resolve(_: ?*anyopaque, request: m.ResolveRequest) ![]const u8 {
        return request.allocator.dupe(u8, request.specifier);
    }
    /// Borrows host callback state through return; state stays live through runtime
    /// teardown. Request ID/attribute bytes retained by this fixture remain runtime-owned
    /// until teardown begins. Returned source uses static or request-allocator storage;
    /// local handles remain in the enclosing HandleScope. Errors transfer no host ownership.
    pub fn load(data: ?*anyopaque, request: m.LoadRequest) !m.LoadResult {
        if (request.import_attributes.len != 0) return error.UnsupportedImportAttributes;
        const scope = request.scope_id;
        const id = request.module_id;
        const self: *Memory = @ptrCast(@alignCast(data.?));
        self.loads += 1;
        if (std.mem.eql(u8, id, "dep")) return .{ .source = if (scope == 0) "export const value = 1" else "export const value = 2" };
        if (std.mem.eql(u8, id, "main")) return .{ .source = "import {value} from 'dep'; export const answer = value; export const origin = import.meta.url; export async function later(){return (await import('dep')).value};" };
        if (std.mem.eql(u8, id, "cycle-a")) return .{ .source = "import {b} from 'cycle-b'; export const a = 3; export function read(){ return b() }" };
        if (std.mem.eql(u8, id, "cycle-b")) return .{ .source = "import {a} from 'cycle-a'; export function b(){return a}" };
        if (std.mem.eql(u8, id, "await")) return .{ .source = "export const value = await Promise.resolve(42)" };
        if (std.mem.eql(u8, id, "dynamic")) return .{ .source = "export const value = (await import('dep')).value" };
        if (std.mem.eql(u8, id, "syntax")) return .{ .source = "export const =" };
        if (std.mem.eql(u8, id, "throw")) return .{ .source = "throw new Error('boom')" };
        if (std.mem.eql(u8, id, "missing-export")) return .{ .source = "import {nope} from 'dep'; export {nope}" };
        if (std.mem.eql(u8, id, "attributes")) return .{ .source = "import x from 'dep' with {type:'json'}" };
        return error.NotFound;
    }
    /// Returns copied callback descriptors borrowing self at its current address
    /// until the consuming Runtime.destroy returns; transfers no ownership.
    pub fn options(self: *Memory) m.Scope.Options {
        return .{ .resolver = .{ .resolve = resolve }, .loader = .{ .data = self, .load = load } };
    }
};

/// Borrows scope/id/name through return; consumes no caller handles.
/// Releases the temporary persistent promise on success/error. The scope global retains
/// the namespace until context disposal; local handles expire before return.
pub fn exposeModule(scope: *m.Scope, id: []const u8, name: []const u8) !void {
    const promise = try scope.importModule(id, null);
    defer promise.deinit();
    scope.runtime.pump();
    const iso = scope.runtime.isolate;
    iso.enter();
    defer iso.exit();
    var h_scope: v8.HandleScope = undefined;
    h_scope.init(iso);
    defer h_scope.deinit();
    const p = promise.deref();
    try t.expectEqual(v8.Promise.PromiseState.Fulfilled, p.state());
    const ctx = scope.context.deref();
    ctx.enter();
    defer ctx.exit();
    // Test-only raw namespace installation. Public capabilities reject namespaces.
    try t.expect(ctx.getGlobal().set(ctx, v8.String.initUtf8(iso, name).name.primitive.value, p.result()).?);
}

pub const Deferred = struct {
    tokens: [8]m.LoadToken = @splat(0),
    count: usize = 0,
    cancelled: usize = 0,
    /// Borrows host callback state through return; state stays live through runtime
    /// teardown. Request ID/attribute bytes retained by this fixture remain runtime-owned
    /// until teardown begins. Returned source uses static or request-allocator storage;
    /// local handles remain in the enclosing HandleScope. Errors transfer no host ownership.
    pub fn load(data: ?*anyopaque, request: m.LoadRequest) !m.LoadResult {
        const self: *Deferred = @ptrCast(@alignCast(data.?));
        self.tokens[self.count] = request.token;
        self.count += 1;
        return .pending;
    }
    /// Borrows host callback state through the cancellation call; records only
    /// scalar accounting and retains no request storage or handles.
    pub fn cancel(data: ?*anyopaque, _: m.LoadToken) void {
        const self: *Deferred = @ptrCast(@alignCast(data.?));
        self.cancelled += 1;
    }
    /// Returns copied callback descriptors borrowing self at its current address
    /// until the consuming Runtime.destroy returns; transfers no ownership.
    pub fn options(self: *Deferred) m.Scope.Options {
        return .{ .resolver = .{ .resolve = Memory.resolve }, .loader = .{ .data = self, .load = load, .cancel = cancel } };
    }
};

/// Borrows runtime and promise through inspection; enters the isolate and
/// releases its local HandleScope on success/error. Retains no caller resources.
pub fn expectState(rt: *m.Runtime, promise: v8.Global.Of(v8.Promise), expected: v8.Promise.PromiseState) !void {
    rt.isolate.enter();
    defer rt.isolate.exit();
    var h_scope: v8.HandleScope = undefined;
    h_scope.init(rt.isolate);
    defer h_scope.deinit();
    try t.expectEqual(expected, promise.deref().state());
}

pub const NativeCounter = struct {
    key: v8.Global.Of(v8.Private),
    /// Borrows callback info and its stable NativeCounter state through return;
    /// the key must remain live until callbacks cease. Mutates receiver private state and
    /// returns a local number or throws a local exception; retains no host inputs.
    pub fn increment(info: v8.FunctionCallbackInfo) callconv(.c) void {
        const self: *NativeCounter = @ptrCast(@alignCast(v8.External.from_opaque(info.data().?.handle).?.pointer()));
        const iso = info.isolate();
        const ctx = iso.getCurrentContext();
        const receiver = info.this();
        if (!(receiver.hasPrivate(ctx, self.key.deref()) orelse false) or info.length() != 1 or !info.get_arg(0).isInt32()) {
            _ = iso.throwException(v8.Exception.typeError(v8.String.initUtf8(iso, "Invalid counter receiver or argument")).?);
            return;
        }
        const prior = receiver.getPrivate(ctx, self.key.deref()).?.i32Value(ctx).?;
        const delta = info.get_arg(0).i32Value(ctx).?;
        const next = std.math.add(i32, prior, delta) catch {
            _ = iso.throwException(v8.Exception.rangeError(v8.String.initUtf8(iso, "Counter overflow")).?);
            return;
        };
        _ = receiver.setPrivate(ctx, self.key.deref(), v8.Number.initInt(iso, next).numeric.primitive.value);
        var result = info.retval();
        result.setInt32(next);
    }
};

pub const AttributeBackend = struct {
    payload_loads: usize = 0,
    checked_contexts: usize = 0,
    custom_error: ?v8.Global.Of(v8.Value) = null,

    /// Borrows request/context/state through this callback. Returns a canonical
    /// ID owned by request.allocator; ownership transfers to the runtime on success.
    /// Errors transfer no result storage; input bytes and local handles are not retained.
    pub fn resolve(_: ?*anyopaque, request: m.ResolveRequest) !m.ModuleId {
        try t.expect(request.context.eq(v8.Isolate.getCurrent().getCurrentContext()));
        if (std.mem.eql(u8, request.specifier, "resolve-error")) {
            _ = v8.Isolate.getCurrent().throwException(v8.Exception.typeError(v8.String.initUtf8(v8.Isolate.getCurrent(), "custom resolver error")).?);
            return error.ResolverDenied;
        }
        return request.allocator.dupe(u8, request.specifier);
    }
    /// Borrows host callback state through return; state stays live through runtime
    /// teardown. Request ID/attribute bytes retained by this fixture remain runtime-owned
    /// until teardown begins. Returned source uses static or request-allocator storage;
    /// local handles remain in the enclosing HandleScope. Errors transfer no host ownership.
    /// The attribute fixture may retain a copied exception handle; its caller releases
    /// that handle before destroying the runtime, including on error.
    pub fn load(data: ?*anyopaque, request: m.LoadRequest) !m.LoadResult {
        const self: *AttributeBackend = @ptrCast(@alignCast(data.?));
        const iso = v8.Isolate.getCurrent();
        try t.expect(request.context.eq(iso.getCurrentContext()));
        self.checked_contexts += 1;
        if (std.mem.eql(u8, request.module_id, "static-denied")) return .{ .source = "import 'denied';" };
        if (std.mem.eql(u8, request.module_id, "main")) return .{ .source =
        \\import {value as one} from 'payload' with {mode:'one',type:'custom'};
        \\import {value as two} from 'payload' with {type:'custom',mode:'two'};
        \\export const values = [one,two];
        };
        if (std.mem.eql(u8, request.module_id, "payload")) {
            self.payload_loads += 1;
            try t.expectEqual(@as(usize, 2), request.import_attributes.len);
            try t.expectEqualStrings("mode", request.import_attributes[0].key);
            try t.expectEqualStrings("type", request.import_attributes[1].key);
            try t.expectEqualStrings("custom", request.import_attributes[1].value);
            return .{ .source = if (std.mem.eql(u8, request.import_attributes[0].value, "one")) "export const value = 1" else "export const value = 2" };
        }
        if (std.mem.eql(u8, request.module_id, "denied") or std.mem.eql(u8, request.module_id, "thrown")) {
            const exception = v8.Exception.typeError(v8.String.initUtf8(iso, "custom loader error")).?;
            try t.expect(exception.toObject(request.context).?.createDataProperty(request.context, v8.String.initUtf8(iso, "code").name, v8.String.initUtf8(iso, "DENIED").name.primitive.value).?);
            if (self.custom_error) |prior| prior.deinit();
            self.custom_error = .new(iso, exception);
            if (std.mem.eql(u8, request.module_id, "thrown")) {
                _ = iso.throwException(exception);
                return error.LoaderDenied;
            }
            return .{ .exception = exception };
        }
        if (std.mem.eql(u8, request.module_id, "strict")) return .{ .source =
        \\export const strict = (function(){return this})() === undefined;
        \\export let denied = false;
        \\try { implicitModuleGlobal = 1 } catch (e) { denied = e instanceof ReferenceError }
        };
        return error.NotFound;
    }
    /// Returns copied callback descriptors borrowing self at its current address
    /// until the consuming Runtime.destroy returns; transfers no ownership.
    pub fn options(self: *AttributeBackend) m.Scope.Options {
        return .{ .resolver = .{ .resolve = resolve }, .loader = .{ .data = self, .load = load } };
    }
};

pub const CacheBackend = struct {
    version: u8 = 1,
    loads: usize = 0,
    /// Borrows host callback state through return; state stays live through runtime
    /// teardown. Request ID/attribute bytes retained by this fixture remain runtime-owned
    /// until teardown begins. Returned source uses static or request-allocator storage;
    /// local handles remain in the enclosing HandleScope. Errors transfer no host ownership.
    pub fn load(data: ?*anyopaque, request: m.LoadRequest) !m.LoadResult {
        const self: *CacheBackend = @ptrCast(@alignCast(data.?));
        self.loads += 1;
        if (std.mem.eql(u8, request.module_id, "dep")) return .{ .source = if (self.version == 1) "export const value = 1" else "export const value = 2" };
        if (std.mem.eql(u8, request.module_id, "main")) return .{ .source = "import {value} from 'dep'; export {value}; export function origin(){return import.meta.url}; export async function later(){return (await import('dep')).value}" };
        return error.NotFound;
    }
    /// Returns copied callback descriptors borrowing self at its current address
    /// until the consuming Runtime.destroy returns; transfers no ownership.
    pub fn options(self: *CacheBackend) m.Scope.Options {
        return .{ .resolver = .{ .resolve = Memory.resolve }, .loader = .{ .data = self, .load = load } };
    }
};

/// Borrows map and input bytes through return; frees the allocator-owned
/// resolution on success/assertion failure. Resolution errors retain no caller resources.
pub fn expectMapResolution(map: *m.ImportMap, specifier: []const u8, referrer: []const u8, expected: []const u8) !void {
    const result = try map.resolve(t.allocator, specifier, referrer);
    defer t.allocator.free(result);
    try t.expectEqualStrings(expected, result);
}

/// Reads allocator accounting without retaining or mutating the allocator.
pub fn retainedBytes(alloc: *const t.FailingAllocator) usize {
    return alloc.allocated_bytes - alloc.freed_bytes;
}

/// Borrows alloc for the map and result lifetimes; releases every map/result
/// before return or error. Disables resizing so failure indices do not depend on
/// incidental backing-allocator in-place growth. Retains no resources.
pub fn mapAllocationFailures(alloc: std.mem.Allocator) !void {
    var no_resize = t.FailingAllocator.init(alloc, .{ .resize_fail_index = 0 });
    const stable_alloc = no_resize.allocator();
    var map = try m.ImportMap.parseJson(stable_alloc, "{\"imports\":{\"exact\":\"./a.js\",\"pkg/\":\"./pkg/\"},\"scopes\":{\"./scope/\":{\"exact\":\"./b.js\"}}}", .{
        .base_url = "APP:/map.json",
        .urls = m.virtual_urls,
    });
    defer map.deinit();
    const scoped = try map.resolve(stable_alloc, "exact", "app:/scope/main.js");
    defer stable_alloc.free(scoped);
    try t.expectEqualStrings("app:/b.js", scoped);
    const prefix = try map.resolve(stable_alloc, "pkg/a.js", "");
    defer stable_alloc.free(prefix);
    try t.expectEqualStrings("app:/pkg/a.js", prefix);
}

/// Borrows alloc through Runtime.destroy and releases all runtime/map allocations
/// before return or error. Retains no resources.
pub fn scopeAllocationFailures(alloc: std.mem.Allocator) !void {
    const rt = try m.Runtime.create(alloc, .{});
    defer rt.destroy();
    var import_map_6 = try m.ImportMap.parseJson(t.allocator, "{\"imports\":{\"ok\":\"./ok.js\"}}", .{ .base_url = "app:/map.json", .urls = m.virtual_urls });
    defer import_map_6.deinit();
    _ = try rt.createScope(.{
        .import_map = &import_map_6,
    });
}
