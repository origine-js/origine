# `origine:@std/fs`

Source: [std/fs.js](../std/fs.js). Rust `std::fs`-style API (snake_case) built on the
Zig-style ops of [`origine:@std/io`](io.md). There is no ambient cwd, so the API is bound to
an `io` and a directory.

```js
import { fs } from 'origine:@std/fs';

const rs = fs(api.fs.sync);                 // or fs(api.fs.async, someDir)
rs.write('a.txt', 'hello');
const text = rs.read_to_string('a.txt');    // async: the same calls return promises
const f = rs.File.open('a.txt'); f.read(buf); f.close();
rs.OpenOptions.new().write(true).create(true).open('b.txt');
```

`fs(io, dir = Dir.cwd())` returns a frozen object; paths are relative to `dir`.
Rust's `Result` maps to **throw** (sync) / **reject** (async) with a frozen `{ errno, name }`
value ([`IoError`](io.md#values)). `contents` arguments accept a string (UTF-8 encoded via
[text](text.md)) or a `Uint8Array`.

## Functions

| Call | Returns |
| --- | --- |
| `read(path)` | `Uint8Array` |
| `read_to_string(path)` | string; `InvalidData` if not UTF-8 |
| `write(path, contents)` | creates or truncates |
| `read_dir(path)` | **array** of `DirEntry` (not lazy) |
| `metadata(path)` | `Metadata` |
| `try_exists(path)` | `false` only for `FileNotFound`; other errors throw |
| `exists(path)` | `false` for any error |
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
  `write_all(bytes)`, `flush()`, `set_len(n)`, `sync_all()`, `sync_data()`, `metadata()`, `close()`.
  Rust closes on drop; **call `close()`** here.
- **`OpenOptions`** (`fs.OpenOptions.new()`, or `File.options()`): chainable `read`, `write`,
  `append`, `truncate`, `create`, `create_new`, then `open(path)`. Validated as in Rust:
  neither read nor write → `InvalidPath`; truncate/create without write → `InvalidPath`;
  `append(true)` → `Unsupported`.

## Not shipped

canonicalize, read_link, symlink, hard_link, set_permissions, `File::seek`, append mode,
lazy `ReadDir`.
