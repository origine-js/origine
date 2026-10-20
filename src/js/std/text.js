// `origine:@std/text`: UTF-8 encoding and decoding. The hardened context has no
// TextEncoder/TextDecoder; fs helpers use these for strings. The host hands this module
// native versions (V8 string conversion and simdutf) through `import.meta.native`, which
// only the embedded `origine:` modules get. They are captured here and deleted from `import.meta`,
// never exported, and only reachable through the wrappers below. `utf8Js` is the plain
// JS implementation used when they are absent, and the reference for tests and benchmarks.
const { encode: nativeEncode, decode: nativeDecode } = import.meta.native ?? {};

/// Encodes a string as UTF-8. Lone surrogates become U+FFFD, like TextEncoder.
export const encodeUtf8 = nativeEncode === undefined ? encodeJs : text => (typeof text === 'string' ? nativeEncode(text) : encodeJs(text));

/// Decodes UTF-8 bytes to a string, or returns `undefined` when the bytes are not
/// valid UTF-8 (overlong forms, surrogates, > U+10FFFF and truncation included).
export const decodeUtf8 =
  nativeDecode === undefined ? decodeJs : bytes => (bytes instanceof Uint8Array ? nativeDecode(bytes) : decodeJs(bytes));

/// The JS implementations, whether or not natives are installed.
export const utf8Js = Object.freeze({ encode: encodeJs, decode: decodeJs });

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

function decodeJs(bytes) {
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
    } else if (lead >= 0xc2 && lead <= 0xdf) {
      if (i >= length || (bytes[i] & 0xc0) !== 0x80) return undefined;
      point = ((lead & 0x1f) << 6) | (bytes[i++] & 63);
    } else if (lead >= 0xe0 && lead <= 0xef) {
      if (i + 1 >= length || (bytes[i] & 0xc0) !== 0x80 || (bytes[i + 1] & 0xc0) !== 0x80) return undefined;
      point = ((lead & 0x0f) << 12) | ((bytes[i] & 63) << 6) | (bytes[i + 1] & 63);
      i += 2;
      if (point < 0x800 || (point >= 0xd800 && point <= 0xdfff)) return undefined;
    } else if (lead >= 0xf0 && lead <= 0xf4) {
      if (i + 2 >= length || (bytes[i] & 0xc0) !== 0x80 || (bytes[i + 1] & 0xc0) !== 0x80 || (bytes[i + 2] & 0xc0) !== 0x80)
        return undefined;
      point = ((lead & 0x07) << 18) | ((bytes[i] & 63) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63);
      i += 3;
      if (point < 0x10000 || point > 0x10ffff) return undefined;
    } else {
      return undefined;
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
