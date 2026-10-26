# origine_api

The V8-facing half of the Rust code: guest API natives written in Rust against the vendored `v8`
crate (`lib/v8_zig/rusty_v8`), running on the isolate that Zig creates. Zig keeps the Host,
scopes, module loading and the sync natives; this crate adds the `native.io.*`, `native.fsAsync.*` and
`native.net.*` tables (async, backed by [`origine_io`](../../origine_io/docs/README.md)).

Details: [natives.md](natives.md) (the native table and each native). Related crates:

| Crate | Role |
|---|---|
| [`origine_api_macros`](../../origine_api_macros/docs/README.md) | `#[native]`, `derive(FromJs)`, `derive(IntoJs)` |
| [`origine_api_core`](../../origine_api_core/docs/README.md) | V8-free logic: errno tables, argument ranges, `NativeError`, handle tables, runtime ceiling |
| `origine_api_fs` (`src/lib.rs`) | V8-free async fs `Grant`: handle tables + operations over `origine_io::fs::Dir` |
| [`origine_io`](../../origine_io/docs/README.md) | loop futures, runtime, fs |

Contract with the Zig side: [`docs/async-host-contract.md`](../../../../docs/async-host-contract.md).
Zig counterpart: `src/api/host.zig`, `src/api/binding.zig`.

## Why this crate cannot run under Miri

It links V8 (the `v8` crate). Everything testable without V8 was pushed down into
`origine_api_core` and `origine_api_fs` so Miri can check it (see
[origine_api_core](../../origine_api_core/docs/README.md)). This crate has no unit tests of its
own; it is exercised by the Zig tests in `src/tests/managed/api.zig`.

## Registration: how Rust natives reach JS

1. `#[native(side_effect = "...", path = "namespace.name", needs = "...", ...)]` on a Rust fn generates an
   `unsafe extern "C" fn <name>_raw(info: *const v8::FunctionCallbackInfo)` plus a
   `NATIVE_<NAME>: RawNative` const (callback, side effect, path, needs)
   ([macros](../../origine_api_macros/docs/README.md)). There is no per-native C symbol.
2. `src/registry.rs` lists every `NATIVE_*` const in `NATIVES` (one line per native; a unit test
   scans the sources and fails when a `#[native]` fn is missing) and exports the table as
   `origine_api_natives_count()` / `origine_api_natives_get(index, out)` (`include/origine_api.h`).
   The symbols end up in `liborigine_native.a` (root crate `rust/src/lib.rs` does
   `pub use origine_api::*`). The partial-link step keeps every `origine_*` symbol global (the
   prefix list is `kept_symbol_prefixes` in `build.zig`), so the `origine_api_*` entry points are
   visible to Zig and everything else is hidden.
