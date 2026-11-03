// Run: zig build run -- examples/host/env/init.js one two   (or: zig-out/bin/origine examples/host/env/init.js one two)
// The process's arguments and environment, read-only. args() starts with the init path, then the user's arguments.
// get(name) is undefined for a missing variable; there is no set. Environment values are not printed here.
//
// Prints (stderr, with the arguments you pass after the init path):
//   args(): examples/host/env/init.js one two
//   user arguments: one two
//   ORIGINE_EXAMPLE_UNSET: undefined
//   environment has entries: true
import { eprintln } from 'origine:@std/debug';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const { env } = api.host;
  const args = env.args();
  eprintln('args():', args.join(' '));
  eprintln('user arguments:', args.slice(1).join(' '));
  eprintln('ORIGINE_EXAMPLE_UNSET:', env.get('ORIGINE_EXAMPLE_UNSET'));
  eprintln('environment has entries:', env.list().length > 0);
}
