# Unintuitive parts of the origine API

Found while writing the examples in [examples/](../examples/README.md). Each item says where it shows up and whether it
was reproduced by running an example or a probe (the probes are not kept). The order is: behaviour that looks like a
bug, error messages that send you the wrong way, names, and reference documentation that is out of date. Nothing here
was fixed by the change that adds these examples; see Status for what the follow-up did.

## Status

Fixed by the follow-up (JS, types and docs only):

| Item | What changed |
| --- | --- |
| 1 | `reference.load()` now rejects `Unsupported` with a message naming `ImportHook.exports`, instead of `NotFound ... is not provided`. A context's own import of an `exports` verdict already worked through the host's chain; making `reference.load()` answer one needs a synthetic reference and is not done. |
| 2 | `IoHandle.backend` is now the backend that runs, and the two meanings are two types: `Backend` (running, no `auto`) and `BackendChoice` (`auto` or a `Backend`) in `types/io.d.ts`, `origine_api_core` and `origine_io`. The loop records what `auto` resolved to (`Loop.kind`), a new `oio_loop_backend` exports it (header, Zig, Rust `sys_gen.rs` and mock), and `io.create` answers it. Not compiled: only `zig ast-check` ran, because `lib/v8_zig/rusty_v8` is absent from this worktree and a full build compiles V8. |
| 5 | Not a bug: `fileWriteMoveAll` is a `writeAll`, typed `void` like `fileWriteAll`. Only `write` and `writeMove` return a count. |
| 18 | Not a bug: `docs/net-grant.md` defines the subject as `host:port`. `net.md` now says so. |
| 14 | Not a bug: `BadHandle` is a `HostError` code, as `docs/io.md` says. |
| 15, 16, 20 | Documented where they bite: `readInto`, `Preload.module` and `env.args()` in `types/`. |
| 19 | `OpenOptions.append` is deleted (JS, types, `fs.md`, the example), per the guidelines. |
| 23 | `docs/api-design.md` no longer lists `env.narrow`, `Socket.write` or `send`. |

Open: 3 (`ImportError.other` is `Unexpected` by design; only the message format is odd), 4 (needs a server ticket
option), 6, 7, 8, 9, 10 (the thread isolate keeps only the Zig error name, `thread_isolate.zig`, and drops the
rejection held in `ErrorInfo`), 11, 12, 13, 17, 21, 22. They change native behaviour or the error model, and need a
real build to check.

Nothing was built or run for this follow-up; the checks were reading the code. The original verification caveat stands:
the examples ran against a `zig-out/bin/origine` older than the branch head, and `oxfmt`, `oxlint` and the TypeScript
check of `examples/` were not run.

## Behaviour that looks like a bug

1. **`ImportHook.exports` fails from a JS hook.** A hook returning `ImportHook.exports({ answer: 42 })` makes the import
   fail with `NotFound: app:/cfg.js is not provided`. The verdict reaches `src/js/glue/graph/driver.js`, where `loadInJs`
   handles the `Accept`, `Provide`, `Final` and `Link` replies but has no branch for `Exports`, so the loop ends with no
   source. Reproduced. `examples/graph/inline-source` uses `ImportHook.source` with `export const answer = 42` instead.
2. **`io.backend` is `'auto'`, not the backend chosen.** `api.io.create({}).backend` is `auto`. The type and the JSDoc
   say it is the backend that was chosen (`uring`, `kqueue` or `threaded`). Reproduced in `examples/io/runtimes`.
3. **`ImportError.other(message)` reaches the importer as `Unexpected`.** A hook that rejects with it shows up as
   `ModuleError: app:/blocked.js: Error: Unexpected: blocked by policy`. The code is wrapped, so a caller that checks
   for `ImportError` codes does not find it. Reproduced in `examples/graph/inline-source`.
4. **Client sessions never resume.** `tls.client({ sessions })` is accepted, but `tls.server` has no option to issue
   session tickets, so every handshake is full and `stream.info().resumed` is `false`. The `TlsSessions` doc says that
   without it no session is resumed; it does not say that a server which issues no tickets makes it moot. Reproduced in
   `examples/tls/resumption`.
5. **`writeMove` returns nothing.** `fileWriteMoveAll` resolves `undefined`, while the other writes return the count. The
   guidelines (`docs/api-guidelines.md`: a `write` returns the number of bytes) say it should return the count.
   Reproduced in `examples/fs/async`.
6. **`toPull()` refuses a server whose connection handler has started.** The first `connection` registration starts the
   flow; after that `toPull()` throws `Unsupported`. The rule is documented, but nothing at the registration says so.
   Reproduced in `examples/net/write-lanes`.

## Errors that point the wrong way

7. **A missing `origine()` resolver layer or provider is reported on the wrong name.** A module that imports
   `origine:@std/debug` fails with `NotFound: cannot resolve origine:@std/debug` when the handler has no `origine()` layer.
   When the handler has the layer but no `origineProvider`, the failure is `ModuleError: main.js: NotFound`: the name is
   the importing module, not the missing id. Both reproduced; every graph example now lists both.
