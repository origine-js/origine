//! macOS kqueue + GCD backend.
//!
//! kqueue is the wait primitive: `EVFILT_USER`/`NOTE_TRIGGER` implements `wake`, a user-space
//! timer heap (timers.zig) implements timeout ops, and `EVFILT_READ`/`EVFILT_WRITE` implement
//! readiness waits for sockets in non-blocking mode. Blocking syscalls run on the GCD global queue through the plain C function
//! `dispatch_async_f` (no blocks). A GCD thread only touches its op and the mutex-guarded
//! done-list, then triggers the user event; it never calls back into the loop.
//!
//! Socket ops (send/recv/sendmsg/recvmsg/accept/connect): if the fd is `O_NONBLOCK` the syscall is
//! attempted right away on the loop thread; on `EAGAIN` (or connect's `EINPROGRESS`) the op waits
//! on a kqueue filter (`EV_ONESHOT`, registered on a private `dup` of the fd so several ops can wait
//! on the same descriptor) and the syscall is retried when ready, so no GCD thread is occupied.
//! Blocking fds simply run the blocking call on GCD.
//!
//! Cancellation: timers and kqueue waits are removed (the dup is closed) and reported as
//! `-ECANCELED`. A GCD op that has not started yet is flagged and skipped (`-ECANCELED`); one
//! already running completes with its real result (GCD work cannot be interrupted).
//!
//! Platform notes (documented limitations):
//!  - fsync: without the datasync flag macOS uses `fcntl(F_FULLFSYNC)` (flushes the drive cache;
//!    falls back to `fsync` if the filesystem rejects it). With datasync (flags bit0) it uses plain
//!    `fsync`, which on macOS does NOT flush the drive cache; there is no `fdatasync` equivalent.
//!  - fallocate: `fcntl(F_PREALLOCATE)` from the physical EOF, then `ftruncate` when the file would
//!    grow and `KEEP_SIZE` is not set. Only the range past the current EOF is allocated (macOS
//!    cannot preallocate holes inside a file); a range wholly inside the file is a no-op.
//!  - sendfile: `sendfile(2)` is used when the output is a socket, otherwise a pread/write copy
//!    loop. With input offset -1 the input file position is read with `lseek` and advanced.
//!  - futex_*: `os_sync_wait_on_address` & co (macOS 14.4+) are weak-linked; on older systems the
//!    ops complete with `-ENOSYS`. A wait occupies a GCD thread. A wait whose value changed between
//!    the pre-check and the kernel wait reports 0 (spurious wake), not `-EAGAIN`. The kernel
//!    does not report how many threads it woke, so the wake result counts only waiters submitted
//!    through this backend instance (tracked via the outstanding-GCD-op list; woken waiters are
//!    marked so they are not counted twice; timed-out/finished/cancelled-before-start waits are not
//!    counted): it wakes min(count, tracked waiters) and returns that number. Waiters registered
//!    by other code on the same address are not counted (they may still be woken by the kernel
//!    only if one of ours was, since each wake call is issued per tracked waiter).
//!  - SIGPIPE: Darwin has no `MSG_NOSIGNAL`; set `SO_NOSIGPIPE` on sockets that need it.
//!  - destroy cancels queued GCD ops, kqueue waits and timers first, then waits only for ops that
//!    are already blocked inside a syscall (those cannot be interrupted; e.g. a blocking `recv`
//!    with no peer data keeps destroy waiting until the syscall returns).
//!
//! Per-fd ordering of streaming (offset == -1) ops is not provided.
const std = @import("std");
const builtin = @import("builtin");
const op_mod = @import("../op.zig");
const backend = @import("../backend.zig");
const tm = @import("../timers.zig");

const Op = op_mod.Op;
const Queue = op_mod.Queue;
const Drained = backend.Drained;
const PostNode = backend.PostNode;

pub const supported = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => true,
    else => false,
};

pub const c = std.c;

/// Events fetched per kevent call (uSockets uses 1024; 256 keeps the stack frame at 8 KiB).
const event_batch = 256;
/// Registrations buffered between polls; at most `event_batch` so errors fit the event list.
const change_batch = 64;
/// Largest descriptor number the wait table indexes (1M); above it socket waits fail ENOMEM.
const max_fd = 1 << 20;

// libSystem dispatch, no blocks needed.
const dispatch = struct {
    const Fn = *const fn (?*anyopaque) callconv(.c) void;
    extern "c" fn dispatch_get_global_queue(identifier: isize, flags: usize) ?*anyopaque;
    extern "c" fn dispatch_async_f(queue: ?*anyopaque, context: ?*anyopaque, work: Fn) void;
    const QOS_CLASS_USER_INITIATED: isize = 0x19;
};

// Darwin constants not (all) exposed by std.
const S_IFMT: u32 = 0o170000;
const S_IFSOCK: u32 = 0o140000;
pub const O_CLOEXEC: u32 = 0x01000000;
pub const O_NONBLOCK: c_int = 0x4;
const AT_SYMLINK_NOFOLLOW: c_int = 0x20;
const F_GETFL: c_int = 3;
const F_SETFD: c_int = 2;
const F_FULLFSYNC: c_int = 51;
const F_PREALLOCATE: c_int = 42;
const F_ALLOCATECONTIG: c_uint = 2;
const F_ALLOCATEALL: c_uint = 4;
const F_PEOFPOSMODE: c_int = 3;
pub const FD_CLOEXEC: c_int = 1;
const SOL_SOCKET: c_int = 0xffff;
const SO_ERROR: u32 = 0x1007;
pub const SEEK_SET: c_int = 0;
pub const SEEK_CUR: c_int = 1;
const user_ident: usize = 1;

