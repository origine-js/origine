# origine

origine is a capability-based JavaScript runtime shell built on V8, written in Zig and Rust.
It starts as an empty, hardened engine: a program receives **no ambient authority** and gets
files, network, environment and contexts only through an `api` object that the host
hands to its exported `main(api)`. Compatibility layers (Node, test runners, sandboxes) are
meant to be built in JavaScript on top of `api`.

| Layer | Where | Role |
| --- | --- | --- |
| Shell, managed runtime, `api` host | `src/` (Zig) | CLI, REPL loop and terminal, isolate and context management, snapshots, native bindings |
| Event loop | `src/io/` (Zig) | Completion-based loop (io_uring, kqueue + GCD, thread pool) with a C ABI |
| Async natives, I/O runtime, TypeScript, REPL parsing | `rust/` (Rust) | `api.io` / async `api.fs` / `api.net` natives, op futures, oxc transformer, REPL line editor and input analysis |
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
  and `.jsx` files are transformed by oxc. The evaluated init graph is cached in a snapshot in a
  global cache (`~/.cache/origine/code_caches`, or `$ORIGINE_CACHE_DIR`; V8 code caches live there too),
  so later runs skip evaluation. The cache holds at most `ORIGINE_CACHE_BUDGET` (default 1200 MiB) and drops
  the least recently used files first. `ORIGINE_NO_SNAPSHOT=1` turns the init snapshot off,
  `ORIGINE_NO_CODE_CACHE=1` the code caches.

```js
// init.js
import { fs } from 'origine:@std/fs';
import { eprintln } from 'origine:@std/debug';

export async function main(api) {
  const files = fs(api.fs.requestSync({ handle: 'plain', access: 'r' }));
  eprintln(files.read_to_string('README.md').length);
}
```

### Module graphs

`api.graph` loads modules and `api.context` runs them in a realm. This program imports
`main.js`, which imports `greet.js`, both read through one read-only fs grant. The graph
itself holds no authority: the hook names the grant that reads the files.

```js
// examples/graph-hello/init.js
import { ImportHandler } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { relative } from 'origine:@std/graph/resolve/layers';
import { fsProvider } from 'origine:@std/graph/providers';
import { eprintln } from 'origine:@std/debug';

export async function main(api) {
  const src = api.fs.requestSync({ handle: 'plain', root: 'examples/graph-hello', access: 'r' });
  const handler = ImportHandler.make({
    resolver: ImportResolver.layered().layer(relative()),   // './x' resolves against the importer
    hooks: [fsProvider({ fs: src, read: 'copy' })],          // reads the files through `src`
  });
  using ctx = await api.context.create({ import: handler, graph: api.graph.root });
  const main = await ctx.import('./main.js');
  eprintln(api.graph.root.exports(main).message);           // prints: hello, graph
}
```

```js
// examples/graph-hello/main.js
import { greet } from './greet.js';
export const message = greet('graph');
```

```js
// examples/graph-hello/greet.js
export const greet = name => `hello, ${name}`;
```

`zig build run -- examples/graph-hello/init.js` runs it. The graph API is described in
[src/js/docs/graph.md](src/js/docs/graph.md) and [docs/graph-api.md](docs/graph-api.md).

### Capabilities

The `api` object offers `fs`, `host`, `graph`, `context`, `isolate` and, when the host grants an
I/O runtime, `io` (timers, async runtimes) and `net` (loopback TCP). A closeable resource is
closed by `using` (sync) or `await using` (async) at scope exit, also when the scope throws:

```js
export async function main(api) {
  await using io = api.io.create({});
  await io.sleep(100);
}   // the runtime is closed here
```

The design, narrowing rules and security properties are in [docs/api-design.md](docs/api-design.md);
the guest modules are in [src/js/docs/](src/js/docs/README.md). Runnable examples live in `examples/`:

| Example | Shows |
| --- | --- |
| [examples/draft-1](examples/draft-1/init.js) | sync and async fs, `io`, a context with an import handler and preload |
| [examples/timers](examples/timers/init.js) | `io.sleepUntil`, cancellable timers |
| [examples/net](examples/net/README.md) | loopback TCP with promises and with events |
| [examples/typescript](examples/typescript/init.ts) | TypeScript inits; `children.ts` loads TypeScript and JSX in a context |
| [examples/graph-hello](examples/graph-hello/init.js) | the module graph in one program (above) |
| [examples/graph-basic](examples/graph-basic/init.js) | declaring, loading and evaluating a recipe step by step |
| [examples/graph-hooks](examples/graph-hooks/init.js) | hooks answer resolved ids in order |
| [examples/graph-resolve](examples/graph-resolve/init.js) | resolver layers and the `NotFound` case |
| [examples/graph-transform](examples/graph-transform/init.js) | transformers between reading a source and compiling it |
| [examples/graph-cache](examples/graph-cache/init.js) | `ImportCache` tables and code caches |
| [examples/graph-cross-context](examples/graph-cross-context/init.js) | two contexts sharing one graph |
| [examples/graph-migrate-scope](examples/graph-migrate-scope/init.js) | the removed `api.scope` call and its replacement |

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
