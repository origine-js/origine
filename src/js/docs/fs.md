# `origine:@std/fs`

Source: [std/fs.js](../std/fs.js). Rust `std::fs`-style API (snake_case) built on the
Zig-style ops of [`origine:@std/io`](io.md). There is no ambient cwd, so the API is bound to
an `io` and a directory.

```js
import { fs } from 'origine:@std/fs';

const rs = fs(api.fs.requestSync({ access: 'rw' }));   // blocking, std.Io
const io = api.io.create({});                          // an async runtime
const ars = fs(await api.fs.requestAsync({ io, access: 'rw' }), someDir);   // every call returns a promise
rs.write('a.txt', 'hello');
const text = rs.read_to_string('a.txt');    // async: the same calls return promises
const f = rs.File.open('a.txt'); f.read(buf); f.close();
rs.OpenOptions.new().write(true).create(true).open('b.txt');
```

`fs(io, dir = Dir.cwd())` returns a frozen object; paths are relative to `dir`.
Rust's `Result` maps to **throw** (sync) / **reject** (async) with a frozen `{ errno, name }`
value ([`IoError`](io.md#values)). `contents` arguments accept a string (UTF-8 encoded via
[text](text.md)) or a `Uint8Array`.

Async calls run on the `io` runtime the grant was requested with; closing it (`await io.close()`)
cancels what is in flight (those promises reject with `IoError.Canceled`). **Writes always copy**:
`write`, `File.write` and `File.write_all` take the bytes at call time and never detach the
caller's `ArrayBuffer`, on both ios. To hand a buffer over without the copy use the explicit
async-only `File.write_move(bytes)` / `File.write_move_all(bytes)`: they **detach** the whole
ArrayBuffer (it and its views are empty afterwards, whatever the outcome) and write from its memory,
and fail `Unsupported` (buffer untouched, nothing written, no silent copy) when it cannot be
detached: shared, resizable or wasm memory. A string is encoded to a fresh buffer and then moved.
On a sync io the move variants throw `Unsupported` (a blocking write has nothing to hand over).
`File.read(buf)` copies too: it fills `buf` when the read completes
(it rejects if `buf` was detached meanwhile), so `buf` must not be reused for another read until
the promise settles. For zero-copy reads use the [Zig-style `File.readInto`/`readAlloc`](io.md)
or `api.fs` async ops (`fileReadInto`, `fileReadAlloc`).

## Functions

| Call | Returns |
| --- | --- |
| `read(path)` | `Uint8Array` |
| `read_to_string(path)` | string; `InvalidData` if not UTF-8 |
| `write(path, contents)` | creates or truncates |
| `read_dir(path)` | **array** of `DirEntry` (not lazy) |
| `metadata(path)` | `Metadata`; **follows** a final symlink like `std::fs::metadata` (a dangling link is `NotFound`) |
| `symlink_metadata(path)` | `Metadata` of the entry itself, a final symlink is not followed |
| `try_exists(path)` | follows symlinks (a dangling one is `false`); `false` only for `NotFound`, every other error throws (a loop, a denied read, `NotADirectory`, a write-only grant) |
| `exists(path)` | like `Path::exists`: `false` on **any** error, including denied access; use `try_exists` to tell them apart |
| `copy(from, to)` | bytes copied (64 KiB chunks) |
| `create_dir`, `create_dir_all` | |
| `remove_file`, `remove_dir`, `remove_dir_all` | |
| `rename(from, to)` | |
| `kind` | the `io` kind, `'sync'` or `'async'` |

## Types

- **`Metadata`**: `len()`, `is_file()`, `is_dir()`, `is_symlink()`, `file_type()`.
- **`FileType`**: `is_file()`, `is_dir()`, `is_symlink()`.
- **`DirEntry`**: `file_name()`, `file_type()`, `path()` (parent joined with the name).
- **`File`** (`fs.File`): `open(path)`, `create(path)`, `create_new(path)`, `options()`.
  An instance has `read(buf)` (count, `0` at end), `read_exact(buf)` (`InvalidData` on early
  end), `read_to_end()` (returns a `Uint8Array`), `read_to_string()`, `write(bytes)` (count),
  `write_all(bytes)` (both copy), `write_move(bytes)` / `write_move_all(bytes)` (async only, detach
  the buffer, see above), `flush()`, `set_len(n)`, `sync_all()`, `sync_data()`, `metadata()`, `close()`.
  Rust closes on drop; **call `close()`** here.
- **`OpenOptions`** (`fs.OpenOptions.new()`, or `File.options()`): chainable `read`, `write`,
  `append`, `truncate`, `create`, `create_new`, then `open(path)`. Validated as in Rust:
  neither read nor write → `InvalidInput`; truncate/create without write → `InvalidInput`;
  `append(true)` → `Unsupported`.

## Symlinks and confinement

Paths are confined to the grant's root **lexically** only (no `..`, no absolute path, no
`__oricache__` component: `PermissionDenied`; a NUL byte: `InvalidInput`). Symlinks are not
resolved by that check, so `metadata`, `try_exists`, `File.open` and friends, which follow a symlink,
can leave the root when the root contains a link that points outside it. Do not grant a root you do
not trust the contents of until confinement of symlinks is decided.

## Not shipped

canonicalize, read_link, symlink, hard_link, set_permissions, `File::seek`, append mode,
lazy `ReadDir`.
