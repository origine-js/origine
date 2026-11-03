// Run: zig build run -- examples/fs/access/init.js   (or: zig-out/bin/origine examples/fs/access/init.js)
// A grant's `access` is required and is exactly what it allows: 'r', 'w' or 'rw'. A request is never silently
// downgraded, and a missing access is an error, not a default. `handle` is required too: 'plain' checks each id the
// natives receive, 'hardened' also refuses handles the grant did not issue. The work/ directory is created by the
// program and is git-ignored.
//
// Prints (stderr):
//   access 'r': write -> PermissionDenied
//   access 'w': read -> PermissionDenied, write -> ok
//   access 'rw': read and write -> ok
//   no access given: InvalidInput
//   hardened: Dir.cwd() -> ok
//   hardened: its own handle -> ok
//   hardened: a handle from the plain grant -> InvalidInput
//   plain: a handle from the hardened grant -> BadHandle
import { fs } from 'origine:@std/fs';
import { Dir, IoError } from 'origine:@std/io';
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
  fs(api.fs.requestSync({ handle: 'plain', root: 'examples/fs/access', access: 'rw' })).create_dir_all('work');
  const root = 'examples/fs/access/work';
  const rw = fs(api.fs.requestSync({ handle: 'plain', root, access: 'rw' }));
  rw.write('seed.txt', 'seeded');

  const readOnly = fs(api.fs.requestSync({ handle: 'plain', root, access: 'r' }));
  eprintln(`access 'r': write -> ${thrown(() => readOnly.write('new.txt', 'x'))}`);

  const writeOnly = fs(api.fs.requestSync({ handle: 'plain', root, access: 'w' }));
  eprintln(`access 'w': read -> ${thrown(() => writeOnly.read_to_string('seed.txt'))}, write -> ${thrown(() => writeOnly.write('w.txt', 'x'))}`);
  eprintln(`access 'rw': read and write -> ${thrown(() => rw.write('rw.txt', rw.read_to_string('seed.txt')))}`);

  // `access` has no default: leaving it out is InvalidInput. The types require it, so this is a runtime check only.
  eprintln(`no access given: ${thrown(() => api.fs.requestSync({ handle: 'plain', root }))}`);

  // 'hardened': the grant takes only the handles it issued, plus Dir.cwd(). A plain grant takes any handle it can
  // check. Sync ops report failure through the grant's errno, so IoError.check is what throws it.
  const plain = api.fs.requestSync({ handle: 'plain', root, access: 'r' });
  const hardened = api.fs.requestSync({ handle: 'hardened', root, access: 'r' });
  const fromPlain = IoError.check(plain, plain.dirOpenDir(Dir.cwd(), '.'));
  const fromHardened = IoError.check(hardened, hardened.dirOpenDir(Dir.cwd(), '.'));
  eprintln(`hardened: Dir.cwd() -> ${thrown(() => IoError.check(hardened, hardened.dirOpenDir(Dir.cwd(), '.')))}`);
  eprintln(`hardened: its own handle -> ${thrown(() => IoError.check(hardened, hardened.dirOpenDir(fromHardened, '.')))}`);
  eprintln(`hardened: a handle from the plain grant -> ${thrown(() => IoError.check(hardened, hardened.dirOpenDir(fromPlain, '.')))}`);
  eprintln(`plain: a handle from the hardened grant -> ${thrown(() => IoError.check(plain, plain.dirOpenDir(fromHardened, '.')))}`);
}
