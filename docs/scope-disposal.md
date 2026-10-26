# Scope disposal

Status: implemented (managed layer, host, `api.scope.close`). Deviations from the original design:

* Natives of a disposed scope fail with the existing `StaleHandle` errno, not a new `ScopeDisposed` one (the errno set is a closed contract). The managed layer's own methods still return `error.ScopeDisposed`.
* `ScopeCore` is a field of `ScopeState`; both stay allocated until `Host.destroy`.
* Async loaders keep their `Pending` records (orphaned, loader pointer cleared) instead of using a token map.
* Not done: weak-callback freeing of `ScopeCore`; Rust-side io runtimes are still owned by the host until `Host.destroy`.

## Problem

A `Scope` (one V8 context, its module map, capabilities and import map) is created by
`Runtime.createScope` and freed only by `Runtime.destroy`. `api.scope.create()` therefore leaks a
context per child for the life of the runtime, and `scope.close()` only revokes the guest handle and
clears the import cache (`src/api/scope.zig`, `docs/api-design.md`). A host that creates short-lived
scopes (per-request sandboxes, plugin reloads, a REPL `.reset`) grows without bound.

Goal: let a host or guest dispose a single scope, returning its context, module map, host state and
Zig allocations, without invalidating anything else in the runtime.

Non-goals: forcing the V8 heap to drop a context that other realms still reference (V8 cannot);
disposing the scope that is currently the only user of the isolate; multi-threading.

## What blocks it today

| Hazard | Where | Why it matters once scopes can go away |
| --- | --- | --- |
| Scope id is `rt.scopes.items.len` | `Scope.create` | Removal would make ids collide. Ids also key `Host.states` lookup (`init_loader.meta`) and the script-origin option. |
| Context embedder slot 1 holds a raw `*Scope` | `Scope.create`, `fromContext` (unwraps `.?`) | A surviving reference into the context (a hardened export, a closure held by another realm, a queued microtask) can still trigger `importMeta` or dynamic `import()` and would dereference freed memory. |
| `Runtime.pump`, `completeLoad`, `destroy` iterate `rt.scopes` | `runtime.zig` | Removal while iterating (guest code can close a scope mid-pump) skips or repeats entries. |
| Async loaders hold `*Pending` in a V8 `External` | `js_loader.zig` | Freeing the loader on disposal leaves promise handlers pointing at freed memory. |
| `ScopeState` (io runtimes, fs grants, std-module state) is owned by `Host` and keyed by scope; every native reads it through an `External`, pure ones too | `host.attach/detach`, `binding.native` | Resources must be released before the context goes (detach exists), but the pointer natives hold must stay valid for zombie calls. See "Host natives in a disposed scope". |
| Child bookkeeping is positional (`host.children`, id = index + 1) | `api/scope.zig` | Needs tombstones, not removal. |
| One shared `MicrotaskQueue` | `Runtime.queue` | Reactions of a disposed context may still be queued. They run in a context V8 keeps alive for them, so they must tolerate a missing `*Scope`. |

## Design

### Lifecycle

```
live ──disposeScope()──> disposed ──reap() at depth 0──> freed
```

* **live**: today's behavior.
* **disposed**: set immediately and synchronously, from anywhere (host code, a native called by
  guest code, a callback running inside the scope itself). Nothing is freed. Effects:
  * the scope is skipped by `pump` and `completeLoad`;
  * `eval`, `importModule*`, `harden`, `installCapability`, `*ImportCache` return
    `error.ScopeDisposed`;
  * `fromContext`-based callbacks (`importMeta`, `dynamic`) reject with `ScopeDisposed` instead of
    running.
* **freed**: done by `reap()` once no code of any scope is on the stack. This is what makes it safe
  to dispose a scope from inside its own callbacks, or from a sibling mid-`pump`.

Disposal is idempotent. `Runtime.destroy` frees any remaining scopes exactly as today (disposed ones
included).

### Runtime API

```zig
// Marks the scope disposed. Safe at any time on the runtime thread. Idempotent.
pub fn disposeScope(self: *Runtime, scope: *Scope) void;

// Frees disposed scopes. No-op while any Session is open (depth > 0).
pub fn reap(self: *Runtime) void;

// Scope
pub fn isDisposed(self: *const Scope) bool;
```

