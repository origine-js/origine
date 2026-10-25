const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const m = @import("@managed");
const repl = @import("../../repl.zig");
const ensureV8 = @import("../support.zig").ensureV8;
const check = @import("support.zig").check;

fn expectText(scope: *m.Scope, value: v8.Global.Of(v8.Value), expected: []const u8) !void {
    const isolate = scope.runtime.isolate;
    isolate.enter();
    defer isolate.exit();
    var handles: v8.HandleScope = undefined;
    handles.init(isolate);
    defer handles.deinit();
    const text = value.deref().toString(scope.context.deref()).?;
    const bytes = try t.allocator.alloc(u8, text.lenUtf8(isolate));
    defer t.allocator.free(bytes);
    const len = text.writeUtf8(isolate, bytes);
    try t.expectEqualStrings(expected, bytes[0..len]);
}

test "REPL bare object literals use expression grammar and never execute twice" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    const helpers = try repl.Helpers.init(scope);
    defer helpers.deinit();
    for ([_][]const u8{ "{a:123,b:234}", "{a:123,b:234};", "{\na:123,\nb:234\n}" }) |source| {
        const value = try repl.eval(scope, source, null);
        defer value.deinit();
        const shown = try helpers.display("inspect", value);
        defer shown.deinit();
        try expectText(scope, shown, "{ a: 123, b: 234 }");
    }
    try t.expect(repl.incomplete(scope, "{a:123,\nb:"));
    try t.expect(!repl.incomplete(scope, "{a:123,b:234}"));
    try t.expect(!repl.incomplete(scope, "{a: ,b:}"));
    const initial = try repl.eval(scope, "globalThis.executions = 0", null);
    initial.deinit();
    try t.expectError(error.JavaScriptException, repl.eval(scope, "{a: (++executions, (() => { throw Error('once') })())}", null));
    try check(scope, "executions === 1");
    const block = try repl.eval(scope, "{ executions++; executions; }", null);
    defer block.deinit();
    try check(scope, "executions === 2");
}

test "REPL lexical completions, special results and rich builtins" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    const helpers = try repl.Helpers.init(scope);
    defer helpers.deinit();
    const source = "const fruit = {apple: 1, apricot: 2}; fruit";
    const value = try repl.eval(scope, source, null);
    defer value.deinit();
    try helpers.remember(source, value, false);
    const matches = try helpers.complete("fruit.app");
    defer matches.deinit();
    try expectText(scope, matches, "fruit.apple");
    try check(scope, "_ === fruit");
    const destructured_source = "const {one, two: second} = {one: 1, two: 2}, third = 3;";
    const destructured = try repl.eval(scope, destructured_source, null);
    defer destructured.deinit();
    try helpers.remember(destructured_source, destructured, false);
    const second = try helpers.complete("secon");
    defer second.deinit();
    try expectText(scope, second, "second");
    const third = try helpers.complete("thir");
    defer third.deinit();
    try expectText(scope, third, "third");
    const cases = [_][2][]const u8{
        .{ "new Map([['a', 123]])", "Map { \"a\" => 123 }" },
        .{ "new Set([1, 2])", "Set { 1, 2 }" },
        .{ "new Uint8Array([1, 2, 255])", "Uint8Array(3) [ 1, 2, 255 ]" },
        .{ "/hello/gi", "/hello/gi" },
        .{ "new Error('hello')", "Error: hello" },
    };
    for (cases) |case| {
        const item = try repl.eval(scope, case[0], null);
        defer item.deinit();
        const shown = try helpers.display("inspect", item);
        defer shown.deinit();
        try expectText(scope, shown, case[1]);
    }
    const colored = try helpers.display("inspectColor", value);
    defer colored.deinit();
    try expectText(scope, colored, "{ apple: \x1b[33m1\x1b[0m, apricot: \x1b[33m2\x1b[0m }");
}

test "REPL continuation probes compile without executing and preserve real syntax errors" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    try t.expect(repl.incomplete(scope, "function add(a, b) {"));
    try t.expect(repl.incomplete(scope, "({ answer:"));
    try t.expect(repl.incomplete(scope, "`hello ${"));
    try t.expect(repl.incomplete(scope, "/* unfinished comment"));
    try t.expect(!repl.incomplete(scope, "const bad = ; {"));
    try t.expect(!repl.incomplete(scope, "'unterminated string"));
    try t.expect(!repl.incomplete(scope, "const complete = 42; complete"));
    try t.expect(repl.incomplete(scope, "globalThis.probeCount = 1; if (true) {"));
    try check(scope, "typeof probeCount === 'undefined' && typeof complete === 'undefined'");
    try check(scope, "const persistent = 42; persistent === 42");
    try t.expect(!repl.incomplete(scope, "persistent + 1"));
    try check(scope, "persistent === 42");
}

test "REPL inspection bounds cyclic graphs and never invokes getters or proxy traps" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    const helpers = try repl.Helpers.init(scope);
    defer helpers.deinit();
    const value = try scope.eval(
        \\globalThis.inspectionEffects = 0;
        \\globalThis.sample = { answer: 42, get secret() { inspectionEffects++; throw Error('getter'); } };
        \\sample.self = sample;
        \\sample.proxy = new Proxy({}, { ownKeys() { inspectionEffects++; throw Error('trap'); } });
        \\sample
    , "test:inspect", null);
    defer value.deinit();
    const formatted = try helpers.display("inspect", value);
    defer formatted.deinit();
    try expectText(scope, formatted, "{ answer: 42, secret: [Getter], self: [Circular], proxy: [Proxy] }");
    try check(scope, "inspectionEffects === 0");
    const deep = try scope.eval("({a:{b:{c:{d:1}}}})", "test:deep", null);
    defer deep.deinit();
    const bounded = try helpers.display("inspect", deep);
    defer bounded.deinit();
    try expectText(scope, bounded, "{ a: { b: { c: [Object] } } }");
}

test "REPL completion resolves descriptor paths without evaluating accessors" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    const helpers = try repl.Helpers.init(scope);
    defer helpers.deinit();
    const math = try helpers.complete("Math.ma");
    defer math.deinit();
    try expectText(scope, math, "Math.max");
    try check(scope,
        \\globalThis.completionEffects = 0;
        \\Object.defineProperty(globalThis, 'completionGetter', { get() { completionEffects++; return Math; } });
        \\globalThis.completionProxy = new Proxy({}, { ownKeys() { completionEffects++; return []; } });
        \\true
    );
    for ([_][]const u8{ "completionGetter.ma", "completionProxy.a" }) |prefix| {
        const result = try helpers.complete(prefix);
        defer result.deinit();
        try expectText(scope, result, "(no completions)");
    }
    try check(scope, "completionEffects === 0");
}

test {
    _ = repl.input;
    _ = repl.terminal;
    _ = @import("../../repl/session.zig");
}

test "REPL pretty printing wraps long collections with nested indentation" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    const helpers = try repl.Helpers.init(scope);
    defer helpers.deinit();
    const value = try scope.eval("({ nested: { first: 'abcdefghijklmnopqrstuvwxyz', second: 'abcdefghijklmnopqrstuvwxyz', third: [1, 2] } })", "test:pretty", null);
    defer value.deinit();
    const formatted = try helpers.display("inspect", value);
    defer formatted.deinit();
    try expectText(
        scope,
        formatted,
        "{\n  nested: {\n    first: \"abcdefghijklmnopqrstuvwxyz\",\n    second: \"abcdefghijklmnopqrstuvwxyz\",\n    third: [ 1, 2 ]\n  }\n}",
    );
}
