# Async host contract

The agreement between the Rust side (`rust/crates/origine_api*`) and the Zig/JS side (`src/api`,
`src/js`, `build.zig`) for asynchronous host work: `api.io` runtimes, async `api.fs`, `api.net` and
timers. Both sides code against this file. The guest-facing design is in
[api-design.md](api-design.md); the native table is in
[natives.md](../rust/crates/origine_api/docs/natives.md); the generated or checked parts of the
C ABI are described in [contracts.md](contracts.md).

The sections below are the original contract (async runtimes and copying fs natives), followed by
the zero-copy buffer rules that were added later. `api.net` and the `io` timers (`now`, `sleep`,
`cancelTimer`) follow the same patterns; their natives are listed in natives.md.

## Guest API (JS)
```js
const sync = api.fs.requestSync({ root, write });           // unchanged semantics (std.Io, errno cell); returns the sync cap
const io = api.io.create({ backend: 'auto', entries: 256 }); // exists (spike): frozen { kind: 'io', id, backend }
const async = await api.fs.requestAsync({ io, root, write }); // rejects BadHandle/AccessDenied/Unsupported
await io.close();                                           // Promise<void>: cancels in-flight ops, destroys the runtime
```
`api.fs.request` is removed. `api.fs.narrow` keeps `{root, write}` plus `{sync, async}` switches. `api.io.narrow({ backends, maxRuntimes })`
only narrows what `create` may do (embedder ceiling = `Config.runtime`). Handles are frozen data, not transferable across scopes.

## Errno additions (numbers fixed here; Zig `src/api/errno.zig` enum and Rust `origine_api_core::errno` must match)
`Canceled=14, TimedOut=15, WouldBlock=16, ConnectionRefused=17, ConnectionReset=18, BrokenPipe=19, AddressInUse=20, NotConnected=21`.
io::ErrorKind mapping in Rust (others stay 255): `ErrorKind::TimedOut->15`, `WouldBlock->16`,
`ConnectionRefused->17`, `ConnectionReset->18`, `BrokenPipe->19`, `AddrInUse->20`, `NotConnected->21`; `-ECANCELED` (raw 125 linux/89 macos) ->14.

