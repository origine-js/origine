# Backends

A backend executes ops and reports completions; it never invokes callbacks (`Loop` does, from `run`). Interface: `src/io/backend.zig`. Implementations: `backend/uring.zig` (Linux), `backend/kqueue.zig` (Darwin), `backend/threaded.zig` (portable POSIX). Selection rules are in the [README](README.md#backends-and-selection); lifecycle and thread diagrams in [event-loop.md](event-loop.md).

## Capability table

`loop.caps()` returns these bits (`backend.Caps`, C: `OIO_CAP_*`).

| cap (bit) | io_uring | kqueue+GCD | threaded |
|---|---|---|---|
| nop (0), file_io (1), timeout (2), cancel (3) | yes | yes | yes |
| pollable (4) | yes (ring fd) | yes (kqueue fd) | yes (self-pipe read end) |
| vectored (5) | yes | yes | yes |
| sockets (6) | yes | yes | yes |
| futex (7) | only if the kernel probe lists FUTEX_WAIT and FUTEX_WAKE (Linux >= 6.7) | only if `os_sync_wait_on_address`, `..._with_timeout`, `os_sync_wake_by_address_any` exist at run time (macOS >= 14.4) | Linux and Darwin builds |
| sendfile (8), fallocate (9), link (10), sync (11) | yes | yes | yes |
| readdir (12) | yes (helper pool) | yes | Linux and Darwin builds |
| ftruncate (13) | only if the kernel probe lists FTRUNCATE (Linux >= 6.9) | yes | yes |

A missing optional capability makes the corresponding op complete with `-ENOSYS` (see [ops.md](ops.md#what-returns--enosys-where)); the threaded `futex` bit is static per build, so on Darwin it is set even if the `os_sync_*` symbols turn out to be absent (the op then returns `-ENOSYS`).

## io_uring (Linux)

Uses `std.os.linux.IoUring` directly (no liburing).

- **Ownership.** The ring is owned by the loop thread; `submit`, `cancel`, `poll` and `destroy` take no locks. Only `wake` and `post` are thread-safe.
- **Submit.** `submit` only queues SQEs (`user_data` = the `Op` pointer); the kernel sees them at the next `poll` (`io_uring_submit` / `submit_and_wait`) or when the SQ is full. If a pair of linked SQEs does not fit it flushes first. Embedders that poll `pollable()` themselves must call `run(NOWAIT)` after submitting.
- **Wake.** An eventfd is watched by a permanently re-armed read SQE (`user_data = 1`). `wake` writes 1 to it from any thread; the read CQE ends a blocking `poll`.
- **Post.** A lock-free MPSC stack (CAS push, `Xchg` drain, reversed to FIFO), then `wake`. Nodes come from `std.heap.c_allocator`.
- **Poll.** Reap CQEs (batches of 64), drain posts, drain finished readdirs; if `block` and nothing was collected, `submit_and_wait(1)` and reap again.
- **Timeouts.** `timeout` is `IORING_OP_TIMEOUT` (`-ETIME` is mapped to result 0). `futex_wait` with `offset >= 0` is a `FUTEX_WAIT` SQE linked (`IOSQE_IO_LINK`) to an `IORING_OP_LINK_TIMEOUT` SQE; the op has two CQEs and completes on the second, mapping "wait cancelled by the timeout" to `-ETIMEDOUT`. Futex ops use `FUTEX2_SIZE_U32 | FUTEX2_PRIVATE` with a match-any mask.
- **fstat/stat** use `statx` into a heap `Statx`, converted to `Stat` on completion.
- **sendfile** has no io_uring opcode: it allocates a pipe (`pipe2`, enlarged best effort to 1 MiB) and loops `splice(in -> pipe)` then `splice(pipe -> out)` as chained SQEs until `count` bytes moved or EOF. The pipe and state are freed when the op completes. A short result is success; an error is reported only if nothing was copied.
- **readdir** has no opcode either: a helper pool of up to 4 threads (spawned on demand when outstanding requests >= threads; first readdir creates the pool) blocks on a counting eventfd (`EFD_SEMAPHORE`), pops requests from a spinlock-guarded FIFO and runs `lseek(cookie)` + `getdents64` (16 KiB scratch) + packing. Finished ops are pushed on an MPSC stack and the loop is woken through the main eventfd. A queued readdir can be cancelled; a running one finishes normally.
- **cancel.** Queues `IORING_OP_ASYNC_CANCEL` for the op; returns false if the op is not outstanding or no SQE is free.
- **destroy.** Sets `closing` (multi-step ops such as sendfile stop and complete `-ECANCELED`), joins the readdir workers, cancels the wake read and every outstanding op, waits until all CQEs are back, hands remaining posts to the loop, closes the eventfd and the ring.
- **pollable.** The ring fd (readable when completions are queued). Deferred SQEs are not visible to it until a `poll` call submits them.
- **Failure to create** (kernel without io_uring, seccomp, ...) makes `auto` fall back to the threaded backend; explicit `uring` returns the error.

## kqueue + GCD (macOS)

Wait primitive is kqueue; blocking syscalls run on the libdispatch global queue via the plain C function `dispatch_async_f` (no blocks, `QOS_CLASS_USER_INITIATED`).

- **Wake.** `EVFILT_USER` with `NOTE_TRIGGER` (ident 1, registered `EV_CLEAR`). `post` appends to a mutex-guarded list then triggers the event.
- **Timers.** `EVFILT_TIMER` one-shot with `NOTE_NSECONDS`, ident = op address. Cancel deletes the kevent.
- **GCD ops** (open, close, read, write, fstat, stat, mkdir, unlink, rename, link, fsync, fallocate, ftruncate, readdir, sendfile, readv, writev, futex_wait, and sockets on blocking fds). `submit` links the op in an outstanding list, marks it queued, and `dispatch_async_f`s it. A GCD thread (function `work`) only touches its op and the mutex-guarded done list, sets `op.result`, pushes the op, triggers the user event and signals a condvar. It never calls into the loop. Per-op states live in `priv[1]`: idle, queued, running, cancelled, timer, waiting, done.
- **Non-blocking sockets.** For `send/recv/sendmsg/recvmsg/accept/connect`, if the fd has `O_NONBLOCK` (checked with `F_GETFL` at submit) the syscall is attempted on the loop thread. On `EAGAIN` (connect: `EINPROGRESS`) the op registers a one-shot `EVFILT_READ` (accept/recv/recvmsg) or `EVFILT_WRITE` (send/sendmsg/connect) on a private `dup` (`F_DUPFD_CLOEXEC`) of the fd, so several ops can wait on the same descriptor, then retries when the event fires. Cancelling closes the dup and reports `-ECANCELED`. No GCD thread is held while waiting. Blocking fds run the call on GCD.
- **futex.** `futex_wait` runs `os_sync_wait_on_address(_with_timeout)` on a GCD thread (weak-linked; absent means `-ENOSYS` and no `futex` cap). `futex_wake` completes inline on the loop thread: the kernel cannot report how many it woke, so the backend scans its own outstanding futex waits for that address, marks `min(count, waiting)` of them, issues that many `os_sync_wake_by_address_any` calls and returns the number. Waiters from other code on the same word are not counted.
- **readdir.** `__getdirentries64` with a 64 KiB scratch, limited to the space left in the output so every native entry that is read packs whole (a packed entry is smaller than its dirent). `d_seekoff` is 0 on APFS, so the only valid cookie is the fd position after a read (`lseek(fd, 0, SEEK_CUR)`).
- **fsync.** Without the data-only flag: `fcntl(F_FULLFSYNC)`, falling back to `fsync` if the filesystem rejects it. With data-only: plain `fsync`, which on macOS does not flush the drive cache (no `fdatasync` equivalent).
- **fallocate.** See [ops.md](ops.md#fallocflags).
- **sendfile.** `sendfile(2)` when `out` is a socket; else a pread/write loop.
- **destroy.** Deletes timers, drops socket waits, flags queued GCD ops as cancelled (they complete `-ECANCELED` when GCD gets to them), then waits on a condvar for ops that are already inside a syscall. Those cannot be interrupted, so destroy blocks until they return.
- **pollable.** The kqueue fd itself (can be added to another kqueue or `poll`ed). Ops finished inline on the loop thread (nop, futex_wake, immediate socket results, submission errors) sit on an internal ready list that does not make the kqueue fd readable; they are collected by the next `poll`, so call `run(NOWAIT)` after submitting.
- `Options.entries` is ignored. Per-fd ordering of streaming (`offset == -1`) ops is not provided.

## threaded (portable POSIX)

A pool of worker threads runs blocking libc calls.

- **Pool.** `entries` workers at creation (default 4, at most 64). When an op is submitted while every worker is busy (`queued > idle`) and fewer than 64 threads exist, `submit` spawns another worker, so blocked ops (accept, recv, futex_wait, pipe reads) do not starve later ops, up to the cap. Workers are never retired before `destroy`. Beyond 64 blocked ops, further ops wait in the queue.
- **Sync.** One mutex guards the work queue, done queue, post list, stop/woken flags and each op's state (`priv[1]`: none, queued, running, running_cancelled, done). Workers touch only the op and these queues.
- **Timers** live in a loop-thread-only list; the deadline (`CLOCK_MONOTONIC`) is stashed in `op.result` until expiry. A blocking `poll` waits on a condvar with an absolute timeout computed from the earliest deadline.
- **Nop** completes inline: it is queued as done and signals the pollable pipe.
- **Wake/post.** Set a flag (or append a node), signal the condvar and the self-pipe.
- **Self-pipe / `pollable()`.** A non-blocking close-on-exec pipe; the read end is returned. One byte is written when something is pending (coalesced through a `signalled` flag guarded by the mutex) and `poll` drains it. It is level-triggered and tracks worker completions, `wake`, `post` and inline nops. **Timer expiry does not make it readable** (timers are only examined inside `poll`), so a foreign loop must arrange its own timeout for outstanding `timeout` ops.
- **Cancel.** Timer: removed, `-ECANCELED`. Queued: removed from the work queue, `-ECANCELED`, deterministic. Running: marked, and when the syscall returns its result is replaced by `-ECANCELED`.
- **Per-OS notes.** open/read/write/etc. are libc calls (EINTR is retried). Linux: `accept4(SOCK_CLOEXEC)`, `statx`, `futex(2)` private ops, `fdatasync` for data-only fsync, `fallocate(2)`. Darwin: `F_FULLFSYNC`, `F_PREALLOCATE`, `os_sync_*` through `dlsym`, `sendfile(2)` to sockets, `__getdirentries64`. Sockets are plain blocking calls (see [ops.md](ops.md#sockets)).
- **destroy.** Sets `stop`, completes everything still queued as `-ECANCELED`, completes timers as `-ECANCELED`, joins all workers (so ops already inside a syscall must return first), then drains done ops and posts into the loop and frees everything.

## Known limitations

- **Blocked syscalls cannot be cancelled** on kqueue and threaded (and readdir on io_uring once running). `Loop.destroy` waits for them, so a `recv`/`accept`/`futex_wait` with no peer can hang destroy. Close the descriptor or wake the peer first, or avoid submitting indefinite waits on blocking fds; non-blocking sockets on kqueue are cancellable.
- **Cancelled-but-running results differ**: kqueue keeps the real result, threaded reports `-ECANCELED` even when the syscall succeeded.
- **macOS futex_wake count** is exact only for waiters submitted through the same kqueue backend instance (see above); threaded/Darwin reports 1 or 0. Futex waits on macOS may wake spuriously with result 0.
- **macOS durability**: data-only `fsync` does not flush the drive cache; full `fsync` uses `F_FULLFSYNC`.
- **SIGPIPE / MSG_NOSIGNAL**: Darwin has no `MSG_NOSIGNAL`; set `SO_NOSIGPIPE` on sockets. The library does not mask SIGPIPE.
- **readdir**: use a buffer of at least 4096 bytes (`-ERANGE` otherwise); the cookie is the descriptor position, so only one readdir may be in flight per directory fd, and cookies must be passed back unchanged.
- **`Stat.mode`** includes file type bits on io_uring and threaded but only permission bits on kqueue.
- **mkdir mode 0** is 0o777 on io_uring only.
- **Missing-pointer errors** are `submit` errors on io_uring and `-EINVAL` completions elsewhere.
- **`auto` on non-Darwin BSDs** returns `Unsupported` (it picks kqueue without falling back). Use `threaded`.
- **Foreign-loop embedding** needs `run(NOWAIT)` after submit on io_uring and kqueue, and a separate timer on threaded (see [c-api.md](c-api.md#embedding-in-a-foreign-loop)).
- **No Windows backend**: `iocp` is a reserved enum value.
- Pool growth and GCD concurrency are the only throttles; there is no per-loop limit on outstanding ops except the ring size on io_uring (when the SQ is full, `submit` flushes and retries once, then fails with an error that the C API reports as `-EINVAL`).

## Adding a backend

1. Add a value to `backend.Kind` and a branch in `createBackend` (`loop.zig`); decide whether `auto` should choose it. Export a `create(allocator, Options) !Backend` and a `supported` constant if the file must compile on other OSes (see how `uring.zig` keeps everything in a lazily analysed `Impl`).
2. Implement the vtable (`backend.VTable`). All functions receive the opaque `ctx` returned in `Backend.ctx`.

```zig
pub const VTable = struct {
    submit:   *const fn (ctx: *anyopaque, op: *Op) anyerror!void,
    cancel:   *const fn (ctx: *anyopaque, op: *Op) bool,
    poll:     *const fn (ctx: *anyopaque, block: bool, out: *Drained) void,
    wake:     *const fn (ctx: *anyopaque) void,
    post:     *const fn (ctx: *anyopaque, func: PostFn, ud: ?*anyopaque) anyerror!void,
    pollable: *const fn (ctx: *anyopaque) isize,
    caps: u64,
    destroy:  *const fn (ctx: *anyopaque, out: *Drained) void,
};
```

Contract:

- **Threads.** `submit`, `cancel`, `poll`, `destroy`, `pollable` run on the loop thread. `wake` and `post` run on any thread and must be safe against a concurrent `poll`.
- **submit.** Takes ownership of the op until it is reported through `poll`. Return an error only if the op was *not* accepted (the loop then does not count it and the callback never runs); otherwise always eventually report it. Failures that are properties of the op (bad fd, missing capability) should be reported as a completion with a negative result, not as a submit error. `Loop.submit` has already set `op.result = 0`.
- **Result convention.** Write `op.result` (`>= 0` or `-errno`) before pushing the op on `out.done` (FIFO; `Drained.done` is an `op_mod.Queue`, intrusive through `priv[0]`). Do not use `priv[0]` for anything else while the op is not owned by a queue you control; the other `priv` slots are yours. Fill `op.aux`/`buf` outputs (stat, accept size, readdir cookie) before reporting.
- **Never call `op.cb`.** Only report. The loop calls callbacks and decrements `active` per op taken from `out.done`.
- **poll(block, out).** Collect finished ops into `out.done` and posted functions with `out.pushPost`. If `block`, sleep until a completion, `wake`, `post` or a timer deadline; if nothing was ready and not `block`, return immediately. A `wake` with nothing else must make a blocking `poll` return (the loop returns control to the caller for `run(.once)`).
- **cancel.** Return true if the op will still be reported (with `-ECANCELED` or its real result); false if it is unknown or already reported. Never complete it synchronously inside `cancel` without pushing it on a later `poll`'s `Drained`.
- **post nodes.** `PostNode` must be allocated by the backend with `std.heap.c_allocator`. The loop copies `func`/`ud`, destroys the node with `c_allocator`, then calls `func(ud)`. Posts pending at `destroy` must be moved into `out` so they still run. Preserve FIFO order.
- **pollable.** Return an OS handle (fd) that becomes readable when `poll(false)` would make progress, or `-1` and leave the `pollable` cap unset.
- **destroy(out).** Stop workers, make every outstanding op complete with `-ECANCELED` (or its real result if it already finished) into `out.done`, move leftover posts into `out`, free all resources including `ctx`. After it returns the loop dispatches `out` and frees itself.
- **caps.** Report only what the backend truly supports; `Caps` bits are public API (`oio_loop_caps`). Per-instance capabilities (kernel probes) can be set by copying a base vtable into the state, as `uring.zig` does.
- **Tests.** Drive the vtable directly in the backend file (see [testing.md](testing.md)) and add the backend to the `backends` list in `tests.zig`.
