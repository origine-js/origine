// Run: zig build run -- examples/graph/providers/init.js   (or: zig-out/bin/origine examples/graph/providers/init.js)
// Hooks decide where each import comes from, in order. Providers are the usual hooks: fsProvider reads ids as paths
// under a grant's root (missing: 'skip' passes to the next hook, so several roots are several providers), json
// serves `with { type: 'json' }` imports, origineProvider serves origine:@std/* modules, and fromLoader adapts a
// function that returns the source for an id. The import map is a resolver layer: it turns the bare name 'greeting'
// into an id that the loader can answer.
//
// Prints (stderr, from main.js):
//   json: example | local: primary | shared: fallback | greeting: from a loader
import { ImportHandler } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { relative, importMap, origine } from 'origine:@std/graph/resolve/layers';
import { fsProvider, json, fromLoader, origineProvider } from 'origine:@std/graph/providers';
import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const primary = api.fs.requestSync({ handle: 'plain', root: 'examples/graph/providers/primary', access: 'r' });
  const fallback = api.fs.requestSync({ handle: 'plain', root: 'examples/graph/providers/fallback', access: 'r' });

  const handler = ImportHandler.make({
    resolver: ImportResolver.layered()
      .layer(origine())                                             // recognises origine:@std/* ids
      .layer(relative())
      .layer(importMap({ imports: { greeting: 'app:/greeting.js' } })),
    hooks: [
      json({ fs: primary, missing: 'skip' }),
      // A missing file passes on to the next hook; the fallback root is searched after the primary one.
      fsProvider({ fs: primary, read: 'copy', missing: 'skip' }),
      fsProvider({ fs: fallback, read: 'copy', missing: 'skip' }),
      origineProvider({ std: { include: ['debug'] } }),
      // The last hook: a loader must answer every id that reaches it (undefined is InvalidData), so it comes last.
      fromLoader(id => (id === 'app:/greeting.js' ? "export const greeting = 'from a loader';" : undefined)),
    ],
  });

  const graph = api.graph.create();
  const recipe = ModuleRecipe({ source: ModuleSource.file('main.js', { fs: primary }), import: handler });
  using ctx = await api.context.create({ import: handler, graph });
  const reference = graph.declare(recipe);
  await graph.load(reference);
  await graph.evaluate(reference, ctx);
  graph.close();
}
