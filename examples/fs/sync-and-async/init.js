// Run: zig build run -- examples/fs/sync-and-async/init.js   (or: zig-out/bin/origine examples/fs/sync-and-async/init.js)
// The two file-system grants: a blocking one (requestSync) and a genuinely asynchronous one (requestAsync, which runs
// on an io runtime). Both take the same `root`, `access` and `handle`; both refuse a path that leaves the root.
// The work/ directory is created by the program and is git-ignored.
//
// Prints (stderr):
//   read back: "hi\n"
//   escape rejected: PermissionDenied
import { Dir, IoError, Limit } from 'origine:@std/io';
import { fs } from 'origine:@std/fs';
import { eprintln } from 'origine:@std/debug';

const text = bytes => String.fromCharCode(...bytes);

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  // `root` is relative to the working directory the program started in: run this from the repository root.
  // A grant cannot create its own root, so the parent directory's grant makes work/.
  fs(api.fs.requestSync({ handle: 'plain', root: 'examples/fs/sync-and-async', access: 'rw' })).create_dir_all('work');
  const grant = { root: 'examples/fs/sync-and-async/work', access: 'rw', handle: 'plain' };

  // Sync: calls block the isolate thread. Failures are not thrown by the raw ops; they set the grant's errno,
  // and IoError.check turns that into a throw.
  const sync = api.fs.requestSync(grant);
  const file = IoError.check(sync, sync.dirOpenFile(Dir.cwd(), 'hello.txt', 'w'));
  sync.fileWriteAll(file, Uint8Array.from([104, 105, 10]));
  sync.fileClose(file);

  // Async: every op returns a promise that rejects with an IoError. It needs an io runtime, which must be closed.
  const io = api.io.create({});
  const async = await api.fs.requestAsync({ io, ...grant });
  const again = await async.dirOpenFile(Dir.cwd(), 'hello.txt', 'r');
  eprintln('read back:', JSON.stringify(text(await async.fileReadAll(again, { limit: Limit.unlimited }))));
  await async.fileClose(again);
  await io.close();

  // Confinement is lexical: a `..` component is refused before any system call is made.
  try {
    IoError.check(sync, sync.dirOpenFile(Dir.cwd(), '../escape.txt', 'r'));
  } catch (e) {
    // Failures are `{ errno, name }` values, not Errors: narrow with IoError.is.
    if (!IoError.is(e, IoError.PermissionDenied)) throw e;
    eprintln('escape rejected:', e.name);
  }
}
