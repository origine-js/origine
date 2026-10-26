// `origine:@std/text`: UTF-8 encoding and decoding. The hardened context has no
// TextEncoder/TextDecoder; fs helpers use these for strings. The host hands this module
// native versions (V8 string conversion and simdutf) through `import.meta.native`, which
// only the embedded `origine:` modules get. They are captured here and deleted from `import.meta`,
// never exported, and only reachable through the wrappers below. `utf8Js` is the plain
// JS implementation used when they are absent, and the reference for tests and benchmarks.
const { encode: nativeEncode, decode: nativeDecode } = import.meta.native ?? {};

/// Encodes a string as UTF-8. Lone surrogates become U+FFFD, like TextEncoder.
export const encodeUtf8 = nativeEncode === undefined ? encodeJs : text => (typeof text === 'string' ? nativeEncode(text) : encodeJs(text));

/// Returns the string for strictly valid UTF-8, or `null` for anything else (overlong forms,
/// surrogates, > U+10FFFF and truncation included). No BOM handling, no replacement, never throws.
export const tryDecodeUtf8 = nativeDecode === undefined ? tryDecodeJs : bytes => (bytes instanceof Uint8Array ? (nativeDecode(bytes) ?? null) : tryDecodeJs(bytes));

/// Decodes UTF-8 bytes like `new TextDecoder('utf-8', { fatal, ignoreBOM }).decode(bytes)`: invalid
/// sequences become U+FFFD (maximal subpart rule), a leading BOM is dropped unless `ignoreBOM`, and
/// `fatal` throws a TypeError instead of substituting.
export const decodeUtf8 = makeDecode(tryDecodeUtf8);

/// The JS implementations, whether or not natives are installed.
export const utf8Js = Object.freeze({ encode: encodeJs, decode: makeDecode(tryDecodeJs), tryDecode: tryDecodeJs });

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

function encodeJs(text) {
  const length = text.length;
  let size = 0;
  for (let i = 0; i < length; i++) {
    const unit = text.charCodeAt(i);
    if (unit < 0x80) size += 1;
    else if (unit < 0x800) size += 2;
    else if (unit >= 0xd800 && unit <= 0xdbff && i + 1 < length && (text.charCodeAt(i + 1) & 0xfc00) === 0xdc00) {
      size += 4;
      i++;
    } else size += 3;
  }
  const out = new Uint8Array(size);
  let at = 0;
  for (let i = 0; i < length; i++) {
    let point = text.charCodeAt(i);
    if (point < 0x80) {
      out[at++] = point;
      continue;
    }
    if (point < 0x800) {
      out[at++] = 0xc0 | (point >> 6);
      out[at++] = 0x80 | (point & 63);
      continue;
    }
    if (point >= 0xd800 && point <= 0xdfff) {
      if (point <= 0xdbff && i + 1 < length && (text.charCodeAt(i + 1) & 0xfc00) === 0xdc00) {
        point = 0x10000 + ((point & 0x3ff) << 10) + (text.charCodeAt(++i) & 0x3ff);
        out[at++] = 0xf0 | (point >> 18);
        out[at++] = 0x80 | ((point >> 12) & 63);
        out[at++] = 0x80 | ((point >> 6) & 63);
        out[at++] = 0x80 | (point & 63);
        continue;
      }
      point = 0xfffd;
    }
    out[at++] = 0xe0 | (point >> 12);
    out[at++] = 0x80 | ((point >> 6) & 63);
    out[at++] = 0x80 | (point & 63);
  }
  return out;
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
