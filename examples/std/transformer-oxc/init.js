// Run: zig build run -- examples/std/transformer-oxc/init.js   (or: zig-out/bin/origine examples/std/transformer-oxc/init.js)
// origine:@std/transformer/oxc gives transformer descriptors that the host runs natively on module source: ts strips
// types, tsx and jsx compile JSX (with the classic or automatic runtime). A transformer goes on a source with
// withTransformer, or on a handler's maker with Transform.byExtension. Nothing is type-checked.
//
// Prints (stderr):
//   view('origine') via jsx transformer: {"tag":"p","props":{"class":"greeting"},"children":["hello, ","origine"]}
//   ts transformer on a typed source: 3
import { jsx, ts } from 'origine:@std/transformer/oxc';
import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
import { ImportHandler } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { relative, origine } from 'origine:@std/graph/resolve/layers';
import { fsProvider, origineProvider } from 'origine:@std/graph/providers';
import { eprintln } from 'origine:@std/debug';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const src = api.fs.requestSync({ handle: 'plain', root: 'examples/std/transformer-oxc', access: 'r' });
  // The jsx transformer runs on the file's source before it compiles; `h` is what the classic runtime calls.
  const view = ModuleSource.file('view.jsx', { fs: src }).withTransformer(jsx({ jsx: 'classic', pragma: 'h' }));
  const handler = ImportHandler.make({
    resolver: ImportResolver.layered().layer(origine()).layer(relative()),
    hooks: [origineProvider({ std: { include: ['debug'] } }), fsProvider({ fs: src, read: 'copy' })],
  });
  const graph = api.graph.create();
  const recipe = ModuleRecipe({ source: view, import: handler });
  using ctx = await api.context.create({ import: handler, graph });
  const reference = graph.declare(recipe);
  await graph.load(reference);
  await graph.evaluate(reference, ctx);
  const rendered = graph.exports(reference).view('origine');
  eprintln('view(\'origine\') via jsx transformer:', JSON.stringify(rendered));

  // ts: a typed source becomes plain JavaScript; the type annotation is erased, the value is kept.
  const typed = ModuleRecipe({ source: ModuleSource.file('typed.ts', { fs: src }).withTransformer(ts()), import: handler });
  const typedRef = graph.declare(typed);
  await graph.load(typedRef);
  await graph.evaluate(typedRef, ctx);
  eprintln('ts transformer on a typed source:', graph.exports(typedRef).three);
  graph.close();
}
