// Run: zig-out/bin/origine examples/graph-basic/init.js   (or: zig build run -- examples/graph-basic/init.js)
// The smallest module-graph program. A recipe names a file; a graph reads files through an fs grant;
// a reference is declared, then loaded (its static imports are known), then evaluated in a context.
//
// Prints (stderr), with the modules' own lines in between:
//   declared: declared
//   requests before load: undefined
//   loaded: loaded, requests: ./greet.js -> greet.js (declared)
//   greet.js evaluates first
//   recipe: hello from greet.js
//   evaluated: evaluated, bound to ctx: true
//   exports of recipe.js:
//   dependency greet.js: greeting=hello from greet.js, info frozen: true, same object each call: false
//   bound to a second context: InvalidInput
import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
import { ImportHandler } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { relative } from 'origine:@std/graph/resolve/layers';
import { fsProvider } from 'origine:@std/graph/providers';
import { eprintln } from 'origine:@std/debug';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  // 1. Authority: the graph reads files only through this read-only grant of the example directory.
  const graph = api.graph.derive({ fs: api.fs.requestSync({ handle: 'plain', root: 'examples/graph-basic', access: 'r' }) });
  // 2. The pipeline for the module's own imports: './x' resolved against the importer, then read by the fs provider.
  const handler = ImportHandler.make({
    resolver: ImportResolver.layered().layer(relative()),
    hooks: [fsProvider({ read: 'copy' })],
  });
  // 3. A recipe describes the root module. Building it reads nothing.
  const recipe = ModuleRecipe({ source: ModuleSource.file('recipe.js'), import: handler });
  // 4. A reference to it in the graph. Still nothing is read.
  const reference = recipe.create(graph);
  eprintln('declared:', reference.status);
  eprintln('requests before load:', reference.requests);
  // 5. load() reads, compiles and loads the static imports, one level down.
  await reference.load();
  const [request] = reference.requests;
  eprintln(`loaded: ${reference.status}, requests: ${request.specifier} -> ${request.reference.name} (${request.reference.status})`);
  // 6. A context is a realm. It gets no capability unless one is passed in `preload` values, so a print
  //    function is handed over here; the modules call the global `print`.
  using ctx = await api.context.create({
    import: handler,
    graph,
    preload: [{ source: '(values) => { globalThis.print = values.print; }', values: { print: (...a) => eprintln(...a) } }],
  });
  // 7. evaluate() binds the reference to ctx for good and runs it (top-level await included).
  await reference.evaluate(ctx);
  eprintln(`evaluated: ${reference.status}, bound to ctx: ${reference.context === ctx}`);
  // 8. The creating realm can read a module's exports once it is evaluated: plain data is copied and frozen
  //    (a snapshot, so every call copies again), functions would be shared and keep running in the context.
  //    recipe.js exports nothing. A dependency is read through its own reference, which is bound the same way.
  eprintln('exports of recipe.js:', ...Object.keys(reference.exports()));
  const greet = await ctx.import('./greet.js');
  const first = greet.exports();
  eprintln(`dependency greet.js: greeting=${first.greeting}, info frozen: ${Object.isFrozen(first.info)}, same object each call: ${first === greet.exports()}`);
  // A reference is bound to one context for good: evaluating it in a second one is InvalidInput.
  // To run the same code there, call recipe.create(graph) again.
  const other = await api.context.create({ import: handler, graph });
  await reference.evaluate(other).catch(e => eprintln('bound to a second context:', e.name));
  other.close();
}
