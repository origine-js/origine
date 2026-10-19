# `origine:@std/io`

Source: [std_io.js](../std_io.js). Zig-style `std.Io` vocabulary. Everything exported is
pure data or code: **holding a `Dir` or `File` confers no authority**. The fs object behind
the `io` you pass does the work and checks the grant.

```js
import { Dir, File, FileKind, IoError, Limit, ops } from 'origine:@std/io';
```

## The `io` argument

As in Zig, every `Dir`/`File` method takes `io` first. Here `io` is the fs object from the
host's `api`: `api.fs.sync` (blocks; throws an `IoError` value) or `api.fs.async` (returns
promises that reject with one). Each method dispatches on `io.kind` (`'sync' | 'async'`).

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
| `stat()`, `statFile(path)` | `{ kind, size }`. `statFile` does not follow symlinks. |
| `access(path)` | Resolves (no value) or fails with `FileNotFound` etc. |
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
| `writeStreaming(bytes)` | One write; returns the count (may be partial). |
| `writeStreamingAll(bytes)`, `writePositionalAll(bytes, offset)` | Write everything. |
| `setLength(length)` | Truncate / extend. |

## Values

- **`IoError`** — frozen table of errno values with Zig names (`IoError.FileNotFound`, …,
  the same set as [`ERRNO`](errno.md)) plus helpers:
  `name(code)`, `is(value, code)` (number or any `{ errno }`), `of(code)` → frozen
  `{ errno, name }`, and `check(fs, value)` which throws that value when the sync call left
  a non-zero errno in `fs.errno`. Thrown/rejected errors are `{ errno, name }` data, not `Error`s.
- **`Limit`** — byte limit with `std.Io.Limit` semantics: `Limit.unlimited` (`Infinity`),
  `Limit.nothing` (`0`), `Limit.limited(n)` (`RangeError` unless `n` is a non-negative safe integer).
- **`FileKind`** — `{ file: 1, directory: 2, sym_link: 3, other: 4 }`.
- **`ops`** — the underlying [quansync](quansync.md) operations, each `(io, self, ...args)`,
  for composing in other std modules: `yield* ops.openFile(io, dir, path, flags)` or
  `ops.openFile[io.kind](...)`. `flags` is the raw glue open-mode string
  (`'r' 'rw' 'r+' 'w' 'w+' 'x' 'x+' 'c' 't'`, see [api.js](../api.js)). Names: `openFile openDir
  closeDir stat access createDir createDirPath createDirPathOpen deleteFile deleteDir deleteTree
  rename readDir readFile writeFile fileClose fileStat fileLength fileRead filePread fileReadAll
  fileWrite fileWriteAll filePwriteAll fileSetLength fileSync fileReadPositionalAll`.

## Not shipped

symlink / readlink / realpath, copyFile, permissions, seek, append.
