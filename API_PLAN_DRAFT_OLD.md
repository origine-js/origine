# Plan: `api` global (io.fs, io.net, scope) with an explicit security boundary

## Context
origine embeds V8. Each `Scope` is a hardened context with no host I/O (only the temporary `print`). Today the only way to give a scope something is `Scope.installCapability` (`src/managed/scope.zig:317`), which deep-freezes a value and defines it as a read-only, non-deletable global. There is no capability policy, no fs/net, no main-module concept.
We add one global `api`, installed by the host per scope, that offers three request-based capabilities: `io.fs`, `io.net`, `scope`. Deliverable (confirmed): a design doc plus a Zig skeleton with the global wired up and tests. Real fs and net backends are minimal. 

## security model (the boundary)
**Trust boundary is the Zig host.** Guest JS is untrusted. The authority to do anything lives only in host-side Zig structs. The guest holds unforgeable handles and never holds paths, fds, sockets or policy.

1. **No ambient authority.** `api` is the only host-provided global. Default `ApiConfig` denies everything: `api.io.requestFs/requestNet` reject and `api.scope.create` is absent unless granted.
2. **Guest asks, host decides.** `api.io.requestFs(opts)` and `requestNet(opts)` return a Promise. Options are only a *hint* (wanted root, write, sync). The host `Provider` callback returns `deny` or `grant{backend, limits}`. The guest cannot choose real vs virtual vs overlay. The host does.
3. **Monotonic attenuation.** Every grant is a `Limits` value. A child can only get `child ⊆ parent` (intersect fs roots, net origin lists, quotas, depth). Widening is impossible by construction (`Limits.intersect`, no union op exists).
4. **Handles are brand-checked native objects.** Each fs/net/scope object is a frozen null-prototype object whose methods are native functions. The host pointer lives in a `v8.Private` slot or an External that is not reachable from JS. Methods validate the receiver without coercion (pattern already tested in `capabilities.zig`, "native private capabilities validate receivers"). A handle copied into another scope still works only if the host allowed it. Grants carry a `revoked` flag and a generation, and every call checks both. Scope destroy revokes its grants and in-flight completions, which fail with a stale-token error (pattern: `Runtime.completeLoad` / `error.StaleLoadToken`).
5. **Input is read defensively, once.** Option bags are parsed in Zig using own *data* properties only (no getters, no proxies, no prototype lookups), snapshotted into Zig memory immediately, then validated. This closes TOCTOU, accessor tricks and prototype pollution of option reads. Strings and bytes are copied out before any await.
6. **Results are fresh guest values.** Only the `api` object is hardened. Return values (strings, Uint8Array, response objects) are created in the caller's own context, so the hardener's rejection of ArrayBuffer/Promise does not apply to them and no host or cross-scope object identity leaks.
7. **Errors do not leak.** Denials and failures become frozen error objects with a stable `code` (`EACCES`, `ENOENT`, `EQUOTA`, `ENETDENIED`, `ESTALE`...) and no host paths, IPs or Zig error names. Details go to the host audit hook.
8. **Audit and limits.** `ApiConfig.audit` gets every request, grant, denial and revoke. Limits cover bytes read/written, open handles, in-flight ops, request body/response size, timeouts, child scope count and depth.

## API surface (guest view)
```
api.io.requestFs({ path?, write?, sync? })  -> Promise<Fs>        // Fs has .sync and .async
api.io.requestNet({ origins? })             -> Promise<Net>       // Net.fetch(url, init) -> Promise<Response>
api.scope.create({ main, importMap?, modules?, capabilities?, limits? }) -> Scope handle
```
- `Fs.async`: `readFile, writeFile, readDir, stat, mkdir, rm, rename` (all return Promises). `Fs.sync`: same names, blocking. `.sync` exists only if the grant has `sync = true` AND the runtime option `allow_explicit_blocking_api` is set (already in the draft). Net has no sync variant.
- `Net.fetch`: only http/https, method/header allow-lists, forbidden headers stripped (Host, Cookie unless granted), no ambient cookies or credentials, response size cap, timeout, redirects re-validated against the origin allow-list on each hop. SSRF defense: resolve then check the resolved IP against a deny list (loopback, link-local, private, metadata ranges) unless the grant explicitly allows it. The connect uses the checked IP (no re-resolve, so no DNS rebinding).
- `Scope.create` takes only *data*: `main` specifier, `importMap` (JSON-shaped, parsed with existing `ImportMap.parseJson`), `modules` (specifier to source string, a virtual loader), and `capabilities` (names of grants to pass down, each attenuated, e.g. `{ fs: {path:"/data", write:false} }`). A guest cannot supply a Zig-level resolver or loader. Guest-created scopes always get `ImportMap.resolver()` + a host-built virtual `Loader`; only the *host* may attach custom `Resolver`/`Loader` (via `Scope.Options`, already present). Handle methods: `run()` / `import()` returning a Promise of a *copied, frozen, plain-data* export snapshot (module namespaces are unsupported by the hardener), and `close()`.

