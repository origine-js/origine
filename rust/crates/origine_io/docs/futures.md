# Op futures (`origine_io` crate root)

Source: `src/lib.rs` (futures, `Loop`), `src/sys.rs` (FFI), `src/fs/at.rs` (dirfd-relative ops).

## Loop, LoopHandle, thread rules

| Type | Threads | Notes |
|---|---|---|
| `Loop` | `!Send`, `Clone` (an `Rc<Inner>`) | owns one `oio_loop`. Submitting ops, polling their futures, `run`, `active`, `caps`, `pollable` and dropping the last clone all happen on the driving thread. |
| `LoopHandle` (`Loop::handle()`) | `Send + Sync`, `Clone` | only `wake()` and `post(f)`. Both are no-ops/errors after the loop is gone. |
| `OpFuture<T>` | `!Send` (holds an `Rc` to the loop) | |

`Loop::wake` is a convenience for the same call on the loop's own thread. `LoopHandle::post(f)`
runs `f: FnOnce() + Send + 'static` on the loop thread inside `run`; after the loop was destroyed
it returns `ErrorKind::BrokenPipe` ("loop destroyed"). Posts still queued when the loop is
dropped are run by `oio_loop_destroy` (test `post_runs_on_loop_drop`).

A `LoopHandle` shares a `Mutex<Option<LoopPtr>>` with the loop. `wake`/`post` hold the mutex while
they call into C; `Inner::drop` clears the pointer under the same mutex before `oio_loop_destroy`,
so a handle on another thread can never touch a destroyed loop.

`Loop::new(Options { backend, entries })`: `Backend::{Auto, Uring, KqueueGcd, Iocp, Threaded}` map
to the C backend numbers 0..4; unsupported backends fail with the errno from `oio_loop_create`
(for example `ENOSYS`).

## Owned-buffer model

Ops take buffers by value and hand them back with the result:

```rust
pub type BufResult<T, B = Vec<u8>> = (io::Result<T>, B);

let (res, buf) = lp.read(fd, vec![0; 4096], Some(0)).await;   // BufResult<usize>
let n = res?;
let data = &buf[..n];
```

Why: the loop completes ops asynchronously and may still be reading or writing the memory after
the future that started the op was dropped. A borrowed `&mut [u8]` cannot promise to stay valid;
an owned buffer can, because the op keeps it alive. (This is the tokio-uring design.)

### `IoBuf` / `IoBufMut`

The buffer is any `B: IoBuf` (sources: `write`, `send`, `writev`) or `B: IoBufMut` (sinks: `read`,
`recv`, `readv`), `src/buf.rs`:

```rust
pub unsafe trait IoBuf: Unpin + 'static {
    fn stable_ptr(&self) -> *const u8;   // same address on every call while the value lives
    fn bytes_init(&self) -> usize;       // what a write sends
    fn bytes_total(&self) -> usize;      // what a read may fill
}
pub unsafe trait IoBufMut: IoBuf {
    fn stable_mut_ptr(&mut self) -> *mut u8;
    unsafe fn set_init(&mut self, pos: usize);   // afterwards bytes_init() >= pos
}
```

The `unsafe` contract: the pointer stays valid for the stated lengths and does not change while
the value is alive (moving the handle, like a `Vec` struct, is fine; the bytes must not move), and
the kernel or a worker thread may access the bytes through the raw pointer while the op is in
flight. `'static + Unpin` because a dropped pending future leaves the buffer in the op state,
which owns it as a type-erased `Box<dyn Any>` until the completion callback, then drops it.
`take_owned::<B>()` gives it back typed with the result.

Implemented for: `Vec<u8>` (window = `len()`, *not* the capacity: `read` fills `len()` bytes
exactly like before, pass `vec![0; n]`; `write` sends `len()`; `set_init` is a no-op), `Box<[u8]>`
(IoBuf + IoBufMut), `&'static [u8]` and `String` (IoBuf only), and
**`RawRegion`**: caller-pinned memory.

