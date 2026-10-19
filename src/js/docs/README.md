# `origine:@std/*` — guest-side standard modules

Importable only from the **init context** (see [docs/api-design.md](../../../docs/api-design.md)).
They are plain JS embedded into the binary and served by
[origine_modules.zig](../../api/origine_modules.zig) (one `std_*.zig` per module); the implementation of each module
sits one directory up.

| Module | Source | Doc | What it is |
| --- | --- | --- | --- |
| `origine:@std/errno` | generated from `Errno` in [errno.zig](../../api/errno.zig) | [errno.md](errno.md) | `ERRNO` table of error codes |
| `origine:@std/io` | [std_io.js](../std_io.js) | [io.md](io.md) | Zig-style `Dir`/`File`, `IoError`, `Limit`, `FileKind`, `ops` |
| `origine:@std/fs` | [std_fs.js](../std_fs.js) | [fs.md](fs.md) | Rust `std::fs`-style API over an `io` |
| `origine:@std/quansync` | [quansync.js](../quansync.js) | [quansync.md](quansync.md) | write once, run sync or async |
| `origine:@std/text` | [std_text.js](../std_text.js) | [text.md](text.md) | `encodeUtf8` / `decodeUtf8` |

Not std modules: [api.js](../api.js) is the glue that builds the `api` object from the native
tables (not importable), and [bootstrap.js](../bootstrap.js) is the hardening bootstrap.

Layering: `errno` ← `quansync` ← `io` ← `fs`; `text` is standalone and used by `fs`.
Everything here is authority-free data and code: authority comes only from the `io` object
(`api.fs.sync` / `api.fs.async`) the host hands to `main(api)`, and every native re-checks it.