## Natives (registered in the `native` table; JS glue calls them)
Rust natives (`#[native]`, `rust/crates/origine_api`), all take plain JS values, none touch the shared errno cell; failures reject (promise natives)
or throw `{errno,name}` (sync natives):
- `native.io.create(opts) -> {kind,id,backend}` (sync; creates `io::Loop` + `rt::Runtime` inside HostState; enforces `Config.runtime` ceiling)
- `native.io.close(ioId) -> Promise<void>`
- `native.fsAsync.request(ioId, root: string, write: bool) -> Promise<{ id: u32 }>` (opens `root` relative to the embedder's fs root dir (ceiling) as a `fs::Dir`, registers a Grant bound to that runtime)
- `native.fsAsync.<op>(...)` -> Promise, with EXACTLY the argument lists of the sync natives in `src/api/fs.zig` (refs flattened as `fs, id` pairs;
  `bits`, `Limit` as numbers): `openFile openDir stat createDir deleteFile readDir readAll writeAll close closeDir createDirPath deleteDir
  deleteTree rename fileStat fileRead filePread fileWrite filePwriteAll fileSetLength fileSync`. Results identical to the sync results
  (file id / dir id / `[kind,size]` / flat `[name,kind,...]` / `Uint8Array` / count / undefined). Base buffer semantics: COPY (writes copy the
  guest bytes at call time; reads copy into the guest buffer at completion if it is still attached, else reject). Pin+detach/BYOB is described under "Zero-copy buffers" below.
- Handle tables live in Rust per Grant: ids are per-fs-id like sync (`DirRef{fs,id}`, id 0 = grant root), not reused while an op is in flight (`in_flight`, `closing`; use after close rejects `StaleHandle`/`BadHandle`).
- Ceiling checks mirror Zig (`write` ceiling, `cleanPath` rules are `origine_io::fs::sanitize`).

## C ABI between Zig Host and Rust (symbols exported by the Rust staticlib)

The authoritative declaration is `rust/crates/origine_api/include/origine_api.h` (structs `origine_api_cfg`,
`origine_api_native`, the entry points and the natives registry `origine_api_natives_count/get`); the Zig side
(`src/api/api_abi.zig`) and the Rust side (`abi_gen.rs`) are checked against it (docs/contracts.md, surfaces B and C).
The sketch below is explanatory only.
```
// Called once per Host after attach (spike: origine_api_attach_isolate). Ceiling and limits.
struct OriginCfg { uint32_t max_runtimes; uint32_t backends_mask /*bit per io backend kind 1..4*/; uint32_t default_entries;
                   int32_t fs_root_fd /* dup'd by Rust; -1 = no fs */; uint8_t fs_write; uint8_t fs_async; };
void    origine_api_configure(void *isolate, const OriginCfg *);
// Drive: wait for work and run it. block=false -> poll once without waiting. timeout_ns<0 -> wait indefinitely (still returns on wake()).
// Waits with poll(2) on every runtime's pollable fd + the wake fd, ticks the ready runtimes, settles completed promises (enters each task's saved
// context). Returns the number of live items (tasks + active ops across runtimes), or <0 on error.
int64_t origine_api_poll(void *isolate, uint8_t block, int64_t timeout_ns);
uint8_t origine_api_has_work(void *isolate);      // any runtime with live tasks/ops
int64_t origine_api_pollable(void *isolate);       // a single fd that becomes readable when origine_api_poll(block=0) would make progress; -1 if none
void    origine_api_wake(void *isolate);           // thread-safe: interrupts a blocking origine_api_poll (V8 platform tasks, embedder)
// Existing: origine_api_attach_isolate / origine_api_detach_isolate (detach cancels every runtime, drains until quiescent, drops all Globals).
```
Zig `Host.settle(promise)`: `loop { pumpPlatform; if settled break; if (!has_work && !platformHasWork) return Stalled; origine_api_poll(isolate, 1, timeout); rt.pump() }`.
`timeout` = the platform's next delayed-task deadline if any, else -1. After every `origine_api_poll` Zig runs `Runtime.pump()` (microtasks).
`Host.destroy`: `origine_api_detach_isolate` BEFORE freeing grants and `Runtime.destroy` (as today).

## Linking
The Rust runtime calls the `oio_*` C ABI (`src/io/c_api.zig`). The final executable, the test binary and the snapshot tool each link
`liborigine_io.a` (`src/io/lib.zig`, built by `build.zig`; its `comptime` reference to `@import("@io").c_api` keeps the `export fn`s).
Rust needs no link flags.

## Config (Zig)
`Config.runtime: ?RuntimeConfig = null` (`backends`, `max_runtimes`, `default_entries`); `Config.fs: ?FsConfig` gains `async: bool = true`.
`api.io` exists only when `Config.runtime != null`. `api.fs.requestAsync` requires `fs.async` and an `io`.

## Zero-copy buffers (Rust natives + JS glue; both sides code against this)
Rules (guest buffers = `ArrayBuffer` or any view over one; `view` regions are captured as (byteOffset, byteLength) BEFORE detaching):
- **Eligibility for pinning:** `!backing_store.is_shared() && !is_resizable_by_user_javascript() && ab.is_detachable()` and, after `ab.detach(None)`, `was_detached()`/`byte_length()==0` is confirmed. Otherwise COPY (copy at call time for writes; host buffer + copy-out for reads). Never trust a length the guest can change.
- **Writes** (`fileWrite`, `filePwriteAll`, `writeAll`, `writeAll`-style ops): the guest's ArrayBuffer is DETACHED (transferred) when eligible, the host writes straight from the pinned store (`SharedRef<BackingStore>` kept in the pending entry, memory accessed by the loop through raw `(ptr,len)` wrapped in `origine_io::RawRegion`); results unchanged (count / undefined). After the call the guest's buffer and all its views are empty (documented). Non-eligible buffers are copied and stay usable.
- **BYOB reads** (new natives): `fileReadInto(fs,id,buf)` and `filePreadInto(fs,id,buf,offset)` (`native.fsAsync.fileReadInto` / `filePreadInto`): the guest buffer is detached (if eligible) and read into directly; the promise resolves `{ bytes: number, buffer: ArrayBuffer }` where `buffer` is a NEW ArrayBuffer over the same backing store (pinned case) or the guest's own ArrayBuffer after copy-out (fallback case). The JS glue turns it into `{ bytes, buffer: <Uint8Array view with the original byteOffset/byteLength over that ArrayBuffer> }` for the guest. The original ArrayBuffer is dead after the call in the pinned case.
- **Host-provided reads** (new natives): `fileReadAlloc(fs,id,len)` and `filePreadAlloc(fs,id,len,offset)` (`..._file_read_alloc` / `_file_pread_alloc`): the host allocates a V8 `ArrayBuffer` of `len` bytes up front (sandbox: only V8-allocated memory), pins it, reads once, resolves a `Uint8Array` view of length `bytes` over that buffer (zero-copy, no trailing copy), except that a short read of a large request (<= half of a 4 KiB+ buffer used) is copied into an exact-size buffer so the unused capacity is not retained.
- The existing copying `fileRead`/`filePread` stay (count result, copy-out semantics) for compatibility; `readAll` stays host-provided (one copy out of the Rust Vec).
- Errors: `-ECANCELED`/`io.close()` with a pinned op in flight: the pending entry owns the `SharedRef`, memory stays valid until the loop callback has run; the promise rejects `Canceled` and nothing is resurrected. Zero-length buffers complete immediately without I/O. Offsets/lengths are bound-checked against the store size.
- Required test (no existing coverage): detach + re-wrap of a store obtained via `get_backing_store` under the V8 sandbox, and the guest's old views reading length 0 afterwards.
