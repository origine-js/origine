// Run: zig build run -- examples/std/quansync/init.js   (or: zig-out/bin/origine examples/std/quansync/init.js)
// Write an operation once and run it sync or async. A leaf gives a sync and an async implementation. A composite is a
// generator that yield*s other operations; it runs in whichever mode it is asked for. f[mode] picks by name, so a
// caller that knows io.kind dispatches without branching. A task is single use.
//
// Prints (stderr):
//   double, sync: 42 ; async: 42 (a promise)
//   quadruple via the composite, sync: 84
//   quadruple[async] awaited: 84
//   a task is a task: true ; the mode names: sync,async
import { quansync } from 'origine:@std/quansync';
import { eprintln } from 'origine:@std/debug';

const double = quansync({ sync: n => n * 2, async: async n => n * 2 });

// A composite: `yield*` a leaf or another task; the same generator runs sync or async.
const quadruple = quansync(function* (n) {
  return yield* double(yield* double(n));
});

export async function main() {
  eprintln('double, sync:', double.sync(21), '; async:', await double.async(21), '(a promise)');
  eprintln('quadruple via the composite, sync:', quadruple.sync(21));
  eprintln('quadruple[async] awaited:', await quadruple['async'](21));
  eprintln('a task is a task:', quansync.isTask(double(1)), '; the mode names:', quansync.MODES.join(','));
}
