const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const m = @import("@managed");
const ensureV8 = @import("../support.zig").ensureV8;
const check = @import("support.zig").check;
const exposeModule = @import("support.zig").exposeModule;
const Memory = @import("support.zig").Memory;

/// Serves a small init graph whose evaluation leaves a trace in the global object, so a
/// second evaluation is visible, and counts loader calls so a map hit is visible.
const Graph = struct {
    loads: usize = 0,
    init_source: []const u8 = "import { n } from 'dep'; globalThis.runs = (globalThis.runs ?? 0) + 1; export const answer = n; export const runs = () => globalThis.runs; export const url = import.meta.url;",

    /// Borrows host state and the request through return; returns static sources.
    fn load(data: ?*anyopaque, request: m.LoadRequest) !m.LoadResult {
        const self: *Graph = @ptrCast(@alignCast(data.?));
        self.loads += 1;
        const id = request.module_id;
        if (std.mem.eql(u8, id, "init")) return .{ .source = self.init_source };
        if (std.mem.eql(u8, id, "dep")) return .{ .source = "export const n = 41 + 1;" };
        if (std.mem.eql(u8, id, "extra")) return .{ .source = "import { n } from 'dep'; export const m = n + 1;" };
        return error.NotFound;
    }
    /// Returns copied callback descriptors borrowing self until Runtime.destroy returns.
    fn options(self: *Graph) m.Scope.Options {
        return .{ .resolver = .{ .resolve = Memory.resolve }, .loader = .{ .data = self, .load = load } };
    }
};

/// Hashes a module ID's own text, which stands in for reading its file.
fn hashId(_: ?*anyopaque, id: []const u8) anyerror!?[m.init_snapshot.hash_len]u8 {
    var out: [m.init_snapshot.hash_len]u8 = undefined;
    std.crypto.hash.Blake3.hash(id, &out, .{});
    return out;
}

test "init snapshot: an evaluated graph restores without evaluating again" {
    ensureV8();
    var creating: Graph = .{};
    var image = try m.init_snapshot.create(t.allocator, .{
        .key = @splat(7),
        .scope = creating.options(),
        .specifier = "init",
        .source_hasher = .{ .hash = hashId },
    });
    defer image.deinit();
    try t.expectEqual(@as(usize, 2), creating.loads);
    try t.expectEqual(@as(usize, 2), image.table.modules.len);
    try t.expect(image.sourcesUnchanged(.{ .hash = hashId }));

    const rt = try m.Runtime.create(t.allocator, .{ .snapshot = image.blob });
    defer rt.destroy();
    var restored: Graph = .{};
    var options = restored.options();
    options.init_snapshot = &image.table;
    const scope = try rt.createScope(options);
    // The init body already ran, once, inside the snapshot.
    try check(scope, "globalThis.runs === 1 && Object.isFrozen(Array.prototype)");
    try exposeModule(scope, "init", "init_ns");
    try t.expectEqual(@as(usize, 0), restored.loads);
    try check(scope, "init_ns.answer === 42 && init_ns.runs() === 1 && globalThis.runs === 1 && init_ns.url === 'init'");
    // A module outside the snapshot loads normally and links against the restored dependency.
    try exposeModule(scope, "extra", "extra_ns");
    try t.expectEqual(@as(usize, 1), restored.loads);
    try check(scope, "extra_ns.m === 43");
    // Capabilities and hardening still work in the restored scope.
    const counter = try scope.eval("new (class Counter { #n = 0; inc() { return ++this.#n; } })()", "test:counter", null);
    defer counter.deinit();
    try scope.installCapability("counter", counter, null);
    try check(scope, "counter.inc() === 1");
    // Other scopes of the same runtime start from the pristine context.
    const other = try rt.createScope(.{});
    try check(other, "typeof globalThis.runs === 'undefined' && Object.isFrozen(Array.prototype)");
}

