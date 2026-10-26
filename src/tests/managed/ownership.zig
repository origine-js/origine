const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const eu = @import("@util");
const m = @import("@managed");
const mimalloc = @import("@mimalloc");
const ensureV8 = @import("../support.zig").ensureV8;
const support = @import("support.zig");
const check = support.check;
const Memory = support.Memory;
const exposeModule = support.exposeModule;
const Deferred = support.Deferred;
const expectState = support.expectState;
const retainedBytes = support.retainedBytes;
const mapAllocationFailures = support.mapAllocationFailures;
const scopeAllocationFailures = support.scopeAllocationFailures;

test "runtime allocators: sandbox backing stores are zeroed, reused and released with the runtime" {
    ensureV8();
    if (!v8.V8.isSandboxEnabled()) return error.SkipZigTest;
    for (0..2) |_| {
        const rt = try m.Runtime.create(t.allocator, .{ .array_buffer_allocator = .sandbox });
        defer rt.destroy();
        const scope = try rt.createScope(.{});
        // V8 aborts on a backing store outside the sandbox, so surviving this proves placement.
        try check(scope, "globalThis.buffer = new ArrayBuffer(65536); const view = new Uint8Array(buffer); view.every(x => x === 0) && (view[3] = 42) === 42");
        try check(scope, "buffer = null; const again = new Uint8Array(new ArrayBuffer(65536)); again.every(x => x === 0)");
        try check(scope, "new ArrayBuffer(0).byteLength === 0 && new ArrayBuffer(64 * 1024 * 1024).byteLength === 64 * 1024 * 1024");
    }
}

test "runtime allocators: owned Zig backing stores are zeroed and released" {
    ensureV8();
    // Zig-allocated ArrayBuffer memory cannot live inside the V8 sandbox.
    if (v8.V8.isSandboxEnabled()) return error.SkipZigTest;
    var backing = std.heap.DebugAllocator(.{ .thread_safe = true, .enable_memory_limit = true }){};
    defer t.expect(backing.deinit() == .ok) catch @panic("backing-store leak");
    {
        const rt = try m.Runtime.create(t.allocator, .{ .array_buffer_allocator = .{ .zig = backing.allocator() } });
        defer rt.destroy();
        const scope = try rt.createScope(.{});
        try check(scope, "globalThis.buffer = new ArrayBuffer(65536); const view = new Uint8Array(buffer); view.every(x => x === 0) && (view[3] = 42) === 42");
        try t.expect(backing.total_requested_bytes >= 65536);
        // Fail only backing-store allocation; runtime metadata uses t.allocator.
        backing.requested_memory_limit = backing.total_requested_bytes;
        var info: m.ErrorInfo = .{};
        defer info.deinit();
        try t.expectError(error.JavaScriptException, scope.eval("new ArrayBuffer(1024 * 1024)", "test:backing-oom", &info));
        try t.expect(info.exception != null);
        try check(scope, "new Uint8Array(buffer)[3] === 42");
    }
    try t.expectEqual(@as(usize, 0), backing.total_requested_bytes);
}

test "runtime allocators: borrowed adapter survives runtime with retained backing store" {
    ensureV8();
    // Zig-allocated ArrayBuffer memory cannot live inside the V8 sandbox.
    if (v8.V8.isSandboxEnabled()) return error.SkipZigTest;
    var backing = std.heap.DebugAllocator(.{ .thread_safe = true, .enable_memory_limit = true }){};
    defer t.expect(backing.deinit() == .ok) catch @panic("borrowed allocator leak");
    const aba = try v8.ArrayBuffer.Allocator.fromZig(backing.allocator());
    defer aba.deinit();
    const adapter_bytes = backing.total_requested_bytes;
    var store: v8.SharedBackingStore = undefined;
    var store_alive = false;
    defer if (store_alive) store.deinit();
    var bytes: []u8 = undefined;
    {
        const rt = try m.Runtime.create(t.allocator, .{ .array_buffer_allocator = .{ .borrowed = aba } });
        defer rt.destroy();
        const scope = try rt.createScope(.{});
        rt.isolate.enter();
        defer rt.isolate.exit();
        var h_scope: v8.HandleScope = undefined;
        h_scope.init(rt.isolate);
        defer h_scope.deinit();
        const ctx = scope.context.deref();
        ctx.enter();
        defer ctx.exit();
        const buffer = eu.v.array_buffer(rt.isolate, 256).?;
        try t.expectEqual(@as(usize, 0), @intFromPtr(buffer.data().?) % 16);
        bytes = @as([*]u8, @ptrCast(buffer.data().?))[0..256];
        const zeroes: [256]u8 = @splat(0);
        try t.expectEqualSlices(u8, &zeroes, bytes);
        bytes[0] = 42;
        store = buffer.getBackingStore();
        store_alive = true;
    }
    try t.expectEqual(@as(u8, 42), bytes[0]);
    try t.expectEqual(adapter_bytes + 256, backing.total_requested_bytes);
    store.deinit();
    store_alive = false;
    try t.expectEqual(adapter_bytes, backing.total_requested_bytes);
}

