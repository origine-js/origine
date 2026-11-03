// Run: zig-out/bin/origine examples/graph-transform/init.js   (or: zig build run -- examples/graph-transform/init.js)
// Transformers run between reading a source and compiling it. Two places hold them:
//   - on a source: ModuleSource.file(p, { fs }).withTransformer(t), for this module only;
//   - on the handler's maker: MakeRecipe.inherit({ transformer: Transform.byExtension({...}) }), for every
//     module the handler supplies, picked by the extension of its id.
// A function transformer is (source, id) => string | { source, map }; it runs in this realm, so this
// example needs no oxc. Prints (stderr):
//   transformers: plain 0 stamped 1
//   plan: ...
//   Hello from a text file | build build-42
import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
import { ImportHandler, MakeRecipe, Transform } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { relative } from 'origine:@std/graph/resolve/layers';
import { fsProvider } from 'origine:@std/graph/providers';
import { eprintln } from 'origine:@std/debug';

// Replaces a placeholder before compilation.
const stampBuild = (source, id) => source.replaceAll('__BUILD__', JSON.stringify('build-42'));
// A loader for text files: the file's text becomes a default export.
const textModule = text => `export default ${JSON.stringify(text.trimEnd())};`;

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const src = api.fs.requestSync({ handle: 'plain', root: 'examples/graph-transform', access: 'r' });
  const graph = api.graph.create();
  const handler = ImportHandler.make({
    resolver: ImportResolver.layered().layer(relative()),
    hooks: [fsProvider({ fs: src, read: 'copy' })],
    // Applied to every module this handler supplies: here, only ids ending in .txt have a transformer.
    maker: MakeRecipe.inherit({ transformer: Transform.byExtension({ '.txt': textModule }) }),
  });

  // withTransformer returns a new source; the receiver is unchanged.
  const plain = ModuleSource.file('main.js', { fs: src });
  const stamped = plain.withTransformer(stampBuild);
  eprintln('transformers: plain', plain.transformers.length, 'stamped', stamped.transformers.length);

  const recipe = ModuleRecipe({ source: stamped, import: handler });
  eprintln('plan:', JSON.stringify(handler.plan));

  using ctx = await api.context.create({
    import: handler,
    graph,
    preload: [{ source: '(values) => { globalThis.print = values.print; }', values: { print: (...a) => eprintln(...a) } }],
  });
  await graph.evaluate(graph.declare(recipe), ctx);
}
