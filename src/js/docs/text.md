# `@engine/std/text`

Source: [std_text.js](../std_text.js). Plain JS; the hardened context has no
`TextEncoder`/`TextDecoder`. [`@engine/std/fs`](fs.md) uses it for string contents.

```js
import { encodeUtf8, decodeUtf8 } from '@engine/std/text';
```

| Export | Behavior |
| --- | --- |
| `encodeUtf8(text)` | Returns a new `Uint8Array`. Lone surrogates become U+FFFD, like `TextEncoder`. |
| `decodeUtf8(bytes)` | Returns the string, or **`undefined`** when `bytes` is not valid UTF-8 (overlong forms, surrogates, above U+10FFFF and truncated sequences are all invalid). It never throws and never substitutes U+FFFD. `bytes` is any indexable byte array with `subarray` (a `Uint8Array`). |

`decodeUtf8` returning `undefined` is the contract: callers choose the error
(`fs.read_to_string` fails with `IoError.InvalidData`).

There are also native versions in [text.zig](../../api/text.zig) (prototype); the JS
module does not call them.