```rust
// SAFETY: ptr..ptr+len stays valid until `owner` drops, is exclusively ours for the op
// (e.g. a detached V8 ArrayBuffer), and its address is stable.
let region = unsafe { RawRegion::new(ptr, len, Box::new(owner)) };   // all `len` bytes init
let region = unsafe { RawRegion::new_uninit(ptr, len, owner) };      // bytes_init == 0
let (res, region) = lp.read(fd, region, Some(0)).await;              // region.bytes_init() raised
let owner = region.into_owner();                                      // dropping frees the memory
```

`RawRegion` is `!Send` (`NonNull` + `Box<dyn Any>`): like the op futures it lives on the loop
thread; only its address reaches the kernel/worker. Cancel-on-drop applies unchanged: a dropped
pending future keeps the region (and so its `owner`) alive until the completion callback; the
callback drops it. The `owner`'s `Drop` therefore runs after the op finished, never during.

* `read`/`recv`/`readv` fill the buffer's `bytes_total()` bytes; on success `set_init` is called
  with the high-water mark of what was written (BYOB reads into `RawRegion::new_uninit` learn how
  much is initialized from `bytes_init()` afterwards).
* `read_range(fd, buf, start, off)` reads into `buf[start..bytes_total()]` and calls
  `set_init(start + n)`; `write_range(fd, buf, start, off)` writes `buf[start..bytes_init()]`
  (no copy: pointer + offset). `start` past the end fails with `EINVAL` and returns the buffer.
  `File::write_all` loops `write_range` for partial writes.
* `write`/`send` write the initialized bytes; the result may be less (partial write).
* `readv`/`writev` take `Vec<B>` and return `(io::Result<usize>, Vec<B>)`.
* Offsets are `Option<u64>`: `None` = current file position (`-1` in the C ABI), `Some(o)` =
  `pread`/`pwrite` style. Offsets above `i64::MAX` wrap (`as i64`); fs callers stay far below.
* `futex_wait`/`futex_wake` take an `Arc<AtomicU32>` which the op state keeps alive.
* Paths are copied into a NUL-terminated `Vec<u8>` owned by the op (`cpath`); a path with an
  interior NUL fails immediately with `EINVAL` (`InvalidInput`).

## Op memory, ownership and the abandon states

Each submitted op has an `OpState` on the heap (`Box::into_raw`, owned by the future). It holds
the buffers, paths, the `Waker` and two *separate* heap allocations for the C-visible `oio_op`
and `oio_stat` (so a Rust `&mut OpState` never aliases memory C holds a pointer to). The
address of all of these is stable from submit until the completion callback ran.

State machine (flags `completed`, `abandoned` on `OpState`):

```
submit ──► in flight ──callback──► completed ──poll ready──► future drops state (freed)
               │                       ▲
               │ future dropped        │ (poll after completion is a bug: assert)
               ▼
          abandoned ──callback──► callback frees the state
```

* **Callback (`trampoline`)**: runs on the loop thread. If `abandoned`, it frees the state and
  returns. Otherwise it stores the result, sets `completed`, takes the waker and calls `wake()`
  *after* the last use of the state (waking can run arbitrary executor code).
* **Poll**: if a result is stored, calls the op's `map` fn (turns `-errno`/value and the owned
  buffers into the output) and returns `Ready`. Otherwise registers the waker
  (`will_wake` avoids clones) and returns `Pending`.
* **Drop of a pending future (cancel-on-drop)**: sets `abandoned`, drops the waker, then calls
  `oio_cancel(loop, op)`. The op's memory (buffers included) is *not* freed here: the callback
  frees it later, so a kernel/worker thread never writes into freed memory. `st` is not touched
  after `oio_cancel`, because the callback may run synchronously inside it. A cancelled op usually
  completes with `-ECANCELED` (its result is simply discarded); cancel is advisory, and the
  callback always runs exactly once.
