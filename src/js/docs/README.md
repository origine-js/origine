# `origine:@std/*` — guest-side standard modules

Importable only from the **init context** (see [docs/api-design.md](../../../docs/api-design.md)).
They are plain JS embedded into the binary and served by
[modules.zig](../../api/std/modules.zig) (one file per module under `src/api/std/`); the implementation of each module
sits one directory up.

| Module | Source | Doc | What it is |
| --- | --- | --- | --- |
| `origine:@std/errno` | generated from `Errno` in [errno.zig](../../api/errno.zig) | [errno.md](errno.md) | `ERRNO` table of error codes |
| `origine:@std/io` | [std/io.js](../std/io.js) | [io.md](io.md) | Zig-style `Dir`/`File`, `IoError`, `Limit`, `FileKind`, `ops` |
| `origine:@std/fs` | [std/fs.js](../std/fs.js) | [fs.md](fs.md) | Rust `std::fs`-style API over an `io` |
| `origine:@std/quansync` | [std/quansync.js](../std/quansync.js) | [quansync.md](quansync.md) | write once, run sync or async |
| `origine:@std/text` | [std/text.js](../std/text.js) | [text.md](text.md) | `encodeUtf8` / `decodeUtf8` |

Not std modules: [glue/](../glue/index.js) is the glue that builds the `api` object from the native
tables (not importable), and [bootstrap.js](../bootstrap.js) is the hardening bootstrap.

Layering: `errno` ← `quansync` ← `io` ← `fs`; `text` is standalone and used by `fs`.
Everything here is authority-free data and code: authority comes only from the `io` object
(`api.fs.requestSync(...)` / `await api.fs.requestAsync({ io, ... })`) the host hands to `main(api)`, and every native re-checks it.
