// Run: zig build run -- examples/isolate/basic/init.js   (or: zig-out/bin/origine examples/isolate/basic/init.js)
// An isolate is a V8 isolate on another thread, with its own heap, host and I/O runtimes. It shares nothing by
// default: `data` is structured-cloned, and ports or buffers in it must be listed in `transfer`. The child runs
// `main(api, data)` from its own init module (worker.js here), with the arguments and environment given below.
//
// Prints (stderr):
//   worker: args examples/isolate/basic/worker.js x and MODE=fast
//   worker replied to 21 with 42, identity matches the isolate's id: true
//   join: completed
import { eprintln } from 'origine:@std/debug';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const [port, remote] = new api.host.threading.Channel({ mode: 'pull' });
  // `init` is a path relative to the working directory, not to this module: './worker.js' here would fail with InitFailed.
  // Only the listed args and env reach the child: nothing is inherited.
  const isolate = api.isolate.create({
    init: 'examples/isolate/basic/worker.js',
    args: ['x'],
    env: { MODE: 'fast' },
    data: { port: remote },
    transfer: [remote],
  });

  await port.send({ n: 21 });
  const reply = await port.recv();
  eprintln(`worker replied to 21 with ${reply.data}, identity matches the isolate's id: ${reply.identity === isolate.id}`);

  port.close();                          // the worker's `for await` ends when its port is closed
  const exit = await isolate.join();     // always the same object, once the thread has ended
  eprintln(`join: ${exit.status}`);
}
