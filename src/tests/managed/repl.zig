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

/// Parses `source` as a pending REPL entry in the Rust engine.
fn prepare(engine: repl.Engine, source: []const u8) !repl.engine.Prepared {
    engine.clear();
    try engine.append(source);
    return engine.prepare();
}

/// Runs a REPL entry the way the session does for scripts: the engine decides what V8 evaluates.
fn evalEntry(scope: *m.Scope, engine: repl.Engine, source: []const u8) !v8.Global.Of(v8.Value) {
    try t.expectEqual(repl.engine.Prepared.script, try prepare(engine, source));
    return repl.eval(scope, engine.buffer(.code), null);
}

test "REPL bare object literals use expression grammar and never execute twice" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    const helpers = try repl.Helpers.init(scope);
    defer helpers.deinit();
    const engine = try repl.Engine.init(false);
    defer engine.deinit();
    for ([_][]const u8{ "{a:123,b:234}", "{a:123,b:234};", "{\na:123,\nb:234\n}" }) |source| {
        const value = try evalEntry(scope, engine, source);
        defer value.deinit();
        const shown = try helpers.display("inspect", value);
        defer shown.deinit();
        try expectText(scope, shown, "{ a: 123, b: 234 }");
    }
    try t.expectEqual(repl.engine.Prepared.incomplete, try prepare(engine, "{a:123,\nb:"));
    try t.expectEqual(repl.engine.Prepared.@"error", try prepare(engine, "{a: ,b:}"));
    const initial = try evalEntry(scope, engine, "globalThis.executions = 0");
    initial.deinit();
    try t.expectError(error.JavaScriptException, evalEntry(scope, engine, "{a: (++executions, (() => { throw Error('once') })())}"));
    try check(scope, "executions === 1");
    const block = try evalEntry(scope, engine, "{ executions++; executions; }");
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

test "REPL continuation probes never execute and preserve real syntax errors" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    const engine = try repl.Engine.init(false);
    defer engine.deinit();
    const incomplete = repl.engine.Prepared.incomplete;
    try t.expectEqual(incomplete, try prepare(engine, "function add(a, b) {"));
    try t.expectEqual(incomplete, try prepare(engine, "({ answer:"));
    try t.expectEqual(incomplete, try prepare(engine, "`hello ${"));
    try t.expectEqual(incomplete, try prepare(engine, "/* unfinished comment"));
    try t.expectEqual(repl.engine.Prepared.@"error", try prepare(engine, "const bad = ; {"));
    try t.expectEqual(repl.engine.Prepared.@"error", try prepare(engine, "'unterminated string"));
    try t.expectEqual(repl.engine.Prepared.script, try prepare(engine, "const complete = 42; complete"));
    try t.expectEqual(incomplete, try prepare(engine, "globalThis.probeCount = 1; if (true) {"));
    try t.expect(std.mem.indexOf(u8, engine.buffer(.diagnostics), ": error: ") != null);
    // Parsing never runs guest code.
    try check(scope, "typeof probeCount === 'undefined' && typeof complete === 'undefined'");
    try check(scope, "const persistent = 42; persistent === 42");
    try t.expectEqual(repl.engine.Prepared.script, try prepare(engine, "persistent + 1"));
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
    _ = repl.engine;
    _ = @import("../../repl/tty.zig");
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

test "REPL rewrites top-level await and import into code V8 accepts, and waits for open constructs" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    const engine = try repl.Engine.init(false);
    defer engine.deinit();
    try t.expectEqual(repl.engine.Prepared.script, try prepare(engine, "1 + 1"));
    try t.expectEqual(repl.engine.Prepared.script, try prepare(engine, "const f = async () => 1"));
    try t.expectEqual(repl.engine.Prepared.async, try prepare(engine, "const { a, b: [c] } = await Promise.resolve({ a: 1, b: [2] })\nc"));
    const wrapped = engine.buffer(.code);
    try t.expect(std.mem.startsWith(u8, wrapped, "(async () => {"));
    try t.expect(std.mem.indexOf(u8, wrapped, "[\"a\",\"c\"]") != null);
    try t.expect(std.mem.indexOf(u8, wrapped, "return (c)") != null);
    try t.expect(std.mem.indexOf(u8, engine.buffer(.plain), "await Promise.resolve") != null);
    const promise = try repl.eval(scope, wrapped, null);
    promise.deinit();
    try t.expectEqual(repl.engine.Prepared.async, try prepare(engine, "import def, { x as y } from './mod.js'"));
    try t.expect(std.mem.indexOf(u8, engine.buffer(.code), "default: def, x: y } = await import(") != null);
    try t.expectEqual(repl.engine.Prepared.incomplete, try prepare(engine, "const x = await call({"));
    try t.expectEqual(repl.engine.Prepared.incomplete, try prepare(engine, "await a +"));
    try t.expectEqual(repl.engine.Prepared.async, try prepare(engine, "await a"));
    try t.expectEqual(repl.engine.Prepared.incomplete, try prepare(engine, "1 +"));
}