const Fstore = extern struct { flags: c_uint, posmode: c_int, offset: i64, length: i64, bytesalloc: i64 };

// Declared locally with plain types; the symbols are the same libSystem functions std uses.
pub const sc = struct {
    extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    extern "c" fn fstatat(dirfd: c_int, path: [*:0]const u8, buf: *c.Stat, flag: c_int) c_int;
    extern "c" fn linkat(oldfd: c_int, old: [*:0]const u8, newfd: c_int, new: [*:0]const u8, flag: c_int) c_int;
    extern "c" fn lseek(fd: c_int, off: i64, whence: c_int) i64;
    extern "c" fn ftruncate(fd: c_int, len: i64) c_int;
    extern "c" fn preadv(fd: c_int, iov: ?*const anyopaque, cnt: c_int, off: i64) isize;
    extern "c" fn pwritev(fd: c_int, iov: ?*const anyopaque, cnt: c_int, off: i64) isize;
    extern "c" fn readv(fd: c_int, iov: ?*const anyopaque, cnt: c_int) isize;
    extern "c" fn writev(fd: c_int, iov: ?*const anyopaque, cnt: c_int) isize;
    extern "c" fn send(fd: c_int, buf: ?*const anyopaque, len: usize, flags: c_int) isize;
    extern "c" fn recv(fd: c_int, buf: ?*anyopaque, len: usize, flags: c_int) isize;
    extern "c" fn sendmsg(fd: c_int, msg: ?*const anyopaque, flags: c_int) isize;
    extern "c" fn recvmsg(fd: c_int, msg: ?*anyopaque, flags: c_int) isize;
    extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
    extern "c" fn connect(fd: c_int, addr: ?*const anyopaque, len: u32) c_int;
    extern "c" fn getsockopt(fd: c_int, level: c_int, name: u32, val: ?*anyopaque, len: *u32) c_int;
    extern "c" fn sendfile(fd: c_int, s: c_int, offset: i64, len: *i64, hdtr: ?*anyopaque, flags: c_int) c_int;
};

// os_sync_wait_on_address family (macOS 14.4+), weak so older systems still load.
pub const os_sync = struct {
    const WaitFn = *const fn (?*anyopaque, u64, usize, u32) callconv(.c) c_int;
    const WaitTimeoutFn = *const fn (?*anyopaque, u64, usize, u32, u32, u64) callconv(.c) c_int;
    const WakeFn = *const fn (?*anyopaque, usize, u32) callconv(.c) c_int;
    const OS_CLOCK_MACH_ABSOLUTE_TIME: u32 = 32;

    fn wait() ?WaitFn {
        return @extern(?WaitFn, .{ .name = "os_sync_wait_on_address", .linkage = .weak });
    }
    fn waitTimeout() ?WaitTimeoutFn {
        return @extern(?WaitTimeoutFn, .{ .name = "os_sync_wait_on_address_with_timeout", .linkage = .weak });
    }
    fn wakeAny() ?WakeFn {
        return @extern(?WakeFn, .{ .name = "os_sync_wake_by_address_any", .linkage = .weak });
    }
    fn available() bool {
        return wait() != null and waitTimeout() != null and wakeAny() != null;
    }
};

// Op scratch: priv[0] queue link, priv[1] state, priv[2] owning Kq, priv[3] unused,
// priv[4] timer heap index, or priv[4]/priv[5] prev/next in the Kq's GCD op list, priv[6] connect-in-progress.
const State = enum(usize) { idle = 0, queued, running, cancelled, timer, waiting, done };

fn getState(op: *Op) State {
    return @fromBackingInt(@intCast(@intFromPtr(op.priv[1])));
}
fn setState(op: *Op, s: State) void {
    op.priv[1] = @ptrFromInt(@backingInt(s));
}

fn gcdPrev(op: *Op) ?*Op {
    return @ptrCast(@alignCast(op.priv[4]));
}
fn gcdNext(op: *Op) ?*Op {
    return @ptrCast(@alignCast(op.priv[5]));
}

/// Ops waiting for readiness of one descriptor.
const Waiters = struct {
    read: Queue = .{},
    write: Queue = .{},

    fn queue(w: *Waiters, write: bool) *Queue {
        return if (write) &w.write else &w.read;
    }
};

