// Run: zig build run -- examples/graph/owned-graph/init.js   (or: zig-out/bin/origine examples/graph/owned-graph/init.js)
// api.graph.root is the shared graph; api.graph.create() makes a graph you own, and closing it frees its modules and
// makes its references stale. A ModuleReference is an inert ticket: it shows name, status and context and has no
// methods, so holding one does not let you run or free the module. A reference belongs to one graph.
//
// Prints (stderr):
//   declared: status declared, has load method: false
//   after load: loaded
//   module.js evaluated in its own graph
//   after evaluate: evaluated
//   a reference used on another graph: InvalidInput
//   after close: StaleHandle
import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
import { ImportHandler } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { relative, origine } from 'origine:@std/graph/resolve/layers';
import { fsProvider, origineProvider } from 'origine:@std/graph/providers';
import { eprintln } from 'origine:@std/debug';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const src = api.fs.requestSync({ handle: 'plain', root: 'examples/graph/owned-graph', access: 'r' });
  const handler = ImportHandler.make({
    resolver: ImportResolver.layered().layer(origine()).layer(relative()),
    hooks: [origineProvider({ std: { include: ['debug'] } }), fsProvider({ fs: src, read: 'copy' })],
  });
  const recipe = ModuleRecipe({ source: ModuleSource.file('module.js', { fs: src }), import: handler });

  // `using` closes the graph at scope exit, and the references with it.
  using graph = api.graph.create();
  const reference = graph.declare(recipe);
  eprintln(`declared: status ${reference.status}, has load method: ${typeof reference.load === 'function'}`);

  await graph.load(reference);
  eprintln(`after load: ${reference.status}`);
  using ctx = await api.context.create({ import: handler, graph });
  await graph.evaluate(reference, ctx);
  eprintln(`after evaluate: ${reference.status}`);

  // The reference belongs to `graph`: another graph refuses it.
  using other = api.graph.create();
  await other.load(reference).catch(e => eprintln(`a reference used on another graph: ${e.name}`));

  // A closed graph's references are stale.
  graph.close();
  await graph.load(reference).catch(e => eprintln(`after close: ${e.name}`));
}
