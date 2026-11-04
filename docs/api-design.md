# The origine `api` design

origine runs JavaScript with no ambient authority. A program is an *init module* that exports
`main(api)`; `api` carries every permission, and everything else (Node compatibility, sandboxes,
test runners) is built in JavaScript by narrowing `api` and handing slices to contexts. This
page is the design reference: the model, the guarantees, what is implemented and what is still
open. Reference documentation for the guest modules is in [src/js/docs](../src/js/docs/README.md),
the Zig/Rust agreement is in [async-host-contract.md](async-host-contract.md).

## Implementation status

The host lives in `src/api/` (re-exported by `src/api.zig`), the guest JS in `src/js/`, the
Rust natives in `rust/crates/origine_api*`. Tests: `src/tests/managed/api.zig`. Run an example with
`zig build run -- examples/fs/sync-and-async/init.js args...`.

| Area | State |
|---|---|
| Lifecycle | `Host.run`: evaluates the init module, calls exported `main(api)`, pumps until settled. The evaluated init graph is snapshotted lazily: the first run of `dir/init.js` evaluates it in a throwaway `SnapshotCreator` isolate (snapshot-safe std natives are available through `import.meta.native`; live resource authority is rebound after restoration) and stores `<hash>.v8-snapshot` in the global cache (below); later runs restore it, skip evaluation and call `main`. Valid while the runtime fingerprint, the init specifier and every file-backed module's content hash are unchanged (`src/api/init_cache.zig`, `src/managed/init_snapshot.zig`). An init that throws, awaits I/O or fails to load runs the normal path instead. Modules that run outside the snapshot (lazy imports, or every module when the init cannot be snapshotted) also get a V8 code cache, `<hash>.v8-code-cache` in the same cache, written after the program ran and served only for byte-identical source (V8 itself only compares length); V8 refuses a cache made under a different startup blob, so the name also covers the init snapshot the runtime booted from. Snapshot files carry a readable header (file layout version, V8 build and code-cache tag, then the key); a file from another version is rejected with its reason, never migrated, and a file that fails validation or that V8 rejects is deleted at once. **The cache is global**, not next to the init: `$ORIGINE_CACHE_DIR`, else `$XDG_CACHE_HOME/origine/code_caches`, else `~/.cache/origine/code_caches`, files directly in it under content-hash names (`src/api/cache_dir.zig`). A code cache is named by a hash of the runtime fingerprint (V8 build and flags, this executable, the embedded modules), the startup blob, the module kind and the exact source text, so identical sources share a file; a snapshot by the fingerprint, the init specifier and the working directory. It is bounded by `ORIGINE_CACHE_BUDGET` (default 1200 MiB; K/M/G suffixes; 0 stores nothing): a run that stored something trims it afterwards, deleting the least recently used files (by modification time, refreshed when a file is read after ten idle minutes) down to 90% of the budget, never a file younger than ten seconds. Files are written as `<name>.<hash of pid, process nonce, writer id, counter>.tmp` and renamed into place. `ORIGINE_NO_SNAPSHOT=1` turns the init snapshot off, `ORIGINE_NO_CODE_CACHE=1` the code and glue caches, `ORIGINE_SNAPSHOT_LOG=1` reports snapshot hit/miss (with the reason)/create/skip and the cache's size on stderr. |
| `origine:@std/*` | `io` (Zig-style `Dir`/`File`/`IoError`/`Limit`), `fs` (Rust `std::fs`-style), `quansync` (write once, run sync or async), `text` (`encodeUtf8`/`decodeUtf8`/`tryDecodeUtf8`, no `TextEncoder`/`TextDecoder` in the context), `errno`, `transformer/oxc` (JS descriptor instances validated in JS and run by the host) and `graph/*` (the module graph's data). Each is documented in [src/js/docs](../src/js/docs/README.md). Native versions (V8 string conversion, simdutf) reach `text` through `import.meta.native`, injected by the host for the embedded `origine:` ids only (`Scope.Options.meta`); the module deletes the property after capturing it, and the `origine:` id namespace cannot be taken by working-directory files. The init scope sees every `origine:*` module; a context sees only those its import handler's `origineProvider` serves (`api.context`, 4.5). |
| `api.host.env` | `args()`, `get`, `list`. There is no `narrow`. `args()` includes the init path, then the user arguments. No `set`. |
| `api.fs` | `requestSync({root, access, handle})` (blocking, Zig natives, errno cell), `await requestAsync({io, root, access, handle})` (genuinely asynchronous on an `api.io` runtime; Rust natives); `access` is required: `'r'`, `'w'` or `'rw'`; `handle` is required too: `'plain'` (the natives validate every id) or `'hardened'` (the grant also takes only the handles it issued, plus `Dir.cwd()`); and a request above the host ceiling is denied, never downgraded. No `narrow` on fs for now: `Config.fs` is the only ceiling. Real backend only (no memory/overlay). The two variants have the same op names (`dirOpenFile`, `dirOpenDir`, `dirClose`, `dirStat`, `dirSymlinkStat`, `dirCreateDir`, `dirCreateDirPath`, `dirDeleteFile`, `dirDeleteDir`, `dirDeleteTree`, `dirRename`, `dirRead`, `fileStat`, `fileReadAll`, `fileRead`, `filePread`, `fileWrite`, `fileWriteAll`, `filePwriteAll`, `fileSetLength`, `fileSync`, `fileClose`); async additionally has `fileReadInto`, `filePreadInto`, `fileReadAlloc`, `filePreadAlloc` and the move writes `fileWriteMove`, `fileWriteMoveAll`, `filePwriteMoveAll` (the sync cap has them too, failing `Unsupported`). |
| `api.io` | Only when the embedder sets `Config.runtime` (the ceiling: backends, `max_runtimes`, `default_entries`). `create({backend?: 'auto'\|'uring'\|'kqueue'\|'threaded', entries?})` (sync) returns an `IoHandle` instance with `close()`, `run()`, and the clock and timers `now`, `sleep`, `sleepUntil`, `timer`, `timerAt` ([timers](../src/js/docs/timers.md)); `await io.close()` cancels in-flight operations and destroys the runtime (every call returns the same promise, which settles once the runtime is closed). There is no `narrow`: the embedder's ceiling is the only limit. Handles are not transferable across scopes. See 4.4. |
| `api.net` | Present wherever `api.io` is. Loopback TCP only (`127.0.0.1`, `localhost`, `::1`): `listen`, `connect`, `Server.accept`, `Socket.read/readInto/readCopy` and the write lanes `queued.send`, `queued.put` and `direct.write`, and event-style handles (`register`, `io.run()`). See [net](../src/js/docs/net.md). UDP, other hosts and an embedder network permission are not implemented. |
| Errors | Errno in a native-backed `Uint32Array` (one per scope, `sync.errno`; the glue fetches it once as `native.errno`) for the sync cap; the async cap never uses it and rejects with an `OrigineError` subclass instance. `IoError.check(fs, value)` turns the state into a throw. Detail (a subject name, the raw OS code) rides in a plain `ErrorDetail` object (`native.detail`; section 6; not implemented). |
| `api.graph`, `api.context` | The module graph ([graph-api.md](graph-api.md)): `api.graph.create()` (the fs grant is named by `fsProvider({ fs })`, `ModuleSource.file(path, { fs })`, `CodeCache.dir({ fs, path })`), `graph.declare(recipe)` giving an inert `ModuleReference` that the graph loads, evaluates, reads and releases (`graph.load(ref)`, `graph.evaluate(ref, ctx)`, `graph.exports(ref)`, `graph.release(ref)`), and `api.context.create({import, graph?, preload?})` giving a realm with `import(specifier)`, `references` and `close()`. Replaces `api.scope`. See 4.5. |
| Transformers | The init scope transforms `.ts .mts .cts .tsx .jsx` through oxc by default (`Host.Config.transformers`). Contexts transform what their handler's maker, or a source's `withTransformer`, names; the oxc ones are descriptors run natively (4.5). |
| Intrinsics snapshot | Done (engine level, below the init snapshot): `managed.snapshot.create` builds a startup snapshot whose default context is already frozen; `Runtime.Options.snapshot` consumes it. The build runs `src/snapshot_tool.zig` (same V8 archive and `Engine.init` flags) and embeds the result in the executable (`build_options.has_snapshot`; cross builds skip it and use V8's built-in seed). The embedded engine snapshot is always used. Scope bootstrap helpers are restored from the snapshot instead of recompiled ([startup research](startup-optimization-research.md)). |
| `isolate`, `host.threading`, `host.Snapshot` | Done (see 4.6): isolates on other threads, ports and channels, heap snapshots. |

Measured when the engine snapshot landed (release V8, debug app build, one scope; current numbers are in [shell-performance.md](shell-performance.md)): `Context::New` 3.75 ms average (7.6 ms first) with the unfrozen built-in seed, because each context installs features and freezes the intrinsic graph, versus 0.18 ms restored from a finalized custom snapshot. Scope creation drops from about 4.3 ms to about 0.55 ms; the snapshot takes 7.5 ms and about 400 KB and is generated at build time. Isolate creation (about 2.5 ms) is unchanged.

### Writing natives (`src/api/binding.zig`)

Natives are ordinary typed Zig functions; the binding layer decodes arguments, encodes results and reports errors:

```zig
fn openFile(g: *FsGrant, dir: DirRef, path: EntryPath, bits: u32) !u32 { ... }
fn stat(g: *FsGrant, dir: DirRef, path: Path) !Stat { ... }          // Stat = struct { u32, f64 } -> [kind, size]
fn list(state: *ScopeState, call: *Call) ![]const []const u8 { ... } // *Call is injected, takes no JS argument

const ops = try call.object(FsGrant, grant, .{ .openFile = openFile, .stat = stat });
```

- **State.** The first parameter is the state the function is bound to (`FsGrant`, `ScopeState`, ...). A state type provides `errnoCell()` and `allocator()`.
- **Arguments** are decoded in order: `u32`, `u64`, `f64`, `bool`, `[]const u8` (string, copied into the per-call arena), `[]u8` (typed-array bytes, aliased), `v8.Value/Function/Object`, `?T`, or any type with `pub fn decode(call, index) !T` and an optional `arity`. Validating types such as `Path`, `SubPath` and `DirRef` put the security checks at the boundary, so ops only see checked values. A mistyped or missing argument fails with `InvalidArgument` (reported as `InvalidPath`) before the function runs.
- **Results** are encoded: ints/floats/bools directly, strings, `?T`, slices and tuples as arrays, named structs as objects, V8 handles, or `encode(self, env)`.
- **Errors, two domains.** Natives return either the closed binding set `errno.Error` (env, scope, argument decoding, encoding) or `sys` fs errors (`src/managed/sys.zig`, libc under the Zig side). `errno.of(Error)` maps the closed set strictly (every member has a code, checked at compile time); `errno.ofFs` maps fs errors by name through one alias table (`FileNotFound` -> `NotFound`, `SymLinkLoop` -> `FilesystemLoop`, ...), resolved at compile time for a concrete error set (unknown members become `Unexpected`; `anyerror` is rejected). The `Errno` names follow Rust's `std::io::ErrorKind` and the Rust backend maps `io::Error` onto the same table (`errno_of`); a test provokes the same failures through sync and async fs and compares. `InvalidInput` is a bad argument or path (NUL, empty entry name, missing `access`), `PermissionDenied` every denial: the grant's (`..`, absolute path, wrong access, above the ceiling) and the OS's. `error.OutOfMemory` is never an errno: it panics (natives allocate through `Call.allocSlice`/`print`, which panic, and the mapping functions panic on it). `Call.fail` picks the domain from the error set. Non-fs code narrows its internal errors with `errno.narrow` (the one boundary that also takes the managed layer's `anyerror`-typed callbacks) and asserts it with `comptime errno.requireBinding(native)`, so a native that leaks other errors fails to compile. `JavaScriptException` is not an errno: a native failing with it leaves the pending JS exception to propagate (`Call.fail` writes nothing), and `errno.narrow` turns the managed layer's already-captured exceptions into `InvalidData`. The codes are two enums, `IoErrno` (Rust's `ErrorKind` names) and `HostErrno` (`BadHandle`, `StaleHandle`, `Canceled`, `Unexpected`), numbered in readable blocks (`src/js/docs/errno.md`); `IoError` and `HostError` of `origine:@std/io` expose them. They are the single source of truth for the guest: `origine:@std/errno` (`ERRNO`) is generated from it at compile time and the glue gets `native.errors` generated at install, so adding a member needs no JS change.
- **Tables.** `binding.object` builds a whole native surface from one comptime table: function fields become natives, named structs become nested objects, other fields are plain values.