const Kq = struct {
    allocator: std.mem.Allocator,
    kq: c_int,
    mutex: c.pthread_mutex_t = .{},
    cond: c.pthread_cond_t = .{},

    // Guarded by `mutex`.
    done: Queue = .{},
    posts_head: ?*PostNode = null,
    posts_tail: ?*PostNode = null,
    inflight: usize = 0,

    // Loop thread only.
    ready: Queue = .{},
    /// Timeout ops, ordered by deadline (heap index in priv[4]). No kernel timer per op: `poll`
    /// blocks in kevent with the earliest deadline as its timeout.
    timers: tm.Timers = .{ .slot = 4 },
    /// Ops parked on socket readiness, per descriptor and direction (FIFO each), indexed by
    /// descriptor number: descriptors are small dense integers, so this is a plain array lookup
    /// instead of a hash.
    waiters: std.ArrayList(Waiters) = .empty,
    /// Filter registrations not yet handed to the kernel; `poll` passes them in its own `kevent`
    /// call, so arming a wait costs no syscall of its own.
    changes: [change_batch]c.Kevent = undefined,
    nchanges: usize = 0,
    /// Every op handed to GCD and not yet reported (doubly linked through priv[4]/priv[5]).
    gcd_head: ?*Op = null,

    fn lock(k: *Kq) void {
        _ = c.pthread_mutex_lock(&k.mutex);
    }
    fn unlock(k: *Kq) void {
        _ = c.pthread_mutex_unlock(&k.mutex);
    }

    /// Registers interest in `fd` for the next `poll`. `EV_DISPATCH` makes the filter level
    /// triggered but disables it after each delivery; adding it again (with `EV_ENABLE`, which an existing disabled filter needs) re-enables it, so there is
    /// no one-shot re-registration per op, no `dup`, and no `close`.
    fn watch(k: *Kq, fd: c_int, write: bool) void {
        if (k.nchanges == change_batch) k.flushChanges();
        k.changes[k.nchanges] = .{
            .ident = @intCast(fd),
            .filter = if (write) c.EVFILT.WRITE else c.EVFILT.READ,
            .flags = c.EV.ADD | c.EV.ENABLE | c.EV.DISPATCH,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
        k.nchanges += 1;
    }

    /// Hands queued registrations to the kernel now (only when the batch is full or on destroy).
    /// A failed registration fails the ops waiting on it.
    fn flushChanges(k: *Kq) void {
        if (k.nchanges == 0) return;
        var errs: [change_batch]c.Kevent = undefined;
        const zero: c.timespec = .{ .sec = 0, .nsec = 0 };
        // `EV_RECEIPT` makes this call return only the receipts of the changes (an `EV_ERROR` entry
        // each, `data` 0 on success) and leave pending events in the queue. Without it the event
        // list would also dequeue ready events, and a disabled `EV_DISPATCH` filter never reports
        // them again.
        for (k.changes[0..k.nchanges]) |*change| change.flags |= c.EV.RECEIPT;
        const n = c.kevent(k.kq, &k.changes, @intCast(k.nchanges), &errs, errs.len, &zero);
        k.nchanges = 0;
        if (n <= 0) return;
        for (errs[0..@intCast(n)]) |ev| k.failWaiters(ev);
    }

    /// If `ev` reports a failed registration (`EV_ERROR`), completes that descriptor's waiters.
    fn failWaiters(k: *Kq, ev: c.Kevent) void {
        if (ev.flags & c.EV.ERROR == 0 or ev.data == 0) return;
        const w = k.waitersOf(@intCast(ev.ident)) orelse return;
        const q = w.queue(ev.filter == c.EVFILT.WRITE);
        while (q.pop()) |op| finishLocal(k, op, -@as(i64, ev.data));
    }

    fn waitersOf(k: *Kq, fd: c_int) ?*Waiters {
        if (fd < 0 or fd >= k.waiters.items.len) return null;
        return &k.waiters.items[@intCast(fd)];
    }

    /// The (possibly new) queues of `fd`; null when out of memory or `fd` is absurdly large.
    fn waitersFor(k: *Kq, fd: c_int) ?*Waiters {
        if (fd < 0 or fd > max_fd) return null;
        const need: usize = @as(usize, @intCast(fd)) + 1;
        if (need > k.waiters.items.len) k.waiters.appendNTimes(k.allocator, .{}, need - k.waiters.items.len) catch return null;
        return &k.waiters.items[@intCast(fd)];
    }

    fn trigger(k: *Kq) void {
        const ev = [1]c.Kevent{.{
            .ident = user_ident,
            .filter = c.EVFILT.USER,
            .flags = 0,
            .fflags = c.NOTE.TRIGGER,
            .data = 0,
            .udata = 0,
        }};
        var out: [1]c.Kevent = undefined;
        _ = c.kevent(k.kq, &ev, 1, &out, 0, null);
    }

    fn gcdLink(k: *Kq, op: *Op) void {
        op.priv[4] = null;
        op.priv[5] = k.gcd_head;
        if (k.gcd_head) |h| h.priv[4] = op;
        k.gcd_head = op;
    }

    fn gcdUnlink(k: *Kq, op: *Op) void {
        const prev = gcdPrev(op);
        const next = gcdNext(op);
        if (prev) |p| p.priv[5] = next else k.gcd_head = next;
        if (next) |n| n.priv[4] = prev;
        op.priv[4] = null;
        op.priv[5] = null;
    }
};

fn negErrno() i64 {
    return -@as(i64, @backingInt(c.errno(@as(isize, -1))));
}

fn sys(rc: anytype) i64 {
    if (rc < 0) return negErrno();
    return @intCast(rc);
}

fn errno(e: c.E) i64 {
    return -@as(i64, @backingInt(e));
}

pub fn ecanceled() i64 {
    return errno(.CANCELED);
}

fn atFd(fd: op_mod.Fd) c_int {
    if (fd == op_mod.fd_cwd) return c.AT.FDCWD;
    return @intCast(fd);
}

fn openFlags(aux: u64) u32 {
    var f: u32 = @intCast(aux & 3); // RDONLY/WRONLY/RDWR share values with Darwin
    if (aux & op_mod.O.CREAT != 0) f |= 0x200;
    if (aux & op_mod.O.TRUNC != 0) f |= 0x400;
    if (aux & op_mod.O.APPEND != 0) f |= 0x8;
    if (aux & op_mod.O.EXCL != 0) f |= 0x800;
    if (aux & op_mod.O.DIRECTORY != 0) f |= 0x100000;
    return f | O_CLOEXEC;
}

extern "c" fn openat(fd: c_int, path: [*:0]const u8, oflag: c_int, ...) c_int;

fn fillStat(out: *op_mod.Stat, st: *const c.Stat) void {
    const mode: u32 = @intCast(st.mode);
    out.* = .{
        .size = @intCast(st.size),
        .mode = mode & 0o7777,
        .kind = switch (mode & S_IFMT) {
            0o100000 => 1,
            0o040000 => 2,
            0o120000 => 3,
            else => 0,
        },
    };
}

fn isNonblocking(fd: op_mod.Fd) bool {
    const fl = sc.fcntl(@intCast(fd), F_GETFL);
    return fl >= 0 and (fl & O_NONBLOCK) != 0;
}

fn doFallocate(op: *Op) i64 {
    const fd: c_int = @intCast(op.fd);
    if (op.offset < 0 or op.len == 0) return errno(.INVAL);
    const end = std.math.add(i64, op.offset, std.math.cast(i64, op.len) orelse return errno(.INVAL)) catch return errno(.FBIG);
    var st: c.Stat = undefined;
    if (c.fstat(fd, &st) < 0) return negErrno();
    const size: i64 = @intCast(st.size);
    if (end > size) {
        var store: Fstore = .{ .flags = F_ALLOCATECONTIG | F_ALLOCATEALL, .posmode = F_PEOFPOSMODE, .offset = 0, .length = end - size, .bytesalloc = 0 };
        if (sc.fcntl(fd, F_PREALLOCATE, &store) < 0) {
            // Contiguous space may be unavailable; retry with any layout.
            store.flags = F_ALLOCATEALL;
            if (sc.fcntl(fd, F_PREALLOCATE, &store) < 0) return negErrno();
        }
        if (op.aux & op_mod.FallocFlags.KEEP_SIZE == 0) {
            if (sc.ftruncate(fd, end) < 0) return negErrno();
        }
    }
    return 0;
}

extern "c" fn __getdirentries64(fd: c_int, buf: [*]u8, len: usize, basep: *i64) isize;

/// Darwin `struct dirent` (64-bit inodes): ino u64, seekoff u64, reclen u16, namlen u16, type u8,
/// name at offset 21. `d_seekoff` is 0 on APFS and the fd position is an opaque (chunk, index)
/// pair, so the only valid cookie is the fd position right after a read. To never over-read, each
/// read is limited to the space left in the output: a packed entry (3 + namlen bytes) is always
/// smaller than its dirent (>= 24 + namlen), so everything the kernel returns fits.
const dirent_name_off = 21;
const dirent_min = 32;

fn doReaddir(op: *Op) i64 {
    const fd: c_int = @intCast(op.fd);
    const out: [*]u8 = @ptrCast(op.buf orelse return errno(.INVAL));
    if (op.offset < 0) return errno(.INVAL);
    if (sc.lseek(fd, op.offset, SEEK_SET) < 0) return negErrno();
    var scratch_buf: [64 * 1024]u8 align(8) = undefined;
    var total: usize = 0;
    while (true) {
        const room = op.len - total;
        if (room < dirent_min) {
            if (total == 0) return errno(.RANGE);
            break;
        }
        var base: i64 = 0;
        const n = __getdirentries64(fd, &scratch_buf, @min(scratch_buf.len, room), &base);
        if (n < 0) {
            const e = negErrno();
            if (e == errno(.INTR)) continue;
            // Too small for the next entry's dirent.
            if (e == errno(.INVAL)) {
                if (total == 0) return errno(.RANGE);
                break;
            }
            if (total > 0) break;
            return e;
        }
        if (n == 0) break;
        var pos: usize = 0;
        const end: usize = @intCast(n);
        while (pos + dirent_name_off <= end) {
            const ent = scratch_buf[pos..];
            const reclen = std.mem.readInt(u16, ent[16..18], .little);
            const namlen = std.mem.readInt(u16, ent[18..20], .little);
            const dtype = ent[20];
            if (reclen == 0) break;
            const name = ent[dirent_name_off..][0..namlen];
            pos += reclen;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var kind: u8 = switch (dtype) {
                8 => 1,
                4 => 2,
                10 => 3,
                else => 0,
            };
            if (dtype == 0) {
                var z: [1025]u8 = undefined;
                @memcpy(z[0..namlen], name);
                z[namlen] = 0;
                var st: c.Stat = undefined;
                if (sc.fstatat(fd, @ptrCast(&z), &st, AT_SYMLINK_NOFOLLOW) == 0) {
                    kind = switch (@as(u32, @intCast(st.mode)) & S_IFMT) {
                        0o100000 => 1,
                        0o040000 => 2,
                        0o120000 => 3,
                        else => 0,
                    };
                }
            }
            out[total] = kind;
            std.mem.writeInt(u16, out[total + 1 ..][0..2], namlen, .little);
            @memcpy(out[total + 3 ..][0..namlen], name);
            total += 3 + namlen;
        }
    }
    const cur = sc.lseek(fd, 0, SEEK_CUR);
    if (cur < 0) return negErrno();
    op.aux = @intCast(cur);
    return @intCast(total);
}

fn doSendfile(op: *Op) i64 {
    const out: c_int = @intCast(op.fd);
    const in: c_int = @intCast(op.fd2);
    if (op.len == 0) return 0; // sendfile(2) treats 0 as "to EOF"
    var st: c.Stat = undefined;
    if (c.fstat(out, &st) < 0) return negErrno();
    const explicit = op.offset >= 0;
    var pos: i64 = op.offset;
    if (!explicit) {
        pos = sc.lseek(in, 0, SEEK_CUR);
        if (pos < 0) return negErrno();
    }
    var total: usize = 0;
    if ((@as(u32, @intCast(st.mode)) & S_IFMT) == S_IFSOCK) {
        var l: i64 = std.math.cast(i64, op.len) orelse std.math.maxInt(i64);
        const rc = sc.sendfile(in, out, pos, &l, null, 0);
        if (rc < 0) {
            const e = negErrno();
            // A partial transfer is reported through `l`.
            if (!(l > 0 and (e == errno(.AGAIN) or e == errno(.INTR)))) return e;
        }
        total = @intCast(l);
    } else {
        var buf: [64 * 1024]u8 = undefined;
        while (total < op.len) {
            const want = @min(buf.len, op.len - total);
            const n = c.pread(in, &buf, want, pos + @as(i64, @intCast(total)));
            if (n < 0) {
                const e = negErrno();
                if (e == errno(.INTR)) continue;
                if (total > 0) break;
                return e;
            }
            if (n == 0) break;
            var off: usize = 0;
            const got: usize = @intCast(n);
            while (off < got) {
                const w = c.write(out, buf[off..].ptr, got - off);
                if (w < 0) {
                    const e = negErrno();
                    if (e == errno(.INTR)) continue;
                    if (total + off > 0) {
                        total += off;
                        off = got;
                        break;
                    }
                    return e;
                }
                off += @intCast(w);
            }
            total += off;
            if (off < got) break;
        }
    }
    if (!explicit) _ = sc.lseek(in, pos + @as(i64, @intCast(total)), SEEK_SET);
    return @intCast(total);
}

fn doFutexWait(op: *Op) i64 {
    const wait = os_sync.wait() orelse return errno(.NOSYS);
    const wait_t = os_sync.waitTimeout() orelse return errno(.NOSYS);
    const addr: *u32 = @ptrCast(@alignCast(op.buf orelse return errno(.INVAL)));
    const expected: u32 = @truncate(op.aux);
    if (@atomicLoad(u32, addr, .seq_cst) != expected) return errno(.AGAIN);
    while (true) {
        const rc = if (op.offset < 0)
            wait(addr, expected, 4, 0)
        else
            wait_t(addr, expected, 4, 0, os_sync.OS_CLOCK_MACH_ABSOLUTE_TIME, @intCast(op.offset));
        if (rc >= 0) return 0;
        const e = negErrno();
        if (e == errno(.INTR)) {
            if (@atomicLoad(u32, addr, .seq_cst) != expected) return 0;
            continue;
        }
        return e; // ETIMEDOUT passes through
    }
}

/// Runs on the loop thread. Waiters submitted through this backend are tracked by scanning the
/// Kq's GCD op list (every outstanding futex_wait is in it until poll hands it out). Marks in
/// priv[6]: 2 = "a wake was issued for this slot", 3 = completed by a wake and already accounted.
/// The kernel wakes *some* waiter on the address, not necessarily the marked one, so when an
/// unmarked wait is seen finished by a wake, one marked-but-still-waiting op is unmarked again.
/// A wake then marks min(count, unmarked waiting ops), issues that many kernel wakes and returns
/// that number; woken-but-unreported waits are never counted twice.
fn doFutexWake(op: *Op) i64 {
    const wake_any = os_sync.wakeAny() orelse return errno(.NOSYS);
    const addr = op.buf orelse return errno(.INVAL);
    const k: *Kq = @ptrCast(@alignCast(op.priv[2].?));
    var woken: i64 = 0;
    k.lock();
    // Reconcile waits that finished through a wake we have not accounted for.
    var it = k.gcd_head;
    while (it) |w| : (it = gcdNext(w)) reconcileWait(k, w);
    it = k.gcd_head;
    while (it) |w| : (it = gcdNext(w)) {
        if (woken >= op.aux) break;
        if (w.kind != .futex_wait or w.buf != addr or w.priv[6] != null or !isWaiting(w)) continue;
        w.priv[6] = @ptrFromInt(2);
        woken += 1;
    }
    k.unlock();
    var i: i64 = 0;
    while (i < woken) : (i += 1) _ = wake_any(addr, 4, 0);
    return woken;
}

/// Mutex held. If `w` is a futex wait that finished successfully and was not yet accounted for,
/// mark it accounted and give one marked-but-still-waiting op on the same address its slot back.
fn reconcileWait(k: *Kq, w: *Op) void {
    if (w.kind != .futex_wait or w.priv[6] != null) return;
    if (getState(w) != .done or w.result != 0) return;
    w.priv[6] = @ptrFromInt(3);
    var jt = k.gcd_head;
    while (jt) |x| : (jt = gcdNext(x)) {
        if (x.kind == .futex_wait and x.buf == w.buf and x.priv[6] == @as(?*anyopaque, @ptrFromInt(2)) and isWaiting(x)) {
            x.priv[6] = null;
            break;
        }
    }
}

fn isWaiting(w: *Op) bool {
    return switch (getState(w)) {
        .queued, .running => true,
        else => false,
    };
}

/// Runs on a GCD thread, or on the loop thread for non-blocking socket attempts (where a result of
/// -EAGAIN / -EINPROGRESS means "wait for readiness").
fn execute(op: *Op) i64 {
    const inval = errno(.INVAL);
    switch (op.kind) {
        .open => {
            const path = op.path orelse return inval;
            const mode: c_uint = @truncate(op.aux >> 32);
            return sys(openat(atFd(op.fd), path, @bitCast(openFlags(op.aux)), mode));
        },
        .close => return sys(c.close(@intCast(op.fd))),
        .read => {
            const buf: [*]u8 = @ptrCast(op.buf orelse return inval);
            const fd: c_int = @intCast(op.fd);
            return if (op.offset < 0)
                sys(c.read(fd, buf, op.len))
            else
                sys(c.pread(fd, buf, op.len, op.offset));
        },
        .write => {
            const buf: [*]const u8 = @ptrCast(op.buf orelse return inval);
            const fd: c_int = @intCast(op.fd);
            return if (op.offset < 0)
                sys(c.write(fd, buf, op.len))
            else
                sys(c.pwrite(fd, buf, op.len, op.offset));
        },
        .fstat => {
            const out: *op_mod.Stat = @ptrCast(@alignCast(op.buf orelse return inval));
            var st: c.Stat = undefined;
            const rc = c.fstat(@intCast(op.fd), &st);
            if (rc < 0) return negErrno();
            fillStat(out, &st);
            return 0;
        },
        .stat => {
            const out: *op_mod.Stat = @ptrCast(@alignCast(op.buf orelse return inval));
            const path = op.path orelse return inval;
            var st: c.Stat = undefined;
            const fl: c_int = if (op.flags & 1 != 0) AT_SYMLINK_NOFOLLOW else 0;
            if (sc.fstatat(atFd(op.fd), path, &st, fl) < 0) return negErrno();
            fillStat(out, &st);
            return 0;
        },
        .mkdir => {
            const path = op.path orelse return inval;
            return sys(c.mkdirat(atFd(op.fd), path, @intCast(op.aux & 0o7777)));
        },
        .unlink => {
            const path = op.path orelse return inval;
            // AT_REMOVEDIR (0x80) is selected by flags bit 0.
            const flags: c_uint = if (op.flags & 1 != 0) 0x80 else 0;
            return sys(c.unlinkat(atFd(op.fd), path, flags));
        },
        .rename => {
            const from = op.path orelse return inval;
            const to = op.path2 orelse return inval;
            return sys(c.renameat(atFd(op.fd), from, atFd(op.fd2), to));
        },
        .link => {
            const from = op.path orelse return inval;
            const to = op.path2 orelse return inval;
            return sys(sc.linkat(atFd(op.fd), from, atFd(op.fd2), to, 0));
        },
        .fsync => {
            const fd: c_int = @intCast(op.fd);
            if (op.flags & 1 == 0) {
                if (sc.fcntl(fd, F_FULLFSYNC, @as(c_int, 0)) >= 0) return 0;
                const e = negErrno();
                if (e != errno(.OPNOTSUPP) and e != errno(.INVAL)) return e;
            }
            return sys(c.fsync(fd));
        },
        .fallocate => return doFallocate(op),
        .ftruncate => {
            if (op.offset < 0) return inval;
            while (true) {
                const r = sys(sc.ftruncate(@intCast(op.fd), op.offset));
                if (r != errno(.INTR)) return r;
            }
        },
        .readdir => return doReaddir(op),
        .sendfile => return doSendfile(op),
        .readv, .writev => {
            const fd: c_int = @intCast(op.fd);
            const iov = op.buf orelse return inval;
            const cnt: c_int = std.math.cast(c_int, op.len) orelse return inval;
            while (true) {
                const rc = if (op.kind == .readv)
                    (if (op.offset < 0) sc.readv(fd, iov, cnt) else sc.preadv(fd, iov, cnt, op.offset))
                else
                    (if (op.offset < 0) sc.writev(fd, iov, cnt) else sc.pwritev(fd, iov, cnt, op.offset));
                const r = sys(rc);
                if (r != errno(.INTR)) return r;
            }
        },
        .send, .recv, .sendmsg, .recvmsg => {
            const fd: c_int = @intCast(op.fd);
            const fl: c_int = @bitCast(op.flags);
            while (true) {
                const rc = switch (op.kind) {
                    .send => sc.send(fd, op.buf, op.len, fl),
                    .recv => sc.recv(fd, op.buf, op.len, fl),
                    .sendmsg => sc.sendmsg(fd, op.buf, fl),
                    else => sc.recvmsg(fd, op.buf, fl),
                };
                const r = sys(rc);
                if (r != errno(.INTR)) return r;
            }
        },
        .accept => {
            const fd: c_int = @intCast(op.fd);
            while (true) {
                var len: u32 = @intCast(@min(op.len, std.math.maxInt(u32)));
                const nfd = sc.accept(fd, op.buf, if (op.buf != null) &len else null);
                if (nfd < 0) {
                    const e = negErrno();
                    if (e == errno(.INTR)) continue;
                    return e;
                }
                _ = sc.fcntl(nfd, F_SETFD, FD_CLOEXEC);
                if (op.buf != null) op.aux = len;
                return nfd;
            }
        },
        .connect => {
            const fd: c_int = @intCast(op.fd);
            if (op.priv[6] != null) {
                // Readiness reached after EINPROGRESS: collect the connection result.
                var err: c_int = 0;
                var l: u32 = @sizeOf(c_int);
                if (sc.getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &l) < 0) return negErrno();
                return if (err == 0) 0 else -@as(i64, err);
            }
            const addr = op.buf orelse return inval;
            const rc = sc.connect(fd, addr, @intCast(op.len));
            if (rc == 0) return 0;
            const e = negErrno();
            // An interrupted connect keeps going in the background, like EINPROGRESS.
            return if (e == errno(.INTR)) errno(.INPROGRESS) else e;
        },
        .futex_wait => return doFutexWait(op),
        .futex_wake => return doFutexWake(op),
        else => return errno(.NOSYS),
    }
}

