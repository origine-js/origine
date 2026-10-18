// fs micro-benchmark: `zig build run -Doptimize=ReleaseFast -- bench/fs.js`
// Compares the raw glue ops with the Zig-style Dir/File methods. Uses Date.now,
// the only clock the hardened context keeps, so every case loops long enough.
import { Dir, Limit } from '@engine/std/io';

const bytes = n => new Uint8Array(n).fill(97);

function time(name, iterations, fn) {
  for (let i = 0; i < Math.min(iterations, 200); i++) fn(); // warm up
  const start = Date.now();
  for (let i = 0; i < iterations; i++) fn();
  const ms = Date.now() - start;
  print(name.padEnd(34), String(Math.round((ms * 1e6) / iterations)).padStart(9), 'ns/op');
}

export async function main(api) {
  const fs = await api.fs.request({ write: true, mode: { sync: true } });
  const io = fs.sync;
  const cwd = Dir.cwd();
  cwd.createDirPath(io, 'bench/work');
  const work = cwd.openDir(io, 'bench/work');
  work.writeFile(io, { sub_path: 'small.txt', data: bytes(512) });
  work.writeFile(io, { sub_path: 'big.bin', data: bytes(10 << 20) });

  const N = 20000;
  time('raw dirStat (hit)', N, () => io.dirStat(work, 'small.txt'));
  time('Dir.statFile (hit)', N, () => work.statFile(io, 'small.txt'));
  time('raw dirStat (miss)', N, () => { io.dirStat(work, 'ghost'); io.errno[0] = 0; });
  time('Dir.access (miss, throws)', N, () => { try { work.access(io, 'ghost'); } catch {} });
  time('raw open+readAll+close (512 B)', N / 2, () => {
    const f = io.dirOpenFile(work, 'small.txt', { mode: 'read' });
    io.fileReadAll(f, {});
    io.fileClose(f);
  });
  time('Dir.readFile (512 B)', N / 2, () => work.readFile(io, 'small.txt'));
  time('Dir.writeFile (512 B)', N / 4, () => work.writeFile(io, { sub_path: 'w.txt', data: bytes(512) }));
  time('Dir.readFile (10 MiB)', 20, () => work.readFile(io, 'big.bin', Limit.unlimited));
  time('Dir.readFile limit 4 KiB', N / 2, () => work.readFile(io, 'big.bin', Limit.limited(4096)));

  cwd.deleteTree(io, 'bench/work');
}
