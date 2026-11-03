// Run: zig build run -- examples/graph/custom-code-cache/init.js   (or: zig-out/bin/origine examples/graph/custom-code-cache/init.js)
// CodeCache.custom hands the compiled code to you: store(key, blob) keeps it when flush() runs, load(key, source)
// returns it before V8 compiles the module. The key is the id and the BLAKE3 hash of the exact text V8 compiles, so a
// blob made for other text is never used. This example keeps the blobs in a Map; a real one would write them somewhere.
// The first context stores; a second context with its own import cache finds the blobs.
//
// Prints (stderr):
//   main.js evaluates in the first context
//   first context: flush stored 2 module(s)
//   second context: loads that found a blob: 2
import { CodeCache, ImportCache } from 'origine:@std/graph/cache';
import { ImportHandler } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { relative, origine } from 'origine:@std/graph/resolve/layers';
import { fsProvider, origineProvider } from 'origine:@std/graph/providers';
import { eprintln } from 'origine:@std/debug';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const src = api.fs.requestSync({ handle: 'plain', root: 'examples/graph/custom-code-cache', access: 'r' });
  const blobs = new Map();
  let hits = 0;
  const cache = CodeCache.custom({
    // The blob is opaque: the bytes V8 produced. A miss is `undefined`; a throw is a miss too.
    load: key => {
      const blob = blobs.get(`${key.id}:${key.hash}`);
      if (blob) hits += 1;
      return blob;
    },
    store: (key, blob) => blobs.set(`${key.id}:${key.hash}`, blob),
  });
  const graph = api.graph.create();
  const handler = (imports) =>
    ImportHandler.make({
      resolver: ImportResolver.layered().layer(origine()).layer(relative()),
      hooks: [origineProvider({ std: { include: ['debug'] } }), fsProvider({ fs: src, read: 'copy' })],
      cache: imports,
      codeCache: cache,
    });

  using first = await api.context.create({ import: handler(ImportCache.native({ retain: 'all' })), graph });
  await first.import('./main.js');
  await first.import('./side.js');
  eprintln(`first context: flush stored ${await cache.flush()} module(s)`);

  // A second context with its own ImportCache evaluates the modules again, and V8 gets their code from `load`.
  using second = await api.context.create({ import: handler(ImportCache.native({ retain: 'all' })), graph });
  await second.import('./main.js');
  await second.import('./side.js');
  eprintln(`second context: loads that found a blob: ${hits}`);
  cache.close();
  graph.close();
}