test "REPL inspects promises, classes, sparse arrays and groups long numeric arrays" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    const helpers = try repl.Helpers.init(scope);
    defer helpers.deinit();
    const cases = [_][2][]const u8{
        .{ "Promise.resolve({ a: 1 })", "Promise { { a: 1 } }" },
        .{ "new Promise(() => {})", "Promise { <pending> }" },
        .{ "(() => { const p = Promise.reject(new Error('x')); p.catch(() => {}); return p; })()", "Promise { <rejected> Error: x }" },
        .{ "[class A {}, class B extends Array {}, async () => 1]", "[ [class A], [class B extends Array], [AsyncFunction (anonymous)] ]" },
        .{ "[1, , , 4]", "[ 1, <2 empty items>, 4 ]" },
        .{ "Object.assign(function f() {}, { x: 1 })", "[Function: f] { x: 1 }" },
        .{ "Object.create(null)", "[Object: null prototype] {}" },
        .{ "Array.from({ length: 10 }, (_, i) => i + 1)", "[\n  1, 2, 3, 4,  5,\n  6, 7, 8, 9, 10\n]" },
    };
    for (cases) |case| {
        const item = try scope.eval(case[0], "test:inspect", null);
        defer item.deinit();
        const shown = try helpers.display("inspect", item);
        defer shown.deinit();
        try expectText(scope, shown, case[1]);
    }
}

test "REPL TypeScript pass erases types, keeps object literals and imports, and spots unfinished input" {
    if (!m.Api.oxc.enabled) return error.SkipZigTest;
    const engine = try repl.Engine.init(false);
    defer engine.deinit();
    try t.expectEqual(repl.engine.Prepared.script, try prepare(engine, "const x: number = 1 as number"));
    try t.expect(std.mem.indexOf(u8, engine.buffer(.code), "const x = 1") != null);
    try t.expectEqual(repl.engine.Prepared.script, try prepare(engine, "{ a: 1 as number }"));
    try t.expect(std.mem.startsWith(u8, engine.buffer(.code), "({"));
    try t.expectEqual(repl.engine.Prepared.async, try prepare(engine, "import { unused } from './x.js'"));
    try t.expect(std.mem.indexOf(u8, engine.buffer(.code), "unused") != null);
    for ([_][]const u8{ "function f(a: number) {", "const x: number = 1 +", "interface A {" }) |source| {
        try t.expectEqual(repl.engine.Prepared.incomplete, try prepare(engine, source));
    }
    try t.expectEqual(repl.engine.Prepared.@"error", try prepare(engine, "let y: = 1"));
}

test "REPL engine keeps pending input, history and dot-commands" {
    const engine = try repl.Engine.init(false);
    defer engine.deinit();
    try engine.append("({");
    try engine.append(" answer: 42 })");
    try t.expectEqualStrings("({\n answer: 42 })", engine.source());
    engine.remember();
    engine.clear();
    try engine.recall(null);
    try t.expectEqualStrings("({\n answer: 42 })", engine.source());
    try t.expectEqual(@as(usize, 1), engine.historyLen());
    try t.expectEqualStrings("({\n answer: 42 })", engine.historyEntry(0));
    try t.expectError(error.NoHistoryEntry, engine.recall(2));
    try t.expect(engine.command(" .help ") == .help);
    try t.expect(engine.command(".5 + .2") == .source);
    try t.expect(engine.command(".again 0") == .invalid);
    try t.expectEqual(@as(?usize, 2), engine.command(".again 2").again);
    try t.expectEqual(@as(?usize, null), engine.command(".again").again);
    try t.expectEqualStrings("Math.ma", engine.command(".complete Math.ma").complete);
    engine.clear();
    const big = try t.allocator.alloc(u8, 64 * 1024);
    defer t.allocator.free(big);
    @memset(big, 'x');
    try engine.append(big);
    try t.expectError(error.InputTooLong, engine.append("x"));
}
