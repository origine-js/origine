# Natives (`native.io.*`, `native.fsAsync.*`, `native.net.*`)

Reference for the Rust natives registered into the Zig `native` table (see
[README.md](README.md) for how registration works). Code: `src/io.rs`, `src/fs.rs`, `src/net.rs`; fs semantics in
`rust/crates/origine_api_fs/src/lib.rs`. Planned/changing behaviour is specified in
[`docs/async-host-contract.md`](../../../../docs/async-host-contract.md); this page describes the
code as it is.

## Conventions

* JS name = the `path = "namespace.name"` of `#[native]` (by convention camelCase of the Rust fn
  without its prefix); there is no per-native C symbol, natives are reached through the registry.

  | JS | Rust fn / C symbol suffix |
  |---|---|
  | `native.io.create` | `io_create` |
  | `native.io.close` | `io_close` |
  | `native.fsAsync.request` | `fs_async_request` |
  | `native.fsAsync.<op>` | `fs_async_<snake_op>` (e.g. `openFile` -> `fs_async_open_file`) |

* All use `side_effect = "any"`.
* Argument errors are `TypeError("argument N: expected X")` thrown (sync) or an already-rejected
  promise (promise natives). Failures of the operation are the frozen `{ errno, name }` value
  (`origine_api_core::errno`); none touches the shared errno cell.
* Handles: `{fs, id}` handles are flattened into **two** JS arguments (`DirRef`/`FileRef` have
  `ARITY = 2`). Directory id 0 is the grant root. The sync twins in `src/api/fs.zig` take the same
  argument lists.
* Promise natives return the promise synchronously; the work is spawned on the runtime of the
  grant. Everything is settled by `origine_api_poll`.
* Ownership: a runtime or grant can only be used by the scope that created it (`BadHandle`
  otherwise); a grant belongs to the runtime it was created for and becomes unusable (`BadHandle`)
  when that runtime starts closing.

## `native.io`

| Native | Signature | Result |
|---|---|---|
| `create` | `(opts?: { backend?, entries? })` | frozen `{ kind: 'io', id, backend }` (sync). Throws `{errno}`: `Unsupported` (backend excluded or unavailable), `PermissionDenied` (runtime ceiling), `TypeError` for bad options. |
| `close` | `(id: u32)` | `Promise<void>`: cancels the runtime's ops (their promises reject `Canceled`), drains, releases its grants, destroys the loop. Rejects `BadHandle` for unknown/foreign/closing ids. |
| `sleep` | `(runtime: u32, token: u32, ms: number)` | `Promise<void>` resolving after a monotonic timeout. Finite delays from 0 through 2147483647 ms only; fractions allowed. Tokens are unique per JS runtime handle. Unknown/foreign/closed runtimes reject `BadHandle`. |
| `cancelTimer` | `(runtime: u32, token: u32)` | Boolean; cancels a pending timer task and backend timeout, rejects its promise with `Canceled`, and returns true. False for a settled/unknown token; throws `BadHandle` for an unknown/foreign/closed runtime. |
| `now` | `(runtime: u32)` | Monotonic milliseconds since host creation. Throws `BadHandle` for an unknown/foreign/closed runtime. |

Guest-facing timer and deadline helpers are documented in
[`src/js/docs/timers.md`](../../../../src/js/docs/timers.md).

## `native.fsAsync`

`request(ioId, root, access)` creates a grant; every other op takes `(fs, id)` handles. Order of
checks, like Zig: path validation (`InvalidInput` for NUL, `PermissionDenied` for `..`, absolute and `__oricache__`), then the grant's access (`PermissionDenied`: a mutation on a read-only grant, an observation on a write-only one), then
the handles (`BadHandle` unknown/closed, `StaleHandle` closing), then the OS. These checks run
synchronously, so a bad call returns a rejected promise without starting a task.

