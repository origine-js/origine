// Run: zig-out/bin/origine examples/graph-cross-context/init.js   (or: zig build run -- examples/graph-cross-context/init.js)
// Two contexts, one graph. Context A evaluates lib.js (the exporter); context B imports it through a hook.
//   Import.link(ref): B uses A's module itself, with live bindings and A's own objects. Nothing is copied or
//     frozen, so B can read and write A's `config`, and a function B calls runs in A. This crosses the realm
//     boundary on purpose; hand data over with a copy (origine:@std snapshot / Import.exports) instead.
//   Import.recipe(recipe): B gets its own module of counter.js, with its own state, separate from A's.
// Prints (stderr):
//   counter.js evaluated                      (A, loaded by lib.js)
//   A: lib.js evaluated
//   counter.js evaluated                      (B, its own copy)
//   B: config {"name":"lib","count":0} frozen: false
//   B: bump() in A -> 1 | B sees config.count 1 | A own object frozen: false
//   B: wrote config.count = 99, A bump() -> 100
//   B: counter inc() -> 1 2 | A counter -> 1
//   host: A exports config {"name":"lib","count":100} frozen: false | bump() -> 101 | next read count: 101
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
        if (resolved.id === 'lib.js') return Import.link(lib);
        if (resolved.id === 'counter.js') return Import.recipe(counter); // a recipe is final: B's own module
        return Import.next();
      },
      fsProvider({ read: 'copy' }),
    ],
  });
  using ctxB = await api.context.create({ import: handlerB, graph, preload: printPreload });
  await ctxB.import('./user.js');

  // The creating realm (this one) reads A's live namespace too: A's own objects, no copy.
  const seen = graph.exports(lib);
  const bumped = seen.bump();
  eprintln(
    `host: A exports config ${JSON.stringify(seen.config)} frozen: ${Object.isFrozen(seen.config)} | bump() -> ${bumped} | next read count: ${graph.exports(lib).config.count}`,
  );
}
