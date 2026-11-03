// Run: zig build run -- examples/isolate/terminate/init.js   (or: zig-out/bin/origine examples/isolate/terminate/init.js)
// join() reports how an isolate ended: 'completed', 'failed' (with the error's name) or 'terminated'. terminate()
// interrupts running JavaScript; a child blocked in I/O notices within about 100 ms. `init` paths are relative to the
// working directory, as in examples/isolate/basic.
//
// Prints (stderr):
//   sleeping child: terminated, error undefined
//   throwing child: failed, error MainFailed
import { eprintln } from 'origine:@std/debug';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  await using io = api.io.create({});
  const sleeper = api.isolate.create({ init: 'examples/isolate/terminate/sleeper.js' });
  await io.sleep(100);                   // give the child time to start sleeping
  sleeper.terminate();
  const exit = await sleeper.join();
  eprintln(`sleeping child: ${exit.status}, error ${exit.error}`);

  const thrower = api.isolate.create({ init: 'examples/isolate/terminate/thrower.js' });
  const failed = await thrower.join();
  eprintln(`throwing child: ${failed.status}, error ${failed.error}`);
}