test "runtime allocators: mimalloc metadata and ArrayBuffer integration" {
    ensureV8();
    // Zig-allocated ArrayBuffer memory cannot live inside the V8 sandbox.
    if (v8.V8.isSandboxEnabled()) return error.SkipZigTest;
    const rt = try m.Runtime.create(mimalloc.allocator, .{ .array_buffer_allocator = .{ .zig = mimalloc.allocator } });
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    try check(scope, "const data = new Uint8Array(8192); data.every(x => x === 0) && (data[5] = 99) === 99 && new ArrayBuffer(0).byteLength === 0");
    try scope.module_map.update(.{ .module_id = "memory" }, .{ .source = "export const value = new Uint8Array(4096).every(x => x === 0)" }, null);
    try exposeModule(scope, "memory", "memory");
    try check(scope, "memory.value");
}

test "managed allocations: cache hits, deletion misses and resolution errors retain no scratch" {
    ensureV8();
    var accounting = t.FailingAllocator.init(t.allocator, .{});
    const rt = try m.Runtime.create(accounting.allocator(), .{});
    const Backend = struct {
        loads: usize = 0,
        saved_id: []const u8 = "",
        saved_attributes: []const m.ImportAttribute = &.{},
        /// Borrows host callback state through return; state stays live through runtime
        /// teardown. Request ID/attribute bytes retained by this fixture remain runtime-owned
        /// until teardown begins. Returned source uses static or request-allocator storage;
        /// local handles remain in the enclosing HandleScope. Errors transfer no host ownership.
        fn load(data: ?*anyopaque, request: m.LoadRequest) !m.LoadResult {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            self.loads += 1;
            self.saved_id = request.module_id;
            self.saved_attributes = request.import_attributes;
            return .{ .source = "export const value = 1" };
        }
    };
    var backend: Backend = .{};
    var import_map_5 = try m.ImportMap.parseJson(t.allocator, "{\"imports\":{\"ok\":\"./ok.js\"}}", .{ .base_url = "app:/map.json", .urls = m.virtual_urls });
    defer import_map_5.deinit();
    const scope = try rt.createScope(.{
        .import_map = &import_map_5,
        .loader = .{ .data = &backend, .load = Backend.load },
    });
    var key = [_]u8{ 't', 'y', 'p', 'e' };
    var value = [_]u8{ 'j', 's', 'o', 'n' };
    const attributes = [_]m.ImportAttribute{ .{ .key = &key, .value = &value }, .{ .key = "mode", .value = "one" } };
    {
        const first = try scope.importModuleWithAttributes("ok", &attributes, null);
        defer first.deinit();
        try expectState(rt, first, .Fulfilled);
    }
    const baseline = retainedBytes(&accounting);
    for (0..100) |_| {
        const cached = try scope.importModuleWithAttributes("ok", &.{ attributes[1], attributes[0] }, null);
        defer cached.deinit();
        try expectState(rt, cached, .Fulfilled);
        try t.expectEqual(@as(usize, 0), try scope.deleteImportCache(.{ .module_id = "absent", .import_attributes = &attributes }));
        const denied = try scope.importModule("missing", null);
        defer denied.deinit();
        try expectState(rt, denied, .Rejected);
        const invalid = try scope.importModule("app:/bad%zz", null);
        defer invalid.deinit();
        try expectState(rt, invalid, .Rejected);
        try t.expectEqual(baseline, retainedBytes(&accounting));
    }
    @memset(&key, 'x');
    @memset(&value, 'x');
    try t.expectEqualStrings("app:/ok.js", backend.saved_id);
    try t.expectEqualStrings("type", backend.saved_attributes[1].key);
    try t.expectEqualStrings("json", backend.saved_attributes[1].value);
    try t.expectEqual(@as(usize, 1), backend.loads);
    rt.destroy();
    try t.expectEqual(@as(usize, 0), retainedBytes(&accounting));
}

