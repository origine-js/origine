# Natives (`native.io.*`, `native.fsAsync.*`)

Reference for the Rust natives registered into the Zig `native` table (see
[README.md](README.md) for how registration works). Code: `src/io.rs`, `src/fs.rs`; fs semantics in
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
| `create` | `(opts?: { backend?, entries? })` | frozen `{ kind: 'io', id, backend }` (sync). Throws `{errno}`: `Unsupported` (backend excluded or unavailable), `AccessDenied` (runtime ceiling), `TypeError` for bad options. |
| `close` | `(id: u32)` | `Promise<void>`: cancels the runtime's ops (their promises reject `Canceled`), drains, releases its grants, destroys the loop. Rejects `BadHandle` for unknown/foreign/closing ids. |

## `native.fsAsync`

`request(ioId, root, write)` creates a grant; every other op takes `(fs, id)` handles. Order of
checks, like Zig: path validation (`InvalidPath`), then the write ceiling (`AccessDenied`), then
the handles (`BadHandle` unknown/closed, `StaleHandle` closing), then the OS. These checks run
synchronously, so a bad call returns a rejected promise without starting a task.

| Native | JS arguments | Resolves with |
|---|---|---|
| `request` | `ioId: u32, root: string, write: bool` | `{ id }` (the `fs` of the grant). Opens `root` relative to the embedder's fs root (the dup'd `fs_root_fd`) with `sanitize`; effective write = embedder write && requested write. Rejects `BadHandle` (runtime), `AccessDenied` (no async fs configured), `InvalidPath`, or the OS error. The grant is registered when the promise settles; `Canceled` if its runtime vanished meanwhile. |
| `openFile` | `fs, dirId, path, bits: u32` | file id. `bits`: 1 write, 2 create, 4 truncate, 8 exclusive; any of the four needs a writable grant; `create` implies read+write; a read-only open of a directory fails `IsDir`. Empty path -> `InvalidPath`. |
| `openDir` | `fs, dirId, path` | directory id (`""` opens the dir itself). |
| `stat` | `fs, dirId, path` | `[kind, size]` of the entry itself (symlinks not followed). kind: 1 file, 2 directory, 3 symlink, 4 other. `FileTooBig` above 2^53-1. |
| `createDir` | `fs, dirId, path` | `undefined`. |
| `deleteFile` | `fs, dirId, path` | `undefined` (file or symlink). |
| `readDir` | `fs, dirId` | flat `[name0, kind0, name1, kind1, ...]` (names lossy UTF-8, OS order, no `.`/`..`). |
| `readAll` | `fs, fileId, limit` | `Uint8Array` from the current position to EOF or `limit` (`Limit`: non-negative number or `Infinity`); `FileTooBig` beyond 256 MiB (`MAX_READ_BYTES`). Hitting `limit` is not an error. |
| `writeAll` | `fs, fileId, data` | `undefined`; writes all of `data` at the current position. `data`'s buffer is pinned and DETACHED when eligible (else copied), see README. |
| `close` | `fs, fileId` | `undefined`; waits for in-flight ops on the file, then closes. |
| `closeDir` | `fs, dirId` | `undefined`; the root (id 0) cannot be closed (`BadHandle`). |
| `createDirPath` | `fs, dirId, path` | `mkdir -p`; path must not name the root. |
| `deleteDir` | `fs, dirId, path` | removes an empty directory; not the root. |
| `deleteTree` | `fs, dirId, path` | removes a file/symlink or a directory tree; a missing path is not an error. Uses `Dir::remove_dir_all` (bounded concurrency 16 per level; runs on the grant's runtime). |
| `rename` | `fs, dirId, old, newFs, newDirId, new` | `undefined`; both handles must be of the same grant (`newFs == fs`) else `BadHandle`; neither path may name the root. |
| `fileStat` | `fs, fileId` | `[kind, size]`. |
| `fileRead` | `fs, fileId, buffer` | byte count (0 = EOF); reads `buffer.length` bytes at the current position, copied into `buffer` at completion (`StaleHandle` if it was detached/shrunk meanwhile). |
| `filePread` | `fs, fileId, buffer, offset: u64` | as `fileRead` at `offset`. |
| `fileWrite` | `fs, fileId, data` | bytes written by one `write` (may be partial; `0` for empty data). Pins/detaches like `writeAll`. |
| `filePwriteAll` | `fs, fileId, data, offset: u64` | `undefined`. Pins/detaches like `writeAll`. |
| `fileReadInto` | `fs, fileId, buffer` | `{ bytes, buffer: ArrayBuffer }`: one read at the position into `buffer`'s window; pinned = new ArrayBuffer over the same store (original dead), else the guest's own buffer after copy-out. |
| `filePreadInto` | `fs, fileId, buffer, offset: u64` | as `fileReadInto` at `offset`. |
| `fileReadAlloc` | `fs, fileId, len: u64` | `Uint8Array` of the bytes read (<= `len`, empty at EOF) over a V8-allocated buffer of `len` bytes (or an exact-size copy when at most half of a >= 4 KiB buffer was used); `len` > 256 MiB rejects `FileTooBig`. |
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

Source: [`net.rs`](../src/net.rs). Sockets live in the Host's socket table, bound to the runtime they were created on and checked against the calling scope on every call (`BadHandle` otherwise). `accept`/`read`/`write` run on the runtime's loop; `connect` is a blocking `std` connect, acceptable only because the destination is restricted to loopback (`127.0.0.1`, `localhost`, `::1`; anything else is `AccessDenied`).

| native | args | result |
|---|---|---|
| `net.listen` | `io, host, port` | `{ id, port }` (sync); port 0 picks one |
| `net.accept` | `id` | Promise `{ id, port }` (port = the peer's) |
| `net.connect` | `io, host, port` | Promise `{ id, port }` |
| `net.read` | `id, len` | Promise `Uint8Array` of 1..=`len` bytes (empty at end of stream); host-allocated like `fileReadAlloc` (same compaction of short reads, 256 MiB cap) |
| `net.readCopy` | `id, buffer` | Promise byte count (0 = end of stream) read once into the guest's buffer via a native scratch `Vec` copied at completion: nothing is detached or allocated in V8, so one buffer can be reused for every read |
| `net.readInto` | `id, buffer` | Promise `{ bytes, buffer }`: reads straight into the guest's buffer, which is detached meanwhile (pin protocol) and handed back as a new ArrayBuffer; `Unsupported` for a buffer that cannot be detached (checked before touching it); zero-copy, wins for large reads |
| `net.write` | `id, data` | Promise byte count; copies `data` and sends all of it |
| `net.close` | `id` | sync; streams are shut down so pending reads finish with 0 bytes |

An operation in flight holds an `Rc<Socket>`, so closing never frees a descriptor under a running `recv`. A pending `accept` keeps its listener open until the runtime closes. The guest surface (the `Handle`/`Server`/`Socket` classes) is in [`src/js/docs/net.md`](../../../../src/js/docs/net.md).

## Adding a native

1. Write the fn in `src/` with `#[native(side_effect = "...", path = "ns.name"[, needs = "runtime" | "async_fs"][, promise])]`
   ([macro reference](../../origine_api_macros/docs/README.md)). Async natives return an
   [`Op`](../src/native.rs) (`Op::new(runtime, future)`, `Op::reading(...)`, `.with_hook(..)`) or
   `Result<Op, E>`; the future's output must be `Result<T, E>` with `T: IntoJs`, `E: Into<NativeError>`.
2. Add `<module>::NATIVE_<FN_NAME>,` to `NATIVES` in `src/registry.rs` (Zig installs the registry; the
   JS glue must use the same `native.<namespace>.<name>`; `just check-contracts` verifies both).
3. Keep V8-free logic in `origine_api_core` / `origine_api_fs` so Miri covers it.
