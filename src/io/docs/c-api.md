# C API

Header: `src/io/include/origine_io.h`. Implementation: `src/io/c_api.zig` (`export fn oio_*`, a thin wrapper over `Loop` using `std.heap.c_allocator`). Semantics of each operation are in [ops.md](ops.md); this page covers lifetime, threading, errors, linking and embedding. Diagrams: [event-loop.md](event-loop.md). Rust bindings (`sys.rs`) mirror this header; see [`origine_io` docs](../../../rust/crates/origine_io/docs/README.md).

## Ownership and lifetime

- `oio_loop_create(const oio_options *options /* may be NULL */, oio_loop **out)` allocates a loop. `NULL` options means `{backend = auto, entries = 0}`. You own the loop until `oio_loop_destroy`.
- `oio_op` is caller-owned memory (`struct oio_op`, 160 bytes). It must stay alive and unmoved from the successful `oio_*` call until its callback has returned. Do not copy a submitted op, and do not touch `priv`. Embed it in your own request struct and recover the container from `op` in the callback (or use `op->user`).
- Before the first `oio_*` call on an op, `op->user` must be initialized (zero the struct with `memset`, then set `user`); every submit function rewrites all other fields and keeps `user`. After the callback the op may be reused or freed (the loop no longer references it).
- Everything an op points to (`buf`, paths, iovec arrays, `msghdr`, `sockaddr`, futex word, `oio_stat` out) must stay valid until the callback. Paths are UTF-8, NUL-terminated.
- A successful submit (return 0) guarantees exactly one callback, from inside `oio_loop_run` or `oio_loop_destroy`. A failed submit (negative return) leaves the op untouched by the loop and calls nothing.
- `oio_loop_destroy` cancels outstanding ops (callbacks receive `-ECANCELED`, or the real result if they had already finished), runs those callbacks and the still-pending posted functions, then frees the loop. It may block until uninterruptible syscalls return ([backends.md](backends.md#known-limitations)). Do not call `oio_loop_wake`/`oio_loop_post` after or concurrently with destroy, and do not destroy from inside a callback or posted function.
- Callbacks run on the thread inside `oio_loop_run` (or destroy). They may submit and cancel ops and call `wake`/`post`.

## Error convention

All functions that return `int` return `0` or a value `>= 0` on success and `-errno` on failure.

- `oio_loop_create`: `-ENOMEM` (allocation), `-ENOSYS` (backend not available on this OS, or `iocp`), otherwise `-EINVAL` (this includes failures to create the kernel resources).
- Submit functions and `oio_loop_post`: `-ENOMEM`, `-ENOSYS` (unsupported kind on io_uring), otherwise `-EINVAL` (invalid argument, full submission queue, resource exhaustion). Runtime failures of the operation itself are never reported here; they arrive as the callback's `result`.
- `oio_loop_run(loop, mode)`: returns the number of ops still active (>= 0), or `-EINVAL` for an unknown mode. Modes: `OIO_RUN_ONCE = 0` (block for at least one event: a completion, a wake or a posted function), `OIO_RUN_NOWAIT = 1`, `OIO_RUN_UNTIL_IDLE = 2` (run until no op is active; returns 0). `ONCE` with nothing active blocks until `oio_loop_wake` or `oio_loop_post`.
- `oio_cancel` returns 1 if the op was still outstanding and will complete, 0 otherwise; the callback runs either way (see [ops.md](ops.md#cancellation)).
- Callback `result`: `>= 0` or `-errno` (host errno values).

## Thread safety

| function | threads |
|---|---|
| `oio_loop_create` | any thread; the loop is then driven by whichever thread calls `oio_loop_run` |
| `oio_loop_run`, every submit function (`oio_nop`, `oio_open`, ...), `oio_cancel` | the loop thread only; never concurrently with each other |
| `oio_loop_destroy` | the loop thread, with no other call in progress or to follow |
| `oio_loop_wake`, `oio_loop_post` | **any thread**, while the loop is alive |
| `oio_loop_active` | loop thread only (a plain counter, not atomic) |
| `oio_loop_pollable`, `oio_loop_caps` | constants after creation; in practice readable from any thread |

`oio_loop_post(loop, void (*fn)(void *), void *ud)` queues `fn(ud)` to run on the loop thread during a later `oio_loop_run` (FIFO), and wakes a blocked run. Posts still pending at destroy are run by destroy. `oio_loop_wake` makes a blocked `ONCE` run return even if nothing completed (`wake` calls may coalesce).

## Types

```c
typedef intptr_t oio_fd;                 // descriptor, OIO_FDCWD = -1
typedef void (*oio_cb)(oio_op *op, int64_t result);

struct oio_op {            // Zig: op.Op, extern struct; offsets on LP64
  oio_cb cb;               //   0  (set by oio_* calls)
  void *user;              //   8  (set by you before submitting)
  int32_t kind;            //  16  enum oio_kind
  uint32_t flags;          //  20
  oio_fd fd, fd2;          //  24, 32
  int64_t offset;          //  40
  void *buf;               //  48
  size_t len;              //  56
  const char *path, *path2;//  64, 72
  uint64_t aux;            //  80
  int64_t result;          //  88
  void *priv[8];           //  96..160 backend scratch
};
typedef struct oio_options { uint32_t backend; uint32_t entries; } oio_options;  // 8 bytes
typedef struct oio_stat { uint64_t size; uint32_t mode; uint32_t kind; } oio_stat; // 16 bytes
typedef struct oio_iovec { void *base; size_t len; } oio_iovec;                    // 16 bytes
```

`enum oio_backend`: `OIO_BACKEND_AUTO = 0`, `URING = 1`, `KQUEUE_GCD = 2`, `IOCP = 3`, `THREADED = 4`. `enum oio_kind` values equal `op.Kind` (`OIO_NOP = 0` ... `OIO_FTRUNCATE = 26`). Capability bits `OIO_CAP_*` equal `backend.Caps`. Function list and field usage: [ops.md](ops.md#zig-helpers-and-c-functions).

## Linking

- The `oio_*` symbols are `export fn`s in `src/io/c_api.zig`. `src/io/io.zig` exposes the file as `pub const c_api` but does not export the symbols itself. `src/io/lib.zig` is the root of the static archive `liborigine_io.a`: its `comptime { _ = @import("@io").c_api; }` keeps the exports, and `build.zig` (`ioLibrary`) always builds it in ReleaseFast. Every program that links the Rust runtime (the shell, the test binary, the snapshot tool) links this archive exactly once.
- The Rust crates declare the functions as `extern "C"` (`rust/crates/origine_io/src/sys_gen.rs`, generated from the header) and leave them unresolved in their static library; the final Zig link resolves them against `liborigine_io.a`.
- For standalone Rust tests `rust/crates/origine_io/build.rs` (and `origine_api_fs`) links `liborigine_io.a` from the directory in `ORIGINE_IO_LIB` when that variable is set; see [testing.md](testing.md#rust-tests-against-the-zig-library). Under Miri the Rust crate substitutes a pure-Rust fake (`mock.rs`) instead.
- The library needs libc (`link_libc = true`); the io_uring backend uses raw syscalls, kqueue links libSystem's `dispatch_async_f`, `os_sync_*` are weak symbols.

## Embedding in a foreign loop

`intptr_t oio_loop_pollable(loop)` returns an OS handle, or `-1` if the backend has none (cap `OIO_CAP_POLLABLE` clear; all three current backends provide one). Pattern:

1. Add the handle to your poller (`poll`/`epoll`/`kqueue`) for readability.
2. When it becomes readable, call `oio_loop_run(loop, OIO_RUN_NOWAIT)`; callbacks and posted functions fire inside it.
3. After submitting new ops, call `oio_loop_run(loop, OIO_RUN_NOWAIT)` once as well (or schedule it): io_uring only hands queued SQEs to the kernel when polled, and kqueue/threaded complete some ops inline on a list that the next poll collects (`nop`, errors, `futex_wake` on kqueue).

What the handle is, per backend:

| backend | handle | becomes readable when |
|---|---|---|
| io_uring | the ring fd | the completion queue is non-empty (including the wake eventfd read and readdir worker completions) |
| kqueue+GCD | the kqueue fd | a kevent is pending: timer fired, socket ready, GCD worker finished, wake or post. Not for ops finished inline on the loop thread |
| threaded | read end of a self-pipe | a worker finished, `wake`, `post`, or an inline nop is pending; drained by `poll`. **Not on timer expiry** |

Use your own timer for outstanding `timeout` ops when the handle may not signal them (threaded). The Zig host does this kind of integration with `poll(2)` over every runtime's pollable fd (see [event-loop.md](event-loop.md), section 6).

## ABI stability

- `struct oio_op` is `extern struct` in Zig and a plain C struct in the header: **160 bytes on LP64, offsets as above**. The Rust bindings assert size 160 and the field offsets in `sys.rs`. Do not reorder or resize fields without bumping all consumers. `priv` is part of the layout, so a backend cannot grow its scratch space.
- `oio_options` (8 bytes), `oio_stat` (16), `oio_iovec` (16), the numeric values of `oio_kind`, `oio_backend`, `oio_run_mode`, `OIO_CAP_*` and `OIO_O_*`/`OIO_FALLOC_*` are ABI.
- New op kinds are appended to `Kind` (the Zig enum is non-exhaustive); older loops/backends answer unknown kinds with `-ENOSYS` (io_uring: a submit-time `-ENOSYS`).
- `oio_fd` is `intptr_t` so a future Windows `HANDLE`/`SOCKET` fits; today descriptors are POSIX `int`s stored in an `intptr_t`.
- Ops in flight keep raw pointers into caller memory; this is why the Rust layer uses owned buffers and keeps a cancelled op's memory alive until its callback ([`origine_io` docs](../../../rust/crates/origine_io/docs/README.md)).
