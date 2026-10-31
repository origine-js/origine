// Run: zig-out/bin/origine examples/graph-hello/init.js   (or: zig build run -- examples/graph-hello/init.js)
// The module graph in one program: main.js imports greet.js. Prints `hello, graph`.
import { ImportHandler } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { relative } from 'origine:@std/graph/resolve/layers';
import { fsProvider } from 'origine:@std/graph/providers';
import { eprintln } from 'origine:@std/debug';

export async function main(api) {
  const src = api.fs.requestSync({ handle: 'plain', root: 'examples/graph-hello', access: 'r' });
  const handler = ImportHandler.make({
    resolver: ImportResolver.layered().layer(relative()),
    hooks: [fsProvider({ fs: src, read: 'copy' })],
  });
  using ctx = await api.context.create({ import: handler, graph: api.graph.root });
  const main = await ctx.import('./main.js');
  eprintln(api.graph.root.exports(main).message);
}
