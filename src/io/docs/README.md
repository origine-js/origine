# origine I/O event loop (`src/io`)

A small completion-based event loop written in Zig. It runs file, directory, socket, timer and futex operations asynchronously and reports each one through a callback. It is used directly by the Zig host (`io.Loop`) and, through a C ABI (`oio_*`), by the Rust runtime.

Sources: `op.zig` (the `Op` record), `backend.zig` (vtable, caps, options), `loop.zig` (`Loop`), `io.zig` (public Zig module), `c_api.zig` + `include/origine_io.h` (C ABI), `lib.zig` (root of `liborigine_io.a`), `backend/{uring,kqueue,threaded}.zig`, `tests.zig`.

## The model

- **Completion-based.** You fill an `Op`, submit it, and later the loop calls `op.cb(op, result)`. `result` is a value `>= 0` on success or `-errno` on failure (`-ECANCELED` when cancelled).
- **Caller-owned ops.** The loop never allocates per op. The `Op` must stay alive and unmoved from `submit` until its callback has run. Every pointer it refers to (`buf`, `path`, `path2`, iovec arrays, `msghdr`, sockaddr, futex word, `Stat` out-pointer) must outlive the op as well. `Op` holds plain data only (never engine handles). It is an `extern struct` (see [c-api.md](c-api.md) for the layout).
- **Thread rules.** A loop is driven by one thread, the one that calls `run`.
  - Loop thread only: `submit` (and every typed helper), `cancel`, `run`, `destroy`.
  - Any thread: `wake`, `post`.
  - `pollable()`, `caps()` and `active` are read on the loop thread in practice (see the table in [c-api.md](c-api.md)).
  - Several loops may coexist; they share no state.
- **Callbacks only inside `run`.** Backends never invoke callbacks; they report finished ops (and posted functions) to `Loop`, which dispatches them from `run` (or `destroy`). A callback may submit more ops.
- **Exactly once.** After a successful `submit` the callback runs exactly once, even for cancelled ops and for ops outstanding at `destroy`. If `submit` itself returns an error, the op was not accepted and its callback will not run.
- **Completion order is not submission order.** Ops run concurrently; there is no per-fd ordering for streaming (`offset == -1`) ops.

Diagrams of the layers, one `run` turn, the op lifecycle and the thread model are in [event-loop.md](event-loop.md).

## Backends and selection

`Options.backend` selects the engine (`backend.Kind`):

| value | name | notes |
|---|---|---|
| 0 | `auto` | Linux: io_uring, falling back to threaded if the ring cannot be created. Darwin and other BSDs: kqueue+GCD (no fallback; see below). Everything else: threaded. |
| 1 | `uring` | Linux only; `error.Unsupported` (`-ENOSYS` in C) elsewhere. |
| 2 | `kqueue_gcd` | Darwin only (`macos, ios, tvos, watchos, visionos`); `Unsupported` elsewhere. |
| 3 | `iocp` | Reserved. Always `Unsupported`. |
| 4 | `threaded` | Portable POSIX worker pool. |

`Options.entries` is a hint: io_uring ring entries (default 256, capped at 32768, rounded up to a power of two), initial worker count for threaded (default 4, at most 64), ignored by kqueue.

`auto` on a BSD that is not Darwin calls `kqueue.create`, which reports `Unsupported` there (`supported` is Darwin only) and does not fall back, so request `threaded` explicitly on those systems.

`loop.caps()` returns the `Caps` bits of the chosen backend; use it to feature-test (futex and ftruncate depend on kernel support at runtime). Details and per-backend tables: [backends.md](backends.md).

## Quick start (Zig)

Inside the tree the module is imported as `@import("@io")` (the build wires it); the file itself is `src/io/io.zig`.

```zig
const std = @import("std");
const io = @import("@io");

const Reader = struct {
    op: io.Op = .{},
    result: i64 = 0,
    done: bool = false,
};

fn onRead(op: *io.Op, result: i64) callconv(.c) void {
    const r: *Reader = @fieldParentPtr("op", op);
    r.result = result; // >= 0 bytes read, or -errno
    r.done = true;
}

pub fn readFile(path: [*:0]const u8) !void {
    const loop = try io.Loop.create(std.heap.c_allocator, .{}); // .{} = auto backend
    defer loop.destroy();

    var open: Reader = .{};
    try loop.open(&open.op, io.fd_cwd, path, io.O.RDONLY, 0, onRead, null);
    _ = loop.run(.until_idle);
    if (open.result < 0) return error.OpenFailed;
    const fd: io.Fd = @intCast(open.result);

    var buf: [4096]u8 = undefined;
    var rd: Reader = .{};
    try loop.read(&rd.op, fd, &buf, 0, onRead, null); // offset 0 = pread; -1 = current position
    _ = loop.run(.until_idle);                         // returns the number of ops still active (0)
    // rd.result bytes are in buf[0..]

    var close: Reader = .{};
    try loop.close(&close.op, fd, onRead, null);
    _ = loop.run(.until_idle);
}
```

`Loop.create(allocator, options) !*Loop` and `Loop.read(loop, op, fd, buf: []u8, offset: i64, cb: Callback, user: ?*anyopaque) !void` are the real signatures. `run(.until_idle)` blocks until no op is active; `run(.once)` blocks for one event; `run(.nowait)` only collects what is ready.

## Quick start (C)

```c
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include "origine_io.h"

static void on_read(oio_op *op, int64_t result) {
  int *done = (int *)op->user;
  printf("read -> %lld\n", (long long)result); /* bytes, or -errno */
  *done = 1;
}

int main(void) {
  oio_loop *loop = NULL;
  if (oio_loop_create(NULL, &loop) < 0) return 1; /* NULL = default options (auto backend) */

  int fd = open("/etc/hosts", O_RDONLY);
  char buf[4096];
  int done = 0;
  oio_op op;
  memset(&op, 0, sizeof op);
  op.user = &done;                                /* set before submitting; oio_* keeps it */
  if (oio_read(loop, &op, fd, buf, sizeof buf, 0, on_read) < 0) return 1;

  while (!done) oio_loop_run(loop, OIO_RUN_ONCE); /* callbacks fire inside run */
  oio_loop_destroy(loop);
  return 0;
}
```

Build: link `liborigine_io.a` (root `src/io/lib.zig`); see [c-api.md](c-api.md#linking).

## Where to read next

| document | contents |
|---|---|
| [event-loop.md](event-loop.md) | Mermaid diagrams: layers, a `run` turn, op lifecycle, threads, an async read end to end, host `settle`. |
| [ops.md](ops.md) | Every `Op` kind: field usage table, results, errno conventions, Zig helper and C function, cancellation, portable flags, `Stat`, readdir packing, futex, sendfile, sockets, where `-ENOSYS` is returned. |
| [backends.md](backends.md) | How io_uring, kqueue+GCD and threaded work, capability table, known limitations, how to add a backend. |
| [c-api.md](c-api.md) | The C ABI: ownership, thread-safety table, errors, linking, embedding `pollable()` in a foreign loop, ABI stability. |
| [testing.md](testing.md) | Test layout, `zig build test-io`, running Linux tests in a container, linking Rust tests against the Zig library, pitfalls. |

Rust side (safe futures, runtime, fs on top of the C ABI): [`origine_io` docs](../../../rust/crates/origine_io/docs/README.md), in particular [rt.md](../../../rust/crates/origine_io/docs/rt.md) and [fs.md](../../../rust/crates/origine_io/docs/fs.md). Historical overview for review: `docs/io-api-review.md`.
