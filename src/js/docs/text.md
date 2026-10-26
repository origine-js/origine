# `origine:@std/text`

Source: [std/text.js](../std/text.js). Plain JS; the hardened context has no
`TextEncoder`/`TextDecoder`. [`origine:@std/fs`](fs.md) uses it for string contents.

```js
import { encodeUtf8, decodeUtf8, tryDecodeUtf8 } from 'origine:@std/text';
```

| Export | Behavior |
| --- | --- |
| `encodeUtf8(text)` | Returns a new `Uint8Array`. Lone surrogates become U+FFFD, like `TextEncoder`. |
| `decodeUtf8(bytes, { fatal = false, ignoreBOM = false })` | Like `new TextDecoder('utf-8', { fatal, ignoreBOM }).decode(bytes)`. Each maximal invalid subpart (overlong forms, surrogates, above U+10FFFF, truncation, stray bytes) becomes one U+FFFD; a leading BOM is dropped unless `ignoreBOM`; with `fatal` invalid input throws a `TypeError` instead. |
| `tryDecodeUtf8(bytes)` | The strict form: the string, or **`null`** when `bytes` is not valid UTF-8. It never throws, never substitutes U+FFFD and keeps a leading BOM. |

`bytes` is a `Uint8Array` (the JS fallback accepts any indexable byte array with `subarray`).
`tryDecodeUtf8` returning `null` is the contract callers use to choose their own error
(`fs.read_to_string` fails with `IoError.InvalidData`). `decodeUtf8` runs the native strict decoder
first and only falls back to the JS substitution pass for invalid input.

The exports call native versions ([std/text.zig](../../api/std/text.zig)) that the host
hands the module through `import.meta.native`; `utf8Js` (`encode`, `decode`, `tryDecode`) is the
plain JS implementation (also the fallback when the natives are absent).
