// Run: zig build run -- examples/std/text/init.js   (or: zig-out/bin/origine examples/std/text/init.js)
// UTF-8 without TextEncoder or TextDecoder (the context has neither). encodeUtf8 never fails: lone surrogates become
// U+FFFD. decodeUtf8 replaces invalid bytes by default; with fatal it throws. tryDecodeUtf8 returns null on invalid
// bytes, which is the choice fs.read_to_string makes (InvalidData).
//
// Prints (stderr):
//   encoded bytes of "é🌍": 6
//   lone surrogate encodes to U+FFFD: 239,191,189
//   decodeUtf8 of invalid bytes: "a�b"
//   decodeUtf8 fatal: TypeError
//   tryDecodeUtf8 invalid: null ; valid: hi
//   a leading BOM is dropped by decodeUtf8: "x", kept with ignoreBOM: true
import { encodeUtf8, decodeUtf8, tryDecodeUtf8 } from 'origine:@std/text';
import { eprintln } from 'origine:@std/debug';

const throws = run => {
  try {
    run();
    return 'no error';
  } catch (e) {
    return e.name;
  }
};

export function main() {
  eprintln('encoded bytes of "é🌍":', encodeUtf8('é🌍').length);
  eprintln('lone surrogate encodes to U+FFFD:', Array.from(encodeUtf8('\uD800')).join(','));
  eprintln('decodeUtf8 of invalid bytes:', JSON.stringify(decodeUtf8(Uint8Array.from([0x61, 0xff, 0x62]))));
  eprintln('decodeUtf8 fatal:', throws(() => decodeUtf8(Uint8Array.from([0xff]), { fatal: true })));
  eprintln('tryDecodeUtf8 invalid:', tryDecodeUtf8(Uint8Array.from([0xff])), '; valid:', tryDecodeUtf8(encodeUtf8('hi')));
  const bom = Uint8Array.from([0xef, 0xbb, 0xbf, 0x78]);
  eprintln(`a leading BOM is dropped by decodeUtf8: ${JSON.stringify(decodeUtf8(bom))}, kept with ignoreBOM: ${decodeUtf8(bom, { ignoreBOM: true }).length === 2}`);
}