| Native | JS arguments | Resolves with |
|---|---|---|
| `request` | `ioId: u32, root: string, access: u32` | `{ id }` (the `fs` of the grant). `access` bits: 1 read, 2 write (3 both; anything else `InvalidInput`). Opens `root` relative to the embedder's fs root (the dup'd `fs_root_fd`) with the same lexical check as every path. A write request above the embedder's ceiling is rejected `PermissionDenied`, never downgraded. Rejects `BadHandle` (runtime), `PermissionDenied` (no async fs configured, above the ceiling, or `root` escapes), `InvalidInput`, or the OS error. The grant is registered when the promise settles; `Canceled` if its runtime vanished meanwhile. |
| `openFile` | `fs, dirId, path, bits: u32` | file id. `bits`: 1 write, 2 create, 4 truncate, 8 exclusive; any of the four needs a writable grant; `create` implies read+write; a read-only open of a directory fails `IsADirectory`; a read-only open (bits 0) needs a readable grant. Empty path -> `InvalidInput`. |
| `openDir` | `fs, dirId, path` | directory id (`""` opens the dir itself). |
| `stat` | `fs, dirId, path` | `[kind, size]` like `std::fs::metadata`: a final symlink is followed (a dangling one is `NotFound`; following can leave the root, confinement is lexical). Empty path = the directory. kind: 1 file, 2 directory, 3 symlink, 4 other. `FileTooLarge` above 2^53-1. Needs a readable grant, like `symlinkStat`, `readDir`, `fileStat` and every read. |
| `symlinkStat` | `fs, dirId, path` | as `stat` for the entry itself (`std::fs::symlink_metadata`): a final symlink is not followed. |
| `createDir` | `fs, dirId, path` | `undefined`. |
| `deleteFile` | `fs, dirId, path` | `undefined` (file or symlink). |
| `readDir` | `fs, dirId` | flat `[name0, kind0, name1, kind1, ...]` (names lossy UTF-8, OS order, no `.`/`..`). |
| `readAll` | `fs, fileId, limit` | `Uint8Array` from the current position to EOF or `limit` (`Limit`: non-negative number or `Infinity`); `FileTooLarge` beyond 256 MiB (`MAX_READ_BYTES`). Hitting `limit` is not an error. |
| `writeAll` | `fs, fileId, data` | `undefined`; writes all of `data` at the current position. Always COPIES `data` at call time and never touches the guest's buffer (`StaleHandle` if it is already detached). See README. |
| `writeMoveAll` | `fs, fileId, data` | as `writeAll` but TRANSFERS: `data`'s whole ArrayBuffer is pinned and DETACHED and written in place. `Unsupported`, buffer untouched, when it cannot be detached (shared, resizable, wasm memory): never a silent copy. An empty window detaches nothing. |
| `close` | `fs, fileId` | `undefined`; waits for in-flight ops on the file, then closes. |
| `closeDir` | `fs, dirId` | `undefined`; the root (id 0) cannot be closed (`BadHandle`). |
| `createDirPath` | `fs, dirId, path` | `mkdir -p`; path must not name the root. |
| `deleteDir` | `fs, dirId, path` | removes an empty directory; not the root. |
| `deleteTree` | `fs, dirId, path` | removes a file/symlink or a directory tree; a missing path is not an error. Uses `Dir::remove_dir_all` (bounded concurrency 16 per level; runs on the grant's runtime). |
| `rename` | `fs, dirId, old, newFs, newDirId, new` | `undefined`; both handles must be of the same grant (`newFs == fs`) else `BadHandle`; neither path may name the root. |
| `fileStat` | `fs, fileId` | `[kind, size]`. |
| `fileRead` | `fs, fileId, buffer` | byte count (0 = EOF); reads `buffer.length` bytes at the current position, copied into `buffer` at completion (`StaleHandle` if it was detached/shrunk meanwhile). |
| `filePread` | `fs, fileId, buffer, offset: u64` | as `fileRead` at `offset`. |
| `fileWrite` | `fs, fileId, data` | bytes written by one `write` (may be partial; `0` for empty data). Copies like `writeAll`. |
| `fileWriteMove` | `fs, fileId, data` | as `fileWrite`, moving like `writeMoveAll`. |
| `filePwriteAll` | `fs, fileId, data, offset: u64` | `undefined`. Copies like `writeAll`. |
| `filePwriteMoveAll` | `fs, fileId, data, offset: u64` | as `filePwriteAll`, moving like `writeMoveAll`. |
| `fileReadInto` | `fs, fileId, buffer` | `{ bytes, buffer: ArrayBuffer }`: one read at the position into `buffer`'s window; pinned = new ArrayBuffer over the same store (original dead), else the guest's own buffer after copy-out. |
| `filePreadInto` | `fs, fileId, buffer, offset: u64` | as `fileReadInto` at `offset`. |
| `fileReadAlloc` | `fs, fileId, len: u64` | `Uint8Array` of the bytes read (<= `len`, empty at EOF) over a V8-allocated buffer of `len` bytes (or an exact-size copy when at most half of a >= 4 KiB buffer was used); `len` > 256 MiB rejects `FileTooLarge`. |
| `filePreadAlloc` | `fs, fileId, len: u64, offset: u64` | as `fileReadAlloc` at `offset`. |
| `fileSetLength` | `fs, fileId, length: u64` | `undefined`. |
| `fileSync` | `fs, fileId` | `undefined`. |

Handle lifecycle (`origine_api_core::table`): an id stays reserved while any operation using it is
in flight; `close` marks the entry `Closing` immediately (new ops fail `StaleHandle`), waits for
the in-flight ones, closes the descriptor, then marks it `Closed` so the slot may be reused. Ids
are `1..` per table (files and directories have separate tables); a dropped (cancelled)
operation releases its guard.

Buffer semantics (pin/detach, copy fallback, lifetime invariant): [README](README.md#buffers-pinning-and-copy-fallback).
`fileRead`/`filePread` remain copying (they allocate `buffer.length` bytes per call).

## `net.*` (loopback TCP, `needs = "runtime"`)

Source: [`net.rs`](../src/net.rs). Sockets live in the Host's socket table, bound to the runtime they were created on and checked against the calling scope on every call (`BadHandle` otherwise). `accept`/`read`/`write` run on the runtime's loop; `connect` creates a raw non-blocking `socket(2)` and lets the loop's `connect` op finish the handshake, so nothing blocks the isolate thread. The destination is restricted to loopback: IP literals that are loopback are used as given, `localhost` is never resolved (RFC 6761: `connect` tries `127.0.0.1` then `::1`, `listen` binds `127.0.0.1`), anything else is `PermissionDenied`.

| native | args | result |
|---|---|---|
| `net.listen` | `io, host, port` | `{ id, port }` (sync); port 0 picks one |
| `net.accept` | `id` | Promise `{ id, port }` (port = the peer's) |
| `net.connect` | `io, host, port` | Promise `{ id, port }`; non-blocking (loop `connect`); `ConnectionRefused` etc. map through `errno_of` (for `localhost`, the last attempt's error) |
| `net.read` | `id, len` | Promise `Uint8Array` of 1..=`len` bytes (empty at end of stream); host-allocated like `fileReadAlloc` (same compaction of short reads, 256 MiB cap) |
| `net.readCopy` | `id, buffer` | Promise byte count (0 = end of stream) read once into the guest's buffer via a native scratch `Vec` copied at completion: nothing is detached or allocated in V8, so one buffer can be reused for every read |
| `net.readInto` | `id, buffer` | Promise `{ bytes, buffer }`: reads straight into the guest's buffer, which is detached meanwhile (pin protocol) and handed back as a new ArrayBuffer; `Unsupported` for a buffer that cannot be detached (checked before touching it); zero-copy, wins for large reads |
| `net.close` | `id` | sync; streams are shut down so pending reads finish with 0 bytes |
| `net.subscribe` | `id, dispatch` | sync; routes the socket's events to `dispatch(kind, a, b)` (0 data/length, 1 end, 2 error/errno, 3 drain, 4 connection/new id, port, 5 close); nothing is read yet |
| `net.start` | `id` | sync; starts the read (accept) pump task of a subscribed socket; it and its receive are not counted by `live_items`. A peer's FIN only delivers `end`: the stream stays open (writes work, `io.run` keeps waiting) until `net.close` |
| `net.take` | `id` | sync; ArrayBuffer lease of exactly the chunk's bytes, carved out of the slab they were received into (a V8 store from the isolate's allocator, so inside the sandbox) with a refcounted deleter; no copy, nothing else of the slab reachable (only inside the `data` dispatch, once per event) |
| `net.release` | `id, buffer` | sync; detaches a lease, dropping its hold on the slab (the slab is freed with its last lease) |
| `net.pause` | `id` | sync; parks the socket's events (in order) instead of dispatching them; idempotent |
| `net.resume` | `id` | sync; puts the parked events back in front of the host queue; idempotent |
| `net.directWrite` | `id, data` | sync byte count; one non-blocking write on the isolate thread, 0 when it would block or the outbox is busy; `BrokenPipe` after `net.end` |
| `net.put` | `id, data, max` | sync byte count; idle outbox: tries the kernel first, then copies the rest (at most `max` bytes) into the outbox flushed by a writer task; busy: copies at most `max` bytes. A write error throws its errno and the socket emits `error` and closes |
| `net.queued` | `id` | sync byte count waiting in the outbox |
| `net.flushed` | `id` | Promise<void> resolving once every byte accepted so far reached the kernel; rejects with the outbox's errno (`Canceled` if the socket closed first) |
| `net.end` | `id` | sync; no more writes, the FIN goes out once the outbox is empty; idempotent |
| `io.run` | `io` | Promise<void> resolving once every resumed subscription of the runtime has delivered `close` |

An operation in flight holds an `Rc<Socket>`, so closing never frees a descriptor under a running `recv`. A pending `accept` keeps its listener open until the runtime closes. The guest surface (the `Handle`/`Server`/`Socket` classes) is in [`src/js/docs/net.md`](../../../../src/js/docs/net.md).

## Adding a native

1. Write the fn in `src/` with `#[native(side_effect = "...", path = "ns.name"[, needs = "runtime" | "async_fs"][, promise])]`
   ([macro reference](../../origine_api_macros/docs/README.md)). Async natives return an
   [`Op`](../src/native.rs) (`Op::new(runtime, future)`, `Op::reading(...)`, `.with_hook(..)`) or
   `Result<Op, E>`; the future's output must be `Result<T, E>` with `T: IntoJs`, `E: Into<NativeError>`.
2. Add `<module>::NATIVE_<FN_NAME>,` to `NATIVES` in `src/registry.rs` (Zig installs the registry; the
   JS glue must use the same `native.<namespace>.<name>`; `just check-contracts` verifies both).
3. Keep V8-free logic in `origine_api_core` / `origine_api_fs` so Miri covers it.
