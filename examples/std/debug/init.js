// Run: zig build run -- examples/std/debug/init.js   (or: zig-out/bin/origine examples/std/debug/init.js)
// eprintln is the one output a program has without a capability: one line on standard error, values joined by
// spaces with String(). The console object is not connected to the terminal, so use eprintln.
//
// Prints (stderr):
//   numbers, objects and null: 1 2 [object Object] null
import { eprintln } from 'origine:@std/debug';

export function main() {
  eprintln('numbers, objects and null:', 1, 2, { a: 1 }, null);
}
