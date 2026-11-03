const std = @import("std");
const t = std.testing;
const check = @import("support.zig").check;
const Parent = @import("channel.zig").Parent;

const imports =
    \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
    \\import { ImportHandler, ImportHook } from 'origine:@std/graph/import';
    \\import { ImportResolver } from 'origine:@std/graph/resolve';
    \\import { relative } from 'origine:@std/graph/resolve/layers';
    \\import { fsProvider } from 'origine:@std/graph/providers';
    \\import { CodeCache } from 'origine:@std/graph/cache';
    \\const rel = () => ImportResolver.layered().layer(relative());
    \\const code = e => e.name === 'ModuleError' ? e.message.split(': ').at(-1) : e.name;
    \\
;

test "graph: fsProvider missing says whether the next root gets its turn" {
    var p: Parent = undefined;
    try p.setup("init.js", imports ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const load = async hooks => {
        \\    const graph = api.graph.create();
        \\    const context = await api.context.create({ import: ImportHandler.make({ resolver: rel(), hooks }), graph });
        \\    return context.import('./m.js').then(reference => graph.exports(reference).from, code);
        \\  };
        \\  const load2 = async hooks => {
        \\    // `graph.load` runs a handler with functions in JS: the same choice holds there.
        \\    const graph = api.graph.create();
        \\    const handler = ImportHandler.make({ resolver: rel(), hooks: [resolved => ImportHook.next(), ...hooks] });
        \\    const reference = graph.declare(ModuleRecipe({ source: ModuleSource.text("import './m.js';"), import: handler, name: 'main.js' }));
        \\    return graph.load(reference).then(() => 'loaded', code);
        \\  };
        \\  const kinds = {
        \\    sync: options => api.fs.requestSync({ access: 'r', handle: 'plain', ...options }),
        \\    asyncGrant: options => api.fs.requestAsync({ io, access: 'r', handle: 'plain', ...options }),
        \\  };
        \\  for (const [kind, grant] of Object.entries(kinds)) {
        \\    const empty = await grant({ root: 'empty' });
        \\    const full = await grant({ root: 'full' });
        \\    const second = fsProvider({ fs: full, read: 'copy' });
        \\    const results = [
        \\      await load([fsProvider({ fs: empty, read: 'copy', missing: 'skip' }), second]),
        \\      await load([fsProvider({ fs: empty, read: 'copy', missing: 'abort' }), second]),
        \\      await load([fsProvider({ fs: empty, read: 'copy' }), second]),
        \\      await load([fsProvider({ fs: empty, read: 'copy', missing: 'skip' })]),
        \\      await load2([fsProvider({ fs: empty, read: 'copy', missing: 'skip' }), second]),
        \\      await load2([fsProvider({ fs: empty, read: 'copy' }), second]),
        \\    ];
        \\    out[kind] = results.join();
        \\  }
        \\  const sync = api.fs.requestSync({ access: 'r', root: 'empty', handle: 'plain' });
        \\  const full = api.fs.requestSync({ access: 'r', root: 'full', handle: 'plain' });
        \\  out.mapped = await load([fsProvider({ fs: sync, read: 'mmap', missing: 'skip' }), fsProvider({ fs: full, read: 'mmap' })]);
        \\  out.bad = (() => { try { fsProvider({ fs: sync, read: 'copy', missing: 'ignore' }); return false; } catch (e) { return e.name === 'InvalidInput'; } })();
        \\  out.defaulted = fsProvider({ fs: sync, read: 'copy' }).missing;
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.tmp.dir.createDirPath(t.io, "empty");
    try p.tmp.dir.createDirPath(t.io, "full");
    try p.tmp.dir.writeFile(t.io, .{ .sub_path = "full/m.js", .data = "export const from = 'full';" });
    try p.run();
    const want = "'full,NotFound,NotFound,NotFound,loaded,NotFound'";
    try check(p.scope, "report.sync === " ++ want ++ " && report.asyncGrant === " ++ want);
    try check(p.scope, "report.mapped === 'full' && report.bad && report.defaulted === 'abort'");
}

test "graph: json missing says whether the next root gets its turn" {
    var p: Parent = undefined;
    try p.setup("init.js", imports ++
        \\import { json } from 'origine:@std/graph/providers';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const load = async hooks => {
        \\    const graph = api.graph.create();
        \\    const handler = ImportHandler.make({ resolver: rel(), hooks });
        \\    const context = await api.context.create({ import: handler, graph });
        \\    const reference = graph.declare(ModuleRecipe({ source: ModuleSource.text("import d from './d.json' with { type: 'json' }; export const from = d.from;"), import: handler, name: 'main.js' }));
        \\    return graph.evaluate(reference, context).then(() => graph.exports(reference).from, code);
        \\  };
        \\  const load2 = async hooks => {
        \\    const graph = api.graph.create();
        \\    const handler = ImportHandler.make({ resolver: rel(), hooks: [resolved => ImportHook.next(), ...hooks] });
        \\    const reference = graph.declare(ModuleRecipe({ source: ModuleSource.text("import d from './d.json' with { type: 'json' };"), import: handler, name: 'main.js' }));
        \\    return graph.load(reference).then(() => 'loaded', code);
        \\  };
        \\  const kinds = {
        \\    sync: options => api.fs.requestSync({ access: 'r', handle: 'plain', ...options }),
        \\    asyncGrant: options => api.fs.requestAsync({ io, access: 'r', handle: 'plain', ...options }),
        \\  };
        \\  for (const [kind, grant] of Object.entries(kinds)) {
        \\    const empty = await grant({ root: 'empty' });
        \\    const second = json({ fs: await grant({ root: 'full' }) });
        \\    out[kind] = [
        \\      await load([json({ fs: empty, missing: 'skip' }), second]),
        \\      await load([json({ fs: empty, missing: 'abort' }), second]),
        \\      await load([json({ fs: empty }), second]),
        \\      await load([json({ fs: empty, missing: 'skip' })]),
        \\      await load2([json({ fs: empty, missing: 'skip' }), second]),
        \\      await load2([json({ fs: empty }), second]),
        \\    ].join();
        \\  }
        \\  const sync = api.fs.requestSync({ access: 'r', root: 'empty', handle: 'plain' });
        \\  out.bad = (() => { try { json({ fs: sync, missing: 'ignore' }); return false; } catch (e) { return e.name === 'InvalidInput'; } })();
        \\  out.defaulted = json({ fs: sync }).missing;
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.tmp.dir.createDirPath(t.io, "empty");
    try p.tmp.dir.createDirPath(t.io, "full");
    try p.tmp.dir.writeFile(t.io, .{ .sub_path = "full/d.json", .data = "{\"from\":\"full\"}" });
    try p.run();
    const want = "'full,NotFound,NotFound,NotFound,loaded,NotFound'";
    try check(p.scope, "report.sync === " ++ want ++ " && report.asyncGrant === " ++ want);
    try check(p.scope, "report.bad && report.defaulted === 'abort'");
}

test "graph: limits and store failures of a code cache" {
    var p: Parent = undefined;
    try p.setup("init.js", imports ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const graph = api.graph.create();
        \\  const run = async (cache, names) => {
        \\    const handler = ImportHandler.make({ resolver: rel(), hooks: [], codeCache: cache });
        \\    const context = await api.context.create({ import: handler, graph });
        \\    for (const name of names) await graph.evaluate(graph.declare(ModuleRecipe({ source: ModuleSource.text('export const v = 1;'), import: handler, name })), context);
        \\  };
        \\  const nothing = CodeCache.memory({ limits: { size: 0 } });
        \\  await run(nothing, ['zero.js']);
        \\  out.zero = await nothing.flush();
        \\  const open = CodeCache.memory();
        \\  await run(open, ['open.js']);
        \\  out.open = await open.flush();
        \\  const src = api.fs.requestSync({ access: 'rw', handle: 'plain' });
        \\  out.dirLimits = (() => { try { CodeCache.dir({ fs: src, path: 'c', limits: { size: 1 } }); return false; } catch (e) { return e.name === 'InvalidInput'; } })();
        \\  const kept = [];
        \\  const flaky = CodeCache.custom({ load() {}, store(key) { if (key.id === 'a.js') throw new Error('disk full'); kept.push(key.id); } });
        \\  await run(flaky, ['a.js', 'b.js']);
        \\  out.flushed = await flaky.flush();
        \\  out.kept = kept.join();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.zero === 0 && report.open === 1 && report.dirLimits && report.flushed === 1 && report.kept === 'b.js'");
}

test "graph: a resolver layer cannot set attributes" {
    var p: Parent = undefined;
    try p.setup("init.js", imports ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const load = async answer => {
        \\    const handler = ImportHandler.make({ resolver: ImportResolver.layered().layer(() => answer), hooks: [() => ImportHook.source(ModuleSource.text('export default 1'))] });
        \\    const context = await api.context.create({ import: handler, graph: api.graph.create() });
        \\    return context.import('x').then(() => 'ok', code);
        \\  };
        \\  out.results = [await load('x'), await load({ id: 'x' }), await load({ id: 'x', attributes: { type: 'json' } })].join();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.results === 'ok,ok,InvalidData'");
}

test "graph: a released reference cannot be linked; a closed code cache holds nothing" {
    var p: Parent = undefined;
    try p.setup("init.js", imports ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const graph = api.graph.create();
        \\  const cache = CodeCache.memory();
        \\  const handler = ImportHandler.make({ resolver: rel(), hooks: [], codeCache: cache });
        \\  const context = await api.context.create({ import: handler, graph });
        \\  const declare = name => graph.declare(ModuleRecipe({ source: ModuleSource.text('export const v = 1;'), import: handler, name }));
        \\  const linking = async reference => {
        \\    const importer = ImportHandler.make({ resolver: ImportResolver.layered().layer(({ specifier }) => specifier), hooks: [() => ImportHook.link(reference)] });
        \\    const other = await api.context.create({ import: importer, graph });
        \\    return other.import('x').then(() => 'linked', code);
        \\  };
        \\  const kept = declare('kept.js');
        \\  await graph.evaluate(kept, context);
        \\  out.kept = await linking(kept);
        \\  const released = declare('released.js');
        \\  await graph.evaluate(released, context);
        \\  graph.release(released);
        \\  out.released = await linking(released);
        \\  // Released while it runs: the module still finishes, and no pin is taken for nobody to give back.
        \\  const during = declare('during.js');
        \\  const running = graph.evaluate(during, context);
        \\  graph.release(during);
        \\  await running;
        \\  out.during = during.status;
        \\  out.flushed = await cache.flush();
        \\  globalThis.closeCache = () => cache.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.kept === 'linked' && report.released === 'InvalidInput' && report.during === 'evaluated' && report.flushed > 0");
    // Only a reference nobody released holds a pin.
    for (p.rt.scopes.items) |scope| for (scope.module_map.all_entries.items) |entry| {
        if (std.mem.eql(u8, entry.id, "kept.js")) try t.expectEqual(@as(u32, 1), entry.pins);
        if (std.mem.eql(u8, entry.id, "released.js") or std.mem.eql(u8, entry.id, "during.js")) try t.expectEqual(@as(u32, 0), entry.pins);
    };
    var held: usize = 0;
    for (p.host.code_caches.values()) |store| held += store.memory_size;
    try t.expect(held > 0);
    try check(p.scope, "closeCache() === undefined");
    held = 0;
    for (p.host.code_caches.values()) |store| held += store.memory_size + store.memory.count();
    try t.expectEqual(@as(usize, 0), held);
}
