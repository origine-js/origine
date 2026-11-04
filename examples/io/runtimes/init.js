// Run: zig build run -- examples/io/runtimes/init.js   (or: zig-out/bin/origine examples/io/runtimes/init.js)
// `api.io` makes I/O runtimes: the thing that timers, async file grants and sockets run on. `create` is synchronous
// and returns a handle that must be closed; closing cancels what is in flight. The embedder's ceiling (backends,
// number of runtimes) is the only limit: nothing narrows `api.io`.
//
// Prints (stderr):
//   backend: kqueue (entries option is a positive integer)
//   entries 0: TypeError
//   threaded: backend threaded
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

  // A backend can be named; one the host excluded or the system lacks is Unsupported.
  const threaded = api.io.create({ backend: 'threaded' });
  eprintln(`threaded: backend ${threaded.backend}`);
  await threaded.close();

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
