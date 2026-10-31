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
  // 4. The graph declares it and gives back a reference, an inert ticket: it shows `name`, `status` and `context` and
  //    can do nothing; the graph loads, runs, reads and frees it. Still nothing is read.
  const reference = graph.declare(recipe);
  eprintln('declared:', reference.status);
  eprintln('requests before load:', graph.requests(reference));
  // 5. graph.load() reads, compiles and loads the static imports, one level down.
  await graph.load(reference);
  const [request] = graph.requests(reference);
  eprintln(`loaded: ${reference.status}, requests: ${request.specifier} -> ${request.reference.name} (${request.reference.status})`);
  // 6. A context is a realm. It gets no capability unless one is passed in `preload` values, so a print
  //    function is handed over here; the modules call the global `print`.
  using ctx = await api.context.create({
    import: handler,
    graph,
    preload: [{ source: '(values) => { globalThis.print = values.print; }', values: { print: (...a) => eprintln(...a) } }],
  });
  // 7. graph.evaluate() binds the reference to ctx for good and runs it (top-level await included). The context
  //    must be made with the same graph.
  await graph.evaluate(reference, ctx);
  eprintln(`evaluated: ${reference.status}, bound to ctx: ${reference.context === ctx}`);
  // 8. The creating realm can read a module's exports once it is evaluated: plain data is copied and frozen
  //    (a snapshot, so every call copies again), functions would be shared and keep running in the context.
  //    recipe.js exports nothing. A dependency is read through its own reference, which is bound the same way.
  eprintln('exports of recipe.js:', ...Object.keys(graph.exports(reference)));
  const greet = await ctx.import('./greet.js');
  const first = graph.exports(greet);
  eprintln(
    `dependency greet.js: greeting=${first.greeting}, info frozen: ${Object.isFrozen(first.info)}, same object each call: ${first === graph.exports(greet)}`,
  );
  // A reference is bound to one context for good: evaluating it in a second one is InvalidInput.
  // To run the same code there, declare the recipe again.
  const other = await api.context.create({ import: handler, graph });
  await graph.evaluate(reference, other).catch(e => eprintln('bound to a second context:', e.name));
  other.close();
}
