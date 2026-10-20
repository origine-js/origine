# `origine:@std/errno`

Source: generated at compile time from `Errno` in [errno.zig](../../api/errno.zig)
(`module_source`). Never edit a table by hand; add a member to `Errno` and the module,
`IoError` and `native.errors` all follow.

```js
import { ERRNO } from 'origine:@std/errno';
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
| `Canceled` | 14 (an async operation was canceled: its io runtime closed) |
| `TimedOut` | 15 |
| `WouldBlock` | 16 |
| `ConnectionRefused` | 17 |
| `ConnectionReset` | 18 |
| `BrokenPipe` | 19 |
| `AddressInUse` | 20 |
| `NotConnected` | 21 |
| `DirNotEmpty` | 22 (removing a non-empty directory) |
| `Unexpected` | 255 |

Use it through [`IoError`](io.md#ioerror), which adds `name`/`is`/`of`/`check`.
