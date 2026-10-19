# Finding the docs

Docs live **next to the code they describe**, in a `docs/` folder beside it. Start here,
then go to the nearest `docs/` to the file you are reading.

| Looking for | Go to |
| --- | --- |
| Native bindings: how Zig functions become JS natives, V8 fast calls | [src/api/docs/](src/api/docs/) (`fast-calls.md`) and the `//!` header of [src/api/binding.zig](src/api/binding.zig) |
| Guest-side `origine:@std/*` modules (`io`, `fs`, `quansync`, `text`, `errno`) | [src/js/docs/](src/js/docs/README.md) |
| Overall `api` design, grants, init context, scopes | [docs/api-design.md](docs/api-design.md) |
| Building, V8 dev loop | [docs/BUILD.md](docs/BUILD.md) |
| Shell performance notes | [docs/shell-performance.md](docs/shell-performance.md) |
| The V8 package (`lib/v8_zig`) | [lib/v8_zig/README.md](lib/v8_zig/README.md), [lib/v8_zig/docs/](lib/v8_zig/docs/) |

Rules of thumb: Zig modules explain themselves in a `//!` header; longer topics get a
markdown file in the sibling `docs/`; only cross-cutting design lives in the top-level
[docs/](docs/). Add new docs beside the implementation and list them here only when they
open a new area.
