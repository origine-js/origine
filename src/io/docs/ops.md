# Operations reference

Source of truth: `src/io/op.zig` (`Op`, `Kind`), `src/io/loop.zig` (Zig helpers), `src/io/c_api.zig` and `src/io/include/origine_io.h` (C functions). Behavior notes come from the three backends; where they differ it is stated.

## The `Op` record

```zig
pub const Fd = isize;
pub const fd_cwd: Fd = -1;          // "relative to the current directory" for path ops
pub const Callback = *const fn (op: *Op, result: i64) callconv(.c) void;

pub const Op = extern struct {
    cb: ?Callback = null,
    user: ?*anyopaque = null,        // yours; the loop never touches it
    kind: Kind = .nop,               // i32
    flags: u32 = 0,
    fd: Fd = fd_cwd,
    fd2: Fd = fd_cwd,
    offset: i64 = -1,
    buf: ?*anyopaque = null,
    len: usize = 0,
    path: ?[*:0]const u8 = null,     // UTF-8, must outlive the op
    path2: ?[*:0]const u8 = null,
    aux: u64 = 0,
    result: i64 = 0,
    priv: [8]?*anyopaque = @splat(null),   // backend scratch: do not touch
};
```

Rules:

- `Loop.submit` sets `result = 0` and hands the op to the backend. After `submit` returns without error the callback runs exactly once with `result` (also stored in `op.result`).
- Defaults matter when you build an `Op` by hand: `fd` and `fd2` default to `fd_cwd` (-1), `offset` to -1.
- Unknown `kind` values are not rejected by the type system (`Kind` is non-exhaustive). Result: io_uring fails `submit` with `error.Unsupported` (`-ENOSYS` in C, no callback); kqueue and threaded complete the op with `-ENOSYS`.
- A required pointer that is null (`path`, `path2`, `buf` where needed): io_uring fails `submit` with `error.InvalidArgument` (`-EINVAL` in C, no callback); kqueue and threaded complete the op with `-EINVAL`. Both are programming errors; do not rely on either.
- The C layer maps submit errors as: `OutOfMemory` to `-ENOMEM`, `Unsupported`/`UnsupportedOp` to `-ENOSYS`, anything else (including `InvalidArgument` and `SystemResources`) to `-EINVAL`. On a submit error the op is not in flight and the callback never runs.

### Result and errno convention

`result >= 0` is success, `result < 0` is `-errno` using the host's native errno numbers (Linux and macOS values differ, e.g. `ECANCELED` is 125 on Linux and 89 on macOS). Cancelled ops report `-ECANCELED`. The meaning of a non-negative result is per kind (below). Kinds that produce data besides the result write it through `buf` (stat, readdir, accept) or `aux` (readdir cookie, accept address size).

## Field usage per kind

`-` means unused. "dir" is a directory descriptor or `fd_cwd`.