* **Drop of a completed future**: nothing is in flight, the state is freed immediately.
* **Dropping the `Loop`** (last clone): `oio_loop_destroy` cancels outstanding ops, runs their
  callbacks (which free abandoned states) and pending posts, then frees the loop. Blocked
  syscalls that cannot be interrupted (accept/recv/futex_wait on the threaded backend) make
  destroy wait. Every `OpFuture` holds an `Rc<Inner>`, so no future outlives its loop.
* **Failed submit**: if the C call returns `< 0` the state records that result and the future
  resolves with it on first poll (no callback will come).
* **Detached close** (`close_detached`, used by `Drop` of `Dir`/`File`): a state born
  `abandoned`; the callback frees it. Nothing is awaited or cancelled.

Consequences to remember:

* A dropped op may still *execute* (a write that was already submitted can land). Cancellation
  frees memory safely; it does not undo side effects. A cancelled `close` may leak the descriptor.
* `Loop::active()` still counts a cancelled op until its callback ran; drain with `run(NoWait)`
  (the runtime does this in `Drop`, `origine_api` while a runtime is draining).

## Errors

All results are plain `io::Error`. A negative C result `-n` becomes
`io::Error::from_raw_os_error(n)`, so `kind()` is std's mapping (`NotFound`, `AlreadyExists`,
`DirectoryNotEmpty`, ...). Match on `ErrorKind`, not on numbers. Special cases:

* `Loop::timeout`: expiry reported as `-ETIME` by some backends is success (`Ok(())`).
* `Loop::readdir`: `ERANGE` (34 on Linux and macOS), reported when the *first* pending entry does
  not fit in the buffer, is rewritten to `erange_error()`, an `io::Error` with kind
  `InvalidInput` and message containing `(ERANGE)`, because std has no stable kind for `ERANGE`.
  Test with `is_erange(&e)`. Use buffers of at least 4096 bytes. On any error, `DirRead::cookie`
  is the cookie that was passed in.
* `Loop::accept`: the peer address is truncated to the size C reported (`aux`).
* Argument errors that never reach C (NUL in a path) resolve as `EINVAL`.

## readdir and `parse_dir_entries`

```rust
let r = lp.readdir(dirfd, vec![0; 8192], cookie).await;   // DirRead { result, buf, cookie }
let n = r.result?;                       // bytes written; 0 = end of directory
for e in parse_dir_entries(&r.buf[..n]) { /* DirEntryRaw { kind: FileKind, name: &[u8] } */ }
let cookie = r.cookie;                   // pass to the next call
```

Packed format: `{kind u8, name_len u16 LE, name bytes}` per entry; kind `1` file, `2` directory,
`3` symlink, anything else `FileKind::Other`. `parse_dir_entries` never panics: a truncated
trailing entry ends the iterator. The cookie is the directory fd's position, so run only one
`readdir` at a time on an fd, and dropping a refill mid-flight may skip entries (see
[fs.md](fs.md)).

## `Loop::*` ops and their C functions

Path-taking `Loop` ops are relative to the current directory (`OIO_FDCWD`) or absolute. Directory
relative variants exist only crate-privately in `src/fs/at.rs` and are what `fs::Dir` uses.

