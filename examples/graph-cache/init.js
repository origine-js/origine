// Run: zig-out/bin/origine examples/graph-cache/init.js   (or: zig build run -- examples/graph-cache/init.js)
// Two caches with different jobs. ImportCache names a table of modules (module id -> reference) that the
// contexts using the same object share; `retain` says whether an entry outlives its holders, which decides if a re-import evaluates
// again. CodeCache keeps V8's compiled code, so a compile can be skipped; it never changes what runs.
// The dir cache writes examples/graph-cache/__codecache__/ on the first run (not in .gitignore).
//
// Prints (stderr), with side.js's own line each time it evaluates:
//   retain all: same reference: true , table size: 1
//   delete(side.js) dropped 1 ; after delete, same reference: false
//   clear() dropped 1 ; table size now 0
//   retain used: evaluated again after release: true , table size: 1
//   one cache, two contexts: same module: true , table size: 1   (side.js evaluated once, in the first context)
//   code cache memory: flush stored N modules
//   code cache dir: flush stored N modules   (1 on the first run, 0 on later runs: the file is there)
import { CodeCache, ImportCache } from 'origine:@std/graph/cache';
import { ImportHandler } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { relative } from 'origine:@std/graph/resolve/layers';
import { fsProvider } from 'origine:@std/graph/providers';
import { eprintln } from 'origine:@std/debug';

const makeHandler = cache =>
  ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [fsProvider({ read: 'copy' })], cache });

/** A context whose modules print through `print`. */
const context = (api, handler, graph) =>
  api.context.create({
    import: handler,
    graph,
    preload: [{ source: '(values) => { globalThis.print = values.print; }', values: { print: (...a) => eprintln(...a) } }],
  });

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const fs = api.fs.requestSync({ handle: 'plain', root: 'examples/graph-cache', access: 'rw' });
  const graph = api.graph.derive({ fs });

  // 1. retain 'all' (the default): a module lives as long as its context. Importing twice evaluates once.
  const all = ImportCache.native({ retain: 'all' });
  using ctxAll = await context(api, makeHandler(all), graph);
  const first = await ctxAll.import('./side.js');
  const second = await ctxAll.import('./side.js');
  eprintln('retain all: same reference:', first === second, ', table size:', all.size);
  // delete(id) is an identity reset: the next import makes a new reference and evaluates it again.
  eprintln('delete(side.js) dropped', all.delete('side.js'), '; after delete, same reference:', (await ctxAll.import('./side.js')) === first);
  eprintln('clear() dropped', all.clear(), '; table size now', all.size);

  // 2. retain 'used': an entry is dropped once nothing holds it, so releasing the reference re-evaluates.
  const used = ImportCache.native({ retain: 'used' });
  using ctxUsed = await context(api, makeHandler(used), graph);
  const held = await ctxUsed.import('./side.js');
  held.release();
  const again = await ctxUsed.import('./side.js');
  eprintln('retain used: evaluated again after release:', again !== held, ', table size:', used.size);

  // 2b. Contexts that use the same ImportCache object share its modules: the first to import an id evaluates it
  //     (its print shows), the other links that module: live bindings, the same objects. Two contexts made from one
  //     handler object share too, because the handler made its default cache once; that leaks the realm boundary.
  const together = ImportCache.native({ retain: 'all' });
  const sharedHandler = makeHandler(together);
  using home = await context(api, sharedHandler, graph);
  using guest = await context(api, sharedHandler, graph);
  const inHome = await home.import('./side.js');
  const inGuest = await guest.import('./side.js');
  eprintln('one cache, two contexts: same module:', inHome.exports().id === inGuest.exports().id, ', table size:', together.size);

  // 3. Code caches. `memory` keeps bytes in this graph; `dir` writes one file per distinct source under __codecache__.
  //    Both are written at graph.flush(): it resolves how many modules' caches were stored this time.
  const memory = api.graph.derive({ fs, codeCache: CodeCache.memory() });
  using ctxMem = await context(api, makeHandler(ImportCache.native({ retain: 'all' })), memory);
  await ctxMem.import('./side.js');
  eprintln('code cache memory: flush stored', await memory.flush(), 'modules');

  const onDisk = api.graph.derive({ fs, codeCache: CodeCache.dir(fs) });
  using ctxDir = await context(api, makeHandler(ImportCache.native({ retain: 'all' })), onDisk);
  await ctxDir.import('./side.js');
  eprintln('code cache dir: flush stored', await onDisk.flush(), 'modules');
}
