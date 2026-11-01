# `origine:@std/fs`

Source: [std/fs.js](../std/fs.js). Rust `std::fs`-style API (snake_case) built on the
Zig-style ops of [`origine:@std/io`](io.md). There is no ambient cwd, so the API is bound to
an `io` and a directory.

```js
import { fs } from 'origine:@std/fs';

const rs = fs(api.fs.requestSync({ access: 'rw', handle: 'plain' }));   // blocking
const io = api.io.create({});                          // an async runtime
const ars = fs(await api.fs.requestAsync({ io, access: 'rw', handle: 'plain' }), someDir);   // every call returns a promise
rs.write('a.txt', 'hello');
const text = rs.read_to_string('a.txt');    // async: the same calls return promises
const f = rs.File.open('a.txt'); f.read(buf); f.close();
rs.OpenOptions.new().write(true).create(true).open('b.txt');
```

A grant is the object `requestSync` / `requestAsync` returned. Its issuer is the native grant the host built,
kept in a private field that a script cannot read, copy or inherit, so a copy with every property (`{ ...grant }`, `Object.assign`,
`Object.create(grant)`, a `Proxy`) still runs the same operations but is not a grant where one is the
authority: `fsProvider({ fs })`, `ModuleSource.file(path, { fs })` and `CodeCache.dir({ fs, path })` reject it with `InvalidInput`.

`fs(io, dir = Dir.cwd())` returns a frozen object; paths are relative to `dir`.
Rust's `Result` maps to **throw** (sync) / **reject** (async) with an `OrigineError` subclass
instance ([`IoError`](io.md#values)). `contents` arguments accept a string (UTF-8 encoded via
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
| `remove_file`, `remove_dir` | |
| `remove_dir_all(path)` | like `std::fs::remove_dir_all`: a missing path is `NotFound`, a file is `NotADirectory`, a final symlink is removed and not followed. On a write-only grant a path that is not a directory is `PermissionDenied`, because telling a symlink from a file reads it. |
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
component named `..`: `PermissionDenied`; a NUL byte: `InvalidInput`). Symlinks are not
resolved by that check, so by default (`symlinks: 'follow'`) any operation whose path passes through a
symlink, reads and writes alike, can leave the root when the root contains a link that points outside it.

`requestSync` and `requestAsync` take `symlinks: 'follow' | 'confined'` (default `'follow'`). A `'confined'`
grant walks every path before using it and fails `PermissionDenied` when a symlink's target is absolute or
climbs above the directory the call names (the grant root, or the opened `Dir` it is relative to, so a link
that climbs out of an opened `Dir` is refused even if it stays inside the root). Links that stay inside still
work. Costs and limits:

- One extra stat per path component, one `readlink` per symlink met. On an async grant the stats are async,
  and each `readlink` is a short blocking call on the isolate thread.
- It is a check before the operation, not part of it: a process changing links at the same moment can get past
  it. It stops links already in the tree, not a concurrent attacker with write access to the root.
- It covers the paths a grant is given, the requested `root`, the files the graph reads through the grant and the
  directory of `CodeCache.dir`, but not the files inside that directory.

## Not shipped

canonicalize, read_link, symlink, hard_link, set_permissions, `File::seek`, append mode,
lazy `ReadDir`.