test "managed allocations: direct import-map and normalizer results are caller owned" {
    var accounting = t.FailingAllocator.init(t.allocator, .{});
    const alloc = accounting.allocator();
    const json = try alloc.dupe(u8, "{\"imports\":{\"exact\":\"./exact.js\",\"pkg/\":\"./packages/\",\"blocked\":null}}");
    var map = try m.ImportMap.parseJson(alloc, json, .{ .base_url = "app:/map.json", .urls = m.virtual_urls });
    @memset(json, 'x');
    alloc.free(json);
    const baseline = retainedBytes(&accounting);
    for (0..50) |_| {
        for ([_][]const u8{ "exact", "pkg/a.js", "./relative.js" }) |specifier| {
            const result = try map.resolve(alloc, specifier, "app:/main.js");
            alloc.free(result);
            try t.expectEqual(baseline, retainedBytes(&accounting));
        }
        try t.expectError(error.BlockedImport, map.resolve(alloc, "blocked", ""));
        try t.expectError(error.ImportMapBacktracking, map.resolve(alloc, "pkg/%2e%2e/escape.js", ""));
        try t.expectEqual(baseline, retainedBytes(&accounting));
    }
    const result = try map.resolve(alloc, "exact", "");
    map.deinit();
    try t.expectEqualStrings("app:/exact.js", result);
    alloc.free(result);
    const normalized = try m.virtual_urls.normalize(null, alloc, "APP:/a/%2e%2e/b.js?q=%2e%2f", "");
    try t.expectEqualStrings("app:/b.js?q=%2e%2f", normalized);
    alloc.free(normalized);
    try t.expectError(error.InvalidVirtualURL, m.virtual_urls.normalize(null, alloc, "app:/bad%zz", ""));
    try t.expectEqual(@as(usize, 0), retainedBytes(&accounting));
}

test "managed allocations: map creation and resolution clean up at every allocation failure" {
    try t.checkAllAllocationFailures(t.allocator, mapAllocationFailures, .{});
}

test "managed allocations: scope creation cleans up at every allocation failure" {
    ensureV8();
    try t.checkAllAllocationFailures(t.allocator, scopeAllocationFailures, .{});
}

test "managed allocations: nested dynamic imports keep operation scratch independent" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const Backend = struct {
        /// Borrows host callback state through return; state stays live through runtime
        /// teardown. Request ID/attribute bytes retained by this fixture remain runtime-owned
        /// until teardown begins. Returned source uses static or request-allocator storage;
        /// local handles remain in the enclosing HandleScope. Errors transfer no host ownership.
        fn load(_: ?*anyopaque, request: m.LoadRequest) !m.LoadResult {
            if (std.mem.eql(u8, request.module_id, "outer")) return .{ .source = "export const value = (await import('middle')).value + 1" };
            if (std.mem.eql(u8, request.module_id, "middle")) return .{ .source = "export const value = (await import('inner')).value + 1" };
            return .{ .source = "export const value = 40" };
        }
    };
    const scope = try rt.createScope(.{ .resolver = .{ .resolve = Memory.resolve }, .loader = .{ .load = Backend.load } });
    try exposeModule(scope, "outer", "nested");
    try check(scope, "nested.value === 42");
}

test "managed allocations: replacement OOM preserves old cache and pending imports" {
    ensureV8();
    var checked_failures: usize = 0;
    var offset: usize = 0;
    while (offset < 64) : (offset += 1) {
        var accounting = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
        {
            const rt = try m.Runtime.create(accounting.allocator(), .{});
            defer rt.destroy();
            var backend: Deferred = .{};
            const scope = try rt.createScope(backend.options());
            const pending = try scope.importModule("module", null);
            defer pending.deinit();
            // Force persistent promotion to need a backing allocation rather than
            // depending on the arena's incidental spare capacity.
            const long_value = try t.allocator.alloc(u8, 16 * 1024);
            defer t.allocator.free(long_value);
            @memset(long_value, 'a');
            const attributes = [_]m.ImportAttribute{.{ .key = "format", .value = long_value }};
            try scope.updateImportCache(.{ .module_id = "stable", .import_attributes = &attributes }, .{ .source = "export const value = 1" }, null);
            accounting.fail_index = accounting.alloc_index + offset;
            const outcome = scope.updateImportCache(.{ .module_id = "stable", .import_attributes = &attributes }, .{ .source = "export const value = 99" }, null);
            accounting.fail_index = std.math.maxInt(usize);
            if (outcome) |_| {
                try t.expect(!accounting.has_induced_failure);
            } else |err| {
                try t.expectEqual(error.OutOfMemory, err);
                checked_failures += 1;
            }
            const imported = try scope.importModuleWithAttributes("stable", &attributes, null);
            defer imported.deinit();
            try expectState(rt, imported, .Fulfilled);
            rt.isolate.enter();
            {
                defer rt.isolate.exit();
                var h_scope: v8.HandleScope = undefined;
                h_scope.init(rt.isolate);
                defer h_scope.deinit();
                const ctx = scope.context.deref();
                ctx.enter();
                defer ctx.exit();
                const actual = imported.deref().result().toObject(ctx).?.get(ctx, eu.v.str_utf8(rt.isolate, "value").name.primitive.value).?.i32Value(ctx).?;
                try t.expectEqual(@as(i32, if (accounting.has_induced_failure) 1 else 99), actual);
            }
            try expectState(rt, pending, .Pending);
            try rt.completeLoad(backend.tokens[0], .{ .content = .{ .source = "export const value = 7" } });
            rt.pump();
            try expectState(rt, pending, .Fulfilled);
        }
        try t.expectEqual(@as(usize, 0), retainedBytes(&accounting));
        if (!accounting.has_induced_failure) break;
    }
    try t.expect(checked_failures >= 2);
    try t.expect(offset < 64);
}