3. `Host.install` (`src/api/host.zig`, `installRustNatives`) iterates that table and installs each
   native whose `needs` the embedder's config meets as `native.<namespace>.<name>` in the same
   `native` object the JS glue consumes: `needs = "runtime"` natives (`native.io.*`) exist only when
   `Config.runtime != null`, `needs = "async_fs"` natives (`native.fsAsync.*`) only when
   `Config.fs.async` too. Zig contains no list of natives. They are functions bound to the table's
   `state` (the scope's `ScopeState`) as the callback's External data; `info.data()` is how a native
   learns which guest scope called (`ScopeKey`).
4. A native that is not `export`ed can still be registered in Rust through its `NATIVE_<NAME>`
   constant (`RawNative { callback, side_effect }`).

The `side_effect` declaration is mandatory (no default), as on the Zig side: it tells V8 what the
call may do (`none`, `receiver` = only changes `this`, `any`).

## HostState and the isolate

The `v8` crate keeps per-isolate state in an "annex" in embedder data slot 0, which only
`v8::Isolate::new` creates. Zig creates the isolate, so the vendored fork exposes
`Isolate::attach_foreign_annex` / `detach_foreign_annex`.

* `origine_api_attach_isolate(isolate) -> bool`: attaches the annex (idempotent: returns `false`
  if already attached), creates the wake channel (a non-blocking `UnixStream` pair, see below),
  registers its sender under the isolate address, and stores a `HostState` in the isolate's
  slot via `isolate.set_slot`. Called by `Host.install` the first time a scope is installed.
* `origine_api_configure(isolate, *const OriginCfg)`: once after attach. Sets the ceiling
  (`max_runtimes`, `backends_mask`, `default_entries`) and the async fs config
  (`fs_root_fd` is *duplicated*, `fs_write`, `fs_async`). Before it, `HostState` allows nothing
  (`Ceiling::NONE`, no fs). `backends_mask` has bit `1 << k` for io backend kind `k`
  (1 uring, 2 kqueue, 4 threaded); `auto` is allowed if any bit is set.
* `origine_api_detach_isolate(isolate)`: removes the `HostState`, which runs `drop_all()`, then
  unregisters the waker and detaches the annex. `Host.destroy` calls it **before** freeing grants
  and before `Runtime.destroy`.

`HostState` (`src/host.rs`, single-threaded, lives in the annex slot) holds:

| Field | Meaning |
|---|---|
| `ceiling`, `fs` | embedder limits from `configure` |
| `runtimes: BTreeMap<u32, RuntimeEntry>` | per `api.io` id: `Rc<Loop>`, `Option<Runtime>`, owner `ScopeKey`, state `Open` / `Draining` |
| `grants: BTreeMap<u32, Rc<GrantRecord>>` | async fs grants bound to a runtime and an owner scope |
| `pending: BTreeMap<u64, Pending>` | promises of ops in flight: `v8::Global<PromiseResolver>`, `Global<Context>`, runtime id, optional `Hook` |
| `completions` | queue of finished-task closures, settled on the isolate thread |
| `wake: WakeRx` | receiving end of the wake channel |

Ownership checks: a runtime or grant belongs to the scope (`ScopeKey` = address of the Zig
`ScopeState` from the External data) that made it; another scope presenting the same id gets
`BadHandle`, as does an unknown or closing id.

### What `api.io.create` does today (`native.io.create(opts)`, `src/io.rs`)

This is the code as of this writing; the contract in `docs/async-host-contract.md` is still the
reference for what Zig expects and may be ahead of or behind the code.

`opts` is `Option<IoCreateOpts>` (`{ backend?: 'auto'|'uring'|'kqueue'|'threaded', entries?:
number }`). It calls `HostState::create_runtime(key, backend, entries)`:

1. `Ceiling::check_create(live, backend)`: `Unsupported` for a backend the embedder excluded
   (checked first), `PermissionDenied` when `live >= max_runtimes`.
2. `entries = entries.unwrap_or(default_entries).min(1 << 16)`.
3. `origine_io::Loop::new(Options { backend, entries })`; failure maps to `Unsupported`.
4. `Runtime::new(Rc<Loop>)`, store a `RuntimeEntry`, return the id.
5. Returns the frozen `{ kind: 'io', id, backend }` (`IoHandle`, `derive(IntoJs)`).

`native.io.close(id)` returns a `Promise<void>`: it takes the runtime out of use (`begin_close`):
drops the `Runtime` (cancels every task and op), rejects that runtime's pending promises with
`Canceled`, moves its grants aside and marks the entry `Draining`. Subsequent
`origine_api_poll` turns run the loop with `NoWait` until `active() == 0`, then release the grants
(detached closes of their descriptors), run until quiet again and finally destroy the loop and
resolve the close promise. Closing an unknown, foreign or already closing runtime rejects with
`BadHandle`.

`native.fsAsync.*` are described in [natives.md](natives.md).

### Driving: `origine_api_poll` and friends

The Host drives all runtimes from the isolate thread. `Host.settle` loops `pumpPlatform`; check
promise; `hasWork` else `Stalled`; `origine_api_poll(isolate, block=1, timeout)`; `rt.pump()`
(microtasks).

* `origine_api_poll(isolate, block, timeout_ns) -> i64` (isolate must be entered, as in
  `Runtime.Session`): one `turn`: for every open runtime `rt.tick(Mode::NoWait)`, advance draining
  runtimes (`step_draining`), take the completion queue and settle each finished promise. If
  `block` and nothing settled, wait (`poll(2)` over the wake fd and every loop's `pollable()` fd,
  at most `timeout_ns`, forever when negative; if any loop has no pollable fd the wait is capped
  at 1 ms), then turn again. Returns the live item count (tasks + active ops + draining runtimes
  + queued completions), or `-1` on error/panic.
* `origine_api_has_work(isolate) -> u8`: `live_items() > 0`.
* `origine_api_wake(isolate)`: thread-safe; writes a byte to the wake channel so a blocking poll
  returns.
* `origine_api_pollable(isolate) -> i64`: **not implemented yet, always -1**; embedders without
  their own loop use `Host.poll`.

Settling a promise (`native::finish`) enters the context saved with the op, runs the optional
`Hook` (only for success; an error from it rejects instead), converts the value with `IntoJs` and
resolves, or builds the error value (`error_value`) and rejects.

## Buffers: pinning and copy fallback

Code: `src/pinned.rs` (module docs hold the soundness argument), pure decisions in
`origine_api_core::pin` (Miri-tested). A guest buffer is an `ArrayBuffer` or a view over one.

* **Pin** (not shared, not resizable, detachable, region not empty): the window
  `(byteOffset, byteLength)` is captured, the `SharedRef<BackingStore>` taken, the buffer
  detached and the detach verified (`was_detached()`; `detach` can return `Some(true)` without
  detaching). The store becomes the owner of an `origine_io::RawRegion` over the window; the loop
  reads/writes the guest memory in place. All guest views become length 0.
* **Copy** (SharedArrayBuffer, resizable, non-detachable such as WebAssembly memory, a detach that
  did not take effect): reads use a host `Vec` and a `Wrap` copies the result into the guest
  buffer at completion (`StaleHandle` if it was detached/shrunk meanwhile).
* **Writes choose explicitly.** The plain writes (`writeAll`, `fileWrite`, `filePwriteAll`) ALWAYS
  copy at call time (`pinned::copy_for_write`) and never detach the guest's buffer. The `*Move`
  natives (`writeMoveAll`, `fileWriteMove`, `filePwriteMoveAll`, `pinned::pin_for_move`) pin and
  detach, and fail `Unsupported`, buffer untouched, where a pin is impossible (shared, resizable,
  wasm memory): no silent copy.
* **Empty** (0 bytes): no I/O, nothing detached or copied.
* A buffer that is already detached at call time rejects `StaleHandle`.
* Order: write ceiling, handle checks, THEN the buffer is taken (`Grant::*_with(.., make)`), so a
  rejected call leaves the guest buffer intact. After the buffer is taken, an I/O error or
  `Canceled` rejection does not give it back.
* **Lifetime invariant:** the region (and its `SharedRef`) is owned by the op future. A dropped
  future (cancel, `io.close()`, runtime teardown, `origine_api_detach_isolate`) leaves it in the
  loop's op state until the completion callback ran; teardown cancels then drains the loop
  before dropping the loop, so memory the kernel/worker may write is never freed early. V8 handles
  never enter tasks: Globals live in `Pending` (hook/`Wrap`).
* **Resolutions:** `fileReadInto`/`filePreadInto` resolve `{ bytes, buffer: ArrayBuffer }`:
  pinned = a NEW `ArrayBuffer` over the same store (`ArrayBuffer::with_backing_store`), copy or
  empty = the guest's own `ArrayBuffer`. `fileReadAlloc`/`filePreadAlloc` allocate a V8 store of
  `len` bytes (max `MAX_ALLOC_READ` = 256 MiB, else `FileTooLarge`), read once and resolve a
  `Uint8Array(0..bytes)` over it (`len` 0: empty array, no I/O).
* Legacy: `fileRead`/`filePread` still copy out (count result); `readAll` is host-provided (one
  copy out of a Rust `Vec`).
* Numbers: `u64` arguments/results are limited to 2^53 - 1 (`RangeError` / `TypeError`
  otherwise). Strings are copied (`to_rust_string_lossy`).

## Safety rules

* **Globals before detach.** Rust `v8::Global`s live only in `Pending` records (and hooks), never
  in tasks. `HostState::drop_all` (run by the detach function, by `Drop`) clears `pending` and the
  completion queue first, then cancels and drains runtimes, bounded (about 2000 iterations of
  5 ms), then destroys whatever is left with its loop (which fires the remaining callbacks). It
  must finish before `Runtime.destroy`, because V8 handles cannot be released after the isolate
  is gone. Tasks must not hold `Global`s for the same reason.
* **No unwinding into C++.** Every extern entry point is wrapped in `catch_unwind`:
  `run_sync` turns a panic into a thrown JS `Error("internal error in a native function")`;
  `origine_api_poll` returns -1; attach returns `false`; `configure`/`has_work` abort the process
  on a panic (`with_host`'s default is an abort, because there is no value to return); each
  completion closure is also run under `catch_unwind`. Async task bodies are polled under
  `Guarded` and a panic becomes `Errno(Unexpected)`; the runtime additionally catches task panics
  ([rt.md](../../origine_io/docs/rt.md)). The release profile keeps `panic = "unwind"`.
* **Single thread.** Everything touches V8 only on the isolate thread. The sole cross-thread
  entry is `origine_api_wake`.
* **Re-entrancy.** A native cannot hold `&mut HostState` and a V8 scope at the same time (running
  JS could re-enter another native); the macro lets a native take either the host state or a scope
  as parameters, and natives that need both fetch the state via `host_mut(scope)` between V8 calls.
* **No errno cell.** None of these natives touches the shared per-scope errno cell: failures
  reject promises (async) or throw `{ errno, name }` (sync, e.g. `io.create`).
* Lints: `unsafe` blocks need `// SAFETY:` ([workspace](../../../docs/README.md)).

## Building

Plain `cargo build -p origine_api` does not work: the vendored `v8` crate's `build.rs` needs the
`V8_ZIG_*` environment (`V8_ZIG_ARCHIVE`, `V8_ZIG_MIMALLOC`, `V8_ZIG_V8_ROOT`, `V8_ZIG_GN_OUT`,
`V8_ZIG_BINDING`) pointing at the exact V8 archive Zig builds and links. `rust/scripts/cargo-v8.sh`
sets them (plus `LIBCLANG_PATH` for bindgen on macOS when it is unset) and `cd`s to `rust/` so the
toolchain pin applies; `build.zig`'s `cargoCommand` calls it with the V8 dependency's paths.

* `zig build clippy` (also `-Dcargo-offline=true`): clippy `-D warnings --workspace --all-targets`
  with that environment. This is what `just check-rust` runs; do not run clippy on this crate with
  plain cargo.
* `zig build` builds the whole workspace as the staticlib `liborigine_native.a` and partial-links
  it so only `origine_*` symbols stay global (the archive carries its own Rust std, whose symbols
  would otherwise collide with V8's bundled Rust code).
* With `-Dprebuilt_v8_path` there is no GN output for bindgen, so the Rust workspace cannot be
  built (documented limitation in `build.zig`).
* The `v8` crate does not bundle libv8/mimalloc into this crate's rlib; the final Zig link
  supplies V8 exactly once.
* Crates without a V8 dependency build and test with plain cargo: `-p origine_api_core`,
  `-p origine_api_macros`, `-p origine_io` (see its testing doc), `-p origine_api_fs` (needs
  `ORIGINE_IO_LIB` outside Miri).

## Module map

```
src/lib.rs     C entry points (attach/detach/configure/poll/has_work/pollable/wake), OriginCfg
src/host.rs    HostState, Pending, runtimes, grants, draining, poll/turn
src/native.rs  run_sync, promise, Op, finish, ScopeKey, error_value, SideEffect, RawNative
src/decode.rs  FromJs, ArrayBufferArg, Handle (DirRef/FileRef, 2 args), Limit, property reads
src/encode.rs  IntoJs, object helpers, Stat/DirListing encodings
src/io.rs      native.io.create / close
src/fs.rs      native.fsAsync.*
src/sys.rs     poll(2) + the wake channel
```
