# Examples

Runnable `init` programs, one folder per API area. Each example is a directory with an `init.js` (or `init.ts`)
that exports `main(api)`, plus any modules it imports. Every example prints what it checks to stderr; the first
lines of each file's header comment say what to expect.

Run them from the repository root. Grant roots such as `examples/fs/rust-style/work` are relative to the working
directory, and so are `init` paths given to `api.isolate.create` (see [the unintuitive notes](../docs/api-unintuitive.md)).

```sh
zig build run -- examples/io/timers/init.js          # or: zig-out/bin/origine examples/io/timers/init.js
zig build run -- examples/host/env/init.js one two   # extra arguments follow the init path
```

Examples that write files do it under a `work/` directory they create and that git ignores (`/examples/**/work/`).
`examples/graph/cache/cache/` holds the on-disk code cache of one example, also ignored.

## Index

| Area | Example | Shows |
| --- | --- | --- |
| [fs](fs) | [sync-and-async](fs/sync-and-async/init.js) | `requestSync` and `requestAsync`, the same root, `IoError.check` |
| | [rust-style](fs/rust-style/init.js) | `origine:@std/fs`: the Rust `std::fs` functions, `File`, `OpenOptions` |
| | [zig-style](fs/zig-style/init.js) | `origine:@std/io`: `Dir`, `File`, `Limit`, `FileKind`, copy-on-write buffers |
| | [async](fs/async/init.js) | `readAlloc`, `readInto` (detaches), `writeMove` (detaches), `Canceled` on `io.close()` |
| | [access](fs/access/init.js) | `access` `'r' \| 'w' \| 'rw'`, `handle` `'plain' \| 'hardened'`, refusals |
| | [symlinks](fs/symlinks/init.js) | `symlinks: 'follow' \| 'confined'` with a link that leaves the root |
| [io](io) | [timers](io/timers/init.js) | `sleep`, `sleepUntil`, `timer`, `timerAt`, cancellation |
| | [runtimes](io/runtimes/init.js) | `create` options, `narrow`, `maxRuntimes`, `now`, `run`, `close`, `await using` |
| [net](net) | [promises](net/promises/init.js) | `'pull'` sockets: `read`, `readCopy`, `readInto`, `queued.send` |
| | [events](net/events/init.js) | `'event'` sockets: `register`, `queued.put`, `drain`, `pause`, leases |
| | [lifecycle](net/lifecycle/init.js) | `end('write')`, the auto-close rule, `toEvent()` |
| | [write-lanes](net/write-lanes/init.js) | `direct.write`, `queued.limit`, `drained()`, `end('read')`, server `toEvent`/`toPull` |
| | [addresses](net/addresses/init.js) | loopback by default, `localhost`, `PermissionDenied` outside the ceiling |
| [tls](tls) | [loopback](tls/loopback/init.js) | `tls.server`, `tls.client`, `RootPki`, `Identity`, `tls.info`, the errors |
| | [resumption](tls/resumption/init.js) | `TlsSessions` and what the server must also do |
| | [client-auth](tls/client-auth/init.js) | `ClientAuth.require`, client `identity` |
| [http](http) | [session](http/session/init.js) | `http.session` over a socket, streams, flow control (h2c) |
| | [fetch](http/fetch/init.js) | `http.serve`, `http.pool`, `http.fetch`, redirects, `QuotaExceeded` |
| | [event](http/event/init.js) | event mode: `register('request')`, exchange handlers |
| | [tls](http/tls/init.js) | HTTP/2 over TLS with `http.connect({ tls })` |
| [dns](dns) | [resolver](dns/resolver/init.js) | a resolver over DNS-over-TCP to a loopback responder, the cache |
| | [presets](dns/presets/init.js) | `presets`, the network ceiling, `dnssec` |
| [host](host) | [env](host/env/init.js) | `args()`, `get`, `list` |
| | [threading](host/threading/init.js) | `Channel` in `'pull'` and `'event'` modes, `transfer`, ports in messages |
| | [snapshot](host/snapshot/init.js) | `Snapshot.create`, `origineDataBlob`, `fromOrigineDataBlob`, `fromRaw` |
| [isolate](isolate) | [basic](isolate/basic/init.js) | `create`, `data`, `transfer`, `join`, a worker with a port |
| | [terminate](isolate/terminate/init.js) | `terminate`, the `join` statuses, a failing init |
| [graph](graph) | [hello](graph/hello/init.js) | the module graph in one program |
| | [basic](graph/basic/init.js) | declare, load, evaluate, the references |
| | [hooks](graph/hooks/init.js) | hook verdicts in order: `next`, `reject`, `accept` |
| | [resolve](graph/resolve/init.js) | resolver layers, `importMap`, `NotFound` |
| | [transform](graph/transform/init.js) | `withTransformer`, `Transform.byExtension`, `MakeRecipe.inherit` and `MakeRecipe.fn` |
| | [cache](graph/cache/init.js) | `ImportCache` tables, `CodeCache.memory` and `CodeCache.dir` |
| | [custom-code-cache](graph/custom-code-cache/init.js) | `CodeCache.custom` with `load` and `store` |
| | [providers](graph/providers/init.js) | `fsProvider` (`missing`), `json`, `origineProvider`, `fromLoader` |
| | [inline-source](graph/inline-source/init.js) | `ModuleSource.text`, `SourceMap`, `ImportHook.source` and `reject` |
| | [owned-graph](graph/owned-graph/init.js) | `api.graph.create`, references, `StaleHandle` after `close()` |
| [context](context) | [preload](context/preload/init.js) | `preload` scripts and modules, what a realm can see |
| | [security](context/security/init.js) | `security.codeGeneration` and its caution |
| | [cross-context](context/cross-context/init.js) | `ImportHook.link`, `ImportHook.recipe`, two realms on one graph |
| | [migrate-from-scope](context/migrate-from-scope/init.js) | the removed `api.scope` options and their replacements |
| [std](std) | [text](std/text/init.js) | `encodeUtf8`, `decodeUtf8`, `tryDecodeUtf8` |
| | [data](std/data/init.js) | `snapshot`, `deepFreeze` |
| | [debug](std/debug/init.js) | `eprintln` |
| | [quansync](std/quansync/init.js) | one operation, sync and async |
| | [errno](std/errno/init.js) | the `ERRNO` tables |
| | [errors](std/errors/init.js) | `IoError`, `HostError`, `OrigineError`, `ImportError` |
| | [net-addr](std/net-addr/init.js) | `IpAddr`, `SocketAddr` |
| | [transformer-oxc](std/transformer-oxc/init.js) | `ts`, `jsx` descriptors |
| [typescript](typescript) | [init.ts](typescript/init.ts) | TypeScript inits, enums and namespaces |
| | [children.ts](typescript/children.ts) | a context that loads TypeScript and JSX |

The API reference for each module is in [src/js/docs](../src/js/docs/README.md). Where an example and a reference
disagree, the example's output is the one checked: [docs/api-unintuitive.md](../docs/api-unintuitive.md) lists the
differences found while writing them.
