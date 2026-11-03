// Run: zig build run -- examples/std/data/init.js   (or: zig-out/bin/origine examples/std/data/init.js)
// Plain data across realms, without sharing the realm. snapshot copies plain data (objects, arrays, primitives) into
// this realm; deepFreeze freezes an object graph in place. Things that carry their realm (functions, Maps, typed arrays,
// promises, Proxies) are refused with the path where they are found, so nothing is shared silently.
//
// Prints (stderr):
//   snapshot is a copy: true ; frozen: true ; the original is not frozen: true
//   shared reference kept: true
//   function refused: Unsupported at $.handler
//   deepFreeze froze the nested object: true
import { snapshot, deepFreeze } from 'origine:@std/data';
import { eprintln } from 'origine:@std/debug';

const throws = run => {
  try {
    run();
    return 'no error';
  } catch (e) {
    return `${e.name}${/\$\.[\w.]+/.exec(e.message)?.[0] ? ` at ${/\$\.[\w.]+/.exec(e.message)[0]}` : ''}`;
  }
};

export function main() {
  const shared = { n: 1 };
  const config = { name: 'app', nested: { shared }, twice: shared };
  const copy = snapshot(config, { deepFreeze: true });
  eprintln('snapshot is a copy:', copy !== config, '; frozen:', Object.isFrozen(copy.nested), '; the original is not frozen:', !Object.isFrozen(config));
  eprintln('shared reference kept:', copy.nested.shared === copy.twice);
  eprintln('function refused:', throws(() => snapshot({ handler: () => 1 })));

  const graph = { child: { list: [1, 2] } };
  deepFreeze(graph);
  eprintln('deepFreeze froze the nested object:', Object.isFrozen(graph.child.list));
}
