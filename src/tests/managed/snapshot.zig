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

test "snapshot: restored bootstrap helpers preserve validation and code-generation lockdown" {
    ensureV8();
    const blob = try m.snapshot.create(t.allocator);
    defer t.allocator.free(blob);
    const rt = try m.Runtime.create(t.allocator, .{ .snapshot = blob });
    defer rt.destroy();
    const a = try rt.createScope(.{});
    const b = try rt.createScope(.{});
    for ([_]*m.Scope{ a, b }) |scope| {
        try t.expectError(error.JavaScriptException, scope.eval("Object.prototype.modified = true", "test:intrinsic", null));
        try t.expectError(error.JavaScriptException, scope.eval("Function('return 1')()", "test:codegen", null));
        for ([_][]const u8{ "new Map()", "new Uint8Array(1)", "Promise.resolve(1)", "[][Symbol.iterator]()", "new Proxy({}, {ownKeys(){throw new Error('trap')}})" }) |source| {
            const value = try scope.eval(source, "test:unsupported", null);
            defer value.deinit();
            try t.expectError(error.UnsupportedExport, scope.harden(value, null));
        }
        const graph = try scope.eval("globalThis.getterCalls = 0; globalThis.graph = {get value(){getterCalls++; return 1}}; graph", "test:descriptors", null);
        defer graph.deinit();
        try scope.harden(graph, null);
        try check(scope, "getterCalls === 0 && Object.isFrozen(graph) && Object.isFrozen(Object.getOwnPropertyDescriptor(graph, 'value').get)");
    }
}
