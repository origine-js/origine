const std = @import("std");
const t = std.testing;
const m = @import("@managed");
const mimalloc = @import("@mimalloc");
const ensureV8 = @import("../support.zig").ensureV8;
const support = @import("support.zig");
const check = support.check;
const exposeModule = support.exposeModule;
const expectMapResolution = support.expectMapResolution;

test "managed step 6: immutable maps, scope precedence, virtual URLs and blocked paths" {
    const json =
        \\{"imports":{"lib":"./lib.js","pkg/":"./packages/","pkg/deep/":"./deep/","blocked":null,"./alias.js":"./real.js"},
        \\"scopes":{"./plugins/":{"lib":"./plugin.js","blocked":null},"./plugins/a/":{"extra":"./extra.js"},"./exact.js":{"lib":"./exact-lib.js"}}}
    ;
    var map = try m.ImportMap.parseJson(t.allocator, json, .{ .base_url = "app:/root/map.json", .urls = m.virtual_urls });
    defer map.deinit();
    try expectMapResolution(&map, "lib", "app:/root/main.js", "app:/root/lib.js");
    try expectMapResolution(&map, "lib", "app:/root/plugins/a/main.js", "app:/root/plugin.js");
    try expectMapResolution(&map, "extra", "app:/root/plugins/a/main.js", "app:/root/extra.js");
    try expectMapResolution(&map, "lib", "app:/root/exact.js", "app:/root/exact-lib.js");
    try expectMapResolution(&map, "lib", "app:/root/exact.js/child", "app:/root/lib.js");
    try expectMapResolution(&map, "pkg/deep/a.js", "", "app:/root/deep/a.js");
    try expectMapResolution(&map, "pkg/a.js", "", "app:/root/packages/a.js");
    try expectMapResolution(&map, "./alias.js", "app:/root/main.js", "app:/root/real.js");
    try expectMapResolution(&map, "../other.js", "app:/root/plugins/main.js", "app:/root/other.js");
    try t.expectError(error.BlockedImport, map.resolve(t.allocator, "blocked", ""));
    try t.expectError(error.ImportMapBacktracking, map.resolve(t.allocator, "pkg/../escape.js", ""));
    try t.expectError(error.ImportMapBacktracking, map.resolve(t.allocator, "pkg/%2e%2e/escape.js", ""));
    try t.expectError(error.UnmappedSpecifier, map.resolve(t.allocator, "missing", ""));
    try expectMapResolution(&map, "app:/a%2eb.js?q=%2e%2f", "", "app:/a%2eb.js?q=%2e%2f");
    for ([_][]const u8{ "[]", "{\"imports\": []}", "{\"imports\": {\"x\":\"bare\"}}", "{\"imports\": {\"x/\":\"./file.js\"}}" }) |invalid| {
        if (m.ImportMap.parseJson(t.allocator, invalid, .{ .base_url = "app:/map.json", .urls = m.virtual_urls })) |good| {
            var unexpected = good;
            unexpected.deinit();
            return error.ExpectedInvalidMap;
        } else |_| {}
    }
}

test "typed import maps: caller construction and reuse outlive caller map" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    {
        var map = try m.ImportMap.init(t.allocator, .{
            .base_url = "app:/map.json",
            .urls = m.virtual_urls,
            .imports = &.{ .{ .key = "demo", .target = "./one.js" }, .{ .key = "blocked", .target = null } },
            .scopes = &.{.{ .prefix = "./nested/", .mappings = &.{.{ .key = "demo", .target = "./two.js" }} }},
        });
        defer map.deinit();
        try expectMapResolution(&map, "demo", "app:/nested/main.js", "app:/two.js");
        try t.expectError(error.BlockedImport, map.resolve(t.allocator, "blocked", ""));
        _ = try rt.createScope(.{ .import_map = &map });
        _ = try rt.createScope(.{ .import_map = &map });
    }
    const a = rt.scopes.items[0];
    const b = rt.scopes.items[1];
    try t.expect(a.import_map.? != b.import_map.?);
    try a.module_map.update(.{ .module_id = "app:/one.js" }, .{ .source = "export const value = 1" }, null);
    try b.module_map.update(.{ .module_id = "app:/one.js" }, .{ .source = "export const value = 2" }, null);
    try exposeModule(a, "demo", "module");
    try exposeModule(b, "demo", "module");
    try check(a, "module.value === 1");
    try check(b, "module.value === 2");
}

test "scope isolation: distinct import maps and shared private counter" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const Backend = struct {
        /// Borrows host callback state through return; state stays live through runtime
        /// teardown. Request ID/attribute bytes retained by this fixture remain runtime-owned
        /// until teardown begins. Returned source uses static or request-allocator storage;
        /// local handles remain in the enclosing HandleScope. Errors transfer no host ownership.
        fn load(_: ?*anyopaque, request: m.LoadRequest) !m.LoadResult {
            if (std.mem.eql(u8, request.module_id, "app:/one.js")) return .{ .source = "export const value = 1" };
            if (std.mem.eql(u8, request.module_id, "app:/two.js")) return .{ .source = "export const value = 2" };
            return error.NotFound;
        }
    };
    var import_map_3 = try m.ImportMap.parseJson(t.allocator, "{\"imports\":{\"same\":\"./one.js\"}}", .{ .base_url = "app:/map.json", .urls = m.virtual_urls });
    defer import_map_3.deinit();
    const a = try rt.createScope(.{ .import_map = &import_map_3, .loader = .{ .load = Backend.load } });
    var import_map_4 = try m.ImportMap.parseJson(t.allocator, "{\"imports\":{\"same\":\"./two.js\"}}", .{ .base_url = "app:/map.json", .urls = m.virtual_urls });
    defer import_map_4.deinit();
    const b = try rt.createScope(.{ .import_map = &import_map_4, .loader = .{ .load = Backend.load } });
    try exposeModule(a, "same", "module");
    try exposeModule(b, "same", "module");
    try check(a, "module.value === 1");
    try check(b, "module.value === 2");
    const counter = try a.eval("new (class Counter { #value = 0; inc(){return ++this.#value} get value(){return this.#value} })()", "app:/counter.js", null);
    defer counter.deinit();
    try a.installCapability("counter", counter, null);
    try b.installCapability("counter", counter, null);
    for ([_]*m.Scope{ a, b }) |scope| {
        const setup = try scope.eval("globalThis.moduleValue = 0; import('same').then(m => { moduleValue = m.value });", "app:/setup.js", null);
        setup.deinit();
    }
    rt.pump();
    try check(a, "moduleValue === 1 && counter.inc() === 1");
    try check(b, "moduleValue === 2 && counter.inc() === 2");
    try check(a, "counter.value === 2 && Reflect.ownKeys(counter).length === 0");
    try check(b, "counter.value === 2 && Reflect.ownKeys(counter).length === 0");
}
