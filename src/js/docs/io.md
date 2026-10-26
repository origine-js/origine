# `origine:@std/io`

Source: [std/io.js](../std/io.js). Zig-style `std.Io` vocabulary. Everything exported is
pure data or code: **holding a `Dir` or `File` confers no authority**. The fs object behind
the `io` you pass does the work and checks the grant.

```js
import { Dir, File, FileKind, IoError, Limit, ops } from 'origine:@std/io';
```

## The `io` argument

As in Zig, every `Dir`/`File` method takes `io` first. Here `io` is the fs object from the
host's `api`: `api.fs.requestSync({ root, access })` (blocks; throws an `IoError` value; failures
go through the shared `errno` cell, `IoError.check`) or `await api.fs.requestAsync({ io, root, access })`
(returns promises that reject with an `IoError`-shaped value; never touches the errno cell;
operations run on the `api.io` runtime `io`). Each method dispatches on `io.kind`
(`'sync' | 'async'`). The async arm has the same operation names and result shapes.

### Grants: `access`

`access` is **required**: `'r'` (read), `'w'` (write) or `'rw'`. A missing or unknown value is
`InvalidInput`; a request the host's ceiling (`Config.fs.write`) does not allow, such as `'w'` or
`'rw'` on a read-only host, is `PermissionDenied`. It is never silently downgraded. `'r'` denies
every mutation (`PermissionDenied`). Native handles are always readable when writable, so `'w'`
(write-only) is enforced by the grant: it denies (`PermissionDenied`) everything that observes what
exists, namely opening for read (the default mode), `readStreaming`/`readPositional`/`readAll`/
`readInto`/`readAlloc`, `stat`/`statFile`/`access`/`length`, and `iterate`. It allows creating
and writing files (`createFile`, `openFile(path, { mode: 'write_only' })`, `writeFile`,
`write*`, `setLength`, `sync`), directories, deletes and renames. There is no `narrow`: the embedder's `Config`
is the only ceiling.

### Buffers

**Writes always copy** the bytes at call time and never detach your ArrayBuffer, on both ios
(`writeStreaming`, `writeStreamingAll`, `writePositionalAll`). The async-only `*Move` variants
(`writeStreamingMove`, `writeStreamingMoveAll`, `writePositionalMoveAll`) transfer instead: the
whole ArrayBuffer (and every view over it) is detached, whatever the outcome, and written from its
memory. They fail `Unsupported`, with nothing written and the buffer untouched, when it cannot be
detached (a `SharedArrayBuffer`, a resizable buffer, wasm memory): there is never a silent copy.
An empty buffer detaches nothing. A detached buffer is `StaleHandle`. A sync io has no move
variant: they throw `Unsupported`, like the other async-only operations.
`readStreaming`/`readPositional` copy into your buffer at completion
(rejecting if it was detached meanwhile). `File.readInto(io, view, offset?)` is the zero-copy
read: it detaches `view`'s buffer and resolves `{ bytes, buffer }`, `buffer` being a view like
`view` over the filled memory (use it, not `view`). `File.readAlloc(io, len, offset?)` resolves a
fresh `Uint8Array` of exactly the bytes read. Both are async-only (`Unsupported` on a sync io).

```js
const dir = Dir.cwd();
const file = dir.openFile(io, 'a.txt');           // sync: File; async: Promise<File>
const bytes = file.readAll(io, Limit.limited(1 << 20));
file.close(io);
```

## `Dir`

`Dir.cwd()` is the sentinel each fs resolves to its own root. `Dir.at(fs, id)` builds a
descriptor, `Dir.is(value)` tests one. Descriptors are frozen `{ kind: 'dir', fs, id }`.

| Method (after `io`) | Zig counterpart / behavior |
| --- | --- |
| `openFile(path, { mode })` | `mode`: `'read_only'` (default), `'write_only'`, `'read_write'`. Writable handles are read/write natively. Returns `File`. |
| `createFile(path, { truncate = true, exclusive = false })` | exclusive → fails if present; truncate → empty it; else create and keep contents. |
| `openDir(path)` | Returns `Dir`. |
| `close()` | Closes a descriptor opened with `openDir`/`createDirPathOpen`. |
| `createDir(path)`, `createDirPath(path)`, `createDirPathOpen(path)` | Create one level / all levels / all levels then open. |
| `deleteFile(path)`, `deleteDir(path)`, `deleteTree(path)` | Remove a file / empty dir / whole tree. |
| `rename(oldPath, newDir, newPath)` | Zig's `rename(old_dir, old, new_dir, new, io)` as `oldDir.rename(io, old, newDir, new)`. |
| `stat()`, `statFile(path, { follow_symlinks = true })` | `{ kind, size }`. `statFile` follows a final symlink (a dangling one is `NotFound`), `{ follow_symlinks: false }` does not. Confinement is lexical: following a symlink can leave the grant's root. |
| `access(path)` | Resolves (no value) or fails with `NotFound` etc. (follows symlinks). |
| `iterate()` | Array of `{ name, kind }`. Not lazy. |
| `readFile(path, limit = Limit.unlimited)` | Whole file as `Uint8Array`, at most `limit` bytes. |
| `writeFile({ sub_path, data, flags })` | Creates/truncates by `flags` (same options as `createFile`) and writes `data`. |