test "init snapshot: preparation does not execute main or unused functions" {
    ensureV8();
    var creating: Graph = .{ .init_source =
        \\globalThis.prepared = (globalThis.prepared ?? 0) + 1;
        \\export let calls = 0;
        \\export function main() { calls++; return 17; }
        \\export function unused() { throw new Error('must only execute when called'); }
    };
    var image = try m.init_snapshot.create(t.allocator, .{ .key = @splat(8), .scope = creating.options(), .specifier = "init" });
    defer image.deinit();
    const rt = try m.Runtime.create(t.allocator, .{ .snapshot = image.blob });
    defer rt.destroy();
    var options = creating.options();
    options.init_snapshot = &image.table;
    const scope = try rt.createScope(options);
    try exposeModule(scope, "init", "ns");
    try check(scope, "prepared === 1 && ns.calls === 0");
    try check(scope, "ns.main() === 17 && ns.calls === 1 && prepared === 1");
    try check(scope, "(() => { try { ns.unused(); return false; } catch(e) { return e.message.includes('must only execute'); } })()");
}

test "init snapshot: a changed source is noticed and a foreign key is refused" {
    ensureV8();
    var creating: Graph = .{};
    var image = try m.init_snapshot.create(t.allocator, .{ .key = @splat(1), .scope = creating.options(), .specifier = "init", .source_hasher = .{ .hash = hashId } });
    defer image.deinit();
    const Changed = struct {
        fn hash(_: ?*anyopaque, id: []const u8) anyerror!?[m.init_snapshot.hash_len]u8 {
            if (std.mem.eql(u8, id, "dep")) return @as([m.init_snapshot.hash_len]u8, @splat(0));
            return hashId(null, id);
        }
        fn gone(_: ?*anyopaque, _: []const u8) anyerror!?[m.init_snapshot.hash_len]u8 {
            return error.FileNotFound;
        }
    };
    try t.expect(!image.sourcesUnchanged(.{ .hash = Changed.hash }));
    try t.expect(!image.sourcesUnchanged(.{ .hash = Changed.gone }));
    const copy = try t.allocator.alignedAlloc(u8, m.init_snapshot.alignment, image.bytes.len);
    var copy_owned = false;
    defer if (!copy_owned) t.allocator.free(copy);
    @memcpy(copy, image.bytes);
    const same: m.init_snapshot.Identity = .{};
    try t.expectError(error.KeyMismatch, m.init_snapshot.parse(t.allocator, copy, @splat(2), same));
    try t.expectError(error.BadSnapshotFile, m.init_snapshot.parse(t.allocator, copy[0..40], @splat(1), same));
    // A file from another file layout or V8 build is refused with that reason, key or not.
    try t.expectError(error.FormatMismatch, m.init_snapshot.parse(t.allocator, copy, @splat(1), .{ .format = 2 }));
    try t.expectError(error.EngineMismatch, m.init_snapshot.parse(t.allocator, copy, @splat(1), .{ .engine = "v8 99.0" }));
    var parsed = try m.init_snapshot.parse(t.allocator, copy, @splat(1), same);
    // `copy` is owned by the parsed image from here on.
    parsed.deinit();
    copy_owned = true;
}

test "init snapshot: creation refuses an init that fails or cannot settle" {
    ensureV8();
    var throwing: Graph = .{ .init_source = "import 'dep'; throw new Error('boom')" };
    try t.expectError(error.InitFailed, m.init_snapshot.create(t.allocator, .{ .key = @splat(0), .scope = throwing.options(), .specifier = "init" }));
    var waiting: Graph = .{ .init_source = "await new Promise(() => {}); export const x = 1" };
    try t.expectError(error.InitNotSettled, m.init_snapshot.create(t.allocator, .{ .key = @splat(0), .scope = waiting.options(), .specifier = "init" }));
    var missing: Graph = .{ .init_source = "import 'nowhere'" };
    try t.expectError(error.InitFailed, m.init_snapshot.create(t.allocator, .{ .key = @splat(0), .scope = missing.options(), .specifier = "init" }));
}