fn work(ctx: ?*anyopaque) callconv(.c) void {
    const op: *Op = @ptrCast(@alignCast(ctx.?));
    const k: *Kq = @ptrCast(@alignCast(op.priv[2].?));
    var res: i64 = undefined;
    k.lock();
    const skip = getState(op) == .cancelled;
    if (!skip) setState(op, .running);
    k.unlock();
    res = if (skip) ecanceled() else execute(op);
    k.lock();
    op.result = res;
    setState(op, .done);
    k.done.push(op);
    k.trigger();
    k.inflight -= 1;
    _ = c.pthread_cond_broadcast(&k.cond);
    k.unlock();
    // `k` may be freed from here on.
}

fn kqOf(ctx: *anyopaque) *Kq {
    return @ptrCast(@alignCast(ctx));
}

fn toGcd(k: *Kq, op: *Op) void {
    k.lock();
    k.inflight += 1;
    setState(op, .queued);
    k.unlock();
    k.gcdLink(op);
    const q = dispatch.dispatch_get_global_queue(dispatch.QOS_CLASS_USER_INITIATED, 0);
    dispatch.dispatch_async_f(q, op, work);
}

fn waitsForWrite(kind: op_mod.Kind) bool {
    return kind == .send or kind == .sendmsg or kind == .connect;
}