## `File`

`File.at(fs, id)`, `File.is(value)`; frozen `{ kind: 'file', fs, id }`.

| Method (after `io`) | Behavior |
| --- | --- |
| `close()`, `sync()` | Close; flush to storage. |
| `stat()`, `length()` | `{ kind, size }`; size only. |
| `readStreaming(buffer)` | One read into `buffer`; returns the count, `0` at end. |
| `readPositional(buffer, offset)` | One positional read. |
| `readPositionalAll(buffer, offset)` | Fills `buffer` until full or end; returns the count. |
| `readAll(limit = Limit.unlimited)` | Rest of the file as `Uint8Array`. |
| `readInto(view, offset?)` | Async only. BYOB: detaches `view`'s buffer (if eligible), resolves frozen `{ bytes, buffer }` with `buffer` a view like `view` over the filled memory. |
| `readAlloc(len, offset?)` | Async only. Resolves a `Uint8Array` of the bytes read (at most `len`; empty at end). |
| `writeStreaming(bytes)` | One write; returns the count (may be partial). Copies. |
| `writeStreamingAll(bytes)`, `writePositionalAll(bytes, offset)` | Write everything. Copy. |
| `writeStreamingMove(bytes)`, `writeStreamingMoveAll(bytes)`, `writePositionalMoveAll(bytes, offset)` | Async only. Same, but detach `bytes`' buffer and write from it in place; `Unsupported` when it cannot be detached. |
| `setLength(length)` | Truncate / extend. |

## Values

- **`IoError`** — frozen table of the I/O error codes, named like Rust's `std::io::ErrorKind`
  (`IoError.NotFound`, …, the set of [`ERRNO.io`](errno.md)) plus helpers: `name(code)` (either
  domain), `is(value, code)` (number or any `{ errno }`), `of(code)` → frozen `{ errno, name }`, and
  `check(fs, value)` which throws that value (an I/O or a host error) when the sync call left a non-zero
  errno in `fs.errno`. Thrown/rejected errors are `{ errno, name }` data, not `Error`s. fs and net fail
  with an `IoError`, or a `HostError` for a bad handle.
- **`HostError`** — the same for origine's own runtime codes (`HostError.BadHandle`, `StaleHandle`,
  `Canceled`, `Unexpected`; [`ERRNO.host`](errno.md)), with `name`, `is`, `of`. `io.close()`, timers
  and scope handles fail with a `HostError` only.
- **`Limit`** — byte limit with `std.Io.Limit` semantics: `Limit.unlimited` (`Infinity`),
  `Limit.nothing` (`0`), `Limit.limited(n)` (`RangeError` unless `n` is a non-negative safe integer).
- **`FileKind`** — `{ file: 1, directory: 2, sym_link: 3, other: 4 }`.
- **`ops`** — the underlying [quansync](quansync.md) operations, each `(io, self, ...args)`,
  for composing in other std modules: `yield* ops.openFile(io, dir, path, flags)` or
  `ops.openFile[io.kind](...)`. `flags` is the raw glue open-mode string
  (`'r' 'rw' 'r+' 'w' 'w+' 'x' 'x+' 'c' 't'`, see [glue/fs.js](../glue/fs.js)). Names: `openFile openDir
  closeDir stat symlinkStat access createDir createDirPath createDirPathOpen deleteFile deleteDir deleteTree
  rename readDir readFile writeFile fileClose fileStat fileLength fileRead filePread fileReadAll
  fileReadInto filePreadInto fileReadAlloc filePreadAlloc fileWrite fileWriteAll filePwriteAll fileWriteMove fileWriteMoveAll filePwriteMoveAll fileSetLength fileSync fileReadPositionalAll`.

## Not shipped

symlink / readlink / realpath, copyFile, permissions, seek, append.