Known limitations:
- **Async fs is real:** `requestAsync` operations run on an `io` runtime (Zig `src/io` loop + Rust runtime, see 4.4). Writes and the `*Into`/`*Alloc` reads move buffers to the host instead of copying (see the buffer semantics in 4.4).
- **Path checks are lexical.** NUL, absolute paths and `..` are rejected; a symlink inside the root can still point outside it.
- **Option bags** are read from own data properties, but Proxies are not detected.
- **`scope.close()`** revokes the handle and disposes the child and its own children (`Runtime.disposeScope`); the context and host state are freed at the runtime's next safe point. Handles also implement `Symbol.dispose`. See `docs/scope-disposal.md`.
- **Loader** is called as `loader(moduleId: string)` and may return a string, `{ source }`, or a promise of either. `{ exports }` results and a custom `resolver` are not supported. Creating a scope from inside a loader callback is refused (`Unsupported`).
- **Cross-realm errors:** a child's failed `run()` rejects with a fresh `{errno: 255, name: 'ModuleError', message}`; child error objects never reach the parent.
- **No `scope.narrow`:** the only option was a total-creation `count`, which was never restored on close; it was removed. A scope depth or live-count limit is not implemented.
- Sync fs ignores `allow_explicit_blocking_api`.
- **Network** is loopback-only with no embedder permission; there is no UDP or `fetch`.

