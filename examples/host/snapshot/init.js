// Run: zig build run -- examples/host/snapshot/init.js   (or: zig-out/bin/origine examples/host/snapshot/init.js)
// A heap snapshot holds an init module's graph already evaluated. Create it once (on this thread, which waits until it
// is done), keep it as bytes, and start isolates from it: they skip loading and evaluating the graph. The snapshot
// is tied to its init: the same specifier, and the same build and source files, or it is refused.
//
// Prints (stderr):
//   snapshot init: examples/host/snapshot/worker.js
//   data blob is non-empty: true
//   isolate from the restored snapshot prints: made at snapshot time
//   fromRaw has no init: undefined
import { eprintln } from 'origine:@std/debug';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const init = 'examples/host/snapshot/worker.js';
  const snapshot = api.host.Snapshot.create({ init });
  eprintln('snapshot init:', snapshot.init);

  // The file form: the bytes can be kept on disk, and read back later with the same init.
  const bytes = snapshot.origineDataBlob();
  eprintln('data blob is non-empty:', bytes.length > 0);
  const restored = api.host.Snapshot.fromOrigineDataBlob(bytes, { init });

  const isolate = api.isolate.create({ init, snapshot: restored });
  await isolate.join();

  // A raw V8 blob has no module table, so it has no init and the isolate evaluates its init normally.
  const raw = api.host.Snapshot.fromRaw(snapshot.blob());
  eprintln('fromRaw has no init:', raw.init);
  raw.close();
  restored.close();
  snapshot.close();
}
