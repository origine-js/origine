# Documentation index

Docs live **next to the code they describe**, in a `docs/` folder beside it. Zig modules
explain themselves in a `//!` header; longer topics get a Markdown file in the sibling
`docs/`; only cross-cutting material lives in the top-level [docs/](docs/). Add new docs
beside the implementation and list them here.

## Using and building

| Document | Covers |
| --- | --- |
| [README.md](README.md) | What origine is, quick start, running programs, examples |
| [docs/BUILD.md](docs/BUILD.md) | Requirements, build options, V8 patching loop, checks, Rust and TypeScript support |
| [docs/repl.md](docs/repl.md) | Interactive REPL: multiline input, inspection, history, completion |
| [docs/repl-architecture.md](docs/repl-architecture.md) | What the REPL does in Rust (parsing, line editor) and what stays in Zig and JS |
| [examples/net/README.md](examples/net/README.md) | Loopback TCP demos |

## Design and contracts

| Document | Covers |
| --- | --- |
| [docs/api-design.md](docs/api-design.md) | The `api` capability model: lifecycle, grants, narrowing, scopes, errors, status |
| [docs/async-host-contract.md](docs/async-host-contract.md) | Zig host and Rust natives: async runtimes, C ABI, buffer ownership |
| [docs/contracts.md](docs/contracts.md) | Cross-language contract surfaces and how each is generated or checked |

## Guest API reference (`src/js/docs/`)

[Index](src/js/docs/README.md) of the `origine:@std/*` modules: [io](src/js/docs/io.md),
[fs](src/js/docs/fs.md), [quansync](src/js/docs/quansync.md), [text](src/js/docs/text.md),
[errno](src/js/docs/errno.md), plus the runtime handle's [timers](src/js/docs/timers.md) and
loopback [net](src/js/docs/net.md).

[types/](types/README.md) is `@origine/types`: the TypeScript declarations of `api` and `origine:@std/*` plus a `tsconfig` preset; the rules of [docs/api-guidelines.md](docs/api-guidelines.md) (names, required options) apply to them as to the API.

## Zig internals

| Document | Covers |
| --- | --- |
| [src/api/docs/fast-calls.md](src/api/docs/fast-calls.md) | How Zig natives get V8 fast API entries; the `//!` header of [src/api/binding.zig](src/api/binding.zig) covers native bindings |
| [src/io/docs/](src/io/docs/README.md) | Event loop: [model](src/io/docs/README.md), [loop](src/io/docs/event-loop.md), [ops](src/io/docs/ops.md), [backends](src/io/docs/backends.md), [C ABI](src/io/docs/c-api.md), [testing](src/io/docs/testing.md) |
| [rust/crates/origine_repl/BUN-NOTICE.md](rust/crates/origine_repl/BUN-NOTICE.md) | Attribution and license notice for the REPL parts ported from Bun |

## Rust workspace

[rust/docs/README.md](rust/docs/README.md) is the overview (crates, toolchain, lints, linking).
Per crate:
[origine_alloc](rust/crates/origine_alloc/docs/README.md),
[origine_io](rust/crates/origine_io/docs/README.md)
([futures](rust/crates/origine_io/docs/futures.md), [rt](rust/crates/origine_io/docs/rt.md),
[fs](rust/crates/origine_io/docs/fs.md), [testing](rust/crates/origine_io/docs/testing.md)),
[origine_api_core](rust/crates/origine_api_core/docs/README.md),
[origine_api_macros](rust/crates/origine_api_macros/docs/README.md),
[origine_api](rust/crates/origine_api/docs/README.md)
([natives](rust/crates/origine_api/docs/natives.md)),
[origine_oxc](rust/crates/origine_oxc/docs/README.md).
`origine_api_fs` is documented in its crate docs (`src/lib.rs`).

## Performance and research

| Document | Covers |
| --- | --- |
| [docs/shell-performance.md](docs/shell-performance.md) | Startup tracing and binary-size measurement |
| [docs/startup-optimization-research.md](docs/startup-optimization-research.md) | Startup latency experiments and results (dated 2026-10-23) |
| [docs/timer-implementation-research.md](docs/timer-implementation-research.md) | How Bun and Deno implement timers (dated 2026-10-23); informed `api.io` timers |
| [docs/io-api-review.md](docs/io-api-review.md) | Review-oriented tour of the Zig loop and the Rust runtime API |
| [bench/tcp/README.md](bench/tcp/README.md) | TCP ping-pong benchmark against Bun and Deno |

## The V8 package (`lib/v8_zig`)

It retains its own Git history, tests, build tooling and documentation; run package-specific
commands from `lib/v8_zig`. Start at [lib/v8_zig/README.md](lib/v8_zig/README.md), then
[lib/v8_zig/docs/](lib/v8_zig/docs/) (builtin PGO, intrinsics, native scopes, ICU data
compression, rusty_v8) and [lib/v8_zig/build-tools/README.md](lib/v8_zig/build-tools/README.md).
