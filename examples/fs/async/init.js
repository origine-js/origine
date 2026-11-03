// Run: zig build run -- examples/fs/async/init.js   (or: zig-out/bin/origine examples/fs/async/init.js)
// An asynchronous grant runs its operations on an io runtime, so a read or write does not block the isolate.
// Its buffers follow the rules of origine:@std/io: copies by default; the zero-copy calls detach the buffer you pass
// (readInto, the *Move writes) and say so. The work/ directory is created by the program and is git-ignored.
//
// Prints (stderr):
//   readAlloc: 5 bytes "async"
//   readInto: 5 bytes, your view is detached: true
//   the bytes are in the returned buffer: async
//   writeMove: source detached: true
//   io.close() while a read is pending: Canceled
import { Dir, IoError, Limit } from 'origine:@std/io';
import { fs } from 'origine:@std/fs';
import { eprintln } from 'origine:@std/debug';
import { encodeUtf8, decodeUtf8 } from 'origine:@std/text';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  fs(api.fs.requestSync({ handle: 'plain', root: 'examples/fs/async', access: 'rw' })).create_dir_all('work');
  const grant = { root: 'examples/fs/async/work', access: 'rw', handle: 'plain' };

  // One runtime per group of work. `await using` closes it at scope exit, also when something throws.
  await using io = api.io.create({});
  const async = await api.fs.requestAsync({ io, ...grant });

  // Write with a copy first: the source buffer stays usable.
  const cwd = Dir.cwd();
  const file = await async.dirOpenFile(cwd, 'data.txt', 'w');
  await async.fileWriteAll(file, encodeUtf8('async'));
  await async.fileClose(file);

  // readAlloc: a fresh Uint8Array of exactly the bytes read (at most `len`).
  const reader = await async.dirOpenFile(cwd, 'data.txt', 'r');
  const allocated = await async.fileReadAlloc(reader, 1024);
  eprintln(`readAlloc: ${allocated.length} bytes "${decodeUtf8(allocated)}"`);

  // readInto: zero-copy. The view's ArrayBuffer is detached while the read runs; the bytes come back in `buffer`.
  // readAlloc read to the end, so this reads from a second handle.
  const again = await async.dirOpenFile(cwd, 'data.txt', 'r');
  const view = new Uint8Array(16);
  const { bytes, buffer } = await async.fileReadInto(again, view);
  eprintln(`readInto: ${bytes} bytes, your view is detached: ${view.byteLength === 0}`);
  // `buffer` is a view over the filled memory: use it (subarray), not `view`.
  eprintln('the bytes are in the returned buffer:', decodeUtf8(buffer.subarray(0, bytes)));
  await async.fileClose(again);
  await async.fileClose(reader);

  // writeMove: the whole ArrayBuffer is handed over. It is detached afterwards, whatever the outcome.
  const moved = await async.dirOpenFile(cwd, 'moved.txt', 'w');
  const payload = encodeUtf8('move');
  await async.fileWriteMoveAll(moved, payload);
  eprintln(`writeMove: source detached: ${payload.byteLength === 0}`);
  await async.fileClose(moved);

  // Closing the runtime cancels what is in flight: the pending read rejects with Canceled.
  const pending = await async.dirOpenFile(cwd, 'data.txt', 'r');
  const slow = async.fileRead(pending, new Uint8Array(4));
  await io.close();
  await slow.catch(e => eprintln(`io.close() while a read is pending: ${IoError.is(e, IoError.Canceled) ? 'Canceled' : e.name}`));

  // Limit is a value, not an option: it is used by the readers that take one.
  eprintln('Limit.limited(3) is a number:', Limit.limited(3) === 3);
}