`Runtime.Session.init/deinit` maintain `rt.session_depth`. The public entry points that open the
outermost session (`pump`, `pumpPlatform`, `completeLoad`, `createScope`) call `reap()` first when
`session_depth == 0`. The host's settle loop already goes through `pumpPlatform` each iteration, so
a disposed scope is reclaimed at the next loop turn with no new call needed by embedders.

### Identity

* `Runtime.next_scope_id` (monotonic, starts at 0). `Scope.id` takes from it. Behavior is identical
  to today when nothing is disposed, so snapshot/script-origin ids are unchanged.
* `rt.scopes` becomes a plain list that `reap` compacts with `orderedRemove`. All iterations already
  re-read the list or run at depth 0, except `pump`, which is by index and skips disposed entries,
  and which never reaps (reaping only happens before the session opens).

### Teardown order (in `reap`, isolate entered, scope's context entered)

1. `Host` hook: `host.detach(scope)` releases `ScopeResources` (io runtimes, fs grants, native module
   state), sets `core.detached`, and clears the rebinder slot. `ScopeCore` stays. The host also disposes the scope's own children first
   (post-order), so a child never outlives the parent's host state.
2. `module_map.deinit()`: cancels pending loads through `Loader.cancel`, rejects unsettled import
   tasks with `RuntimeClosed` (already done today at destroy).
3. Clear embedder data slot 1 to null. From here a stray reference into the context sees "no
   scope".
4. Release `hardener`, `unsupported_prototype`, cloned import map, then `context.deinit()`.
5. Remove from `rt.scopes`, free the `Scope`.
6. Throttled `isolate.contextDisposedNotification()` so V8 can collect the context sooner. At most
   once per N disposals or T ms; it is a hint, never required for correctness.

Order 1 then 2 matters: host state may hold promises resolvers rooted in the context, and
`module_map.deinit` must still be able to enter it.

### Zombie semantics

If another realm holds a reference into a disposed context (an exported function, a value the parent
kept), V8 keeps that context's memory alive and its code stays callable. It simply has no scope:
* dynamic `import()` rejects with `ScopeDisposed`; `import.meta` yields a bare object
  (`fromContext` returns `?*Scope`; callers handle null);
* host natives follow the rule below;
* memory is reclaimed when the last foreign reference is dropped. Documented as expected.

We do not walk other realms to sever references. `harden`ed exports cross realms as frozen data
already, which limits what escapes.

#### Host natives in a disposed scope

A native must not fail merely because its scope is gone. Pure natives (text encoding, path and
string helpers, errno tables, anything with `side_effect = .none` that touches no resource) keep
working, so a closure that escaped a disposed scope still computes. Natives that need a resource the
disposal released (fs grants, io runtimes, std-module state, child scopes) fail.

The obstacle is lifetime, not policy. Every native is bound to its `ScopeState` through a V8
`External` and reads `state.allocator()` and `state.errnoCell()` on every call, pure ones
included. Freeing the `ScopeState` at disposal would make even a pure native a use-after-free. So the
state is split:

* `ScopeCore`: allocator pointer, the errno cell, a `detached` flag. Tiny, allocated by the host,
  stable address. It is what the `External` points to. It is not freed at disposal.
* `ScopeResources`: grants, io runtimes, module states, loaders. Released by `host.detach`, which
  sets `core.detached = true`.

Binding rule: a native declares whether it runs detached.

```zig
.encodeUtf8 = func(encodeUtf8, .{ .side_effect = .none, .detached = .allow }),
.openFile   = func(openFile,   .{ .side_effect = .any }),   // default: .fail
```

* `.detached = .fail` (the default): the wrapper checks `core.detached` first and throws
  `ScopeDisposed` without calling the native. Safe by default, so a new native cannot touch released
  resources by omission.
* `.detached = .allow`: the native is called as usual. It must use only `ScopeCore`. Enforced at
  compile time: such a native takes `*ScopeCore`, not `*ScopeState`, so it cannot reach resources.
  `.allow` also requires `side_effect = .none`, so a native that mutates anything cannot opt in.
* `stat` is `side_effect = .none` and still `.fail`: it reads a grant that disposal closed. The two
  flags are independent, which is why `.none` alone is not the criterion.

Cost: one small `ScopeCore` per disposed scope stays until `Host.destroy`. To bound it for hosts that
churn scopes, `ScopeCore` can be freed from a V8 weak callback on the context's global once nothing
references the context, or from the host once `Isolate` reports the context collected. Until that
refinement lands, the leak is on the order of 100 bytes per disposed scope, against a whole context
today.

