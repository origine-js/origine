// utf8 micro-benchmark: `zig build run -Doptimize=ReleaseFast -- bench/text.js`
// Times the exported encodeUtf8 and decodeUtf8.
import { encodeUtf8, decodeUtf8 } from 'origine:@std/text';
import { eprintln } from 'origine:@std/debug';

function time(name, iterations, fn) {
  for (let i = 0; i < Math.min(iterations, 200); i++) fn(); // warm up
  const start = Date.now();
  for (let i = 0; i < iterations; i++) fn();
  const ms = Date.now() - start;
  eprintln(name.padEnd(34), String(Math.round((ms * 1e6) / iterations)).padStart(10), 'ns/op');
}

const samples = {
  'ascii 16 B': 'hello, world 0123'.slice(0, 16),
  'ascii 4 KiB': 'a'.repeat(4096),
  'ascii 1 MiB': 'a'.repeat(1 << 20),
  'mixed 4 KiB': 'aé✓\u{1F600}'.repeat((4096 / 10) | 0),
  'cjk 1 MiB': '日本語テキスト'.repeat(((1 << 20) / 21) | 0),
};

/** @param {import('@origine/types').Api} _api */
export async function main(_api) {
  for (const [label, text] of Object.entries(samples)) {
    const bytes = encodeUtf8(text);
    const n = bytes.length > 256 << 10 ? 40 : bytes.length > 256 ? 20000 : 200000;
    if (decodeUtf8(bytes) !== text) throw new Error(`roundtrip failed for ${label}`);
    time(`encode ${label}`, n, () => encodeUtf8(text));
    time(`decode ${label}`, n, () => decodeUtf8(bytes));
  }
}