| `Loop` method | Output | C function / op kind |
|---|---|---|
| `nop()` | `io::Result<()>` | `oio_nop` |
| `read(fd, B: IoBufMut, Option<u64>)` | `BufResult<usize, B>` | `oio_read` |
| `read_range(fd, B: IoBufMut, start, Option<u64>)` | `BufResult<usize, B>` | `oio_read` |
| `write(fd, B: IoBuf, Option<u64>)` | `BufResult<usize, B>` | `oio_write` |
| `write_range(fd, B: IoBuf, start, Option<u64>)` | `BufResult<usize, B>` | `oio_write` |
| `readv(fd, Vec<B: IoBufMut>, Option<u64>)` | `(io::Result<usize>, Vec<B>)` | `oio_readv` |
| `writev(fd, Vec<B: IoBuf>, Option<u64>)` | same | `oio_writev` |
| `open(path, flags, mode)` | `io::Result<Fd>` | `oio_open` (`FDCWD`) |
| `close(fd)` | `io::Result<()>` | `oio_close` |
| `fstat(fd)` | `io::Result<Stat>` | `oio_fstat` |
| `stat_at(path, nofollow)` | `io::Result<Stat>` | `oio_stat_at` (`FDCWD`) |
| `mkdir(path, mode)` | `io::Result<()>` | `oio_mkdir` |
| `unlink(path, rmdir)` | `io::Result<()>` | `oio_unlink` (`rmdir` = remove empty dir) |
| `rename(from, to)` | `io::Result<()>` | `oio_rename` |
| `link(old, new)` | `io::Result<()>` | `oio_link` (hard link) |
| `fsync(fd, datasync)` | `io::Result<()>` | `oio_fsync` |
| `fallocate(fd, offset, len, keep_size)` | `io::Result<()>` | `oio_fallocate` (`OIO_FALLOC_KEEP_SIZE`) |
| `ftruncate(fd, len)` | `io::Result<()>` | `oio_ftruncate` |
| `sendfile(out, in, Option<u64>, count)` | `io::Result<usize>` | `oio_sendfile` |
| `readdir(dirfd, Vec<u8>, cookie)` | `DirRead` | `oio_readdir` |
| `timeout(Duration)` | `io::Result<()>` | `oio_timeout` (ns, saturating to `u64::MAX`) |
| `send(fd, B: IoBuf, msg_flags)` | `BufResult<usize, B>` | `oio_send` |
| `recv(fd, B: IoBufMut, msg_flags)` | `BufResult<usize, B>` | `oio_recv` |
| `connect(fd, sockaddr: Vec<u8>)` | `io::Result<()>` | `oio_connect` |
| `accept(fd, addr_cap)` | `io::Result<(Fd, Vec<u8>)>` | `oio_accept` |
| `futex_wait(Arc<AtomicU32>, expected, Option<Duration>)` | `io::Result<()>` | `oio_futex_wait` (`EAGAIN` if the word already differs, `ETIMEDOUT`) |
| `futex_wake(Arc<AtomicU32>, count)` | `io::Result<u32>` | `oio_futex_wake` (number woken) |

`oio_sendmsg` / `oio_recvmsg` are declared in `sys.rs` but have no safe wrapper yet. Open flags
live in `origine_io::flags` (`RDONLY`, `WRONLY`, `RDWR`, `CREAT`, `TRUNC`, `APPEND`, `EXCL`,
`DIRECTORY`). `Loop::caps()` returns a bit set (`CAP_NOP`, `CAP_FILE_IO`, `CAP_TIMEOUT`,
`CAP_CANCEL`, `CAP_POLLABLE`, `CAP_VECTORED`, `CAP_SOCKETS`, `CAP_FUTEX`, `CAP_SENDFILE`,
`CAP_FALLOCATE`, `CAP_LINK`, `CAP_SYNC`, `CAP_READDIR`, `CAP_FTRUNCATE`); an op a backend lacks is
expected to fail with `ENOSYS` (the Miri mock does this for sockets). Per-kind field conventions of the underlying `Op` are in
[`src/io/docs/ops.md`](../../../../src/io/docs/ops.md); the C functions in
[c-api.md](../../../../src/io/docs/c-api.md).

`Stat { size: u64, mode: u32, kind: FileKind }`, `FileKind::{Other, File, Directory, Symlink}`.

## Helpers

* `block_on(&Loop, fut)`: polls `fut` and runs the loop between polls (`Once`, or `NoWait` if the
  waker fired). For tests and simple programs. Panics if `run` fails.
* `join(a, b)`: poll two futures concurrently, return both outputs (also in `rt`; the same code).
* Higher level scheduling: [rt.md](rt.md).
