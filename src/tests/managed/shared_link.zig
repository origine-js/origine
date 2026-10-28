//! Spike for `Import.link(ref, { mode: 'shared' })`: can a module of one context be linked into
//! the module graph of another context of the same isolate (live bindings, same objects)?
//! The answer decides whether the `'shared'` mode of the module graph ships or answers
//! `Unsupported` (docs/graph-api.md).
const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const eu = @import("@util");
const m = @import("@managed");
const ensureV8 = @import("../support.zig").ensureV8;
const support = @import("support.zig");
const check = support.check;
const Memory = support.Memory;

/// The module of context A that the importer in context B resolves `dep` to.
var shared_dep: ?v8.Global.Of(v8.Module) = null;

fn resolveShared(_: v8.Context, _: v8.String, _: v8.FixedArray, _: v8.Module) callconv(.c) v8.MaybeHandle {
    return shared_dep.?.deref().data.handle;
}

test "a module evaluated in one context links into the graph of another context" {
    ensureV8();
    var memory: Memory = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const a = try rt.createScope(memory.options());
    const b = try rt.createScope(memory.options());

    // `dep` is evaluated in A (scope id 0 exports 1). Keep a handle to its V8 module.
    try support.exposeModule(a, "dep", "dep");
    shared_dep = (try a.module_map.get(.{ .module_id = "dep" }, null)).?;
    defer {
        shared_dep.?.deinit();
        shared_dep = null;
    }

    // B compiles `import { value } from 'dep'` itself and links A's module instead of its own.
    var session: m.Scope.Session = undefined;
    session.init(b);
    defer session.deinit();
    const iso = session.isolate();
    var origin = b.scriptOrigin("shared-importer", true);
    var source: v8.ScriptCompiler.Source = undefined;
    source.init(eu.v.str_utf8(iso, "import { value } from 'dep'; export const seen = value; export const same = globalThis.sameRealm === undefined;"), &origin, null);
    defer source.deinit();
    const importer = v8.ScriptCompiler.compileModule(iso, &source, 0, 0) orelse return error.CompileFailed;

    const linked = importer.instantiateModule(session.ctx, resolveShared, null);
    try t.expectEqual(@as(?bool, true), linked);
    const evaluation = importer.evaluate(session.ctx) orelse return error.EvaluateFailed;
    const promise = v8.Promise.from_opaque(evaluation.data.handle).?;
    try t.expectEqual(v8.Promise.PromiseState.Fulfilled, promise.state());

    // The importer in B sees the value A's `dep` exported (1 in scope 0, which is A).
    const namespace = importer.getModuleNamespace().?.toObject(session.ctx).?;
    const seen = namespace.get(session.ctx, eu.v.str_utf8(iso, "seen").name.primitive.value).?;
    try t.expectEqual(@as(i32, 1), seen.i32Value(session.ctx).?);
}

test "a linked module keeps live bindings and the same objects across contexts" {
    ensureV8();
    var memory: Memory = .{};
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const a = try rt.createScope(memory.options());
    const b = try rt.createScope(memory.options());

    try a.updateImportCache(.{ .module_id = "counter" }, .{ .source = "export let n = 1; export function inc() { n++; } export const shared = { tag: 'a' };" }, null);
    try support.exposeModule(a, "counter", "counter");
    shared_dep = (try a.module_map.get(.{ .module_id = "counter" }, null)).?;
    defer {
        shared_dep.?.deinit();
        shared_dep = null;
    }
    try check(a, "counter.n === 1");

    var session: m.Scope.Session = undefined;
    session.init(b);
    defer session.deinit();
    const iso = session.isolate();
    var origin = b.scriptOrigin("shared-importer", true);
    var source: v8.ScriptCompiler.Source = undefined;
    source.init(eu.v.str_utf8(iso, "import { n, shared } from 'counter'; export const read = () => n; export { shared };"), &origin, null);
    defer source.deinit();
    const importer = v8.ScriptCompiler.compileModule(iso, &source, 0, 0) orelse return error.CompileFailed;
    try t.expectEqual(@as(?bool, true), importer.instantiateModule(session.ctx, resolveShared, null));
    const promise = v8.Promise.from_opaque((importer.evaluate(session.ctx) orelse return error.EvaluateFailed).data.handle).?;
    try t.expectEqual(v8.Promise.PromiseState.Fulfilled, promise.state());

    // A bumps the counter; B's binding follows (live binding).
    {
        const bump = try a.eval("counter.inc(); counter.n", "test:bump", null);
        defer bump.deinit();
    }
    const namespace = importer.getModuleNamespace().?.toObject(session.ctx).?;
    const read = v8.Function.from_opaque(namespace.get(session.ctx, eu.v.str_utf8(iso, "read").name.primitive.value).?.data.handle).?;
    const after = read.call(session.ctx, eu.v.undefined_value(iso).value, &.{}).?;
    try t.expectEqual(@as(i32, 2), after.i32Value(session.ctx).?);

    // The object B sees is A's own object: it carries A's prototype, not B's.
    const seen = namespace.get(session.ctx, eu.v.str_utf8(iso, "shared").name.primitive.value).?;
    const a_ctx = a.context.deref();
    const a_object = seen.toObject(session.ctx).?;
    try t.expect(a_object.getCreationContext().?.eq(a_ctx));
    try t.expect(!a_object.getCreationContext().?.eq(session.ctx));
}