/// Parks `op` until its descriptor is ready (FIFO among ops of the same descriptor and
/// direction). Returns an error result (-errno) if it cannot be queued.
fn armWait(k: *Kq, op: *Op) ?i64 {
    const fd: c_int = @intCast(op.fd);
    const w = k.waitersFor(fd) orelse return errno(.NOMEM);
    const write = waitsForWrite(op.kind);
    w.queue(write).push(op);
    setState(op, .waiting);
    k.watch(fd, write);
    return null;
}

/// Removes a parked op from its descriptor's queue.
fn unwait(k: *Kq, op: *Op) void {
    const fd: c_int = @intCast(op.fd);
    if (k.waitersOf(fd)) |w| _ = w.queue(waitsForWrite(op.kind)).remove(op);
}

/// Tries a non-blocking socket op on the loop thread. Returns null if it must wait for readiness.
fn attemptSocket(op: *Op) ?i64 {
    const r = execute(op);
    if (r == errno(.AGAIN)) return null;
    if (op.kind == .connect and op.priv[6] == null and r == errno(.INPROGRESS)) {
        op.priv[6] = @ptrFromInt(1);
        return null;
    }
    return r;
}

fn submit(ctx: *anyopaque, op: *Op) anyerror!void {
    const k = kqOf(ctx);
    op.priv[1] = null;
    op.priv[2] = k;
    op.priv[3] = null;
    op.priv[4] = null;
    op.priv[5] = null;
    op.priv[6] = null;
    switch (op.kind) {
        .nop => finishLocal(k, op, 0),
        .timeout => {
            const deadline = tm.deadlineAfter(tm.nowNs(), op.aux);
            k.timers.push(k.allocator, op, deadline) catch return finishLocal(k, op, errno(.NOMEM));
            setState(op, .timer);
        },
        .open, .close, .read, .write, .fstat, .mkdir, .unlink, .rename => toGcd(k, op),
        .fsync, .fallocate, .ftruncate, .readdir, .sendfile, .stat, .link, .readv, .writev, .futex_wait => toGcd(k, op),
        // Never blocks: complete inline.
        .futex_wake => finishLocal(k, op, doFutexWake(op)),
        .send, .recv, .sendmsg, .recvmsg, .accept, .connect => {
            if (!isNonblocking(op.fd)) return toGcd(k, op);
            // Receiving ops usually find nothing yet: park first (readiness is level triggered,
            // so data that is already there is reported at the next poll) instead of paying
            // for a syscall that returns EAGAIN. Sending ops and connect try right away.
            if (!waitsForWrite(op.kind)) {
                if (armWait(k, op)) |err| finishLocal(k, op, err);
                return;
            }
            if (attemptSocket(op)) |res| return finishLocal(k, op, res);
            if (armWait(k, op)) |err| finishLocal(k, op, err);
        },
        else => finishLocal(k, op, errno(.NOSYS)),
    }
}

