# origine

origine is a capability-based JavaScript runtime shell built on V8, written in Zig and Rust.
It starts as an empty, hardened engine: a program receives **no ambient authority** and gets
files, network, environment and child scopes only through an `api` object that the host
hands to its exported `main(api)`. Compatibility layers (Node, test runners, sandboxes) are
meant to be built in JavaScript on top of `api` by narrowing it.

| Layer | Where | Role |
| --- | --- | --- |
| Shell, managed runtime, `api` host | `src/` (Zig) | CLI, REPL, isolate/scope management, snapshots, native bindings |
| Event loop | `src/io/` (Zig) | Completion-based loop (io_uring, kqueue + GCD, thread pool) with a C ABI |
| Async natives, I/O runtime, TypeScript | `rust/` (Rust) | `api.io` / async `api.fs` / `api.net` natives, op futures, oxc transformer |
| V8 package | `lib/v8_zig/` | Fetches, patches and builds V8; exposes `@v8`, `@engine`, `@managed`, `@util`, `@mimalloc`, `@diagnostics` |
| Guest JavaScript | `src/js/` | `origine:@std/*` modules, the glue that builds `api`, hardening bootstrap |

## Quick start

You need Zig 0.17.0, Rust (via rustup), [uv](https://docs.astral.sh/uv/), git, rsync and
network access for the first build, which compiles V8 and takes 20+ minutes. Prerequisites and
options are in [docs/BUILD.md](docs/BUILD.md).

```sh
zig build                       # build zig-out/bin/origine
zig build run                   # start the REPL
zig build run -- examples/timers/init.js
zig build test                  # V8 package and managed runtime tests
```

`just build`, `just run` and `just test` wrap the same commands; `just` lists the rest.

## Running programs

```sh
origine                       # interactive REPL (or piped input)
origine path/to/init.js [args...]
```

- **No argument:** a REPL with multiline input, inspection, history and Tab completion; see
  [docs/repl.md](docs/repl.md). It has no `api`.
- **With a path:** the file is the *init module*. origine evaluates it, calls its exported
  `main(api)` (which may be `async`) and runs until the returned promise settles. `.ts`, `.tsx`
  and `.jsx` files are transformed by oxc. The evaluated init graph is cached in a snapshot
  under an `__oricache__/` directory next to the file, so later runs skip evaluation;
  `ORIGINE_NO_SNAPSHOT=1` disables the caches.

```js
// init.js
import { fs } from 'origine:@std/fs';

export async function main(api) {
  const files = fs(api.fs.requestSync({ write: false }));
  print(files.read_to_string('README.md').length);
}
```

The `api` object offers `fs`, `env`, `scope`, and (when the host grants an I/O runtime) `io`
(timers, async runtimes) and `net` (loopback TCP). The design, narrowing rules and security
properties are in [docs/api-design.md](docs/api-design.md); the guest modules are in
[src/js/docs/](src/js/docs/README.md). Runnable examples live in `examples/`:

| Example | Shows |
| --- | --- |
| [examples/draft-1](examples/draft-1/init.js) | sync and async fs, `io`, child scopes with a loader and preload |
| [examples/timers](examples/timers/init.js) | `io.sleepUntil`, cancellable timers |
| [examples/net](examples/net/README.md) | loopback TCP with promises and with events |
| [examples/typescript](examples/typescript/init.ts) | TypeScript inits; `children.ts` passes transformers to child scopes |

## Repository layout

```
src/            Zig sources: main.zig, repl*, api/ (host + natives), managed/ (runtime), io/ (event loop), js/ (guest JS)
rust/           one cargo workspace built into liborigine_native.a (crates/, docs/, scripts/)
lib/v8_zig/     local V8 package with its own history, tests, build tooling and docs
docs/           cross-cutting documentation
bench/          fs/text microbenchmarks, TCP comparison (bench/tcp), startup harness (bench/startup)
examples/       runnable init programs
```

## Documentation

[DOCS.md](DOCS.md) indexes every document. Start with:

- [docs/BUILD.md](docs/BUILD.md): building, V8 development loop, build options, checks
- [docs/api-design.md](docs/api-design.md): the `api` capability model
- [docs/contracts.md](docs/contracts.md): how Zig, Rust, C and JS declarations are kept in sync
- [docs/repl.md](docs/repl.md): the REPL

Docs live next to the code they describe; only cross-cutting topics are in `docs/`.
