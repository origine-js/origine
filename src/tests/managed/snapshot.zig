const std = @import("std");
const t = std.testing;
const m = @import("@managed");
const ensureV8 = @import("../support.zig").ensureV8;
const check = @import("support.zig").check;
const Memory = @import("support.zig").Memory;

test "snapshot: runtime restores finalized scopes that behave like fresh ones" {
    ensureV8();
    const blob = try m.snapshot.create(t.allocator);
    defer t.allocator.free(blob);
    try t.expect(blob.len > 0);
    const rt = try m.Runtime.create(t.allocator, .{ .snapshot = blob });
    defer rt.destroy();
    var memory: Memory = .{};
    const a = try rt.createScope(memory.options());
    const b = try rt.createScope(.{});
    try check(a, "Object.isFrozen(Array.prototype) && !Reflect.set(globalThis, 'Array', () => {})");
    try check(a, "typeof print === 'function' && typeof Date.now === 'function'");
    // Per-scope state is added after restore: scopes stay distinct and share hardened values.
    const cap = try a.eval("new (class Counter { #n = 0; inc() { return ++this.#n; } })()", "test:counter", null);
    defer cap.deinit();
    try a.installCapability("counter", cap, null);
    try b.installCapability("counter", cap, null);
    try check(b, "counter.inc() === 1");
    try t.expectError(error.UnsupportedExport, b.installCapability("bad", try a.eval("new Map()", "test:map", null), null));
    // Module loading still works in a restored context.
    const promise = try a.importModule("main", null);
    defer promise.deinit();
    rt.pump();
    try check(a, "true");
    try t.expect(memory.loads > 0);
}

test "snapshot: truncated blobs are rejected before V8 sees them" {
    ensureV8();
    var junk: [128]u8 align(16) = @splat(0xAB);
    try t.expectError(error.InvalidSnapshot, m.Runtime.create(t.allocator, .{ .snapshot = &junk }));
}