8. **`Stalled` for an `await` that only a handler can settle.** Awaiting a socket's `close` event without a pending
   `io.run()` ends the program with `error: Stalled` and no hint (`examples/net/lifecycle`, first version). A socket with
   a `data` handler also does not close when the peer's FIN arrives: it closes only after your own `end('write')` as well.
   The second part is documented and easy to miss.
9. **`fromLoader` answers `InvalidData` for `undefined`, and the order of hooks decides what a loader sees.** A loader that
   returns `undefined` is `InvalidData`, not `NotFound`. Its position matters: a provider before it with the default
   `missing: 'abort'` ends the chain with `NotFound` (documented; not reproduced on its own), so every provider before a
   loader that can miss needs `missing: 'skip'`. Reproduced in `examples/graph/providers`, which orders the hooks that way.
10. **An isolate's `init` is resolved against the working directory, and a failure says only `InitFailed`.**
    `api.isolate.create({ init: './worker.js' })` fails with `InitFailed` and no reason; `init:
    'examples/isolate/basic/worker.js'` works. `join()` reports the same bare error. Reproduced.
11. **A raw sync operation does not throw.** `grant.dirOpenFile(...)` on a `requestSync` grant returns `undefined` and sets
    the grant's errno; only `IoError.check(grant, value)` or the `origine:@std/fs` wrapper throws. Forgetting the check
    gives a silent `undefined`. Reproduced.
12. **A grant cannot create its own root.** `requestSync({ root })` for a directory that does not exist fails with
    `NotFound` and an empty message. The examples create `work/` through the parent directory's grant. Reproduced.
13. **The same mistake gives two errors.** Passing a handle from another grant: a `hardened` grant answers `InvalidInput`,
    a `plain` grant answers `BadHandle`, and that `BadHandle`'s message is the bare path `.`. Reproduced in
    `examples/fs/access`.
14. **`IoError.BadHandle` does not exist.** `BadHandle` is a `HostError` code (`HostError.BadHandle`); `IoError.BadHandle`
    is `undefined`. Reproduced.
15. **`readInto`'s `buffer` is a view, and `new Uint8Array(buffer, 0, n)` does not slice it.** Passing a TypedArray to the
    constructor copies all of it, so the result has the whole 16-byte view with zero padding. The working form is
    `buffer.subarray(0, bytes)`. Reproduced in `examples/fs/async` (the first version printed trailing NULs).
16. **`preload`'s `module` is source text, not a specifier.** `{ module: './preload.js' }` runs the string as code and fails
    with `ReferenceError: preload is not defined`. The name reads as a specifier. Reproduced in `examples/context/preload`.
17. **Transformers seem to depend on the module id's extension.** `ModuleSource.text('export const v: number = 3;')
    .withTransformer(ts())` strips the types when the id is `app:/a.ts`, and fails with `SyntaxError: Missing initializer`
    when the id is `app:/b.js`. A file source named `typed.ts` works. The reference does not say the transformer is chosen
    by extension. Reproduced; the cause is not checked in the code.
18. **The `PermissionDenied` subject of a connect includes the port.** `connect` to `10.0.0.1` reports
    `subject 10.0.0.1:49330`, while `net.md` says the subject is the address. Reproduced in `examples/net/addresses`.
19. **`OpenOptions.append(true)` is offered but always fails.** It throws `Unsupported` at `open`. `fs.md` lists append as
    not shipped; the Rust-style surface still has it. The guidelines say to delete a shape that is not implemented.
    Reproduced in `examples/fs/rust-style`.
20. **`env.args()` starts with the init path.** `args()` is `[init, ...userArgs]`, so `args()[0]` is not the first user
    argument. Reproduced in `examples/host/env`.

## Names

21. **`fs` means three things.** `api.fs` is the capability, `origine:@std/fs` is the Rust-style module, and `origine:@std/io`
    is the Zig-style one, whose `IoError.check` takes the grant as its first argument.
22. **`Dir.cwd()` is not the working directory.** It is the sentinel for the root of the grant it is used with. In
    `examples/fs/zig-style` it is that example's `work/`.

## Reference documentation out of date

23. **`docs/api-design.md` describes an older surface.** It says `api.host.env` has `narrow({allow})` (the type has `args`,
    `get` and `list` only), says `api.net` has `Socket.write` and `send` (there are `queued.send`, `queued.put` and
    `direct.write`), says `api.io.create` returns an "IoHandle", and cites `examples/draft-1/init.js`, which is now
    `examples/fs/sync-and-async/init.js`. Reproduced by reading the types; the `narrow` on `env` was checked against
    `types/env.d.ts`.
24. **Example output lived in the tree.** `examples/draft-1` created `examples/draft-1/work/hello.txt`, and
    `examples/graph/cache` writes `cache/` next to its source. Both are untracked by default. Now `/examples/**/work/` and
    `/examples/graph/cache/cache/` are git-ignored.

## Not covered by the examples

- Anything that needs a second machine, a real DNS server or the public internet: `system()`, DoH, DoT and the presets'
  servers. `examples/dns/presets` shows the refusal instead.
- Server-issued TLS session tickets (item 4), and `ImportHook.exports` working from a JS hook (item 1).
- The REPL, which has no `api`; see [repl.md](repl.md).