/// Completes `op` on the loop thread at the next poll.
fn finishLocal(k: *Kq, op: *Op, res: i64) void {
    op.result = res;
    setState(op, .done);
    k.ready.push(op);
}

fn cancel(ctx: *anyopaque, op: *Op) bool {
    const k = kqOf(ctx);
    switch (getState(op)) {
        .idle => return false,
        .timer => {
            _ = k.timers.remove(op);
            finishLocal(k, op, ecanceled());
            return true;
        },
        .waiting => {
            unwait(k, op);
            finishLocal(k, op, ecanceled());
            return true;
        },
        .queued => {
            k.lock();
            if (getState(op) == .queued) setState(op, .cancelled);
            k.unlock();
            return true;
        },
        .running, .cancelled, .done => return true,
    }
}

fn handOut(op: *Op, out: *Drained) void {
    setState(op, .idle);
    out.done.push(op);
}

/// Moves the shared lists into `out`. Takes the mutex.
fn drainShared(k: *Kq, out: *Drained) void {
    k.lock();
    var done = k.done;
    k.done = .{};
    var posts = k.posts_head;
    k.posts_head = null;
    k.posts_tail = null;
    k.unlock();
    while (done.pop()) |op| {
        if (op.kind == .futex_wait) {
            k.lock();
            reconcileWait(k, op);
            k.unlock();
        }
        k.gcdUnlink(op);
        handOut(op, out);
    }
    while (posts) |n| {
        posts = n.next;
        out.pushPost(n);
    }
}