### Async loader safety

`Pending` handlers stop carrying a raw pointer. They carry a `u64` load token; the host keeps
`pending: HashMap(token -> Pending)`. Disposal removes the scope's tokens; a late `fulfilled` or
`rejected` looks the token up, finds nothing, and returns (`completeLoad` would also report
`StaleLoadToken`, which both handlers already ignore). `JsLoader.deinit` is then safe to run at
disposal.

### Guest-facing API

* `scope.close()` now means dispose: handle revoked (as today), then `Runtime.disposeScope` for the
  child and, recursively, its descendants. `run()` promises still pending reject with
  `Canceled`.
* Handles gain `[Symbol.dispose]` (calls `close()`), and `[Symbol.asyncDispose]` that closes and
  resolves after the next reap, so `await using scope = await api.scope.create(...)` is a complete
  pattern.
* `host.children` keeps tombstones (`closed = true`, `scope = null`) so ids stay stable; the stale
  id error (`StaleHandle`) is unchanged.
* A child cannot dispose its parent: `childFor` already requires `child.parent == state.scope`.

### Why not the alternatives

* **Free immediately in `disposeScope`.** Breaks when a scope disposes itself (guest calls a parent
  callback that closes the caller) or when `pump` is mid-iteration. Deferral costs one list scan per
  entry point and removes a whole class of re-entrancy bugs.
* **Swap-remove with index ids.** Cheap but reuses ids; a stale id held in a forged handle or the
  script origin could then address a different scope.
* **One isolate per scope.** Gives true teardown but loses the shared microtask queue and
  cross-realm hardening, and costs far more startup. Out of scope.

## Failure modes and answers

| Case | Behavior |
| --- | --- |
| Dispose while `eval` of that scope is running | Flagged now, freed after the outermost session ends. |
| Dispose twice | No-op. |
| Pending dynamic import in the scope | Rejected `RuntimeClosed` at reap; its loader token cancelled. |
| Late loader promise settles after reap | Token lookup misses; ignored. |
| Parent disposed before child | Host disposes children first. |
| Zombie closure calls `import()` | Rejects with `ScopeDisposed`. |
| Zombie closure calls a pure native (`.detached = .allow`) | Works. |
| Zombie closure calls a resourceful native (default) | Throws `ScopeDisposed`; no resource is touched. |
| `Runtime.destroy` with disposed-not-yet-reaped scopes | Freed by `destroy` as today. |
| OOM during reap | Teardown steps are infallible (frees and deinits only). |

## Test plan

1. **Leak**: with `std.testing.allocator`, create and dispose 1,000 scopes with a module map, import
   map and loader; no leak reported.
2. **Heap**: create and dispose in a loop with `lowMemoryNotification`; `used_heap_size` stays
   bounded (compare after 100 vs 1,000 cycles).
3. **Re-entrancy**: a scope closes itself from a host callback; a scope closes a sibling inside
   `pump`; both survive and reap once.
4. **Zombie**: export a function from a disposed scope into a live one; calling it that uses
   `import()` rejects, plain computation and a `.detached = .allow` native work, an fs native throws
   `ScopeDisposed`, no crash under the debug allocator.
5. **Pending loads**: dispose with an async load in flight, settle the loader promise afterwards;
   no use-after-free (run under the debug allocator).
6. **Ids**: dispose scope 0, create another; ids differ and `init_loader.meta` finds the right
   `ScopeState`.
7. **Cascade**: parent with children and grandchildren; closing the parent frees all, handles go
   stale.
8. **Guest**: `await using` closes on exit, including on throw.
9. **Snapshot paths**: restored init scope can be disposed without touching the snapshot blob.

## Rollout

1. `next_scope_id`, `session_depth`, `disposed` flag, `ScopeDisposed` errors, nullable `fromContext`.
   No behavior change.
2. Token-based `Pending` in `js_loader.zig`.
3. Split `ScopeState` into `ScopeCore` and `ScopeResources`; add the `.detached` binding option and
   audit the pure natives that should opt in.
4. `disposeScope` / `reap` / teardown order, with tests 1 to 6.
5. `api.scope.close` becomes dispose, tombstones, cascade, `Symbol.dispose`; update
   `docs/api-design.md` (the line that says `Runtime` cannot destroy a single scope).
6. Optional: weak-callback freeing of `ScopeCore`; REPL `.reset` using a fresh scope.
