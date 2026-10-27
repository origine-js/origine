// `origine:@std/text`: UTF-8 encoding and decoding. The hardened context has no
// TextEncoder/TextDecoder; fs helpers use these for strings. The host hands this module
// native versions (V8 string conversion and simdutf) through `import.meta.native`, which
// only the embedded `origine:` modules get. They are captured here and deleted from `import.meta`,
// never exported, and only reachable through the wrappers below.
const { encode: nativeEncode, decode: nativeDecode } = import.meta.native;

/// Encodes a string as UTF-8. Lone surrogates become U+FFFD, like TextEncoder. Throws a TypeError for anything but a string.
export const encodeUtf8 = text => {
  if (typeof text !== 'string') throw new TypeError('encodeUtf8 expects a string');
  return nativeEncode(text);
};

/// Returns the string for strictly valid UTF-8, or `null` for anything else (overlong forms,
/// surrogates, > U+10FFFF and truncation included). No BOM handling, no replacement, never throws.
export const tryDecodeUtf8 = bytes => (bytes instanceof Uint8Array ? (nativeDecode(bytes) ?? null) : tryDecodeJs(bytes));

/// Decodes UTF-8 bytes like `new TextDecoder('utf-8', { fatal, ignoreBOM }).decode(bytes)`: invalid
/// sequences become U+FFFD (maximal subpart rule), a leading BOM is dropped unless `ignoreBOM`, and
/// `fatal` throws a TypeError instead of substituting.
export const decodeUtf8 = makeDecode(tryDecodeUtf8);

function makeDecode(tryDecode) {
  return (bytes, options) => {
    const fatal = options?.fatal === true;
    const bom = options?.ignoreBOM !== true && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf;
    const view = bom ? bytes.subarray(3) : bytes;
    const text = tryDecode(view);
    if (text !== null) return text;
    if (fatal) throw new TypeError('The encoded data was not valid UTF-8');
    return decodeJs(view, true);
  };
}

const CHUNK = 8192;

function tryDecodeJs(bytes) {
  return decodeJs(bytes, false);
}

// Strict: `null` on the first invalid sequence. Lossy: each maximal invalid subpart becomes one
// U+FFFD, following the WHATWG UTF-8 decoder (the offending byte is not consumed).
function decodeJs(bytes, lossy) {
  const length = bytes.length;
  let result = '';
  let units = [];
  let i = 0;
  while (i < length) {
    const lead = bytes[i++];
    let point;
    if (lead < 0x80) {
      // Bulk-append the whole ASCII run instead of one code unit at a time.
      let end = i;
      while (end < length && bytes[end] < 0x80) end++;
      if (units.length !== 0) {
        result += String.fromCharCode.apply(null, units);
        units = [];
      }
      for (let at = i - 1; at < end; at += CHUNK) result += String.fromCharCode.apply(null, bytes.subarray(at, Math.min(end, at + CHUNK)));
      i = end;
      continue;
    }
    let need = 0;
    let bad = false;
    let lower = 0x80;
    let upper = 0xbf;
    if (lead >= 0xc2 && lead <= 0xdf) {
      need = 1;
      point = lead & 0x1f;
    } else if (lead >= 0xe0 && lead <= 0xef) {
      need = 2;
      point = lead & 0x0f;
      if (lead === 0xe0) lower = 0xa0;
      else if (lead === 0xed) upper = 0x9f;
    } else if (lead >= 0xf0 && lead <= 0xf4) {
      need = 3;
      point = lead & 0x07;
      if (lead === 0xf0) lower = 0x90;
      else if (lead === 0xf4) upper = 0x8f;
    } else {
      bad = true;
    }
    for (let k = 0; k < need; k++) {
      const next = i < length ? bytes[i] : -1;
      if (next < lower || next > upper) {
        bad = true;
        break;
      }
      lower = 0x80;
      upper = 0xbf;
      point = (point << 6) | (next & 63);
      i++;
    }
    if (bad) {
      if (!lossy) return null;
      point = 0xfffd;
    }
    if (point >= 0x10000) {
      point -= 0x10000;
      units.push(0xd800 | (point >> 10), 0xdc00 | (point & 0x3ff));
    } else {
      units.push(point);
    }
    if (units.length >= CHUNK) {
      result += String.fromCharCode.apply(null, units);
      units = [];
    }
  }
  if (units.length !== 0) result += String.fromCharCode.apply(null, units);
  return result;
}