## Fs backends (host side, behind one vtable `FsBackend`)
- **real**: rooted at a directory handle; every path is canonicalized in Zig (reject NUL, `..` escape, absolute paths) and opened relative to the root fd with symlink-following disabled (`O_NOFOLLOW`/per-component checks). Read-only grants reject all mutating ops in Zig, not in JS.
- **memory (virtual)**: in-process tree with byte and node quotas.
- **overlay**: lower (read-only) + upper (writable) with whiteouts and copy-up; lower can never be mutated.
- Async ops run on a host work queue and complete through the runtime pump, so promises resolve on the isolate thread only.

## Files
New:
- `docs/api-design.md`: this security model, threat table, non-goals.
- `src/managed/api.zig`: `ApiConfig`, `install(scope, config)`, building the frozen `api` object, option parsing helpers.
- `src/managed/capability.zig`: `Limits`, `Grant`, `Provider`, `intersect`, revocation and audit types.
- `src/managed/fs.zig`: `FsBackend` vtable, path canonicalization, memory and real backends, overlay.
- `src/managed/net.zig`: `NetBackend` vtable, request validation, SSRF/redirect policy, minimal std.http backend.
- `src/tests/managed/api.zig`, registered in `src/tests.zig`.

Modified:
- `src/managed/scope.zig`: `Options.api: ?ApiConfig`; call `api.install` after bootstrap using existing `installCapability`. Revoke grants in `destroy`.
- `src/managed/runtime.zig`: work-queue completion hook feeding `pump`, plus a generation counter for stale completions.
- `src/managed.zig`: re-export `ApiConfig`, `Limits`, `Provider`.
- `src/main.zig`: default CLI config with `api` absent (deny-all) and a `--allow-fs=<dir>` style flag is out of scope for the first pass.

Reuse: `Scope.installCapability`/`harden`, `supportedExport` rules, `v8.Private` brand pattern and the test helpers (`check`, `ensureV8`, `FailingAllocator` OOM helpers) in `src/tests/managed/support.zig`, `ImportMap.parseJson`, `Runtime.completeLoad` token/staleness model.

## Tests (`src/tests/managed/api.zig`)
- Default config: `api` exists but requests reject; `scope.create` missing.
- Provider deny/grant; guest hint cannot upgrade real to write or widen root.
- Option parsing: getter, Proxy, polluted `Object.prototype.path` and inherited props are ignored or rejected.
- Fs: `..`, absolute path, symlink escape, NUL byte rejected; read-only grant rejects writes; quotas; overlay never mutates lower; `.sync` absent without both flags.
- Net: origin allow-list, redirect to disallowed origin blocked, private IP blocked, size and timeout limits (a fake backend, no real network in tests).
- Scope: child limits are an intersection; guest cannot pass a resolver function; depth/count limits; close revokes child grants; in-flight completion after close is dropped.
- Brand checks: handle methods called with a foreign `this` throw; handle is frozen and null-proto.
- Error objects contain no paths.
- OOM paths via the existing `FailingAllocator` helpers.

## Verification
- `zig build test` (all existing tests must still pass, including `capabilities.zig`).
- Manual: `zig build run -- demo.js` with a host config granting a memory fs and a fake net, confirming denial messages and audit output.

## Open items, flagged in the doc
- The draft exposes `SharedArrayBuffer`/`Atomics`. `api` never accepts or returns a shared buffer, and the hardener already blocks passing one across scopes. Revisit if timing side channels matter.
- Wasm absence now relies on the dirty `lib/v8_zig` patches (the Zig `denyWasm` callback was removed in your draft). I did not inspect the submodule.