## 1. Context

Origine embeds V8 (`Runtime` owns the isolate, `Scope` is one hardened context). A scope starts with no host I/O; the one debugging output, `eprintln` of `origine:@std/debug`, is an `origine:` module a scope must be given; the engine does not know Node and exposes only authority-bearing primitives. `Scope.installCapability` (`src/managed/scope.zig`), which deep-freezes a value and defines it as a read-only global, is the lower-level mechanism the tests use; the production path hands the `api` object to `main`.

The model: **the engine runs an init file once, snapshots it, then calls its exported `main(api)`. `api` carries every permission. Everything else (node compat, sandboxes, test runners) is built in JS on top of `api` by narrowing it and handing slices to contexts.**

The engine knows nothing about Node. It exposes only authority-bearing primitives, and userland composes them.

## 2. Lifecycle

```
origine init.js [args...]
  1. init phase     evaluate init.js in a fresh *init context*  (no api, no ambient authority)
  2. snapshot       serialize the init context's heap -> snapshot blob  (cached by init-graph hash)
  3. restore        deserialize into the live context
  4. main phase     call exported `main(api)`; await its result; pump until idle
```

- **Init context.** Hardened like any scope. The only host-provided import is `origine:@std/io` (section 3). It cannot do I/O or read the clock, environment or randomness, so the snapshot is deterministic and cacheable.
- **Snapshot.** Contains the init module graph, the module sources and compiled code for anything init defined (e.g. an entire `node:*` library), and `main`. It cannot contain host handles, so `api` is never captured. It is injected only at step 4.
- **`main(api)`.** Gets the root `api`, which grants all permissions. It may be `async`. The process exit code comes from its result or its rejection.
- **Why snapshot.** A node-compat layer is megabytes of JS. Parsing and evaluating it on every start is the cost the snapshot removes.
- **Snapshot reuse.** If the init files are unchanged, the cached snapshot is reused and steps 1-2 are skipped, so the evaluation cost is paid only when the init changes. Cache key: a hash of every init module (source, resolved specifier, import map) plus the engine build id and V8 version and flags. Any change in the key invalidates the cache. Because the init context is deterministic (no clock, env or randomness), equal keys give equal snapshots. The cache is global (see the status table for the directory, the names, the budget and the eviction).

## 3. `origine:@std/io` (init-visible, authority-free)

Zig-style Io API: plain data types plus a naming convention. It has no capabilities of its own.

```js
import { Dir, File, OpenFlags, Stat, IoError } from "origine:@std/io";
Dir.cwd()       // sentinel descriptor, not a handle to a real directory
Dir.at(fs, id)   // descriptor naming a directory inside the fs that issued it
```

- `Dir` and `File` are **descriptors**: immutable native `DirRef`/`FileRef` instances. Holding one confers **no authority**. They only name a thing inside an fs object.
- Every operation takes a descriptor and goes through an fs object: `fs.async.dirOpenFile(Dir.cwd(), "a.txt", "r")`, as in Zig's `dir.openFile(io, ...)`.
- `Dir.cwd()` is a sentinel. **Each fs object decides what "cwd" means.** A real fs maps it to the process cwd or its root. A virtual fs maps it to its own root. This is what lets `readFileSync` code stay identical across backends.
- Descriptors are **bound to the fs that issued them** (an fs id plus a generation). Using fs A's file with fs B fails with `IoError.BadHandle`.
- The JS wrappers validate arguments and construct snapshot-safe native references; each scope has its own state.

## 4. The `api` object

Delivered to `main`, frozen, with a null prototype. Every member is optional and can be absent after narrowing.

