// Run: zig build run -- examples/fs/symlinks/init.js   (or: zig-out/bin/origine examples/fs/symlinks/init.js)
// Symlinks and the grant's root. The root is examples/fs/symlinks/tree; tree/up.txt is a link to ../secret.txt, which
// is outside it. The paths are checked lexically, so by default (symlinks: 'follow') a link can leave the root. A grant
// with symlinks: 'confined' refuses a link whose target climbs above the directory the call names.
// The links are committed as symlinks: keep them as links (git stores them so).
//
// Prints (stderr):
//   follow: inside.txt -> "inside the root"
//   follow: up.txt -> "outside the root" (the link left the root)
//   confined: inside.txt -> "inside the root"
//   confined: up.txt -> PermissionDenied
import { fs } from 'origine:@std/fs';
import { IoError } from 'origine:@std/io';
import { eprintln } from 'origine:@std/debug';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const root = 'examples/fs/symlinks/tree';
  const follow = fs(api.fs.requestSync({ handle: 'plain', root, access: 'r', symlinks: 'follow' }));
  const confined = fs(api.fs.requestSync({ handle: 'plain', root, access: 'r', symlinks: 'confined' }));

  for (const [name, grant] of [['follow', follow], ['confined', confined]]) {
    for (const link of ['inside.txt', 'up.txt']) {
      try {
        eprintln(`${name}: ${link} -> ${JSON.stringify(grant.read_to_string(link).trim())}`);
      } catch (e) {
        eprintln(`${name}: ${link} -> ${IoError.is(e, IoError.PermissionDenied) ? 'PermissionDenied' : e.name}`);
      }
    }
  }
}
