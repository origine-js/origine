// Driver: runs every cell REPS times per implementation (fresh process each), takes the median
// run by rounds/sec, writes raw JSON lines + a markdown table.
//   bun run.js [out_dir] [warmup_s] [measure_s] [reps=2]
import { spawnSync } from 'node:child_process';
import { writeFileSync, mkdirSync } from 'node:fs';
const out = process.argv[2] ?? '.';
const warm = process.argv[3] ?? '1',
  meas = process.argv[4] ?? '3',
  REPS = Number(process.argv[5] ?? 2);
const here = import.meta.dir;
const impls = [
  ['origine rt', (s, c) => [`${here}/rust/target/release/tcp_bench`, String(s), String(c), warm, meas]],
  ['origine JS', (s, c) => [`${here}/../../zig-out/bin/origine`, `${here}/bench.origine.js`, String(s), String(c), warm, meas]],
  ['Bun native', (s, c) => ['bun', `${here}/bench.js`, 'native', String(s), String(c), warm, meas]],
  ['Bun node:net', (s, c) => ['bun', `${here}/bench.js`, 'node', String(s), String(c), warm, meas]],
  ['Deno native', (s, c) => ['deno', 'run', '-A', `${here}/bench.js`, 'native', String(s), String(c), warm, meas]],
  ['Deno node:net', (s, c) => ['deno', 'run', '-A', `${here}/bench.js`, 'node', String(s), String(c), warm, meas]],
];
const sizes = [1024],
  conns = [1, 64];
const fmtNs = n => (n >= 1e6 ? (n / 1e6).toFixed(2) + ' ms' : (n / 1e3).toFixed(1) + ' us');
const raw = [],
  res = {};
for (const s of sizes)
  for (const c of conns) {
    // Interleave implementations across reps so drift hits all of them alike.
    const runs = Object.fromEntries(impls.map(([n]) => [n, []]));
    for (let r = 0; r < REPS; r++)
      for (const [name, cmd] of impls) {
        const [bin, ...a] = cmd(s, c);
        const p = spawnSync(bin, a, { encoding: 'utf8' });
        if (p.status !== 0) {
          console.error(name, s, c, p.stderr);
          process.exit(1);
        }
        // origine's `print` writes to stderr; the others print to stdout.
        const j = JSON.parse((p.stdout.trim() || p.stderr.trim()).split('\n').pop());
        raw.push({ name, rep: r, ...j });
        runs[name].push(j);
        console.error(`${name} ${s}B x${c} rep${r}: ${j.rps} rt/s p50 ${j.p50_ns === undefined ? 'n/a' : fmtNs(j.p50_ns)}`);
      }
    for (const [name] of impls) {
      const v = runs[name].sort((a, b) => a.rps - b.rps);
      res[`${s}/${c}/${name}`] = v[Math.floor(v.length / 2)];
    }
  }
let md = `| size | conns | ${impls.map(([n]) => n).join(' | ')} |\n|---|---|${impls.map(() => '---').join('|')}|\n`;
for (const s of sizes)
  for (const c of conns) {
    md +=
      `| ${s >= 1024 ? s / 1024 + ' KiB' : s + ' B'} | ${c} | ` +
      impls
        .map(([n]) => {
          const j = res[`${s}/${c}/${n}`];
          return j.p50_ns === undefined
            ? `${j.rps.toLocaleString('en-US')} rt/s<br>mean ${fmtNs(j.mean_ns)}`
            : `${j.rps.toLocaleString('en-US')} rt/s<br>p50 ${fmtNs(j.p50_ns)} / p99 ${fmtNs(j.p99_ns)}`;
        })
        .join(' | ') +
      ' |\n';
  }
mkdirSync(out, { recursive: true });
writeFileSync(`${out}/raw.jsonl`, raw.map(x => JSON.stringify(x)).join('\n') + '\n');
writeFileSync(`${out}/table.md`, md);
console.log(md);
