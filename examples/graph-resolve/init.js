// Run: zig-out/bin/origine examples/graph-resolve/init.js   (or: zig build run -- examples/graph-resolve/init.js)
// Resolver layers turn a specifier into an id. The first layer that answers wins; none means NotFound.
// Three kinds are stacked here: an import map (exact names, and a scope for one referrer prefix),
// relative(), and a function layer. The sources are in memory and served by fromLoader, so no fs grant.
//
// Prints (stderr), with the modules' own lines in between:
//   handler.native: false
//   plan: [...]  (which layers and hooks run in JS)
//   app:/main.js: util -> app:/lib/util-v2.js
//   app:/main.js: ./legacy/old.js -> app:/legacy/old.js
//   app:/main.js: virtual:clock -> app:/virtual/clock.js
//   main: util v2 | legacy sees util v1 | a virtual clock   (the scope applies to legacy/old.js only)
import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
import { ImportHandler } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { importMap, relative } from 'origine:@std/graph/resolve/layers';
import { fromLoader } from 'origine:@std/graph/providers';
import { eprintln } from 'origine:@std/debug';

const sources = {
  'app:/main.js':
    "import { util } from 'util'; import { legacy } from './legacy/old.js'; import { now } from 'virtual:clock';" +
    " print('main:', util, '|', legacy, '|', now);",
  'app:/legacy/old.js': "import { util } from 'util'; export const legacy = 'legacy sees ' + util;",
  'app:/lib/util-v2.js': "export const util = 'util v2';",
  'app:/lib/util-v1.js': "export const util = 'util v1';",
  'app:/virtual/clock.js': "export const now = 'a virtual clock';",
};

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const handler = ImportHandler.make({
    resolver: ImportResolver.layered()
      // 1. Import map, web semantics: values are URLs against 'app:/map.json'. A scope applies to
      //    referrers under its prefix and is tried before the top-level imports.
      .layer(
        importMap({
          imports: { util: 'app:/lib/util-v2.js' },
          scopes: { 'app:/legacy/': { util: 'app:/lib/util-v1.js' } },
        }),
      )
      // 2. './x' and '../x' against the importer's id.
      .layer(relative())
      // 3. A function layer, run in the creating realm (it may be async). It answers `virtual:` names only;
      //    anything else returns undefined and falls through to NotFound.
      .layer(async ({ specifier }) => (specifier.startsWith('virtual:') ? { id: `app:/virtual/${specifier.slice(8)}.js` } : undefined)),
    hooks: [fromLoader(id => sources[id])],
  });
  eprintln('handler.native:', handler.native);
  // handler.plan says which elements enter JS: the import map and relative() are native, the function layer is not.
  eprintln('plan:', JSON.stringify(handler.plan));

  // Every source is text, so the root graph (api.graph, no fs grant) is enough.
  const main = api.graph.declare(
    ModuleRecipe({ source: ModuleSource.text(sources['app:/main.js']), import: handler, name: 'app:/main.js' }),
  );
  await api.graph.load(main);
  for (const r of api.graph.requests(main)) eprintln(`app:/main.js: ${r.specifier} -> ${r.reference.name}`);
  // Not shown: the requests of a dependency. Its load() returns without compiling it today, so its
  // `requests` stay undefined (see graph-NOTES.md). The scope is visible in what the module evaluates to.

  using ctx = await api.context.create({
    import: handler,
    graph: api.graph,
    preload: [{ source: '(values) => { globalThis.print = values.print; }', values: { print: (...a) => eprintln(...a) } }],
  });
  await api.graph.evaluate(main, ctx);
}
