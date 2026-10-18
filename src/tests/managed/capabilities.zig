const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const m = @import("@managed");
const ensureV8 = @import("../support.zig").ensureV8;
const support = @import("support.zig");
const check = support.check;
const NativeCounter = support.NativeCounter;

test "managed step 2: intrinsic inventory and code generation lockdown" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    const attacks = [_][]const u8{
        "Object.prototype.polluted = true",                                               "Array.prototype.push = () => 0",
        "Object.defineProperty(Object.prototype, Symbol.iterator, {value: 1})",           "Object.setPrototypeOf(Object.prototype, {})",
        "Object = function(){}",                                                          "Object.getPrototypeOf([][Symbol.iterator]()).next = () => 0",
        "Object.getPrototypeOf(Object.getPrototypeOf((function*(){})())).next = () => 0", "Object.getPrototypeOf(Object.getPrototypeOf((async function*(){})())).next = () => 0",
        "Function('return globalThis')()",                                                "eval('1')",
        "(async()=>{}).constructor('return 1')()",                                        "(function*(){}).constructor('yield 1')()",
        "(async function*(){}).constructor('yield 1')()",                                 "Date.prototype.setTime = () => 0",
    };
    for (attacks) |attack| try t.expectError(error.JavaScriptException, scope.eval(attack, "test:attack", null));
    try check(scope, "typeof WebAssembly === 'object' && Object.isFrozen(WebAssembly) && typeof SharedArrayBuffer === 'function' && typeof Atomics === 'object'");
    try check(scope, "const bytes = new Uint8Array(new SharedArrayBuffer(4)); bytes[0] = 42; bytes[0] === 42 && Object.isFrozen(SharedArrayBuffer.prototype)");
    try check(scope, "class C { #x = 1; inc() { return ++this.#x; } }; new C().inc() === 2 && [1,2].map(x=>x+1)[1] === 3");
    try check(scope, "Object.isFrozen(Object.getPrototypeOf(async()=>{}))");
    try check(scope, "globalThis.done = false; Promise.resolve().then(()=>{done = true}); true");
    rt.pump();
    try check(scope, "done === true");
}

test "managed step 3: hardened sharing and private state" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const a = try rt.createScope(.{});
    const b = try rt.createScope(.{});
    const cap = try a.eval("new (class Counter { #n = 0; inc() { return ++this.#n; } })()", "test:counter", null);
    defer cap.deinit();
    try a.installCapability("counter", cap, null);
    try b.installCapability("counter", cap, null);
    try b.installCapability("sameCounter", cap, null);
    try check(b, "counter === sameCounter && counter.inc() === 1 && Reflect.ownKeys(counter).length === 0");
    try check(a, "counter.inc() === 2");
    try t.expectError(error.JavaScriptException, b.eval("counter.inc.call({})", "test:brand", null));
    try t.expectError(error.JavaScriptException, b.eval("Object.getPrototypeOf(counter).inc = () => 0", "test:prototype", null));
    try t.expectError(error.JavaScriptException, b.eval("counter = {}", "test:binding", null));
    const cycle = try a.eval("globalThis.accessed = 0; const graph = {get x(){accessed++; throw 1}}; graph.self = graph; graph", "test:cycle", null);
    defer cycle.deinit();
    try a.harden(cycle, null);
    try check(a, "accessed === 0 && Object.isFrozen(graph)");
    const unsupported = [_][]const u8{ "new Map()", "new Uint8Array(1)", "new SharedArrayBuffer(4)", "Promise.resolve(1)", "new WeakRef({})", "[][Symbol.iterator]()", "globalThis", "new Proxy({}, {ownKeys(){throw 1}})" };
    for (unsupported) |source| {
        const value = try a.eval(source, "test:unsupported", null);
        defer value.deinit();
        try t.expectError(error.UnsupportedExport, a.harden(value, null));
    }
}

test "managed step 7: native private capabilities validate receivers without coercion" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const a = try rt.createScope(.{});
    const b = try rt.createScope(.{});
    rt.isolate.enter();
    defer rt.isolate.exit();
    var h_scope: v8.HandleScope = undefined;
    h_scope.init(rt.isolate);
    defer h_scope.deinit();
    const ctx = a.context.deref();
    ctx.enter();
    defer ctx.exit();
    var native: NativeCounter = .{ .key = .new(rt.isolate, v8.Private.init(rt.isolate, null)) };
    defer native.key.deinit();
    const object = v8.Object.init(rt.isolate);
    try t.expect(object.setPrivate(ctx, native.key.deref(), v8.Number.initInt(rt.isolate, 0).numeric.primitive.value).?);
    const function = v8.Function.init(ctx, NativeCounter.increment, v8.External.init(rt.isolate, &native).value.data, 1, .Throw, .HasSideEffect);
    try t.expect(object.createDataProperty(ctx, v8.String.initUtf8(rt.isolate, "inc").name, function.object.value).?);
    const cap = v8.Global.Of(v8.Value).new(rt.isolate, object.value);
    defer cap.deinit();
    try b.installCapability("native", cap, null);
    try check(b, "native.inc(2) === 2 && Reflect.ownKeys(native).length === 1");
    try t.expectError(error.JavaScriptException, b.eval("native.inc.call({}, 1)", "test:forged", null));
    try check(b, "globalThis.coerced = false; try {native.inc({valueOf(){coerced = true; throw 1}})} catch {} !coerced");
    try t.expectError(error.JavaScriptException, b.eval("new native.inc(1)", "test:constructor", null));
    try check(b, "native.inc(3) === 5");
}

test "managed step 7: cross-scope exotic rejection, callbacks and failures" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const a = try rt.createScope(.{});
    const b = try rt.createScope(.{});
    for ([_][]const u8{ "new WeakRef({})", "new FinalizationRegistry(()=>{})", "[][Symbol.iterator]()", "new Proxy({}, {ownKeys(){throw 1}})" }) |source| {
        const value = try a.eval(source, "test:foreign-exotic", null);
        defer value.deinit();
        try t.expectError(error.UnsupportedExport, b.installCapability("bad", value, null));
    }
    const fn_ = try a.eval("(callback => callback(Object.freeze({value: 42})))", "test:callback", null);
    defer fn_.deinit();
    try b.installCapability("call", fn_, null);
    try check(b, "call(x => Object.isFrozen(x) && x.value === 42)");
    try check(b, "try {call(() => {throw 17})} catch (e) {globalThis.thrown = e} thrown === 17");
    const promised = try a.eval("(() => Promise.resolve(Object.freeze({value:42})))", "test:promise", null);
    defer promised.deinit();
    try b.installCapability("later", promised, null);
    try check(b, "globalThis.answer = 0; later().then(x=>{answer=x.value}); true");
    rt.pump();
    try check(b, "answer === 42");
    try t.expectError(error.InvalidImportMap, m.ImportMap.parseJson(t.allocator, "[]", .{ .base_url = "app:/map", .urls = m.virtual_urls }));
    try t.expectEqual(@as(usize, 2), rt.scopes.items.len);
    const valid = try rt.createScope(.{});
    try check(valid, "true");
}
