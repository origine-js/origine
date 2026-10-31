// Run: zig-out/bin/origine examples/graph-cross-context/init.js   (or: zig build run -- examples/graph-cross-context/init.js)
// Two contexts, one graph. Context A evaluates lib.js (the exporter); context B imports it through a hook.
//   Import.link(ref, { mode: 'hardened' }): B gets a snapshot of A's exports. Plain data is copied and the
//     copies are frozen, so B cannot write to them and A's own object stays mutable. A function is shared,
//     so calling it runs in A and changes A's object, not B's copy.
//   Import.provide(recipe): B gets its own module of counter.js, with its own state, separate from A's.
// Prints (stderr):
//   counter.js evaluated                      (A, loaded by lib.js)
//   A: lib.js evaluated
//   counter.js evaluated                      (B, its own copy)
//   B: config copy {"name":"lib","count":0} frozen: true
//   B: bump() in A -> 1 | B copy still 0 | A own object frozen: false
//   B: writing the copy throws TypeError
//   B: counter inc() -> 1 2 | A counter -> 1
//   host: A exports config {"name":"lib","count":1} frozen: true | bump() -> 2 | next read count: 2
import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
import { Import, ImportHandler } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { relative } from 'origine:@std/graph/resolve/layers';
import { fsProvider } from 'origine:@std/graph/providers';
import { eprintln } from 'origine:@std/debug';

const printPreload = [{ source: '(values) => { globalThis.print = values.print; }', values: { print: (...a) => eprintln(...a) } }];

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const graph = api.graph.derive({ fs: api.fs.requestSync({ handle: 'plain', root: 'examples/graph-cross-context', access: 'r' }) });
  const handlerA = ImportHandler.make({
    resolver: ImportResolver.layered().layer(relative()),
    hooks: [fsProvider({ read: 'copy' })],
  });

  // A: the exporter. lib.js is evaluated here and the reference is kept for B's hook to link.
  using ctxA = await api.context.create({ import: handlerA, graph, preload: printPreload });
  const lib = graph.declare(ModuleRecipe({ source: ModuleSource.file('lib.js'), import: handlerA }));
  await graph.evaluate(lib, ctxA);
  const counter = ModuleRecipe({ source: ModuleSource.file('counter.js'), import: handlerA });

  // B: the importer. Its hooks decide where each import comes from; a link needs an evaluated reference.
  const handlerB = ImportHandler.make({
    resolver: ImportResolver.layered().layer(relative()),
    hooks: [
      resolved => {
        if (resolved.id === 'lib.js') return Import.link(lib, { mode: 'hardened' });
        if (resolved.id === 'counter.js') return Import.provide(counter); // a recipe is final: B's own module
        return Import.next();
      },
      fsProvider({ read: 'copy' }),
    ],
  });
  using ctxB = await api.context.create({ import: handlerB, graph, preload: printPreload });
  await ctxB.import('./user.js');

  // The creating realm (this one) can read A's exports too: a frozen copy of the data, shared functions.
  const seen = graph.exports(lib);
  const bumped = seen.bump();
  eprintln(
    `host: A exports config ${JSON.stringify(seen.config)} frozen: ${Object.isFrozen(seen.config)} | bump() -> ${bumped} | next read count: ${graph.exports(lib).config.count}`,
  );
}
