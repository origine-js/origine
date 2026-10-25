# The origine `api` design

origine runs JavaScript with no ambient authority. A program is an *init module* that exports
`main(api)`; `api` carries every permission, and everything else (Node compatibility, sandboxes,
test runners) is built in JavaScript by narrowing `api` and handing slices to child scopes. This
page is the design reference: the model, the guarantees, what is implemented and what is still
open. Reference documentation for the guest modules is in [src/js/docs](../src/js/docs/README.md),
the Zig/Rust agreement is in [async-host-contract.md](async-host-contract.md).

## Implementation status

The host lives in `src/api/` (re-exported by `src/api.zig`), the guest JS in `src/js/`, the
Rust natives in `rust/crates/origine_api*`. Tests: `src/tests/managed/api.zig`. Run an example with
`zig build run -- examples/draft-1/init.js args...`.

| Area | State |
|---|---|
| Lifecycle | `Host.run`: evaluates the init module, calls exported `main(api)`, pumps until settled. The evaluated init graph is snapshotted lazily: the first run of `dir/init.js` evaluates it in a throwaway `SnapshotCreator` isolate (no host natives, so only `source` modules and pure-JS `origine:@std/*`; `import.meta.native` is absent) and stores `dir/__oricache__/init.js.<engine>.v8-snapshot`; later runs restore it, skip evaluation and call `main`. Valid while the engine tag, the init specifier and every file-backed module's content hash are unchanged (`src/api/init_cache.zig`, `src/managed/init_snapshot.zig`). An init that throws, awaits I/O or fails to load runs the normal path instead. Modules that run outside the snapshot (lazy imports, or every module when the init cannot be snapshotted) also get a V8 code cache, `name.<engine>.v8-code-cache` in the same `__oricache__`, written after the program ran and served only for byte-identical source (V8 itself only compares length); V8 refuses a cache made under a different startup blob, so a rebuilt snapshot costs one round of rejected caches. Snapshot files carry a readable header (file layout version, V8 build and code-cache tag, then the key); a file from another version is rejected with its reason, never migrated, and writing a cache file sweeps the directory of cache files made by other engine tags. `ORIGINE_NO_SNAPSHOT=1` disables both, `ORIGINE_SNAPSHOT_LOG=1` reports snapshot hit/miss (with the reason)/create/skip on stderr. |
| `origine:@std/*` | `io` (Zig-style `Dir`/`File`/`IoError`/`Limit`), `fs` (Rust `std::fs`-style), `quansync` (write once, run sync or async), `text` (`encodeUtf8`/`decodeUtf8`, no `TextEncoder`/`TextDecoder` in the context), `errno`, and `transformer/oxc`. Each is documented in [src/js/docs](../src/js/docs/README.md). Native versions (V8 string conversion, simdutf) reach `text` through `import.meta.native`, injected by the host for the embedded `origine:` ids only (`Scope.Options.meta`); the module deletes the property after capturing it, and the `origine:` id namespace cannot be taken by working-directory files. Scopes only see `origine:*` when created with `enable_origine_namespace` (the init scope has it; child scopes never do). |
| `api.env` | `args()`, `get`, `list`, `narrow({allow})`. `args()` includes the init path, then the user arguments. No `set`. |
| `api.fs` | `requestSync({root, write})` (blocking, Zig natives, errno cell), `await requestAsync({io, root, write})` (genuinely asynchronous on an `api.io` runtime; Rust natives), `narrow({root, write, mode: {sync, async}})`. Real backend only (no memory/overlay). The two variants have the same op names (`dirOpenFile`, `dirOpenDir`, `dirClose`, `dirStat`, `dirCreateDir`, `dirCreateDirPath`, `dirDeleteFile`, `dirDeleteDir`, `dirDeleteTree`, `dirRename`, `dirRead`, `fileStat`, `fileReadAll`, `fileRead`, `filePread`, `fileWrite`, `fileWriteAll`, `filePwriteAll`, `fileSetLength`, `fileSync`, `fileClose`); async additionally has `fileReadInto`, `filePreadInto`, `fileReadAlloc`, `filePreadAlloc`. |
| `api.io` | Only when the embedder sets `Config.runtime` (the ceiling: backends, `max_runtimes`, `default_entries`). `create({backend?: 'auto'\|'uring'\|'kqueue'\|'threaded', entries?})` (sync) returns a frozen handle with `close()`, `run()`, and the clock and timers `now`, `sleep`, `sleepUntil`, `timer`, `timerAt` ([timers](../src/js/docs/timers.md)); `await io.close()` cancels in-flight operations and destroys the runtime; `narrow({backends, maxRuntimes})` only lowers the ceiling. Handles are not transferable across scopes. See 4.4. |
| `api.net` | Present wherever `api.io` is. Loopback TCP only (`127.0.0.1`, `localhost`, `::1`): `listen`, `connect`, `Server.accept`, `Socket.read/readInto/readCopy/write`, and event-style handles (`register`, `send`, `io.run()`). See [net](../src/js/docs/net.md). UDP, other hosts and an embedder network permission are not implemented. |
| Errors | Errno in a native-backed `Uint32Array` (one per scope, `sync.errno`; the glue fetches it once as `native.errno`) for the sync cap; the async cap never uses it and rejects with a frozen `{errno, name}`. `IoError.check(fs, value)` turns the state into a throw. The cppgc out-parameter for detailed errors is not implemented. |
| `api.scope` | `create({main, importMap, loader, preload, transformers})`, `narrow({count})`; handle has `run()` and `close()`. |
| Transformers | The init scope transforms `.ts .mts .cts .tsx .jsx` through oxc by default (`Host.Config.transformers`); children get none unless the init passes them. See 4.5. |
| Intrinsics snapshot | Done (engine level, below the init snapshot): `managed.snapshot.create` builds a startup snapshot whose default context is already frozen; `Runtime.Options.snapshot` consumes it. The build runs `src/snapshot_tool.zig` (same V8 archive and `Engine.init` flags) and embeds the result in the executable (`build_options.has_snapshot`; cross builds skip it and use V8's built-in seed). `ORIGINE_NO_SNAPSHOT=1` disables it for comparison runs. Scope bootstrap helpers are restored from the snapshot instead of recompiled ([startup research](startup-optimization-research.md)). |
| `isolate` | Absent (reserved name, see 4.6). |

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
- **Errors, two domains.** Natives return either the closed binding set `errno.Error` (env, scope, argument decoding, encoding) or `std.Io` fs errors. `errno.of(Error)` maps the closed set strictly (every member has a code, checked at compile time); `errno.ofFs` maps fs errors by name, resolved at compile time for a concrete error set (unknown members become `Unexpected`; `anyerror` is rejected). `error.OutOfMemory` is never an errno: it panics (natives allocate through `Call.allocSlice`/`print`, which panic, and the mapping functions panic on it). `Call.fail` picks the domain from the error set. Non-fs code narrows its internal errors with `errno.narrow` (the one boundary that also takes the managed layer's `anyerror`-typed callbacks) and asserts it with `comptime errno.requireBinding(native)`, so a native that leaks other errors fails to compile. The `Errno` enum is the single source of truth for the guest: `origine:@std/errno` (`ERRNO`) is generated from it at compile time and the glue gets `native.errors` generated at install, so adding a member needs no JS change.
- **Tables.** `binding.object` builds a whole native surface from one comptime table: function fields become natives, named structs become nested objects, other fields are plain values.

Known limitations:
- **Async fs is real:** `requestAsync` operations run on an `io` runtime (Zig `src/io` loop + Rust runtime, see 4.4). Writes and the `*Into`/`*Alloc` reads move buffers to the host instead of copying (see the buffer semantics in 4.4).
- **Path checks are lexical.** NUL, absolute paths and `..` are rejected; a symlink inside the root can still point outside it.
- **Option bags** are read from own data properties, but Proxies are not detected.
- **`scope.close()`** revokes the handle and clears the import cache. The V8 context stays alive until `Runtime.destroy`, since `Runtime` cannot destroy a single scope.
- **Loader** is called as `loader(moduleId: string)` and may return a string, `{ source }`, or a promise of either. `{ exports }` results and a custom `resolver` are not supported. Creating a scope from inside a loader callback is refused (`Unsupported`).
- **Cross-realm errors:** a child's failed `run()` rejects with a fresh `{errno: 255, name: 'ModuleError', message}`; child error objects never reach the parent.
- **Depth limit** for `scope.narrow` is not implemented (only `count`).
- Sync fs ignores `allow_explicit_blocking_api`.
- **Network** is loopback-only with no embedder permission; there is no UDP or `fetch`.

## 1. Context

Origine embeds V8 (`Runtime` owns the isolate, `Scope` is one hardened context). A scope starts with no host I/O except `print`; the engine does not know Node and exposes only authority-bearing primitives. `Scope.installCapability` (`src/managed/scope.zig`), which deep-freezes a value and defines it as a read-only global, is the lower-level mechanism the tests use; the production path hands the `api` object to `main`.

The model: **the engine runs an init file once, snapshots it, then calls its exported `main(api)`. `api` carries every permission. Everything else (node compat, sandboxes, test runners) is built in JS on top of `api` by narrowing it and handing slices to child scopes.**

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
- **Snapshot reuse.** If the init files are unchanged, the cached snapshot is reused and steps 1-2 are skipped, so the evaluation cost is paid only when the init changes. Cache key: a hash of every init module (source, resolved specifier, import map) plus the engine build id and V8 version and flags. Any change in the key invalidates the cache. Because the init context is deterministic (no clock, env or randomness), equal keys give equal snapshots. The cache lives in an `__oricache__` directory next to the init file (see the status table for the file names and eviction of files made by other engine tags).

## 3. `origine:@std/io` (init-visible, authority-free)

Zig-style Io API: plain data types plus a naming convention. It has no capabilities of its own.

```js
import { Dir, File, OpenFlags, Stat, IoError } from "origine:@std/io";
Dir.cwd()       // sentinel descriptor, not a handle to a real directory
Dir.at(fs, id)   // descriptor naming a directory inside the fs that issued it
```

- `Dir` and `File` are **descriptors**: frozen, data-only values (`{ kind, id }`). Holding one confers **no authority**. They only name a thing inside an fs object.
- Every operation takes a descriptor and goes through an fs object: `fs.async.dirOpenFile(Dir.cwd(), "a.txt", "r")`, as in Zig's `dir.openFile(io, ...)`.
- `Dir.cwd()` is a sentinel. **Each fs object decides what "cwd" means.** A real fs maps it to the process cwd or its root. A virtual fs maps it to its own root. This is what lets `readFileSync` code stay identical across backends.
- Descriptors are **bound to the fs that issued them** (an fs id plus a generation). Using fs A's file with fs B fails with `IoError.BadHandle`.
- The module is pure JS, so it is snapshot-safe and shared by all scopes.

## 4. The `api` object

Delivered to `main`, frozen, with a null prototype. Every member is optional and can be absent after narrowing.

```ts
interface Api {
  fs:      FsCap;       // request an fs object
  io:      IoCap;       // async runtimes, timers (needs the embedder's runtime ceiling)
  net:     NetCap;      // loopback tcp (needs io); fetch and udp are todo
  env:     EnvCap;      // args and environment variables
  scope:   ScopeCap;    // create child scopes
  isolate: IsolateCap;  // create isolates (not implemented)
}   // each capability has its own narrow(); there is no api-level narrow
```

### 4.1 Request, then grant (`fs`)

```ts
const sync: SyncFs = api.fs.requestSync({ root?, write? });                       // hint only; throws {errno, name} when denied
const async: AsyncFs = await api.fs.requestAsync({ io, root?, write? });         // hint only; rejects BadHandle / AccessDenied / ...
interface SyncFs  { kind: 'sync';  id: number; errno: Uint32Array; /* FsOps<sync> */ }
interface AsyncFs { kind: 'async'; id: number;                      /* FsOps<Promise> */ }
```

- The guest sends a **hint**. The **host's provider decides** and returns one of: the real fs (rooted), a virtual (memory) fs, an overlay (lower read-only plus upper writable), or a denial. Only the real fs and denial exist today. The guest cannot tell which one it got and cannot choose.
- The sync and async variants expose the **same operation names** (`dirOpenFile`, `fileRead`, `fileWrite`, `dirCreateDir`, `stat`, `dirIterate`, `fileClose`, ...). Sync blocks the isolate thread. `requestSync` throws `AccessDenied` unless the grant allows it (host `FsConfig.sync`, not narrowed away), and the runtime must have `allow_explicit_blocking_api` set (already in `Runtime.Options`). `requestAsync` additionally needs `FsConfig.async`, `Config.runtime`, and an `io` handle of the same scope that is still open.
- An fs object is the whole authority for its backend. Sub-directory grants are made with `narrow`.

### 4.2 `env`

`env` gives `args`, `get(name)` and `list()`. `narrow({ allow })` filters the visible variable names. Replacing values with a fixed table and a `set` operation are ideas, not implemented.

### 4.3 `net`

Implemented as loopback TCP on an `io` runtime; the reference is [net.md](../src/js/docs/net.md) and the natives are in [natives.md](../rust/crates/origine_api/docs/natives.md). Handles are class instances the guest cannot construct, and every socket belongs to the runtime it was created with. Open: whether wider network access follows the request/grant shape, and policy (SSRF/IP checks, redirect revalidation). UDP and `fetch` are not started.

### 4.4 `io`: async runtimes and timers

```ts
const io = api.io.create({ backend?: 'auto' | 'uring' | 'kqueue' | 'threaded', entries?: number });   // sync
const fs = await api.fs.requestAsync({ io, root, write });   // the grant's operations run on `io`
await io.close();                                             // cancels in-flight operations, destroys the runtime
```

- **The Host owns every runtime.** `api.io.create` creates a Zig `io.Loop` plus a Rust runtime inside the Host (registered against `Config.runtime.max_runtimes`; the embedder never creates loops). All runtimes are driven by the isolate thread: `Host.run`/`settle` loops `origine_api_poll` (waits on every runtime's pollable fd and a wake fd, ticks the ready ones, settles completed promises) followed by `Runtime.pump` (microtasks). `Stalled` is reported only when no runtime has live tasks or operations and no platform task remains. V8's default platform cannot report delayed-task deadlines, so a blocking wait is capped at 100 ms and the platform pumped again. Embedders with their own event loop use `Host.pollable()` (one fd) and `Host.poll(rt)` instead of `run`; `Host.wake()` interrupts a blocking poll from another thread.
- **Ceiling and narrowing.** `Config.runtime` (null: no `api.io`, no async fs) is the embedder's ceiling; `api.io.narrow({ backends, maxRuntimes })` only lowers it. `create` throws a frozen `{errno, name}`: `InvalidPath` for malformed options, `Unsupported` when the backend or count is not allowed or available.
- **Handles** are frozen data (`{kind: 'io', id, backend}` plus `close`), not transferable across scopes; `requestAsync` rejects `BadHandle` for a missing, forged, closed or foreign `io`. Using a grant after its runtime closed rejects (`Canceled` for work that was in flight, a stale/bad handle error afterwards).
- **Errors.** The open point of section 6 is resolved: async operations never touch the shared errno cell; they reject with the frozen `{errno, name}` value. Errno members for the async/network world: `Canceled` 14, `TimedOut` 15, `WouldBlock` 16, `ConnectionRefused` 17, `ConnectionReset` 18, `BrokenPipe` 19, `AddressInUse` 20, `NotConnected` 21 (single source of truth: `Errno` in `src/api/errno_codes.zig`; the Rust table is generated from it, see [contracts.md](contracts.md) surface D).
- **Buffer semantics (pin + detach, BYOB, host-allocated).** Where possible the host takes guest memory for the duration of an operation instead of copying it (details in [async-host-contract.md](async-host-contract.md)).
  - *Eligibility.* A guest ArrayBuffer can be pinned only if it is not shared (`SharedArrayBuffer`), not resizable, not WebAssembly memory (not detachable) and detaching it succeeds. Anything else falls back to copying, with the buffer left usable. The decision is the host's and is not observable except through the detach, so guests must treat both outcomes as valid.
  - *Writes* (`fileWrite`, `filePwriteAll`, `fileWriteAll`, and everything built on them: `File.writeStreaming*`, `Dir.writeFile`, Rust-style `write`/`write_all`): an eligible buffer is **detached** (transferred) and written from directly. Afterwards the buffer reads `byteLength === 0` and every view over it has length 0, whether the write succeeds, fails or is canceled. Pass `bytes.slice()` to keep the data; never write one buffer twice or in a loop (a partial `fileWrite` remainder must come from a copy). Non-eligible buffers are copied at call time.
  - *BYOB reads* (`fileReadInto(file, view)`, `filePreadInto(file, view, offset)`; `File.readInto(io, view, offset?)`): `view` is an ArrayBuffer or any view; its buffer is pinned and detached, the read lands in it, and the promise resolves a frozen `{ bytes, buffer }` where `buffer` is a view of the same kind, byteOffset and length as `view` over the filled memory. Use `buffer`, not `view` (detached when pinned; in the copy fallback `view` also holds the data). A buffer can be handed to one operation at a time: a second operation on an already-detached buffer is a zero-length request or a rejection, never a use of freed memory.
  - *Host-allocated reads* (`fileReadAlloc(file, len)`, `filePreadAlloc(file, len, offset)`; `File.readAlloc(io, len, offset?)`): the host allocates the buffer, reads once and resolves a `Uint8Array` of exactly the bytes read (shorter than `len` near the end, empty at the end). No guest buffer is involved, so there is nothing to detach.
  - *Unchanged.* `fileRead`/`filePread` still copy into the caller's buffer at completion and resolve a count (rejecting if the buffer was detached meanwhile); `readAll` returns a host-provided `Uint8Array`. The sync variants never detach and have no `*Into`/`*Alloc` operations (`File.readInto`/`readAlloc` throw `Unsupported` on a sync io).
  - *Cancellation.* `io.close()` with a pinned operation in flight rejects it with `Canceled`; the host keeps the memory alive until the runtime has finished with it and nothing is handed back to the guest.
- **Timers.** `now`, `sleep`, `sleepUntil`, `timer` and `timerAt` run on the same runtime and are cancelled by `io.close()`; see [timers.md](../src/js/docs/timers.md).
- **Linking.** The Rust runtime calls the `oio_*` C ABI of `src/io/c_api.zig`; `build.zig` links the archive `liborigine_io.a` (root `src/io/lib.zig`) into the executable, the test binary and the snapshot tool.
- Contract between the Zig/JS side and the Rust side: [async-host-contract.md](async-host-contract.md).

### 4.5 `scope`: child scopes

```ts
const child = await api.scope.create({
  main:      "app:/main.js",        // main module specifier
  importMap: { imports: {...} },    // data-only, parsed by ImportMap.parseJson
  loader:    (moduleId) => Content, // basic JS callback loader (may be async)
  preload:   [{ source, values }],  // scripts run before main
});
await child.run();    // evaluate main
child.close();        // destroy scope, revoke its grants
```

- **`importMap` plus a basic JS callback `loader` (first version, to get things working).** `loader: (moduleId) => Content | Promise<Content>` where `Content` is a source string or `{ source }` (`{ exports }` is not supported in draft-1). It maps onto `Scope.Options.loader`: the native adapter calls the JS function in the **creating scope's** context and returns `.pending`, then finishes with `Runtime.completeLoad(token, ...)` when the result (or promise) settles. A thrown error or rejection becomes `Completion.exception`. A custom `resolver` stays tbd (the import map is the only resolution control). Loader callbacks must not call `createScope` (existing `Runtime.pump` rule), and the callback is not trusted by the child: results are copied in as module source or hardened exports.
- **`transformers`: extension-keyed source transforms.** `transformers: { ".ts": t, ".tsx": t2 }` maps a file extension (starts with `.`, no `/ \\ ? #`, no trailing dot, no `..`; longest suffix wins, so `.d.ts` beats `.ts`) to a transformer, applied to loader results before compilation. A value is a host transformer from `origine:@std/transformer/oxc` (`ts(options)`, `tsx(options)`, `jsx(options)`: a native function branded with a `v8::Private` symbol, options supplied per transformer) or a plain JS function `(source, id) => string | { source }` (promises are not supported). Requires `loader`; a child gets no transformers unless the init passes them. The init scope itself uses `Host.Config.transformers` (default: `.ts .mts .cts` and `.tsx .jsx` through oxc). Syntax errors are reported as `file:line:col: error: message`; runtime stack positions refer to the transformed text. The JSX automatic runtime needs the runtime module to be importable (`importSource`), or use the classic runtime.
- **Scope is not exposed to children by default.** A child's preload `values` and globals contain no `scope` capability. Creating a scope requires the init to explicitly request and hand it a narrowed `scope` capability.
- **Preload scripts and `values`.** Each preload is evaluated in the child before `main`, as `(values) => { ... }`. `values` is a hardened (deep-frozen) value built in the parent. The preload can install globals (`globalThis.process`, `Buffer`, `console`) and close over the received `api` slices. Values that cross a scope boundary follow the existing `Scope.harden` rules: plain data and functions only. No Promise/ArrayBuffer/Proxy/Map/etc. passes through the boundary.
- **Child authority.** A child gets only what the init passes through preload `values` (already-narrowed capability objects). Nothing is inherited implicitly.

### 4.6 `isolate`

Not implemented. Reserved name. Constraints already fixed: it is an `api` capability, it is narrowable (count, heap limit), and it returns handles, never shared objects. Cross-isolate values would be structured-clone only.

## 5. Narrowing (monotonic attenuation)

Each capability narrows itself: `api.fs.narrow(spec)`, `api.env.narrow(spec)`, `api.scope.narrow(spec)`, `api.io.narrow(spec)`. (`api.net` has no `narrow` yet.) Each returns a new capability that is a subset. **Nothing widens a grant**: there is no union or "elevate" operation.

```js
const roFs   = api.fs.narrow({ root: "/data", write: false, mode: { sync: false } });
const env    = api.env.narrow({ allow: ["HOME", "PATH"] });
const scopes = api.scope.narrow({ count: 4 });   // `depth` is not implemented
```

- **`api.*` is just an object map of functions, so narrowing is function replacement.** `narrow` returns a copy of the map in which the affected functions are replaced by wrappers that check the spec first and return an error (or call the original). For example the narrowed `dirOpenFile` rejects a path outside `root`, and a narrowed `fileRead` clamps its `limit`. This is plain JS, so it is easy to write and audit, and the init can narrow with any policy it likes (the spec shapes above are only examples).
- **Native narrowing is an optional extra hardening layer.** Because a JS wrapper is only as sound as its author, the engine can additionally enforce the same spec in Zig on the grant (an intersect-only `Grant` check inside the native function). A JS wrapper can then never exceed the native grant even if buggy. Open: which specs get a native layer first (fs root and write, sync).
- **Byte limits use `std.Io.Limit`.** A limit is a `usize` counting bytes, with Zig's semantics:

  | Value | Meaning |
  |---|---|
  | `Limit.unlimited` | `maxInt(usize)`; reads the whole file |
  | `Limit.limited(n)` | `n`; reads at most `n` bytes |
  | `Limit.nothing` | `0`; reads nothing |

  `origine:@std/io` exposes the same three values to JS. They are the `limit` argument of reads (`fileReadAll(file, { limit })`) and the byte quota in fs specs. Quotas are not a bag of unrelated knobs: any byte budget is a `Limit`, and narrowing takes the minimum of two limits.
- **`sync` is the init's decision.** The init chooses whether to expose `sync` to anything it hands a capability to, by narrowing it away (`mode: { sync: false }`) or leaving it.
- Revoking a parent revokes its descendants: each grant has a generation and a `revoked` flag that every call checks (the `StaleLoadToken` pattern from `Runtime.completeLoad`). `Scope.destroy` and `child.close()` bump it, and in-flight completions fail with the stale-handle error (`IoError.StaleHandle`, see section 6).

## 6. Security properties

1. **Host is the trust boundary.** Authority lives in host structs. JS holds frozen handles, whose native methods validate the receiver (the `v8.Private` brand pattern tested in `capabilities.zig`).
2. **No ambient authority.** The init context has none. Root `api` exists only in `main`.
3. **Guest asks, host decides.** Request options are hints.
4. **Attenuate only.** See section 5.
5. **Inputs are read once, defensively.** Option bags are parsed from own data properties only (no getters, Proxies or prototype lookups) and copied into Zig memory before validation or `await`.
6. **Results are fresh values in the caller's context.** No host or cross-scope identity leaks.
7. **Errors are a closed set with no host details.** Errors never carry host paths or Zig internals; details go to an audit hook. See "Error representation" below.
8. **Audit and quotas.** Requests, grants, denials and revokes are all audited. Limits: open handles, in-flight ops, bytes (`Limit`), scope depth and count.

### Error representation (decided): errno out-state

Node-style string codes are cryptic and per-failure `Error` objects with captured stacks are slow (the cost that makes `Deno.errors`-style classes hurt in hot paths). Instead the native side does not throw for expected failures:

- **Error state is a `Uint32Array`.** The native side exposes a `Uint32Array` as the error state. When an operation fails it writes a **non-zero errno** into element 0 and returns a neutral value (e.g. `-1` / `undefined`). On success it leaves element 0 as `0` (the caller resets it, or the native side clears it on entry). A failure check is one typed-array read, with no allocation and no stack capture.
- **Detailed errors via an out parameter.** When more than an errno is needed, the caller passes a **pre-constructed cppgc object** as an out parameter, and the native side fills it in. Reuse is the caller's choice, so the common path allocates nothing.
- **`IoError` in `origine:@std/io`** is a frozen table of errno values with Zig-style names (`IoError.FileNotFound`, `AccessDenied`, `NotDir`, `StaleHandle`, `BadHandle`). It is data only, so it is snapshot-safe.
- **Node layer maps to codes in userland.** `node:fs` turns `IoError.FileNotFound` into a Node-style error with `code: "ENOENT"`, paying for stack capture only where Node semantics demand it.
- **No host details.** The errno is the whole default payload. Paths and Zig internals go to the audit hook.

Open points:
- **Async (resolved).** A single shared array would be racy with concurrent in-flight ops, so async operations do not use it: they reject with a frozen `{errno, name}` (section 4.4).
- **Hardener.** `supportedExport` rejects `ArrayBufferView`, so the state array cannot cross a scope boundary through `values`. It must stay in the init-side closure (the node layer), which matches the intended design, but a narrowed fs handed to a child cannot carry the array.
- **cppgc.** `lib/v8_zig` has cppgc bindings (`binding/binding.hpp`), but no native uses a cppgc out-parameter yet.

## 7. Worked example: Node compat as userland

`init.js` (snapshotted):

```js
import { Dir } from "origine:@std/io";
import { makeNodeFs }   from "./node/fs.js";    // factories take `api` slices
import { makeProcess }  from "./node/process.js";

export async function main(api) {
  const fs = { sync: api.fs.requestSync({ root: "/", write: true }) };   // async: await api.fs.requestAsync({ io, root: "/", write: true })

  const nodeFs  = makeNodeFs(fs, Dir);
  const process = makeProcess(api.env.narrow({ allow: ["HOME", "PATH"] }));

  const app = await api.scope.create({
    main: "file:///app/index.js",
    importMap: { imports: { "node:fs": "app:/shim/node-fs.js" } },
    loader: async (id) => id === "app:/shim/node-fs.js"
      ? "export default globalThis.nodeFs"   // installed by the preload below
      : await readSource(fs, id),
    preload:  [{ source: PRELOAD_GLOBALS, values: { process, nodeFs } }],
  });
  await app.run();
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
| `api` object, grants, lifecycle | `src/api/host.zig` (`Host`, `Config`), `src/api/{fs,env,scope}.zig`, guest shape in `src/js/glue/` |
| Typed native bindings, errno cell | `src/api/binding.zig`, `call.zig`, `errno.zig`, `errno_codes.zig` |
| Async runtimes, async fs, net, timers | Rust: `rust/crates/origine_api` (natives), `origine_api_fs` (grants), `origine_io` (futures, runtime); Zig: `src/io` (event loop) |
| Init snapshot and code caches | `src/api/{init_cache,init_loader}.zig`, `src/managed/{init_snapshot,snapshot}.zig` |
| Child scopes and loaders | `src/api/scope.zig`, `src/api/js_loader.zig`, `src/managed/{scope,runtime,module_map}.zig` |
| Handles and brands | `v8.Private` receiver checks (`src/tests/managed/capabilities.zig`); net classes are instances with private-field ids |
| Narrowing | JS wrappers in `src/js/glue/*.js`; the host grant (`Config.fs`, `Config.runtime`) is the ceiling that natives re-check |
| Transformers | `src/api/transform/`, `rust/crates/origine_oxc` |
| Entry | `src/main.zig` (`runInit`) |

Embedded modules are `Module { id, source, bindings }` values (`src/api/module.zig`), one file each under `std/`, joined in `std/modules.zig`. `bindings` is `stateless(table)` (natives bound to the scope state) or `stateful(S, table)` (one `S` per scope, created on the module's first `import.meta` read, `init`/`deinit` optional, torn down by `Host.destroy`); `Config.modules` replaces the table, which is how tests add their own.

Layout: `src/api/{host,glue,fs,env,scope,js_loader,init_loader,init_cache,errno,call,binding,module}.zig`, `src/api/std/{modules,io,errno,quansync,fs,text,transformer/oxc}.zig`, `src/api/transform/{transformer,transformers,ts,jsx,handle,oxc}.zig`, `src/js/{bootstrap.js,glue/{index,util,fs,env,scope,io,net}.js,std/{io,fs,text,quansync,transformer/oxc}.js}`.

## 9. Delivery status

1. Snapshot plus `main(api)`; `origine:@std/io` descriptors: done.
2. `fs`: real backend with sync and async variants and `narrow` done; memory and overlay backends not started.
3. `scope.create` with import map, preload `values`, a JS callback loader and transformers: done (custom resolver not started).
4. `env`: done. `io`, timers and loopback `net`: done. Wider `net` (fetch, UDP): not started.
5. `isolate`: not started.

## 10. Open questions

- **Resolver:** a custom module resolver is not supported; the import map is the only resolution control. Exception routing and reentrancy beyond the no-`createScope`-in-loader rule still need a definition.
- **Native narrowing:** which specs get a native intersect layer beyond fs `root`/`write`/`mode` (section 5).
- **Network permission:** how the embedder grants wider network access than loopback, and whether it follows the request/grant shape (4.3).
- **Detailed errors:** the cppgc out-parameter (section 6) is unimplemented.
- **Hardener and typed arrays:** `supportedExport` rejects `ArrayBufferView`, so the errno array cannot cross a scope boundary through `values`; a narrowed sync fs handed to a child cannot carry it.
- **`SharedArrayBuffer`/`Atomics`:** `api` never accepts or returns shared buffers. Timing side channels are unaddressed.
- **Wasm:** V8's WebAssembly namespace is built in and sealed by the hardening patches ([intrinsics](../lib/v8_zig/docs/intrinsics.md)); no host API is offered for it, and its interaction with the `api` buffer rules is not designed.

Decided: the evaluated `init.js` is snapshotted and `main` is not called while snapshotting; `Dir.cwd()` is the real process cwd for the real backend (virtual and overlay backends would define their own); the init decides whether `sync` is exposed to others (section 5); errors are errno states for sync and `{errno, name}` rejections for async (section 6).

## 11. Verification

- `zig build test` runs the managed runtime tests, including `src/tests/managed/capabilities.zig` (brands, hardening) and `src/tests/managed/api.zig` (monotonic narrowing under the host ceiling, child scopes inheriting no authority, loaders and preload values, sync and async fs, `io` lifetime and cancellation, pinned and detached buffers, net echo and events, timers, TypeScript transformers, snapshot restore of the prepared API).
- `just check-contracts` and `just check-rust` verify the Zig/Rust/C agreement ([contracts.md](contracts.md)).
- Manual: `zig build run -- examples/draft-1/init.js`, `examples/timers/init.js`, `examples/net/*.js`, `examples/typescript/init.ts`.