test "managed allocations: import OOM releases lookup and entry storage at teardown" {
    ensureV8();
    const Backend = struct {
        /// Borrows host callback state through return; state stays live through runtime
        /// teardown. Request ID/attribute bytes retained by this fixture remain runtime-owned
        /// until teardown begins. Returned source uses static or request-allocator storage;
        /// local handles remain in the enclosing HandleScope. Errors transfer no host ownership.
        fn load(_: ?*anyopaque, _: m.LoadRequest) !m.LoadResult {
            return .{ .source = "export const value = 1" };
        }
    };
    var offset: usize = 0;
    var failures: usize = 0;
    while (offset < 64) : (offset += 1) {
        var accounting = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
        {
            const rt = try m.Runtime.create(accounting.allocator(), .{});
            defer rt.destroy();
            const scope = try rt.createScope(.{ .resolver = .{ .resolve = Memory.resolve }, .loader = .{ .load = Backend.load } });
            accounting.fail_index = accounting.alloc_index + offset;
            const outcome = scope.importModuleWithAttributes("new-entry", &.{.{ .key = "type", .value = "custom" }}, null);
            accounting.fail_index = std.math.maxInt(usize);
            if (outcome) |promise| {
                defer promise.deinit();
                try expectState(rt, promise, if (accounting.has_induced_failure) .Rejected else .Fulfilled);
            } else |err| try t.expectEqual(error.OutOfMemory, err);
            if (accounting.has_induced_failure) failures += 1;
            const recovered = try scope.importModule("recovery", null);
            defer recovered.deinit();
            try expectState(rt, recovered, .Fulfilled);
        }
        try t.expectEqual(@as(usize, 0), retainedBytes(&accounting));
        if (!accounting.has_induced_failure) break;
    }
    try t.expect(failures >= 3);
    try t.expect(offset < 64);
}

test "ownership contract: public slice inputs may be released immediately after return" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const json = try t.allocator.dupe(u8, "{\"imports\":{\"item\":\"./item.js\"}}");
    const base = try t.allocator.dupe(u8, "app:/map.json");
    var import_map_7 = try m.ImportMap.parseJson(t.allocator, json, .{ .base_url = base, .urls = m.virtual_urls });
    defer import_map_7.deinit();
    const scope = try rt.createScope(.{ .import_map = &import_map_7 });
    t.allocator.free(json);
    t.allocator.free(base);
    try t.expect(scope.options.import_map == null);
    const source = try t.allocator.dupe(u8, "({answer:42})");
    const origin = try t.allocator.dupe(u8, "app:/origin.js");
    const cap = try scope.eval(source, origin, null);
    t.allocator.free(source);
    t.allocator.free(origin);
    const cap_name = try t.allocator.dupe(u8, "capability");
    try scope.installCapability(cap_name, cap, null);
    t.allocator.free(cap_name);
    const id = try t.allocator.dupe(u8, "app:/item.js");
    const export_name = try t.allocator.dupe(u8, "value");
    const exports = try t.allocator.alloc(m.Export, 1);
    exports[0] = .{ .name = export_name, .value = cap };
    try scope.updateImportCache(.{ .module_id = id }, .{ .exports = exports }, null);
    t.allocator.free(id);
    t.allocator.free(export_name);
    t.allocator.free(exports);
    cap.deinit();
    try exposeModule(scope, "item", "owned");
    try check(scope, "owned.value === capability && owned.value.answer === 42");
    const replacement_id = try t.allocator.dupe(u8, "app:/item.js");
    const replacement_source = try t.allocator.dupe(u8, "export const value = 99");
    try scope.updateImportCache(.{ .module_id = replacement_id }, .{ .source = replacement_source }, null);
    t.allocator.free(replacement_id);
    t.allocator.free(replacement_source);
    try exposeModule(scope, "item", "replacement");
    try check(scope, "replacement.value === 99 && owned.value.answer === 42");
}

// Local V8 handles are confined to the Session; the persistent result is released before destroy.