fn poll(ctx: *anyopaque, block: bool, out: *Drained) void {
    const k = kqOf(ctx);
    while (k.ready.pop()) |op| handOut(op, out);

    var timeout: c.timespec = .{ .sec = 0, .nsec = 0 };
    const nonblocking = !block or out.done.head != null;
    if (!nonblocking) {
        if (k.timers.peek()) |dl| {
            const now = tm.nowNs();
            const wait = if (dl > now) dl - now else 0;
            timeout = .{ .sec = @intCast(wait / std.time.ns_per_s), .nsec = @intCast(wait % std.time.ns_per_s) };
        }
    }
    const bounded = nonblocking or !k.timers.isEmpty();
    var events: [event_batch]c.Kevent = undefined;
    // The pending registrations ride along on this call (event_batch >= change_batch, so their
    // failures always fit in the event list).
    const nchanges = k.nchanges;
    const n = c.kevent(k.kq, &k.changes, @intCast(nchanges), &events, events.len, if (bounded) &timeout else null);
    if (n >= 0 or c.errno(@as(isize, -1)) != .INTR) k.nchanges = 0;
    if (n > 0) {
        for (events[0..@intCast(n)]) |ev| {
            // EVFILT_USER is the wake: the shared lists are drained below.
            if (ev.filter != c.EVFILT.READ and ev.filter != c.EVFILT.WRITE) continue;
            if (ev.flags & c.EV.ERROR != 0) {
                k.failWaiters(ev);
                continue;
            }
            serviceReady(k, @intCast(ev.ident), ev.filter == c.EVFILT.WRITE, out);
        }
    }
    if (!k.timers.isEmpty()) {
        const now = tm.nowNs();
        while (k.timers.popDue(now)) |op| {
            op.result = 0;
            handOut(op, out);
        }
    }
    drainShared(k, out);
}

