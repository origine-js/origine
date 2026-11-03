// Run: zig build run -- examples/fs/zig-style/init.js   (or: zig-out/bin/origine examples/fs/zig-style/init.js)
// `origine:@std/io` is Zig's std.Io file vocabulary: Dir and File values, every method takes `io` first, and the same
// code runs on a sync or an async io (`io.kind` decides). Holding a Dir or File confers no authority: the grant behind
// `io` checks everything. The work/ directory is created by the program and is git-ignored.
//
// Prints (stderr):
//   readFile: 6 bytes, kind=file
//   readAll with Limit.limited(3): 3 bytes
//   writes copy the buffer: after writeStreamingAll, the buffer is still 4 bytes long: true
//   Dir.cwd().statFile(follow=false): kind=1
//   IoError.check on a missing file: NotFound (NotFound)
import { Dir, File, FileKind, IoError, Limit } from 'origine:@std/io';
import { fs } from 'origine:@std/fs';
import { eprintln } from 'origine:@std/debug';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  fs(api.fs.requestSync({ handle: 'plain', root: 'examples/fs/zig-style', access: 'rw' })).create_dir_all('work');
  const io = api.fs.requestSync({ handle: 'plain', root: 'examples/fs/zig-style/work', access: 'rw' });
  const cwd = Dir.cwd();                                        // the sentinel: "the root of the grant"

  // Whole-file helpers on a Dir. Writes take bytes; the file is created or truncated.
  cwd.writeFile(io, { sub_path: 'greet.txt', data: Uint8Array.from([104, 101, 108, 108, 111, 10]), flags: {} });
  const bytes = cwd.readFile(io, 'greet.txt');
  eprintln(`readFile: ${bytes.length} bytes, kind=${cwd.statFile(io, 'greet.txt').kind === FileKind.file ? 'file' : 'other'}`);

  // A File is opened on a Dir and read with an explicit buffer. readStreaming returns the count, 0 at the end.
  const file = cwd.openFile(io, 'greet.txt', { mode: 'read_only' });
  const head = file.readAll(io, Limit.limited(3));
  eprintln(`readAll with Limit.limited(3): ${head.length} bytes`);
  file.close(io);

  // Writes copy: the caller's buffer is still usable and still its length afterwards. The *Move variants (async only)
  // are the ones that detach it.
  const out = cwd.createFile(io, 'out.bin', { truncate: true, exclusive: false });
  const buffer = Uint8Array.from([1, 2, 3, 4]);
  out.writeStreamingAll(io, buffer);
  eprintln(`writes copy the buffer: after writeStreamingAll, the buffer is still ${buffer.length} bytes long: ${buffer.length === 4}`);
  out.close(io);

  // statFile does not follow a final symlink when asked (the default follows).
  eprintln(`Dir.cwd().statFile(follow=false): kind=${cwd.statFile(io, 'greet.txt', { follow_symlinks: false }).kind}`);

  // Errors: a failing sync call sets the grant's errno; IoError.check throws it as an IoError value.
  try {
    IoError.check(io, cwd.openFile(io, 'missing.txt', { mode: 'read_only' }));
  } catch (e) {
    eprintln(`IoError.check on a missing file: ${e.name} (${IoError.is(e, IoError.NotFound) ? 'NotFound' : 'other'})`);
  }
  // The File class is the same value type as the one the methods return.
  eprintln('File.is(opened value):', File.is(cwd.openFile(io, 'greet.txt', { mode: 'read_only' })));
  cwd.deleteFile(io, 'out.bin');
}
