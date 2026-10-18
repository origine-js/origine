# Origine `api` design draft

Draft. Supersedes `API_PLAN_DRAFT_OLD.md`, which I leave untouched for you to delete. No Zig code changes are part of this step.

## Draft-1 implementation status

Implemented on branch `draft-1` (`src/managed/api.zig`, `api.js`, `std_io.js`; demo in `examples/draft-1/`; tests in `src/tests/managed/api.zig`). Run with `zig build run -- examples/draft-1/init.js args...`.

| Area | State |
|---|---|
| Lifecycle | `Host.run`: evaluates the init module, calls exported `main(api)`, pumps until settled. **No snapshot yet**: the init is re-evaluated every start. |
| `@engine/std/io` | `Dir`, `File`, `Limit`, `IoError`, `FileKind`. `Dir`/`File` descriptors carry Zig's method names and take the `io` first (`fs.sync` blocks and throws; `fs.async` returns promises): `Dir`: `openFile`, `createFile`, `openDir`, `close`, `createDir`, `createDirPath`, `createDirPathOpen`, `deleteFile`, `deleteDir`, `deleteTree`, `rename`, `stat`, `statFile`, `access`, `iterate`, `readFile`, `writeFile`; `File`: `close`, `stat`, `length`, `readStreaming`, `readPositional`, `readPositionalAll`, `readAll`, `writeStreaming`, `writeStreamingAll`, `writePositionalAll`, `setLength`, `sync`. Not shipped: symlink/readlink/realpath/copyFile/permissions. |
| `api.env` | `args()`, `get`, `list`, `narrow({allow})`. `args()` includes the init path, then the user arguments. |
| `api.fs` | `request({root, write, mode: {async, sync}})`, `narrow(...)`. Real backend only (no memory/overlay). Ops: `dirOpenFile`, `dirOpenDir`, `dirClose`, `dirStat`, `dirCreateDir`, `dirDeleteFile`, `dirRead`, `fileReadAll`, `fileWriteAll`, `fileClose`. |
| Errors | Errno in `Uint32Array` (`fs.errno`) for `fs.sync`; `fs.async` rejects with a frozen `{errno, name}`. `IoError.check(fs, value)` turns the state into a throw. cppgc out-parameter not implemented. |
| `api.scope` | `create({main, importMap, loader, preload})`, `narrow({count})`; handle has `run()` and `close()`. |
| Intrinsics snapshot | Done (engine level, not the init snapshot): `managed.snapshot.create` builds a startup snapshot whose default context is already frozen; `Runtime.Options.snapshot` consumes it. The build runs `src/snapshot_tool.zig` (same V8 archive and `Engine.init` flags) and embeds the 397 KB result in the executable (`build_options.has_snapshot`; cross builds skip it and use V8's built-in seed). `ORIGINE_NO_SNAPSHOT=1` disables it for comparison runs. |
| `net`, `isolate` | Absent. |

Measured (release V8, debug app build, one scope): `Context::New` 3.75 ms average (7.6 ms first) with the unfrozen built-in seed, because each context installs features and freezes the intrinsic graph, versus 0.18 ms restored from a finalized custom snapshot. Scope creation drops from about 4.3 ms to about 0.55 ms; the snapshot takes 7.5 ms and 397 KB and is generated at build time. Isolate creation (about 2.5 ms) is unchanged. Remaining ideas: snapshot the `bootstrap.js` helpers (`addDataToContext`), and snapshot the evaluated init module graph.

Known draft-1 limitations:
- **Async fs is inline.** `fs.async` calls the native op on the isolate thread and returns an already-settled promise. There is no work queue.
- **Path checks are lexical.** NUL, absolute paths and `..` are rejected; a symlink inside the root can still point outside it.
- **Option bags** are read from own data properties, but Proxies are not detected.
- **`scope.close()`** revokes the handle and clears the import cache. The V8 context stays alive until `Runtime.destroy`, since `Runtime` cannot destroy a single scope.
- **Loader** is called as `loader(moduleId: string)` and may return a string, `{ source }`, or a promise of either. `{ exports }` results and a custom `resolver` are not supported. Creating a scope from inside a loader callback is refused (`Unsupported`).
- **Cross-realm errors:** a child's failed `run()` rejects with a fresh `{errno: 255, name: 'ModuleError', message}`; child error objects never reach the parent.
- **Depth limit** for `scope.narrow` is not implemented (only `count`).
- Sync fs ignores `allow_explicit_blocking_api`.

## 1. Context

Origine embeds V8 (`Runtime` owns the isolate, `Scope` is one hardened context). Today a scope has no host I/O except a temporary `print`. The only way to hand it something is `Scope.installCapability` (`src/managed/scope.zig`), which deep-freezes a value and defines it as a read-only global. There is no snapshot step, no `main` convention, no fs/net/env, and no way for guest code to create scopes.

New model: **the engine runs an init file once, snapshots it, then calls its exported `main(api)`. `api` carries every permission. Everything else (node compat, sandboxes, test runners) is built in JS on top of `api` by narrowing it and handing slices to child scopes.**

The engine knows nothing about Node. It exposes only authority-bearing primitives, and userland composes them.

## 2. Lifecycle

```
origine init.js [args...]
  1. init phase     evaluate init.js in a fresh *init context*  (no api, no ambient authority)
  2. snapshot       serialize the init context's heap -> snapshot blob  (cached by init-graph hash)
  3. restore        deserialize into the live context
  4. main phase     call exported `main(api)`; await its result; pump until idle
```

- **Init context.** Hardened like any scope. The only host-provided import is `@engine/std/io` (section 3). It cannot do I/O or read the clock, environment or randomness, so the snapshot is deterministic and cacheable.
- **Snapshot.** Contains the init module graph, the module sources and compiled code for anything init defined (e.g. an entire `node:*` library), and `main`. It cannot contain host handles, so `api` is never captured. It is injected only at step 4.
- **`main(api)`.** Gets the root `api`, which grants all permissions. It may be `async`. The process exit code comes from its result or its rejection.
- **Why snapshot.** A node-compat layer is megabytes of JS. Parsing and evaluating it on every start is the cost the snapshot removes.
- **Snapshot reuse.** If the init files are unchanged, the cached snapshot is reused and steps 1-2 are skipped, so the evaluation cost is paid only when the init changes. Cache key: a hash of every init module (source, resolved specifier, import map) plus the engine build id and V8 version and flags. Any change in the key invalidates the cache. Because the init context is deterministic (no clock, env or randomness), equal keys give equal snapshots. Cache location and eviction are open (section 10).

## 3. `@engine/std/io` (init-visible, authority-free)

Zig-style Io API: plain data types plus a naming convention. It has no capabilities of its own.

```js
import { Dir, File, OpenFlags, Stat, IoError } from "@engine/std/io";
Dir.cwd()       // sentinel descriptor, not a handle to a real directory
Dir.at(token)   // descriptor wrapping a token that an fs gave out
```

- `Dir` and `File` are **descriptors**: frozen, data-only values (`{ kind, id }`). Holding one confers **no authority**. They only name a thing inside an fs object.
- Every operation takes a descriptor and goes through an fs object: `fs.async.dirOpenFile(Dir.cwd(), "a.txt", { mode: "read" })`, as in Zig's `dir.openFile(io, ...)`.
- `Dir.cwd()` is a sentinel. **Each fs object decides what "cwd" means.** A real fs maps it to the process cwd or its root. A virtual fs maps it to its own root. This is what lets `readFileSync` code stay identical across backends.
- Descriptors are **bound to the fs that issued them** (an fs id plus a generation). Using fs A's file with fs B fails with `IoError.BadHandle`.
- The module is pure JS, so it is snapshot-safe and shared by all scopes.

## 4. The `api` object

Delivered to `main`, frozen, with a null prototype. Every member is optional and can be absent after narrowing.

```ts
interface Api {
  fs:      FsCap;       // request an fs object
  net:     NetCap;      // fetch, tcp, udp (todo)
  env:     EnvCap;      // args and environment variables
  scope:   ScopeCap;    // create child scopes
  isolate: IsolateCap;  // create isolates (tbd)
}   // each capability has its own narrow(); there is no api-level narrow
```

### 4.1 Request, then grant (`fs`)

```ts
const fs: Fs = await api.fs.request({ root?, write?, mode?: { async?, sync? } });   // hint only; mode omitted = async only
interface Fs { errno: Uint32Array; sync?: FsOps<sync>; async?: FsOps<Promise> }   // only requested, permitted variants are present
```

- The guest sends a **hint**. The **host's provider decides** and returns one of: the real fs (rooted), a virtual (memory) fs, an overlay (lower read-only plus upper writable), or a denial. The guest cannot tell which one it got and cannot choose.
- `sync` and `async` expose the **same operation names** (`dirOpenFile`, `fileRead`, `fileWrite`, `dirCreateDir`, `stat`, `dirIterate`, `fileClose`, ...). Sync blocks the isolate thread. It exists only if the grant allows it, and the runtime must have `allow_explicit_blocking_api` set (already in `Runtime.Options`).
- An fs object is the whole authority for its backend. Sub-directory grants are made with `narrow`.

### 4.2 `net`, `env`

- `net` is **tbd** (fetch, tcp, udp, and whether it follows the request/grant shape). Policy ideas (SSRF/IP checks, redirect revalidation) in the old draft are not committed to.
- `env` gives `args`, `get(name)`, `list()` and, if granted, `set`. Narrowing can filter the visible variable names or replace the values with a fixed table (useful for a hermetic child).

### 4.3 `scope`: child scopes

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
- **Scope is not exposed to children by default.** A child's preload `values` and globals contain no `scope` capability. Creating a scope requires the init to explicitly request and hand it a narrowed `scope` capability.
- **Preload scripts and `values`.** Each preload is evaluated in the child before `main`, as `(values) => { ... }`. `values` is a hardened (deep-frozen) value built in the parent. The preload can install globals (`globalThis.process`, `Buffer`, `console`) and close over the received `api` slices. Values that cross a scope boundary follow the existing `Scope.harden` rules: plain data and functions only. No Promise/ArrayBuffer/Proxy/Map/etc. passes through the boundary.
- **Child authority.** A child gets only what the init passes through preload `values` (already-narrowed capability objects). Nothing is inherited implicitly.

### 4.4 `isolate`

Tbd. Reserved name. Constraints already fixed: it is an `api` capability, it is narrowable (count, heap limit), and it returns handles, never shared objects. Cross-isolate values would be structured-clone only.

## 5. Narrowing (monotonic attenuation)

Each capability narrows itself: `api.fs.narrow(spec)`, `api.net.narrow(spec)`, `api.env.narrow(spec)`, `api.scope.narrow(spec)`. Each returns a new capability that is a subset. **Nothing widens a grant**: there is no union or "elevate" operation.

```js
const roFs   = api.fs.narrow({ root: "/data", write: false, mode: { sync: false } });
const env    = api.env.narrow({ allow: ["HOME", "PATH"] });
const scopes = api.scope.narrow({ depth: 1, count: 4 });
```

- **`api.*` is just an object map of functions, so narrowing is function replacement.** `narrow` returns a copy of the map in which the affected functions are replaced by wrappers that check the spec first and return an error (or call the original). For example the narrowed `dirOpenFile` rejects a path outside `root`, and a narrowed `fileRead` clamps its `limit`. This is plain JS, so it is easy to write and audit, and the init can narrow with any policy it likes (the spec shapes above are only examples).
- **Native narrowing is an optional extra hardening layer.** Because a JS wrapper is only as sound as its author, the engine can additionally enforce the same spec in Zig on the grant (an intersect-only `Grant` check inside the native function). A JS wrapper can then never exceed the native grant even if buggy. Open: which specs get a native layer first (fs root and write, sync).
- **Byte limits use `std.Io.Limit`.** A limit is a `usize` counting bytes, with Zig's semantics:

  | Value | Meaning |
  |---|---|
  | `Limit.unlimited` | `maxInt(usize)`; reads the whole file |
  | `Limit.limited(n)` | `n`; reads at most `n` bytes |
  | `Limit.nothing` | `0`; reads nothing |

  `@engine/std/io` exposes the same three values to JS. They are the `limit` argument of reads (`fileReadAll(file, { limit })`) and the byte quota in fs specs. Quotas are not a bag of unrelated knobs: any byte budget is a `Limit`, and narrowing takes the minimum of two limits.
- **`sync` is the init's decision.** The init chooses whether to expose `sync` to anything it hands a capability to, by narrowing it away (`mode: { sync: false }`) or leaving it.
- Revoking a parent revokes its descendants: each grant has a generation and a `revoked` flag that every call checks (the `StaleLoadToken` pattern from `Runtime.completeLoad`). `Scope.destroy` and `child.close()` bump it, and in-flight completions fail with the stale-handle error (`IoError.StaleHandle`, see section 6).

## 6. Security properties

1. **Host is the trust boundary.** Authority lives in host structs. JS holds frozen handles, whose native methods validate the receiver (the `v8.Private` brand pattern tested in `capabilities.zig`).
2. **No ambient authority.** The init context has none. Root `api` exists only in `main`.
3. **Guest asks, host decides.** Request options are hints.
4. **Attenuate only.** See section 5.
5. **Inputs are read once, defensively.** Option bags are parsed from own data properties only (no getters, Proxies or prototype lookups) and copied into Zig memory before validation or `await`.
6. **Results are fresh values in the caller's context.** No host or cross-scope identity leaks.
7. **Errors are a closed set with no host details.** Errors never carry host paths or Zig internals; details go to an audit hook. The representation is **undecided**; see "Error representation" below.
8. **Audit and quotas.** Requests, grants, denials and revokes are all audited. Limits: open handles, in-flight ops, bytes (`Limit`), scope depth and count.

### Error representation (decided): errno out-state

Node-style string codes are cryptic and per-failure `Error` objects with captured stacks are slow (the cost that makes `Deno.errors`-style classes hurt in hot paths). Instead the native side does not throw for expected failures:

- **Error state is a `Uint32Array`.** The native side exposes a `Uint32Array` as the error state. When an operation fails it writes a **non-zero errno** into element 0 and returns a neutral value (e.g. `-1` / `undefined`). On success it leaves element 0 as `0` (the caller resets it, or the native side clears it on entry). A failure check is one typed-array read, with no allocation and no stack capture.
- **Detailed errors via an out parameter.** When more than an errno is needed, the caller passes a **pre-constructed cppgc object** as an out parameter, and the native side fills it in. Reuse is the caller's choice, so the common path allocates nothing.
- **`IoError` in `@engine/std/io`** is a frozen table of errno values with Zig-style names (`IoError.FileNotFound`, `AccessDenied`, `NotDir`, `StaleHandle`, `BadHandle`). It is data only, so it is snapshot-safe.
- **Node layer maps to codes in userland.** `node:fs` turns `IoError.FileNotFound` into a Node-style error with `code: "ENOENT"`, paying for stack capture only where Node semantics demand it.
- **No host details.** The errno is the whole default payload. Paths and Zig internals go to the audit hook.

Open points:
- **Async.** A single shared array is racy with concurrent in-flight ops. Candidates: async ops take their own state array or cppgc out object, or they reject with the errno number. Not decided.
- **Hardener.** `supportedExport` rejects `ArrayBufferView`, so the state array cannot cross a scope boundary through `values`. It must stay in the init-side closure (the node layer), which matches the intended design, but a narrowed fs handed to a child cannot carry the array.
- **cppgc.** Confirm `lib/v8_zig` exposes cppgc objects; I did not check.

## 7. Worked example: Node compat as userland

`init.js` (snapshotted):

```js
import { Dir } from "@engine/std/io";
import { makeNodeFs }   from "./node/fs.js";    // factories take `api` slices
import { makeProcess }  from "./node/process.js";

export async function main(api) {
  const fs = await api.fs.request({ root: "/", write: true, mode: { async: true, sync: true } });

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
      const file = fs.sync.dirOpenFile(Dir.cwd(), path, { mode: "read" });
      try { return fs.sync.fileReadAll(file, options); }
      finally { fs.sync.fileClose(file); }
    },
  });
}
```

`app` never sees `fs` directly. It sees `node:fs`, whose closure holds the authority. Swapping `fs` for a memory or overlay fs, or narrowing it to a read-only subtree, changes behavior with no change to the node layer.

## 8. How this maps onto the current code

| Need | Existing piece | New work |
|---|---|---|
| Install `api` in `main` | `harden` (`installCapability` is test-only and not the production path) | Build the frozen `api` object from a Zig `ApiHost`; pass it as the `main` argument rather than as a global |
| Snapshot | none | `SnapshotCreator` path in `Runtime`/`Scope.create`; confirm `lib/v8_zig` exposes it (not verified) |
| Child scopes | `Runtime.createScope`, `Scope.Options.import_map` | `ScopeCap` native bindings; preload runner; `close()` plus a JS-callback `Loader` adapter over `completeLoad` (resolver tbd) |
| Handles and brands | `v8.Private` receiver check pattern | One `Handle` helper, shared by fs/net/env/scope |
| Async completion | `Runtime.pump`, `completeLoad` tokens | Host work queue feeding `pump`; generation checks |
| Fs backends | none | `FsBackend` vtable: real (rooted, `O_NOFOLLOW`), memory, overlay |
| Narrowing | none | JS wrapper narrowing on the `api.*` function maps; optional native `Grant` intersect check; byte limits as `std.Io.Limit` |
| Entry | `src/main.zig` evals a file | Read init file, snapshot, call `main`; default CLI grants `api` per flags |

Suggested files: `src/managed/api.zig`, `capability.zig`, `fs.zig`, `net.zig`, `env.zig`, `snapshot.zig`, `src/js/std_io.js`, and `src/tests/managed/api.zig`.

## 9. Phased delivery

1. Snapshot plus `main(api)` with an empty `api`; `@engine/std/io` descriptors.
2. `fs` (memory backend, then real, then overlay) with sync/async variants and `narrow`.
3. `scope.create` with import map and preload `values` and a basic JS callback loader (custom resolver later).
4. `env`. `net` is tbd.
5. `isolate`.

## 10. Open questions

- **Snapshot support in `lib/v8_zig` (checked):** the bindings exist: `SnapshotCreator` (`setDefaultContext`, `addContext`, `createBlob`), `StartupData`, `Isolate.CreateParams.snapshot_blob` and `external_references`, `Context.fromSnapshot`. A raw test (`src/tests/raw/engine.zig`, "frozen graph and bindings survive a custom context snapshot") already round-trips a hardened context through a blob. The patches (`0002-hardening`) also account for snapshot contexts. Not yet done or verified:
  - `Scope.create` always uses `v8.Context.init` and has no snapshot path; the managed layer needs one (`Context.fromSnapshot`, restoring the embedder-data scope pointer and the import map after restore).
  - Native callbacks inside a snapshotted context (the `print` binding, the hardener validator) need `external_references` registered.
  - ES module graphs in a snapshot: I did not verify that V8 serializes `Module` records and the module map. The init may need to be evaluated as a script/bundle, or the module map rebuilt after restore.
  - Snapshots must be rebuilt after any hardening patch change (`build-tools/README.md`).
- **Snapshot cache:** where the cache lives, eviction, and exactly which inputs go into the key.
- **Error representation (decided):** errno in a `Uint32Array` plus optional cppgc out object (section 6). Async and cppgc availability open.
- **Snapshot contents (decided):** the evaluated `init.js` is snapshotted. `main` is **not called** during snapshotting; it is only exported and called after restore.
- **`Dir.cwd()` (decided):** for the real backend it is the real process cwd. Virtual and overlay backends define their own.
- **Sync (decided):** the init decides whether `sync` is exposed to others (section 5).
- **Resolver:** tbd. Loader is a basic JS callback for now; exception routing and reentrancy beyond the no-`createScope` rule still need a definition.
- **`net`:** tbd.
- **`SharedArrayBuffer`/`Atomics`:** `api` never accepts or returns shared buffers. Timing side channels are unaddressed.
- **Wasm:** not supported yet; the name and behavior are reserved for the future. Current absence relies on uncommitted `lib/v8_zig` changes that I have not inspected.

## 11. Verification (for the implementation that follows)

- `zig build test` keeps all existing tests green, including `capabilities.zig`.
- New `src/tests/managed/api.zig`: narrowing is monotonic; descriptor from fs A is rejected by fs B; revoked and stale calls fail; option bags ignore getters, Proxies and polluted prototypes; errors leak no paths; sync is absent without both flags; a child cannot exceed its `api:`.
- Manual: `zig build run -- init.js` with the section 7 example against a memory fs.
