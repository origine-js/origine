// Run: zig build run -- examples/io/timers/init.js   (or: zig-out/bin/origine examples/io/timers/init.js)
// Monotonic deadlines and cancellable timers. Timers belong to an io runtime, like sockets and async files.
//
// Prints (stderr):
//   deadline reached, timer canceled: true (timerAt and timer both canceled)
import { eprintln } from 'origine:@std/debug';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const io = api.io.create();
  try {
    // Schedule against a monotonic deadline, independent of wall-clock changes.
    const deadline = io.timer.now() + 10;
    await io.timer.sleepUntil(deadline);

    // timerAt is the cancellable sleepUntil: the deadline comes from io.timer.now(), like the one above.
    const later = io.timer.timerAt(io.timer.now() + 60_000);
    later.cancel();
    await later.promise.catch(() => {});

    const timer = io.timer.timer(60_000);
    const canceled = timer.promise.then(
      () => false,
      error => error.name === 'Canceled',
    );
    timer.cancel();
    if (!(await canceled)) throw new Error('timer was not canceled');
    await io.timer.sleep(1);
    eprintln('deadline reached, timer canceled: true');
  } finally {
    await io.close();
  }
}
