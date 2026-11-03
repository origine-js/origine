// Run: zig build run -- examples/fs/rust-style/init.js   (or: zig-out/bin/origine examples/fs/rust-style/init.js)
// `origine:@std/fs` is Rust's std::fs over a grant: snake_case functions, paths relative to the grant's root,
// failures thrown as IoError values. The same calls work on an async grant (every call then returns a promise).
// The work/ directory is created by the program and is git-ignored.
//
// Prints (stderr):
//   read_to_string: hello, fs
//   metadata: file=true len=9 | symlink_metadata of a dir: dir=true
//   exists: true | try_exists(missing): false | exists(../x): false (any error answers false)
//   read_dir: a.txt, binary.bin, nested
//   OpenOptions create_new on an existing file: AlreadyExists
//   copy: 9 bytes | rename and remove_file: ok
//   read_to_string of binary: InvalidData
import { fs } from 'origine:@std/fs';
import { IoError } from 'origine:@std/io';
import { encodeUtf8 } from 'origine:@std/text';
import { eprintln } from 'origine:@std/debug';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  // A grant cannot create its own root, so the parent directory's grant makes work/nested.
  fs(api.fs.requestSync({ handle: 'plain', root: 'examples/fs/rust-style', access: 'rw' })).create_dir_all('work/nested');
  const rs = fs(api.fs.requestSync({ handle: 'plain', root: 'examples/fs/rust-style/work', access: 'rw' }));

  rs.write('a.txt', 'hello, fs');                              // creates or truncates; takes a string or bytes
  eprintln('read_to_string:', rs.read_to_string('a.txt'));

  const meta = rs.metadata('a.txt');                          // follows a final symlink, like Rust
  eprintln(`metadata: file=${meta.is_file()} len=${meta.len()}`);
  eprintln(`symlink_metadata of a dir: dir=${rs.symlink_metadata('nested').is_dir()}`);

  eprintln(`exists: ${rs.exists('a.txt')} | try_exists(missing): ${rs.try_exists('missing.txt')} | exists(../x): ${rs.exists('../x')}`);

  rs.write('binary.bin', Uint8Array.from([0xff, 0xfe]));
  eprintln('read_dir:', rs.read_dir('.').map(entry => entry.file_name()).sort().join(', '));

  // OpenOptions and File are Rust's. There is no Drop: call close().
  const file = rs.File.options().write(true).open('a.txt');
  file.write_all(encodeUtf8('HELLO'));
  file.close();
  eprintln(`OpenOptions write over the start: ${rs.read_to_string('a.txt')}`);
  try {
    rs.OpenOptions.new().write(true).create_new(true).open('a.txt');
  } catch (e) {
    eprintln(`OpenOptions create_new on an existing file: ${e.name}`);
  }

  const copied = rs.copy('a.txt', 'c.txt');
  rs.rename('c.txt', 'renamed.txt');
  rs.remove_file('renamed.txt');
  eprintln(`copy: ${copied} bytes | rename and remove_file: ok`);

  try {
    rs.read_to_string('binary.bin');
  } catch (e) {
    eprintln(`read_to_string of binary: ${IoError.is(e, IoError.InvalidData) ? 'InvalidData' : e.name}`);
  }
  rs.remove_dir_all('nested');
}
