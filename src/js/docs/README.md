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
| `origine:@std/text` | [std/text.js](../std/text.js) | [text.md](text.md) | `encodeUtf8` / `decodeUtf8` / `tryDecodeUtf8` |
| `origine:@std/debug` | [std/debug.js](../std/debug.js) | [debug.md](debug.md) | `eprintln`: one line on stderr |

Not std modules: [glue/](../glue/index.js) is the glue that builds the `api` object from the native
tables (not importable), and [bootstrap.js](../bootstrap.js) is the hardening bootstrap.
The runtime handle's monotonic clock, sleeps, deadlines, and cancellable timers are
documented in [timers.md](timers.md).

The API exposes memoized getters for `fs`, `env`, `scope`, `io`, and `net` (the last
two require a runtime ceiling). Engine and init snapshots contain the prepared API,
its non-configurable getters, frozen methods, and frozen network classes/prototypes.
Installation binds per-scope state; getters bind each capability's native authority
on first access. No general guest-export hardening walk runs for API installation.
Without a snapshot, common glue initializes at installation and capability scripts
load on first access, retaining their separate V8 code caches across runs.
Standard ES modules evaluate on first import
and reuse their module instance on subsequent imports within the same scope.

TypeScript declarations for all of the above (and `api`) live in [types/](../../../types/README.md); the rules of [docs/api-guidelines.md](../../../docs/api-guidelines.md) (names, required options) apply to them, and an API change updates them in the same change.

Layering: `errno` ← `quansync` ← `io` ← `fs`; `text` is standalone and used by `fs`.
Everything here is authority-free data and code: authority comes only from the `io` object
(`api.fs.requestSync(...)` / `await api.fs.requestAsync({ io, ... })`) the host hands to `main(api)`, and every native re-checks it.
