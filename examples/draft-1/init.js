import { Dir, IoError, Limit } from 'origine:@std/io';
import { eprintln } from 'origine:@std/debug';
import { ImportHandler } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { importMap, origine } from 'origine:@std/graph/resolve/layers';
import { fromLoader, origineProvider } from 'origine:@std/graph/providers';

const text = bytes => String.fromCharCode(...bytes);

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  eprintln('args:', api.env.args().join(' '));
  /** @type {import('@origine/types').FsRequest} */
  const grant = { root: 'examples/draft-1/work', access: 'rw' };
  const sync = api.fs.requestSync(grant);
  const io = api.io.create({});
  const async = await api.fs.requestAsync({ io, ...grant });
  const file = IoError.check(sync, sync.dirOpenFile(Dir.cwd(), 'hello.txt', 'w'));
  sync.fileWriteAll(file, Uint8Array.from([104, 105, 10]));
  sync.fileClose(file);
  const again = await async.dirOpenFile(Dir.cwd(), 'hello.txt', 'r');
  eprintln('read back:', JSON.stringify(text(await async.fileReadAll(again, { limit: Limit.unlimited }))));
  await io.close();
  try {
    IoError.check(sync, sync.dirOpenFile(Dir.cwd(), '../escape.txt', 'r'));
  } catch (e) {
    // Failures are `{ errno, name }` values, not Errors: narrow with IoError.is.
    if (!IoError.is(e, IoError.PermissionDenied)) throw e;
    eprintln('escape rejected:', e.name);
  }
  // A context loads through an import handler: here an import map, the host's debug module and a loader.
  const handler = ImportHandler.make({
    resolver: ImportResolver.layered()
      .layer(origine())
      .layer(importMap({ imports: { main: 'app:/main.js', dep: 'app:/dep.js' } })),
    hooks: [
      origineProvider({ std: { include: ['debug'] } }),
      fromLoader(async id =>
        id === 'app:/main.js'
          ? "import { eprintln } from 'origine:@std/debug'; import { v } from 'dep'; eprintln('child sees', v + preloaded)"
          : 'export const v = 40;',
      ),
    ],
  });
  const child = await api.context.create({
    import: handler,
    preload: [{ source: '(values) => { globalThis.preloaded = values.n }', values: { n: 2 } }],
  });
  await child.import('main');
}
