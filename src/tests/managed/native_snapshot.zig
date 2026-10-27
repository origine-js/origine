const std = @import("std");
const t = std.testing;
const m = @import("@managed");
const ensureV8 = @import("../support.zig").ensureV8;
const check = @import("support.zig").check;
const exposeModule = @import("support.zig").exposeModule;

/// Per-scope state of the test module; counts creations and teardowns across the process.
const CounterState = struct {
    var created: u32 = 0;
    var torn_down: u32 = 0;
    count: u32 = 0,

    pub fn init(_: *m.Api.module.ScopeState) !CounterState {
        created += 1;
        return .{ .count = 100 };
    }
    pub fn deinit(_: *CounterState) void {
        torn_down += 1;
    }
    fn next(cell: *m.Api.module.Cell(CounterState)) u32 {
        cell.data.count += 1;
        return cell.data.count;
    }
};

const counter_module: m.Api.module.Module = .{
    .id = "origine:test/counter",
    .source = "const { next } = import.meta.native; export const bump = () => next(); export const native = typeof next === 'function';",
    .bindings = m.Api.module.stateful(CounterState, .{ .next = m.Api.binding.func(CounterState.next, .{ .side_effect = .any }) }),
};
const modules = m.Api.std_modules ++ [_]m.Api.module.Module{counter_module};

const init_source =
    \\import { encodeUtf8, utf8Js } from 'origine:@std/text';
    \\import { bump, native } from 'origine:test/counter';
    \\globalThis.atInit = { text: encodeUtf8 !== utf8Js.encode, counter: native, first: bump(), bytes: encodeUtf8('é').length };
    \\globalThis.runs = (globalThis.runs ?? 0) + 1;
    \\export const encode = s => encodeUtf8(s);
    \\export const again = () => bump();
    \\export function main() {}
;

/// Serves the init module from memory and everything else through the host's own loader.
const Source = struct {
    host: *m.Api.Host,
    base: m.Loader,

    fn load(data: ?*anyopaque, request: m.LoadRequest) !m.LoadResult {
        const self: *Source = @ptrCast(@alignCast(data.?));
        if (std.mem.eql(u8, request.module_id, "init")) return .{ .source = init_source };
        return self.base.load(self.base.data, request);
    }
    fn options(self: *Source) m.Scope.Options {
        var result = self.host.initOptions();
        self.base = result.loader.?;
        result.loader = .{ .data = self, .load = load };
        return result;
    }
};

test "native snapshot: module natives are built for the snapshot and rebind to the restored scope" {
    ensureV8();
    CounterState.created = 0;
    CounterState.torn_down = 0;
    const host = try m.Api.Host.create(t.allocator, .{ .modules = &modules });
    const references = try host.externalReferences(t.allocator);
    var image: ?m.init_snapshot.Image = null;
    var rt: ?*m.Runtime = null;
    // The host releases V8 handles, so it goes before the runtime; the image backs the heap.
    defer {
        host.destroy();
        if (rt) |runtime| runtime.destroy();
        if (image) |*made| made.deinit();
        t.allocator.free(references);
    }
    var source: Source = .{ .host = host, .base = undefined };
    image = try m.init_snapshot.create(t.allocator, .{
        .key = @splat(9),
        .scope = source.options(),
        .specifier = "init",
        .hooks = host.snapshotHooks(),
        .external_references = m.init_snapshot.referenceTable(references),
    });
    // The creation scope's host record is gone again, state torn down.
    try t.expectEqual(@as(u32, 1), CounterState.created);
    try t.expectEqual(@as(u32, 1), CounterState.torn_down);
    try t.expectEqual(@as(usize, 0), host.states.items.len);

    rt = try m.Runtime.create(t.allocator, .{
        .snapshot = image.?.blob,
        .external_references = m.init_snapshot.referenceTable(references),
    });
    var restored = source.options();
    restored.init_snapshot = &image.?.table;
    const scope = try rt.?.createScope(restored);
    // The init ran once, inside the snapshot, with real natives.
    try check(scope, "globalThis.runs === 1 && atInit.text && atInit.counter && atInit.first === 101 && atInit.bytes === 2");
    try exposeModule(scope, "init", "init_ns");
    try check(scope, "globalThis.runs === 1");
    // Before the host attaches a record, a snapshot native cannot find its state.
    try check(scope, "(() => { try { init_ns.encode('x'); return false; } catch (e) { return /attached/.test(e.message); } })()");

    const api = try host.install(scope, null);
    defer api.deinit();
    // After: stateless natives work, and a stateful one gets this scope's fresh state, created on
    // first use (the creation scope's is gone).
    try check(scope, "init_ns.encode('é').length === 2 && init_ns.encode('abc').length === 3");
    try t.expectEqual(@as(u32, 1), CounterState.created);
    try check(scope, "init_ns.again() === 101 && init_ns.again() === 102");
    try t.expectEqual(@as(u32, 2), CounterState.created);
    // A module outside the snapshot still gets ordinary pointer-bound natives.
    try exposeModule(scope, "origine:test/counter", "fresh_counter");
    try check(scope, "fresh_counter.native && fresh_counter.bump() === 103");
}
