// Run: zig-out/bin/origine examples/context/migrate-from-scope/init.js   (or: zig build run -- examples/context/migrate-from-scope/init.js)
// The old child-scope call. api.scope is gone (replaced by api.graph and api.context), so it is shown
// here as a comment only:
//
//   const child = await api.scope.create({
//     main: 'app:/main.js',
//     origineNamespace: true,
//     importMap: { imports: { dep: 'app:/dep.js', './banner.tpl': 'app:/banner.tpl' } },
//     loader: id => sources[id],
//     transformers: { '.tpl': (source, id) => `export default ${JSON.stringify(source.trim())};` },
//   });
//   await child.run();
//
// The same program with the module graph. Each old option now belongs to one piece:
//   importMap          -> a resolver layer: importMap({ imports, scopes })
//   origineNamespace   -> origine() (recognises ids) and origineProvider() (serves every one the creating context has)
//   loader             -> a hook: fromLoader(loader)
//   transformers       -> the maker: MakeRecipe.inherit({ transformer: Transform.byExtension({...}) })
//   main + run()       -> ctx.import(main)
//   create(...)        -> api.context.create({ import, graph }) and the handler is made once with ImportHandler.make
// Prints (stderr):
//   main: dep v1 | banner: hello from a template
//   nothing: ModuleError: app:/nothing.js: InvalidData   (a loader that returns undefined is InvalidData now)
import { ImportHandler, MakeRecipe, Transform } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { importMap, origine } from 'origine:@std/graph/resolve/layers';
import { fromLoader, origineProvider } from 'origine:@std/graph/providers';
import { eprintln } from 'origine:@std/debug';

const sources = {
  'app:/main.js': "import { dep } from 'dep'; import banner from './banner.tpl'; import { eprintln } from 'origine:@std/debug'; eprintln('main:', dep, '| banner:', banner);",
  'app:/dep.js': "export const dep = 'dep v1';",
  'app:/banner.tpl': '  hello from a template\n',
};

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const handler = ImportHandler.make({
    resolver: ImportResolver.layered()
      .layer(origine())
      .layer(importMap({ imports: { main: 'app:/main.js', dep: 'app:/dep.js', './banner.tpl': 'app:/banner.tpl', nothing: 'app:/nothing.js' } })),
    hooks: [
      // The old origineNamespace: true served every origine: module; origineProvider() does the same, for as
      // much as this realm may import. Prefer `origineProvider({ std: { include: [...] } })` once you know which.
      origineProvider(),
      fromLoader(id => sources[id]),
    ],
    // The old transformers, keyed by extension of the module id; the function signature is unchanged.
    maker: MakeRecipe.inherit({
      transformer: Transform.byExtension({ '.tpl': (source, id) => `export default ${JSON.stringify(source.trim())};` }),
    }),
  });

  // The old `main` is the module imported here, and `run()` is its evaluation.
  using ctx = await api.context.create({ import: handler, graph: api.graph.root });
  await ctx.import('main');
  await ctx.import('nothing').catch(e => eprintln(`nothing: ${e.name}: ${e.message}`));
}
