// utf8 micro-benchmark: `zig build run -Doptimize=ReleaseFast -- bench/text.js`
// Compares the plain JS implementation in std/text.js with the exported (native) one.
import { encodeUtf8, decodeUtf8, utf8Js } from 'origine:@std/text';

function time(name, iterations, fn) {
  for (let i = 0; i < Math.min(iterations, 200); i++) fn(); // warm up
  const start = Date.now();
  for (let i = 0; i < iterations; i++) fn();
  const ms = Date.now() - start;
  print(name.padEnd(34), String(Math.round((ms * 1e6) / iterations)).padStart(10), 'ns/op');
}

const samples = {
  'ascii 16 B': 'hello, world 0123'.slice(0, 16),
  'ascii 4 KiB': 'a'.repeat(4096),
  'ascii 1 MiB': 'a'.repeat(1 << 20),
  'mixed 4 KiB': 'aé✓\u{1F600}'.repeat((4096 / 10) | 0),
  'cjk 1 MiB': '日本語テキスト'.repeat(((1 << 20) / 21) | 0),
};

export async function main(_api) {
  const impls = { js: utf8Js, native: { encode: encodeUtf8, decode: decodeUtf8 } };
  for (const [label, text] of Object.entries(samples)) {
    const bytes = encodeUtf8(text);
    const n = bytes.length > 256 << 10 ? 40 : bytes.length > 256 ? 20000 : 200000;
    for (const [impl, { encode, decode }] of Object.entries(impls)) {
      if (decode(encode(text)) !== text) throw new Error(`${impl} roundtrip failed for ${label}`);
      time(`${impl} encode ${label}`, n, () => encode(text));
      time(`${impl} decode ${label}`, n, () => decode(bytes));
    }
  }
}
