# `@engine/std/errno`

Source: generated at compile time from `Errno` in [errno.zig](../../api/errno.zig)
(`module_source`). Never edit a table by hand; add a member to `Errno` and the module,
`IoError` and `native.errors` all follow.

```js
import { ERRNO } from '@engine/std/errno';
ERRNO.FileNotFound // 1
```

`ERRNO` is a frozen `{ Name: code }` object for every `Errno` member except `ok`:

| Name | Code |
| --- | --- |
| `FileNotFound` | 1 |
| `AccessDenied` | 2 |
| `NotDir` | 3 |
| `IsDir` | 4 |
| `PathAlreadyExists` | 5 |
| `BadHandle` | 6 |
| `StaleHandle` | 7 |
| `InvalidPath` | 8 (also a missing or mistyped argument) |
| `NoSpaceLeft` | 9 |
| `Unsupported` | 10 |
| `FileTooBig` | 11 |
| `InvalidData` | 12 |
| `JavaScriptException` | 13 |
| `Unexpected` | 255 |

Use it through [`IoError`](io.md#ioerror), which adds `name`/`is`/`of`/`check`.
