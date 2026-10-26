// fs micro-benchmark: `zig build run -Doptimize=ReleaseFast -- bench/fs.js`
// Compares the raw glue ops with the Zig-style Dir/File methods. Uses Date.now,
// the only clock the hardened context keeps, so every case loops long enough.
import { Dir, Limit } from 'origine:@std/io';
import { fs as rustFs } from 'origine:@std/fs';

const bytes = n => new Uint8Array(n).fill(97);

function time(name, iterations, fn) {
  for (let i = 0; i < Math.min(iterations, 200); i++) fn(); // warm up
  const start = Date.now();
  for (let i = 0; i < iterations; i++) fn();
  const ms = Date.now() - start;
  print(name.padEnd(34), String(Math.round((ms * 1e6) / iterations)).padStart(9), 'ns/op');
}

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const io = api.fs.requestSync({ access: 'rw' });
  const cwd = Dir.cwd();
  cwd.createDirPath(io, 'bench/work');
  const work = cwd.openDir(io, 'bench/work');
  work.writeFile(io, { sub_path: 'small.txt', data: bytes(512) });
  work.writeFile(io, { sub_path: 'big.bin', data: bytes(10 << 20) });

  const N = 20000;
  time('raw dirStat (hit)', N, () => io.dirStat(work, 'small.txt'));
  time('Dir.statFile (hit)', N, () => work.statFile(io, 'small.txt'));
  time('raw dirStat (miss)', N, () => {
    io.dirStat(work, 'ghost');
    io.errno[0] = 0;
  });
  time('Dir.access (miss, throws)', N, () => {
    try {
      work.access(io, 'ghost');
    } catch {}
  });
  time('raw open+readAll+close (512 B)', N / 2, () => {
    // Raw sync ops return undefined on failure (and set io.errno); this loop never fails.
    const f = /** @type {import('@origine/types').FileHandle} */ (io.dirOpenFile(work, 'small.txt', 'r'));
    io.fileReadAll(f, {});
    io.fileClose(f);
  });
  time('Dir.readFile (512 B)', N / 2, () => work.readFile(io, 'small.txt'));
  time('Dir.writeFile (512 B)', N / 4, () => work.writeFile(io, { sub_path: 'w.txt', data: bytes(512) }));
  time('Dir.readFile (10 MiB)', 20, () => work.readFile(io, 'big.bin', Limit.unlimited));
  time('Dir.readFile limit 4 KiB', N / 2, () => work.readFile(io, 'big.bin', Limit.limited(4096)));

  const rs = rustFs(io, work);
  time('Rust metadata (hit)', N, () => rs.metadata('small.txt'));
  time('Rust try_exists (miss)', N, () => rs.try_exists('ghost'));
  time('Rust read (512 B)', N / 2, () => rs.read('small.txt'));
  time('Rust read_to_string (512 B)', N / 2, () => rs.read_to_string('small.txt'));
  time('Rust write (512 B)', N / 4, () => rs.write('w.txt', bytes(512)));
  time('Rust copy (512 B)', N / 4, () => rs.copy('small.txt', 'c.txt'));
  const runtime = api.io.create({});
  const aio = await api.fs.requestAsync({ io: runtime, access: 'rw' });
  const ars = rustFs(aio, Dir.cwd());
  const start = Date.now();
  for (let i = 0; i < 2000; i++) await ars.read('bench/work/small.txt');
  print('Rust read async (512 B)'.padEnd(34), String(Math.round(((Date.now() - start) * 1e6) / 2000)).padStart(9), 'ns/op');
  // Async 1 MiB reads of big.bin: copy-out (`readPositional`), BYOB (`readInto`, zero-copy) and
  // host-allocated (`readAlloc`, zero-copy).
  const big = await Dir.cwd().openFile(aio, 'bench/work/big.bin');
  const asyncTime = async (name, iterations, fn) => {
    const t0 = Date.now();
    for (let i = 0; i < iterations; i++) await fn();
    print(name.padEnd(34), String(Math.round(((Date.now() - t0) * 1e6) / iterations)).padStart(9), 'ns/op');
  };
  const MiB = 1 << 20;
  const copyBuf = new Uint8Array(MiB);
  await asyncTime('async pread 1 MiB (copy-out)', 200, () => big.readPositional(aio, copyBuf, 0));
  let byob = new Uint8Array(MiB);
  await asyncTime('async readInto 1 MiB (BYOB)', 200, async () => {
    byob = (await big.readInto(aio, byob, 0)).buffer; // hand the buffer back each round
  });
  await asyncTime('async readAlloc 1 MiB', 200, () => big.readAlloc(aio, MiB, 0));
  await big.close(aio);
  await runtime.close();

  cwd.deleteTree(io, 'bench/work');
}
