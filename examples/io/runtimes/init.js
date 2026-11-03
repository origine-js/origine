// Run: zig build run -- examples/io/runtimes/init.js   (or: zig-out/bin/origine examples/io/runtimes/init.js)
// `api.io` makes I/O runtimes: the thing that timers, async file grants and sockets run on. `create` is synchronous
// and returns a handle that must be closed; closing cancels what is in flight. `narrow` gives a capability that can
// only do less: it can lower the backends and the number of live runtimes, never raise them.
//
// Prints (stderr):
//   backend: kqueue (entries option is a positive integer)
//   entries 0: TypeError
//   narrow to threaded: backend threaded
//   narrow to threaded, asking for kqueue: Unsupported
//   maxRuntimes 1: second create -> Unsupported
//   run() with nothing flowing resolves: true
//   now() is monotonic: true
//   await using closes at scope exit
import { eprintln } from 'origine:@std/debug';

/** 'ok', or the name of the error the call threw (IoError and HostError values carry their Rust-style name). */
const thrown = run => {
  try {
    run();
    return 'ok';
  } catch (e) {
    return e.name;
  }
};

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  // 'auto' (the default) picks the first backend the host allows and the system supports.
  const io = api.io.create({});
  eprintln(`backend: ${io.backend}`);
  // The options are validated: a non-positive entry count is a TypeError, not silently replaced.
  eprintln(`entries 0: ${thrown(() => api.io.create({ entries: 0 }))}`);

  // narrow() returns a capability; `create` on it may only use the backends it names.
  const threaded = api.io.narrow({ backends: ['threaded'] });
  const onThreaded = threaded.create({});
  eprintln(`narrow to threaded: backend ${onThreaded.backend}`);
  await onThreaded.close();
  eprintln(`narrow to threaded, asking for kqueue: ${thrown(() => threaded.create({ backend: 'kqueue' }))}`);

  // maxRuntimes counts live runtimes through this capability. A slot is given back once close() settles.
  const one = api.io.narrow({ maxRuntimes: 1 });
  const first = one.create({});
  eprintln(`maxRuntimes 1: second create -> ${thrown(() => one.create({}))}`);
  await first.close();
  const again = one.create({}); // the slot is free again
  await again.close();

  // now() is monotonic milliseconds since the host started: use it for deadlines, never as a wall clock.
  const a = io.timer.now();
  await io.timer.sleep(1);
  eprintln('now() is monotonic:', io.timer.now() >= a);

  // run() resolves once every socket with a flowing handler has closed. With none, it resolves at once.
  await io.run();
  eprintln('run() with nothing flowing resolves: true');

  await io.close();
  // close() returns the same promise each time; a closed runtime rejects later use with BadHandle.
  eprintln(`now() after close: ${thrown(() => io.timer.now())}`);

  // `await using` is the same close, done at scope exit (also when the scope throws).
  {
    await using scoped = api.io.create({});
    await scoped.timer.sleep(1);
  }
  eprintln('await using closes at scope exit');
}