```ts
interface Api {
  fs:      FsCap;       // request an fs object
  io:      IoCap;       // async runtimes, timers (needs the embedder's runtime ceiling)
  net:     NetCap;      // loopback tcp (needs io); fetch and udp are todo
  host:    HostCap;     // machine and process: `host.env` (args and environment variables)
  graph:   ModuleGraph; // sources, code caches and the authority modules are produced with
  context: ContextCap;  // realms whose imports run through an import handler
  isolate: IsolateCap;  // isolates on other threads (where the embedder allows them; not in BasicApi)
}   // no capability has a narrow(), and there is no api-level narrow
```

### 4.1 Request, then grant (`fs`)

```ts
const sync: SyncFs = api.fs.requestSync({ handle: 'plain', root?, access });                       // access: 'r' | 'w' | 'rw'; throws an OrigineError subclass when denied
const async: AsyncFs = await api.fs.requestAsync({ handle: 'plain', io, root?, access });         // rejects BadHandle / PermissionDenied / InvalidInput / ...
interface SyncFs  { kind: 'sync';  id: number; errno: Uint32Array; /* FsOps<sync> */ }
interface AsyncFs { kind: 'async'; id: number;                      /* FsOps<Promise> */ }
```

- The guest sends a **hint**. The **host's provider decides** and returns one of: the real fs (rooted), a virtual (memory) fs, an overlay (lower read-only plus upper writable), or a denial. Only the real fs and denial exist today. The guest cannot tell which one it got and cannot choose.
- The sync and async variants expose the **same operation names** (`dirOpenFile`, `fileRead`, `fileWrite`, `dirCreateDir`, `stat`, `dirIterate`, `fileClose`, ...). Sync blocks the isolate thread. `requestSync` throws `PermissionDenied` unless the grant allows it (host `FsConfig.sync`), and the runtime must have `allow_explicit_blocking_api` set (already in `Runtime.Options`). `requestAsync` additionally needs `FsConfig.async`, `Config.runtime`, and an `io` handle of the same scope that is still open.
- An fs object is the whole authority for its backend. A sub-directory grant is a request with a `root`. `access: 'w'` is write-only: native handles are readable when writable, so the grant itself denies (`PermissionDenied`) everything that observes what exists (reads, stat, directory listings, opening for read). Confinement of `root` is lexical only: `..` and absolute paths are denied, but a symlink inside the root can still lead out of it when followed (`metadata`, `stat`, `open`); how to confine symlinks is undecided.

### 4.2 `host.env`

`api.host.env` gives `args`, `get(name)` and `list()`. The environment is configured by the host; there is no environment narrowing API. Replacing values with a fixed table and a `set` operation are ideas, not implemented.

### 4.3 `net`

Implemented as loopback TCP on an `io` runtime; the reference is [net.md](../src/js/docs/net.md) and the natives are in [natives.md](../rust/crates/origine_api/docs/natives.md). Handles are class instances the guest cannot construct, and every socket belongs to the runtime it was created with. Open: whether wider network access follows the request/grant shape, and policy (SSRF/IP checks, redirect revalidation). UDP and `fetch` are not started.

### 4.4 `io`: async runtimes and timers

```ts
const io = api.io.create({ backend?: 'auto' | 'uring' | 'kqueue' | 'threaded', entries?: number });   // sync
const fs = await api.fs.requestAsync({ handle: 'plain', io, root, access });   // the grant's operations run on `io`
await io.close();                                             // cancels in-flight operations, destroys the runtime
```

