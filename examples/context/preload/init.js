// Run: zig build run -- examples/context/preload/init.js   (or: zig-out/bin/origine examples/context/preload/init.js)
// A context is a realm with no authority. It gets only what the creator hands it through `preload`, which runs before
// anything is imported: a script (a function expression, called with `values`) or a module given as source text (its
// default export, called with `values` when it is a function). `values` are plain data and functions, deep-frozen. Here the only thing the
// realm can print with is a function the host passed in.
//
// Prints (stderr):
//   from the realm: hello, origine (greet, defined by the module preload) and the print function from the script preload
//   realm sees api: undefined ; fetch: undefined
//   Map value: TypeError
import { ImportHandler } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { relative, origine } from 'origine:@std/graph/resolve/layers';
import { fsProvider, origineProvider } from 'origine:@std/graph/providers';
import { eprintln } from 'origine:@std/debug';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const src = api.fs.requestSync({ handle: 'plain', root: 'examples/context/preload', access: 'r' });
  const handler = ImportHandler.make({
    resolver: ImportResolver.layered().layer(origine()).layer(relative()),
    hooks: [origineProvider({ std: { include: ['debug'] } }), fsProvider({ fs: src, read: 'copy' })],
  });
  const graph = api.graph.create();

  using ctx = await api.context.create({
    import: handler,
    graph,
    preload: [
      // A script: a function expression; `values` is what the host passed.
      { source: '(values) => { globalThis.print = values.print; }', values: { print: (...a) => eprintln(...a) } },
      // A module: its SOURCE TEXT (not a specifier); its default export runs with `values` (here it defines `greet`).
      { module: "export default values => { globalThis.greet = who => `hello, ${who}`; globalThis.realmName = values.name; };", values: { name: 'origine' } },
    ],
  });
  await ctx.import('./main.js');

  // A value the realm may not receive: a Map is not plain data.
  await api.context
    .create({ import: handler, graph, preload: [{ source: '(values) => {}', values: { map: new Map() } }] })
    .then(() => eprintln('Map value: accepted'), e => eprintln(`Map value: ${e.name}`));
  graph.close();
}