| kind | fd | fd2 | offset | buf | len | path | path2 | flags | aux | result (success) |
|---|---|---|---|---|---|---|---|---|---|---|
| `nop` | - | - | - | - | - | - | - | - | - | 0 |
| `open` | dir | - | - | - | - | file | - | - | `O` flags \| mode << 32 | new fd (close-on-exec) |
| `close` | fd | - | - | - | - | - | - | - | - | 0 |
| `read` | fd | - | -1 = current position, else pread | dest | capacity | - | - | - | - | bytes read (0 = EOF) |
| `write` | fd | - | -1 = current, else pwrite | source | bytes | - | - | - | - | bytes written |
| `readv` | fd | - | -1 = current, else preadv | `*const Iovec` array | iovec count | - | - | - | - | bytes read |
| `writev` | fd | - | -1 = current, else pwritev | `*const Iovec` array | iovec count | - | - | - | - | bytes written |
| `fstat` | fd | - | - | `*Stat` out | - | - | - | - | - | 0 |
| `stat` | dir | - | - | `*Stat` out | - | path | - | bit0: do not follow a final symlink | - | 0 |
| `mkdir` | dir | - | - | - | - | path | - | - | mode (permission bits) | 0 |
| `unlink` | dir | - | - | - | - | path | - | bit0: remove a directory (`AT_REMOVEDIR`) | - | 0 |
| `rename` | old dir | new dir | - | - | - | from | to | - | - | 0 |
| `link` | old dir | new dir | - | - | - | existing | new name | - | - | 0 |
| `timeout` | - | - | - | - | - | - | - | - | nanoseconds | 0 when it fires |
| `fsync` | fd | - | - | - | - | - | - | bit0: data only | - | 0 |
| `fallocate` | fd | - | start | - | length | - | - | - | `FallocFlags` | 0 |
| `ftruncate` | fd | - | new length (>= 0) | - | - | - | - | - | - | 0 |
| `sendfile` | out fd | in fd | in offset (-1 = in's current position) | - | max bytes | - | - | - | - | bytes copied |
| `send` | socket | - | - | data | bytes | - | - | native `MSG_*` | - | bytes sent |
| `recv` | socket | - | - | dest | capacity | - | - | native `MSG_*` | - | bytes received (0 = orderly shutdown) |
| `sendmsg` | socket | - | - | native `struct msghdr *` | - | - | - | native `MSG_*` | - | bytes sent |
| `recvmsg` | socket | - | - | native `struct msghdr *` | - | - | - | native `MSG_*` | - | bytes received |
| `connect` | socket | - | - | native `sockaddr *` | its size | - | - | - | - | 0 |
| `accept` | listening socket | - | - | optional native `sockaddr *` out | its capacity | - | - | - | out: peer address size (only if `buf` set) | new fd (close-on-exec) |
| `futex_wait` | - | - | timeout ns (< 0 = forever) | `*const u32` | - | - | - | - | expected value | 0 woken, `-EAGAIN`, `-ETIMEDOUT` |
| `futex_wake` | - | - | - | `*const u32` | - | - | - | - | max waiters to wake | number woken |
| `readdir` | dir fd | - | cookie in (0 = start) | dest | capacity | - | - | - | out: next cookie | bytes packed, 0 = end |

`*Stat` and `Stat` are `op.Stat`; `Iovec` is `op.Iovec` (same layout as the platform `struct iovec`). `Loop` also has `start(loop, op, fields: Op, cb, user)` to fill any op generically (used for kinds without a typed helper, notably `mkdir`).

## Zig helpers and C functions

All Zig helpers have the shape `fn(loop: *Loop, op: *Op, ..., cb: Callback, user: ?*anyopaque) !void`; they overwrite `*op` completely (so set nothing on it beforehand) and submit. All C functions take `(oio_loop *, oio_op *, ..., oio_cb)`, return 0 or `-errno`, and keep `op->user` (which you set before the call). `Fd` below is `isize` (`oio_fd` is `intptr_t`).

| kind | Zig `Loop` method (after `loop, op`) | C function (after `loop, op`) |
|---|---|---|
| `nop` | `nop()` | `oio_nop(cb)` |
| `open` | `open(dir: Fd, path: [*:0]const u8, flags: u64, mode: u32)` | `oio_open(oio_fd dirfd, const char *path, uint64_t flags, uint32_t mode, cb)` |
| `close` | `close(fd)` | `oio_close(fd, cb)` |
| `read` | `read(fd, buf: []u8, offset: i64)` | `oio_read(fd, void *buf, size_t len, int64_t offset, cb)` |
| `write` | `write(fd, buf: []const u8, offset: i64)` | `oio_write(fd, const void *buf, size_t len, int64_t offset, cb)` |
| `readv` | `readv(fd, iov: []const Iovec, offset: i64)` | `oio_readv(fd, const oio_iovec *iov, size_t iov_count, int64_t offset, cb)` |
| `writev` | `writev(fd, iov: []const Iovec, offset: i64)` | `oio_writev(...)` same shape |
| `fstat` | `fstat(fd, out: *Stat)` | `oio_fstat(fd, oio_stat *out, cb)` |
| `stat` | `stat(dir, path, nofollow: bool, out: *Stat)` | `oio_stat_at(dirfd, path, uint32_t nofollow, oio_stat *out, cb)` |
| `mkdir` | none: `start(op, .{ .kind = .mkdir, .fd = dir, .path = p, .aux = mode }, cb, user)` | `oio_mkdir(dirfd, path, uint32_t mode, cb)` |
| `unlink` | `unlink(dir, path, rmdir: bool)` | `oio_unlink(dirfd, path, uint32_t rmdir, cb)` |
| `rename` | `rename(old_dir, old, new_dir, new)` | `oio_rename(old_dirfd, from, new_dirfd, to, cb)` |
| `link` | `link(old_dir, old, new_dir, new)` | `oio_link(old_dirfd, old, new_dirfd, new_path, cb)` |
| `timeout` | `timeout(ns: u64)` | `oio_timeout(uint64_t ns, cb)` |
| `fsync` | `fsync(fd, datasync: bool)` | `oio_fsync(fd, uint32_t datasync, cb)` |
| `fallocate` | `fallocate(fd, offset: i64, len: usize, flags: u64)` | `oio_fallocate(fd, int64_t offset, size_t len, uint64_t flags, cb)` |
| `ftruncate` | `ftruncate(fd, len: u64)` | `oio_ftruncate(fd, uint64_t len, cb)` |
| `sendfile` | `sendfile(out, in, in_offset: i64, count: usize)` | `oio_sendfile(out_fd, in_fd, int64_t in_offset, size_t count, cb)` |
| `send` | `send(fd, buf: []const u8, msg_flags: u32)` | `oio_send(fd, const void *buf, size_t len, uint32_t msg_flags, cb)` |
| `recv` | `recv(fd, buf: []u8, msg_flags: u32)` | `oio_recv(fd, void *buf, size_t len, uint32_t msg_flags, cb)` |
| `sendmsg` | `sendmsg(fd, msg: *anyopaque, msg_flags: u32)` | `oio_sendmsg(fd, void *msghdr, uint32_t msg_flags, cb)` |
| `recvmsg` | `recvmsg(fd, msg: *anyopaque, msg_flags: u32)` | `oio_recvmsg(...)` same shape |
| `connect` | `connect(fd, addr: *const anyopaque, addr_len: usize)` | `oio_connect(fd, const void *sockaddr, size_t addr_len, cb)` |
| `accept` | `accept(fd, addr: ?*anyopaque, addr_cap: usize)` | `oio_accept(fd, void *addr, size_t addr_cap, cb)` |
| `futex_wait` | `futexWait(addr: *const u32, expected: u32, timeout_ns: i64)` | `oio_futex_wait(const uint32_t *addr, uint32_t expected, int64_t timeout_ns, cb)` |
| `futex_wake` | `futexWake(addr: *const u32, count: u32)` | `oio_futex_wake(const uint32_t *addr, uint32_t count, cb)` |
| `readdir` | `readdir(fd, buf: []u8, cookie: u64)` | `oio_readdir(dirfd, void *buf, size_t len, uint64_t cookie, cb)` |

Note the C `oio_unlink`, `oio_stat_at` and `oio_fsync` take `uint32_t` booleans (non-zero = true). `Loop.nop`/`timeout` etc. also exist in C with the same names (`oio_nop`, `oio_timeout`).

## Cancellation

```zig
pub fn cancel(loop: *Loop, op: *Op) bool        // C: int oio_cancel(oio_loop *, oio_op *)
```

- Loop thread only. Returns `true` if the op is still known to the backend and will still complete (with `-ECANCELED` or, if it was already running or finished, its real result); `false` if the op is not outstanding (never submitted, or already handed to the loop). The callback runs exactly once either way, never inside `cancel` itself.
- Cancelling is a request. What a cancelled op reports depends on its state and backend:

| state | io_uring | kqueue+GCD | threaded |
|---|---|---|---|
| timer | `IORING_OP_ASYNC_CANCEL`; `-ECANCELED` | timer removed; `-ECANCELED` | removed from the timer list; `-ECANCELED` |
| queued, not started | cancelled by the kernel; `-ECANCELED` (readdir: marked, a worker completes it as `-ECANCELED`) | flagged, skipped by GCD; `-ECANCELED` | removed from the work queue; `-ECANCELED` |
| non-blocking socket wait | kernel-side cancel | kqueue wait dropped (dup closed); `-ECANCELED` | n/a (plain blocking calls) |
| already executing a syscall | kernel may still complete it with its real result (readdir always does) | runs to completion; **real result** | runs to completion; result is forced to `-ECANCELED` even if the syscall succeeded and had side effects |
| completed, not yet dispatched | callback with the real result | callback with the real result | callback with the real result |

- A blocked syscall cannot be interrupted on kqueue (GCD) and threaded (worker), so `Loop.destroy` waits for it to return. Typical offenders: `accept`, `recv`, `futex_wait` and reads from pipes on blocking descriptors. io_uring operations are cancelled by the kernel.
- `Loop.destroy` cancels everything outstanding and runs the callbacks before freeing the loop.
- Because the real result can win, treat `-ECANCELED` as "may not have happened", not "did not happen".

## Portable open flags

`aux` of `open` is `flags | (mode << 32)`; flags are in `op.O` (C: `OIO_O_*`), the access mode is the low two bits.

| name | value |
|---|---|
| `O.RDONLY` | 0 |
| `O.WRONLY` | 1 |
| `O.RDWR` | 2 |
| `O.CREAT` | 0x100 |
| `O.TRUNC` | 0x200 |
| `O.APPEND` | 0x400 |
| `O.EXCL` | 0x800 |
| `O.DIRECTORY` | 0x1000 |

All backends translate these to the native flags and always add close-on-exec. Other bits are ignored. `mode` is the file permission for `CREAT` (`Loop.open` and `oio_open` take it as a separate `u32` argument and shift it into `aux`).

`mkdir`: mode is in the low bits of `aux` (no shift). Backend behavior for mode 0 differs: io_uring substitutes 0o777, kqueue masks to `0o7777` and passes 0 through, threaded passes `aux` as is. Always pass an explicit mode.

## `FallocFlags`

`aux` of `fallocate`. Only `FallocFlags.KEEP_SIZE = 1` (C: `OIO_FALLOC_KEEP_SIZE`): allocate without changing the reported file size. Behavior notes:

- Linux (io_uring and threaded): native `fallocate(2)`, mode 0 or `FALLOC_FL_KEEP_SIZE`. The filesystem may reject it (`-EOPNOTSUPP`).
- macOS: `fcntl(F_PREALLOCATE)` from the physical end of file, then `ftruncate` when the file would grow and `KEEP_SIZE` is not set. A range entirely inside the existing file is a successful no-op (macOS cannot preallocate holes). The kqueue backend rejects `offset < 0` or `len == 0` with `-EINVAL`; threaded on Darwin does not check `len == 0`.
- FreeBSD (threaded only): `posix_fallocate`, `KEEP_SIZE` not honored. Other systems: `-ENOSYS`.

## `Stat` layout

```zig
pub const Stat = extern struct { size: u64, mode: u32, kind: u32 };   // 16 bytes; C: oio_stat
```

- `kind`: 1 regular file, 2 directory, 3 symlink, 0 anything else.
- `size`: byte size.
- `mode`: **differs by backend**. io_uring and threaded store the full `st_mode` (file type bits included). kqueue stores only the permission bits (`st_mode & 0o7777`). Portable code should mask with `0o7777` and use `kind` for the type.
- `fstat` and `stat` complete with result 0; the struct is written before the callback runs. `stat` with flags bit0 does not follow a final symlink (`fstatat`/`statx` with `AT_SYMLINK_NOFOLLOW`).
- No timestamps, inode or owner are reported.

## Readdir packing and cookies

`readdir(fd, buf, cookie)`: `fd` is an open directory descriptor (open it with `O.DIRECTORY`). On success `result` is the number of bytes written to `buf`; `0` means end of directory. The next cookie is written to `op.aux`.

Entries are packed back to back, never split across calls, `.` and `..` skipped:

```
kind: u8        // 0 other, 1 file, 2 directory, 3 symlink
name_len: u16   // little endian
name: [name_len]u8   // no NUL terminator
```

Cookie rules:

- Start with cookie 0. Pass exactly the previous completion's `op.aux` for the next call. Do not interpret or construct cookies: on macOS the cookie is an opaque directory-stream position (APFS reports `d_seekoff` as 0), on Linux it is a `d_off`-style position.
- The cookie is the position of the directory descriptor. **Run only one readdir per directory fd at a time**; interleaving them corrupts the position. Other fds opened on the same directory are independent.
- `-ERANGE` is returned when not even the first entry fits. Use a buffer of at least 4096 bytes (the documented minimum). Names longer than 65535 bytes cannot be represented; on io_uring such an entry is treated as "does not fit".
- Entry kind comes from `d_type`; when the filesystem reports unknown, the backend does a no-follow stat of the entry (failure gives kind 0).
- Possible results: `>0` bytes, `0` end, `-ERANGE`, `-EINVAL` (null buffer, negative cookie; threaded also for `len == 0`), `-EBADF`, `-ENOTDIR`, etc.
- Support: io_uring runs it on a helper thread pool (cap `readdir` always set), kqueue on GCD (`__getdirentries64`), threaded on Linux and Darwin only (on other systems the cap is absent and the op returns `-ENOSYS`).
- A request packs at most what fits in `buf`; the call may return fewer bytes than `len` even when more entries remain. Loop until `0`.

## Futex

`futex_wait` / `futex_wake` operate on a 32-bit word in process-private memory (private futexes: io_uring uses `FUTEX2_PRIVATE`, threaded uses `FUTEX_PRIVATE_FLAG` on Linux).

- `futex_wait`: compares `*addr` with `aux` (low 32 bits) and sleeps while equal. Results: `0` woken; `-EAGAIN` the value already differed; `-ETIMEDOUT` if `offset >= 0` nanoseconds elapsed first (`offset < 0` waits forever; note the raw `Op` default is -1). macOS can report a value change between its pre-check and the kernel wait as `0` (spurious wake) rather than `-EAGAIN`; always re-check the word.
- `futex_wake`: wakes up to `aux` waiters. Result is the number woken: exact on io_uring and threaded/Linux. On macOS the kernel does not report counts: kqueue counts only waiters submitted through the same backend instance (it wakes `min(count, tracked)` and returns that); threaded/Darwin wakes one (`count == 1`) or all and returns 1 if there was a waiter, else 0.
- Availability: `Caps.futex`. io_uring: only when the kernel probe lists FUTEX_WAIT/WAKE (Linux >= 6.7); otherwise the ops complete with `-ENOSYS`. kqueue: needs `os_sync_wait_on_address` (macOS >= 14.4, resolved at run time); otherwise `-ENOSYS`. threaded: Linux and Darwin (on Darwin it resolves the same symbols with `dlsym`); `-ENOSYS` elsewhere.
- On kqueue and threaded a pending `futex_wait` occupies a worker thread (GCD / pool) until woken or timed out, and cannot be cancelled once running (threaded cancel then reports `-ECANCELED` after it returns; kqueue reports the real result).

## sendfile

`sendfile(out, in, in_offset, count)`: copies up to `count` bytes from `in` to `out`; `result` is the number of bytes copied, possibly short (EOF on `in`). `count == 0` completes with 0 on all backends. `in_offset == -1` uses and advances `in`'s current file position; otherwise the position is untouched.

- io_uring: splice through a private pipe (sized best effort to 1 MiB, else the default chunk). Short results are success; an error is reported only if nothing was moved. `in` must be spliceable (regular file, etc.).
- kqueue: `sendfile(2)` when `out` is a socket, otherwise a 64 KiB pread/write loop.
- threaded: Linux `sendfile(2)` (falls back to the copy loop on `EINVAL`/`ENOSYS`); Darwin `sendfile(2)` for socket outputs; otherwise the copy loop.

## Sockets

All socket ops use native types: the library does not translate addresses, flags or `msghdr`.

- `flags` of send/recv/sendmsg/recvmsg are the platform's `MSG_*` values (`MSG_PEEK`, `MSG_WAITALL`, `MSG_NOSIGNAL` on Linux, ...). They are passed through unchanged.
- `buf` of connect/accept is the platform `struct sockaddr *`; `len` is its size/capacity. `accept` writes the peer size back to `op.aux` and returns the new fd with close-on-exec set. Pass `buf = null` if you do not need the peer address (`aux` is then untouched).
- `sendmsg`/`recvmsg`: `buf` is the platform `struct msghdr *`; the header and every iovec, control buffer and address it points to must stay valid until the callback.
- SIGPIPE: Linux callers pass `MSG_NOSIGNAL`. Darwin has no `MSG_NOSIGNAL`; set `SO_NOSIGPIPE` on the socket. The loop does not suppress SIGPIPE itself.
- Blocking vs non-blocking descriptors: on kqueue a non-blocking fd is attempted inline and parked on a kqueue filter when it would block (no thread is held); a blocking fd runs the syscall on a GCD thread. io_uring uses native async socket operations. The threaded backend always runs plain blocking calls on workers: a non-blocking fd therefore completes immediately with `-EAGAIN` (or `-EINPROGRESS` for connect) instead of waiting.
- `connect` on a kqueue non-blocking socket waits for writability then reads `SO_ERROR`; the result is 0 or `-error`.

## What returns `-ENOSYS` where

| situation | where | how it shows |
|---|---|---|
| `futex_wait`/`futex_wake` | io_uring on kernels < 6.7; kqueue before macOS 14.4; threaded off Linux/Darwin or without `os_sync_*` symbols | op completes with `-ENOSYS`; `Caps.futex` absent (threaded advertises it on Linux/Darwin only) |
| `ftruncate` | io_uring on kernels < 6.9 | op completes with `-ENOSYS` (`Caps.ftruncate` absent). kqueue and threaded use `ftruncate(2)` |
| `ftruncate` with a negative length | all | `-EINVAL` |
| `readdir` | threaded off Linux/Darwin | op completes with `-ENOSYS`; `Caps.readdir` absent |
| `fallocate` | threaded off Linux/Darwin/FreeBSD | `-ENOSYS` |
| unknown `kind` | io_uring | `submit` error (`-ENOSYS` from the C API), no callback |
| unknown `kind` | kqueue, threaded | op completes with `-ENOSYS` |
| backend selection | `uring` off Linux, `kqueue_gcd` off Darwin, `iocp` anywhere | `Loop.create` error `Unsupported` (`oio_loop_create` returns `-ENOSYS`) |

Check `loop.caps()` before relying on an optional kind. The bits are `Caps` in `backend.zig` (`OIO_CAP_*` in C): `nop, file_io, timeout, cancel, pollable, vectored, sockets, futex, sendfile, fallocate, link, sync, readdir, ftruncate`, bit 0 to 13 in that order.