- **The Host owns every runtime.** `api.io.create` creates a Zig `io.Loop` plus a Rust runtime inside the Host (registered against `Config.runtime.max_runtimes`; the embedder never creates loops). All runtimes are driven by the isolate thread: `Host.run`/`settle` loops `origine_api_poll` (waits on every runtime's pollable fd and a wake fd, ticks the ready ones, settles completed promises) followed by `Runtime.pump` (microtasks). `Stalled` is reported only when no runtime has live tasks or operations and no platform task remains. V8's default platform cannot report delayed-task deadlines, so a blocking wait is capped at 100 ms and the platform pumped again. Embedders with their own event loop use `Host.pollable()` (one fd) and `Host.poll(rt)` instead of `run`; `Host.wake()` interrupts a blocking poll from another thread.
- **Ceiling.** `Config.runtime` (null: no `api.io`, no async fs) is the embedder's ceiling and the only limit (there is no `api.io.narrow`). `create` throws an `OrigineError` subclass instance: `InvalidPath` for malformed options, `Unsupported` when the backend or count is not allowed or available.
- **Handles** are JS `IoHandle` instances with read-only id/backend fields and lifecycle methods, not transferable across scopes; `requestAsync` rejects `BadHandle` for a missing, forged, closed or foreign `io`. Using a grant after its runtime closed rejects (`Canceled` for work that was in flight, a stale/bad handle error afterwards).
- **Errors.** The open point of section 6 is resolved: async operations never touch the shared errno cell; they reject with their own `ErrorDetail` (section 6), which `settled` turns into an `OrigineError` subclass instance. Errno members for the async/network world: `Canceled` 14, `TimedOut` 15, `WouldBlock` 16, `ConnectionRefused` 17, `ConnectionReset` 18, `BrokenPipe` 19, `AddressInUse` 20, `NotConnected` 21 (single source of truth: `Errno` in `src/api/errno_codes.zig`; the Rust table is generated from it, see [contracts.md](contracts.md) surface D).
- **Buffer semantics (pin + detach, BYOB, host-allocated).** Where possible the host takes guest memory for the duration of an operation instead of copying it (details in [async-host-contract.md](async-host-contract.md)).
  - *Eligibility.* A guest ArrayBuffer can be pinned only if it is not shared (`SharedArrayBuffer`), not resizable, not WebAssembly memory (not detachable) and detaching it succeeds. Anything else falls back to copying, with the buffer left usable. The decision is the host's and is not observable except through the detach, so guests must treat both outcomes as valid.
  - *Writes* (`fileWrite`, `filePwriteAll`, `fileWriteAll`, and everything built on them: `File.writeStreaming*`, `Dir.writeFile`, Rust-style `write`/`write_all`): the plain writes ALWAYS copy at call time and never detach the caller's buffer. The explicit `*Move` variants (`fileWriteMove`, `fileWriteMoveAll`, `filePwriteMoveAll`; `File.writeStreamingMove*`, `writePositionalMoveAll`, Rust-style `File.write_move`/`write_move_all`) **detach** (transfer) an eligible buffer and write from it directly: afterwards it reads `byteLength === 0` and every view over it has length 0, whether the write succeeds, fails or is canceled. A buffer that cannot be detached (shared, resizable, wasm memory) fails `Unsupported` untouched; a move never copies silently. Never move one buffer twice or in a loop (a partial `fileWriteMove` remainder must come from a fresh buffer).
  - *BYOB reads* (`fileReadInto(file, view)`, `filePreadInto(file, view, offset)`; `File.readInto(io, view, offset?)`): `view` is an ArrayBuffer or any view; its buffer is pinned and detached, the read lands in it, and the promise resolves a native ReadResult with read-only bytes and buffer fields where `buffer` is a view of the same kind, byteOffset and length as `view` over the filled memory. Use `buffer`, not `view` (detached when pinned; in the copy fallback `view` also holds the data). A buffer can be handed to one operation at a time: a second operation on an already-detached buffer is a zero-length request or a rejection, never a use of freed memory.
  - *Host-allocated reads* (`fileReadAlloc(file, len)`, `filePreadAlloc(file, len, offset)`; `File.readAlloc(io, len, offset?)`): the host allocates the buffer, reads once and resolves a `Uint8Array` of exactly the bytes read (shorter than `len` near the end, empty at the end). No guest buffer is involved, so there is nothing to detach.
  - *Unchanged.* `fileRead`/`filePread` still copy into the caller's buffer at completion and resolve a count (rejecting if the buffer was detached meanwhile); `readAll` returns a host-provided `Uint8Array`. The sync variants never detach and have no `*Into`/`*Alloc`/`*Move` operations (`File.readInto`/`readAlloc`/`writeStreamingMove*` throw `Unsupported` on a sync io).
  - *Cancellation.* `io.close()` with a pinned operation in flight rejects it with `Canceled`; the host keeps the memory alive until the runtime has finished with it and nothing is handed back to the guest.
- **Timers.** `now`, `sleep`, `sleepUntil`, `timer` and `timerAt` run on the same runtime and are cancelled by `io.close()`; see [timers.md](../src/js/docs/timers.md).
- **Linking.** The Rust runtime calls the `oio_*` C ABI of `src/io/c_api.zig`; `build.zig` links the archive `liborigine_io.a` (root `src/io/lib.zig`) into the executable, the test binary and the snapshot tool.
- Contract between the Zig/JS side and the Rust side: [async-host-contract.md](async-host-contract.md).

### 4.5 `graph` and `context`: realms and their modules

The full design, its names and the checklist answers are in [graph-api.md](graph-api.md); this is the summary.

```js
const handler = ImportHandler.make({
  resolver: ImportResolver.layered().layer(origine()).layer(importMap({ imports: { dep: "app:/dep.js" } })),
  hooks: [origineProvider({ std: { include: ["debug"] } }), fromLoader(async id => load(id))],
  maker: MakeRecipe.inherit({ transformer: Transform.byExtension({ ".ts": ts() }) }),
});
using ctx = await api.context.create({ import: handler, graph, preload: [{ source, values }] });
await graph.evaluate(graph.declare(recipe), ctx);   // or: await ctx.import("dep")
```

- **A context is a realm; what it loads is its handler's business.** `api.context.create` makes a V8 context whose `import()` runs through the `ImportHandler` it was given (`resolver` layers, `hooks`, a `maker`). A handler with no JS function in it (`handler.native`) runs entirely in Zig and never calls into JS; otherwise the host runs the chain itself, host elements included, and calls the glue's driver in the **creating** realm once per function it reaches (a layer, a hook, a maker, a transformer or `meta`), parking the request on that call and completing it through `Runtime.completeResolve`/`completeLoad`, so a child is never waiting inside its own link or evaluate path. The driver waits one microtask before it runs any user function, so no layer, hook, maker, transformer or `meta` runs on the stack of a child's `import()`; they run from the microtask checkpoint of `Runtime.pump`, outside its scope iteration, where creating a context is safe (the old `in_loader` guard, which only covered the synchronous call, is gone).
- **Module tables are per context and per `ImportCache` object.** A V8 module belongs to one context, so each context keeps its own tables (in its scope's `ModuleMap`, the table number being part of a module's key). An `ImportCache` object names one table: handlers made with it share it, handlers made with another object get another one, also inside one context. `ImportCache.native({ retain })` sets how a table keeps modules (`'all'`: for the context's lifetime, `'used'`: until nothing holds them), and `size`, `delete(id)` (an identity reset) and `clear()` are on the object.
- **Authority.** A graph holds a sync fs grant and a code cache; a context gets no capability unless the parent hands it a slice through `preload` values, and never receives the graph. `origine:` modules are served only by the native `origineProvider` within its allowlist; a JS hook cannot produce an `origine:` id.
- **Preload scripts and `values`.** Each preload is evaluated in the context before it imports anything, as `(values) => { ... }`. `values` is a hardened (deep-frozen) value built in the parent; values that cross a context boundary follow `Scope.harden`: plain data and functions only. `{ module, values }` evaluates an ES module (`preload:<index>`) whose default export, if a function, is called with `values` and awaited. A failing preload rejects `create` with a `ModuleError` and closes the context.
- **String-to-code.** `eval`, `new Function` and the other string-compiling constructors are off in every realm (`Context::AllowCodeGenerationFromStrings(false)`, set when a scope is bootstrapped). `api.context.create({ security: { codeGeneration: true } })` turns it on for one realm; see the CAUTION in graph-api.md (a function exported from such a realm lets its importers run code in it).
- **Cross-context imports.** `ImportHook.link(reference)` makes a context use another context's evaluated module itself: live bindings, the other realm's objects, nothing copied or frozen (it crosses the realm boundary on purpose; V8 accepts it, see the spike in graph-api.md). `graph.exports(reference)` reads the same live namespace from the creating realm.

### 4.6 `isolate`, `host.threading`, `host.Snapshot`

Implemented. References: [host.md](../src/js/docs/host.md) (ports, channels, snapshots) and [isolate.md](../src/js/docs/isolate.md); types in `types/host.d.ts` and `types/isolate.d.ts`.

- **`api.isolate`** starts a V8 isolate with its own heap, `Host` and I/O runtimes on another thread (`src/api/thread_isolate.zig`). `create({ init, args?, env?, data?, transfer?, snapshot? })` returns `{ id, terminate(), join() }`. The new isolate runs `main(api, data)` where `data` is the structured clone of what the creator passed; `args` and `env` are copied, and nothing is inherited. There is no implicit channel: talking to the creator means passing a port in `data`. It is a separate capability, not part of the basic api, and exists only where the embedder passes `Config.isolates` (platform, a thread-safe ArrayBuffer allocator, the engine snapshot, a `max` of isolates per host); otherwise it is `PermissionDenied`.
- **Authority.** A created isolate is **not** narrowed by its creator: its init module decides what it does, within the embedder's ceiling (the same fs root, runtime limits and isolate limit). This differs from `graph`/`context`, whose children get nothing. Nothing is shared except what crosses a message: values are structured-clone only, `SharedArrayBuffer`s are shared by reference (so `Atomics` works across isolates), and `ArrayBuffer`s and ports move only when listed in a transfer list.
- **Lifetime.** Destroying a host terminates and joins every isolate it created, so the V8 engine outlives them all. The ports an isolate was given are closed when its thread ends, however it ends (a crash, `terminate`, an init that never loaded), so a peer is never left waiting. `terminate` interrupts running JavaScript at once; a thread blocked in I/O notices within about 100 ms.
- **`host.threading`.** `parallelism` (logical CPUs) and `Channel`: `new Channel({ mode })` makes two connected ports, `[port, remotePort]`, in the same two read modes as `api.net` handles: `'pull'` (`recv()`, `for await`) and `'event'` (`register('message', fn)`), converted with `toEvent()`/`toPull()`. A message is `{ identity, data, transfer }`; `identity` names the sending isolate. Natives and codec: `rust/crates/origine_api/src/channel.rs` and `message.rs` (V8 `ValueSerializer`; a port is a host object that moves between isolates, owned by whichever isolate holds it and closed with it).
- **`host.Snapshot`.** `create({ init })` evaluates an init graph in a throwaway isolate on the calling thread and snapshots the heap; `fromRaw`, `fromOrigineDataBlob`, `blob()` and `origineDataBlob()` convert to and from the raw V8 blob and the cache's file format. `create({ snapshot })` starts an isolate whose graph is already evaluated; the snapshot is reference counted so the isolate keeps it alive. A snapshot file fits only the build, the init specifier and the source files it was made from.
- **Concurrency of the init cache.** The cache writers (`cache_dir.writeAtomic`) write `<name>.<hash of pid, process nonce, writer isolate id, counter>.tmp` and rename it into place, so threads and processes can store the same entry at once and a reader sees a whole file or none; a test hammers one entry from four threads. Isolates do not write the cache themselves: only the process entry point does.
- **V8 workers.** The platform's background threads (`Engine.Options.thread_pool_size`) are shared by all isolates; `ORIGINE_V8_WORKERS=n` sets them in the shell (default 1, 0 lets V8 choose from the CPU count).

Not done: an I/O runtime that runs on another thread than its owner (the `io` capability stays on the isolate thread that made it), and passing a module recipe or import handler (rather than a specifier) to `create` and `Snapshot.create`.

## 5. Narrowing (monotonic attenuation)

No capability has a `narrow`: not environment access, fs, graph, context, net nor io (`api.io.narrow` was removed; the embedder's `Config.runtime` is the only limit on backends and runtimes). Filesystem requests choose explicit access within the host ceiling; the fs grant is named where it is used (`fsProvider({ fs })`, `ModuleSource.file(path, { fs })`) and the code cache by the handler or recipe (`codeCache`).

```js
const io = api.io.create({ backend: "threaded" });
const roFs = api.fs.requestSync({ handle: 'plain', root: "data", access: "r" });
```

- **Byte limits use `std.Io.Limit`.** A limit is a `usize` counting bytes, with Zig's semantics:

  | Value | Meaning |
  |---|---|
  | `Limit.unlimited` | `maxInt(usize)`; reads the whole file |
  | `Limit.limited(n)` | `n`; reads at most `n` bytes |
  | `Limit.nothing` | `0`; reads nothing |

  `origine:@std/io` exposes the same three values to JS. They are the `limit` argument of reads (`fileReadAll(file, { limit })`) and the byte quota in fs specs. Quotas are not a bag of unrelated knobs: any byte budget is a `Limit`, and narrowing takes the minimum of two limits.
- **`sync` is the init's decision.** The init chooses whether to expose `sync` to anything it hands a capability to, by not handing the sync grant on, or leaving it.
- Revoking a parent revokes its descendants: each grant has a generation and a `revoked` flag that every call checks (the `StaleLoadToken` pattern from `Runtime.completeLoad`). `Scope.destroy` and `child.close()` bump it, and in-flight completions fail with the stale-handle error (`IoError.StaleHandle`, see section 6).

## 6. Security properties

1. **Host is the trust boundary.** Authority lives in host structs. JS holds immutable JS handles, whose operations unwrap private JS state and validate resource ownership in native code (the `v8.Private` brand pattern tested in `capabilities.zig`).
2. **No ambient authority.** The init context has none. Root `api` exists only in `main`.
3. **Guest asks, host decides.** Request options are hints.
4. **Attenuate only.** See section 5.
5. **Inputs are read once, defensively.** Option bags are parsed from own data properties only (no getters, Proxies or prototype lookups) and copied into Zig memory before validation or `await`.
6. **Results are fresh values in the caller's context.** No host or cross-scope identity leaks.
7. **Errors are a closed set with no host details.** Errors never carry host paths or Zig internals; details go to an audit hook. See "Error representation" below.
8. **Audit and quotas.** Requests, grants, denials and revokes are all audited. Limits: open handles, in-flight ops, bytes (`Limit`), scope depth and live count (not implemented).

### Error representation (decided): errno out-state

Node-style string codes are cryptic and per-failure `Error` objects with captured stacks are slow (the cost that makes `Deno.errors`-style classes hurt in hot paths). Instead the native side does not throw for expected failures:

- **Error state is a `Uint32Array`.** The native side exposes a `Uint32Array` as the error state. When an operation fails it writes a **non-zero errno** into element 0 and returns a neutral value (e.g. `-1` / `undefined`). On success it leaves element 0 as `0` (the caller resets it, or the native side clears it on entry). A failure check is one typed-array read, with no allocation and no stack capture.
- **Detail is a plain `ErrorDetail` object, filled by the native side.** The errno stays the cheap failure signal. What else a failure knows lives in an object of a fixed shape (`subject`: a name the caller supplied or an id the guest already holds, never an absolute host path; `os`: the raw OS error code when the backend has one), built with every field always present (`undefined` when unset). The key list and order are one generated layout shared by Zig and Rust, so both build the same map: Zig makes the sync one once with the glue (`error_detail.zig`), and Rust's `error_value` sets the fields on the plain `Error` an async operation rejects with (which also keeps `errno` and `name`). It is not cppgc: Zig cannot define a cppgc class, the accessors would cost a native call per field read, and a Zig-to-Rust call per sync failure plus the release-link work buy nothing here (lazy fields and an unforgeable brand are not needed). It is not a brand either: guest code cannot reach the glue or the cell, so `settled` trusts what the natives reject with. Rust-style defaults: an error is a kind plus the raw OS code; `subject` is attached only where a native names it (`.subject = <JS argument index>` in the native's `func` options, or `Call.failAt(arg_index, err)`; the fast path never does). The glue copies the fields onto the error as own properties (`detail` itself is not public), and `message` names the subject.
  - **Sync.** The scope has one preallocated `ErrorDetail` next to the errno cell (`native.errno`, `native.detail`; neither is ever reassigned, so V8 never sees a property change type). A failing native overwrites every field, then writes the errno; the wrapper reads both straight away (`takeError`) and resets them. The fast path reports only the kind. The success path touches only `errno[0]`.
  - **Async.** No shared cell, no shared detail. Each failing operation rejects with its own object carrying the fields, built by the Rust side that ran it (`error_value`). `settled` builds the `IoError` from the fields of the object it already holds, with no further native call. Async fs names the path of each path native (`fs.rs` `named`) and carries the raw OS code.
  - **Module errors** (`ModuleError`, a real `OrigineError` subclass) are built in the creating realm from the child's errno (read from an own data property) and message; child objects never cross. Their `subject` is the id of the module that failed (the module map stamps it on the failure with a private property, along with the immediate importer as `referrer`; the call's own specifier when no module was reached), and `cause` is an error rebuilt in the parent realm.
  - **No stack trace for now.** The error is made when the operation settles, so a stack would start at the microtask; capturing one at the call costs too much. V8's async stack traces still show the `await` chain.
- **`IoError` in `origine:@std/io`** is an `OrigineError` subclass with static errno constants with Zig-style names (`IoError.NotFound`, `PermissionDenied`, `NotADirectory`, `StaleHandle`, `BadHandle`, named like Rust's `io::ErrorKind`). Its constructors and Error instances are snapshot-safe.
- **Node layer maps to codes in userland.** `node:fs` turns `IoError.NotFound` into a Node-style error with `code: "ENOENT"`, preserving the runtime error's stack.
- **No host details.** The errno is the whole default payload. Paths and Zig internals go to the audit hook.

Open points:
- **Async (resolved).** A single shared array would be racy with concurrent in-flight ops, so async operations do not use it: they reject with an `OrigineError` subclass instance (section 4.4).
- **Hardener.** `supportedExport` rejects `ArrayBufferView`, so the state array cannot cross a scope boundary through `values`. It must stay in the init-side closure (the node layer), which matches the intended design, but a narrowed fs handed to a child cannot carry the array.
- **cppgc.** Considered and not used: `lib/v8_zig` has cppgc bindings and V8's default cppgc heap would do, but see the `ErrorDetail` bullet above. Revisit only if lazy fields or an unforgeable brand become requirements. Nothing is created before `main()` (the fs and io capabilities are requested there), so snapshots are not involved.

## 7. Worked example: Node compat as userland

`init.js` (snapshotted):

```js
import { Dir } from "origine:@std/io";
import { makeNodeFs }   from "./node/fs.js";    // factories take `api` slices
import { makeProcess }  from "./node/process.js";

export async function main(api) {
  const fs = { sync: api.fs.requestSync({ handle: 'plain', root: "/", access: "rw" }) };   // async: await api.fs.requestAsync({ handle: 'plain', io, root: "/", access: "rw" })

  const nodeFs  = makeNodeFs(fs, Dir);
  const process = makeProcess(api.host.env);

  const handler = ImportHandler.make({
    resolver: ImportResolver.layered().layer(importMap({ imports: { "node:fs": "app:/shim/node-fs.js", index: "app:/index.js" } })),
    hooks: [fromLoader(async id => id === "app:/shim/node-fs.js"
      ? "export default globalThis.nodeFs"   // installed by the preload below
      : await readSource(fs, id))],
  });
  const app = await api.context.create({ graph: api.graph.root,
    import: handler,
    preload:  [{ source: PRELOAD_GLOBALS, values: { process, nodeFs } }],
  });
  await app.import("index");
}
```

`node/fs.js` (inside the snapshot):

```js
export function makeNodeFs(fs, Dir) {
  return Object.freeze({
    readFileSync(path, options) {
      const file = fs.sync.dirOpenFile(Dir.cwd(), path, "r");
      try { return fs.sync.fileReadAll(file, options); }
      finally { fs.sync.fileClose(file); }
    },
  });
}
```

`app` never sees `fs` directly. It sees `node:fs`, whose closure holds the authority. Swapping `fs` for a memory or overlay fs, or narrowing it to a read-only subtree, changes behavior with no change to the node layer.

## 8. Where it lives

| Concern | Code |
|---|---|
| `api` object, grants, lifecycle | `src/api/host.zig` (`Host`, `Config`), `src/api/{fs,env,graph,context}.zig`, guest shape in `src/js/glue/` |
| Typed native bindings, errno cell | `src/api/binding.zig`, `call.zig`, `errno.zig`, `errno_codes.zig` |
| Async runtimes, async fs, net, timers | Rust: `rust/crates/origine_api` (natives), `origine_api_fs` (grants), `origine_io` (futures, runtime); Zig: `src/io` (event loop) |
| Init snapshot and code caches | `src/api/{init_cache,init_loader}.zig`, `src/managed/{init_snapshot,snapshot}.zig` |
| Child scopes and loaders | `src/api/scope.zig`, `src/api/js_loader.zig`, `src/managed/{scope,runtime,module_map}.zig` |
| Handles and brands | `v8.Private` receiver checks (`src/tests/managed/capabilities.zig`); net classes are instances with private-field ids |
| Narrowing | JS wrappers in `src/js/glue/*.js`; the host grant (`Config.fs`, `Config.runtime`) is the ceiling that natives re-check |
| Transformers | `src/api/transform/`, `rust/crates/origine_oxc` |
| Entry | `src/main.zig` (`runInit`) |

Embedded modules are `Module { id, source, bindings }` values (`src/api/module.zig`), one file each under `std/`, joined in `std/modules.zig`. `bindings` is `stateless(table)` (natives bound to the scope state) or `stateful(S, table)` (one `S` per scope, created on the module's first `import.meta` read, `init`/`deinit` optional, torn down by `Host.destroy`); `Config.modules` replaces the table, which is how tests add their own.

Layout: `src/api/{host,glue,fs,env,scope,js_loader,init_loader,init_cache,errno,call,binding,module}.zig`, `src/api/std/{modules,io,errno,quansync,fs,text,transformer/oxc}.zig`, `src/api/transform/{transformer,transformers,ts,jsx,handle,oxc}.zig`, `src/js/{bootstrap.js,glue/{index,util,fs,host,graph,context,io,net}.js,std/{io,fs,text,quansync,transformer/oxc}.js}`.

## 9. Delivery status

1. Snapshot plus `main(api)`; `origine:@std/io` descriptors: done.
2. `fs`: real backend with sync and async variants done (`narrow` dropped for now); memory and overlay backends not started.
3. `api.context.create` with an import handler (layered, possibly async resolver; hooks; maker; transformers), preload `values`, `api.graph` with code caches, `ImportHook.link`: done (replaces `api.scope`). Source and defer phases: not implemented.
4. `host` (with `host.env`): done. `io`, timers and loopback `net`: done. Wider `net` (fetch, UDP): not started.
5. `isolate`: not started.

## 10. Open questions

- **Resolver:** done by the module graph ([graph-api.md](graph-api.md)): layered, possibly async resolver layers, with `ModuleMap` parking a module while a request resolves (`Resolver.resolve_async`, `Runtime.completeResolve`). Phase imports (`import source`, `import defer`) are still rejected.
- **Native narrowing:** which specs get a native intersect layer beyond `root`/`mode` of the dropped fs `narrow` (section 5).
- **Network permission:** how the embedder grants wider network access than loopback, and whether it follows the request/grant shape (4.3).
- **Detailed errors:** the plain `ErrorDetail` (section 6) is decided and unimplemented. Open: the field names (`subject`, `os`), a transient classifier for "is it worth retrying", and `referrer`/`phase` on `ModuleError`.
- **Hardener and typed arrays:** `supportedExport` rejects `ArrayBufferView`, so the errno array cannot cross a scope boundary through `values`; a narrowed sync fs handed to a child cannot carry it.
- **`SharedArrayBuffer`/`Atomics`:** `api` never accepts or returns shared buffers. Timing side channels are unaddressed.
- **Wasm:** V8's WebAssembly namespace is built in and sealed by the hardening patches ([intrinsics](../lib/v8_zig/docs/intrinsics.md)); no host API is offered for it, and its interaction with the `api` buffer rules is not designed.

Decided: the evaluated `init.js` is snapshotted and `main` is not called while snapshotting; `Dir.cwd()` is the real process cwd for the real backend (virtual and overlay backends would define their own); the init decides whether `sync` is exposed to others (section 5); errors use the shared errno cell for sync and OrigineError subclass rejections for async (section 6).

## 11. Verification

- `zig build test` runs the managed runtime tests, including `src/tests/managed/capabilities.zig` (brands, hardening) and `src/tests/managed/api.zig` (the host ceiling, contexts inheriting no authority, native and JS import handlers, hooks, makers, transformers, `origineProvider` and its allowlist, `ImportHook.link`, code caches, the refcounted module table, preload values, sync and async fs, `io` lifetime and cancellation, pinned and detached buffers, net echo and events, timers, snapshot restore of the prepared API); `shared_link.zig` and `async_resolve.zig` cover the managed layer.
- `just check-contracts` and `just check-rust` verify the Zig/Rust/C agreement ([contracts.md](contracts.md)).
- Manual: `zig build run -- examples/fs/sync-and-async/init.js`, `examples/io/timers/init.js`, `examples/net/*/init.js`, `examples/typescript/init.ts` (all of `examples/` is listed in [examples/README.md](../examples/README.md)).
