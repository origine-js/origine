// Run: zig build run -- examples/typescript/init.ts
// The init scope transforms .ts/.mts/.cts/.tsx/.jsx by default (oxc); types are erased and
// enums, namespaces and parameter properties become runtime code.
import { greet, type Greeting } from './greeter.ts';

enum Color { Red, Green, Blue }

namespace Palette {
  export const favourite: Color = Color.Green;
}

class Point {
  constructor(public x: number, private y: number) {}
  norm1(): number { return Math.abs(this.x) + Math.abs(this.y); }
}

export function main(): void {
  const g: Greeting = greet('origine');
  print(g.text, Color[Palette.favourite], new Point(3, -4).norm1());
}