/// A descriptor became ready: runs the first op waiting on it. The filter was disabled by the
/// delivery (`EV_DISPATCH`); it is re-armed only while someone still waits.
fn serviceReady(k: *Kq, fd: c_int, write: bool, out: *Drained) void {
    const w = k.waitersOf(fd) orelse return;
    const q = w.queue(write);
    const op = q.head orelse return;
    if (attemptSocket(op)) |res| {
        _ = q.pop();
        op.result = res;
        handOut(op, out);
    }
    if (!q.isEmpty()) k.watch(fd, write);
}

fn wake(ctx: *anyopaque) void {
    kqOf(ctx).trigger();
}

fn post(ctx: *anyopaque, func: backend.PostFn, ud: ?*anyopaque) anyerror!void {
    const k = kqOf(ctx);
    // Nodes are freed by whoever runs them (Loop), with the same thread-safe allocator.
    const node = try std.heap.c_allocator.create(PostNode);
    node.* = .{ .func = func, .ud = ud };
    k.lock();
    if (k.posts_tail) |t| t.next = node else k.posts_head = node;
    k.posts_tail = node;
    k.unlock();
    k.trigger();
}

fn pollable(ctx: *anyopaque) isize {
    return kqOf(ctx).kq;
}

fn destroy(ctx: *anyopaque, out: *Drained) void {
    const k = kqOf(ctx);

    // Cancel everything that can be cancelled before waiting for the rest.
    while (k.timers.popFirst()) |op| {
        op.result = ecanceled();
        handOut(op, out);
    }
    for (k.waiters.items) |*entry| {
        inline for (.{ &entry.read, &entry.write }) |q| {
            while (q.pop()) |op| {
                op.result = ecanceled();
                handOut(op, out);
            }
        }
    }
    k.waiters.deinit(k.allocator);
    k.lock();
    var it = k.gcd_head;
    while (it) |op| : (it = gcdNext(op)) {
        if (getState(op) == .queued) setState(op, .cancelled);
    }
    // Only ops already blocked inside a syscall remain; they cannot be interrupted.
    while (k.inflight != 0) _ = c.pthread_cond_wait(&k.cond, &k.mutex);
    k.unlock();

    while (k.ready.pop()) |op| handOut(op, out);
    drainShared(k, out);

    k.timers.deinit(k.allocator);
    _ = c.close(k.kq);
    _ = c.pthread_cond_destroy(&k.cond);
    _ = c.pthread_mutex_destroy(&k.mutex);
    k.allocator.destroy(k);
}

const base_caps = backend.Caps.nop | backend.Caps.file_io | backend.Caps.timeout | backend.Caps.cancel |
    backend.Caps.pollable | backend.Caps.vectored | backend.Caps.sockets | backend.Caps.sendfile |
    backend.Caps.fallocate | backend.Caps.link | backend.Caps.sync | backend.Caps.readdir | backend.Caps.ftruncate;

const vtable: backend.VTable = .{
    .submit = submit,
    .cancel = cancel,
    .poll = poll,
    .wake = wake,
    .post = post,
    .pollable = pollable,
    .caps = base_caps,
    .destroy = destroy,
};

/// Same, with the futex bit; chosen when os_sync_wait_on_address is present at runtime.
const vtable_futex: backend.VTable = .{
    .submit = submit,
    .cancel = cancel,
    .poll = poll,
    .wake = wake,
    .post = post,
    .pollable = pollable,
    .caps = base_caps | backend.Caps.futex,
    .destroy = destroy,
};

pub fn create(allocator: std.mem.Allocator, opts: backend.Options) !backend.Backend {
    _ = opts;
    if (comptime !supported) return error.Unsupported;
    const kq = c.kqueue();
    if (kq < 0) return error.SystemResources;
    errdefer _ = c.close(kq);
    const k = try allocator.create(Kq);
    k.* = .{ .allocator = allocator, .kq = kq };
    const ev = [1]c.Kevent{.{
        .ident = user_ident,
        .filter = c.EVFILT.USER,
        .flags = c.EV.ADD | c.EV.CLEAR,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    }};
    var out: [1]c.Kevent = undefined;
    if (c.kevent(kq, &ev, 1, &out, 0, null) < 0) {
        allocator.destroy(k);
        return error.SystemResources;
    }
    return .{ .ctx = k, .vtable = if (os_sync.available()) &vtable_futex else &vtable };
}
