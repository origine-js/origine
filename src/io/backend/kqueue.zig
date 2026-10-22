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

const c = std.c;

/// Events fetched per kevent call (uSockets uses 1024; 256 keeps the stack frame at 8 KiB).
const event_batch = 256;
/// Registrations buffered between polls; at most `event_batch` so errors fit the event list.
const change_batch = 64;

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
const O_CLOEXEC: u32 = 0x01000000;
const O_NONBLOCK: c_int = 0x4;
const AT_SYMLINK_NOFOLLOW: c_int = 0x20;
const F_GETFL: c_int = 3;
const F_SETFD: c_int = 2;
const F_FULLFSYNC: c_int = 51;
const F_PREALLOCATE: c_int = 42;
const F_ALLOCATECONTIG: c_uint = 2;
const F_ALLOCATEALL: c_uint = 4;
const F_PEOFPOSMODE: c_int = 3;
const FD_CLOEXEC: c_int = 1;
const SOL_SOCKET: c_int = 0xffff;
const SO_ERROR: u32 = 0x1007;
const SEEK_SET: c_int = 0;
const SEEK_CUR: c_int = 1;
const user_ident: usize = 1;

const Fstore = extern struct { flags: c_uint, posmode: c_int, offset: i64, length: i64, bytesalloc: i64 };

// Declared locally with plain types; the symbols are the same libSystem functions std uses.
const sc = struct {
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
const os_sync = struct {
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
    /// Ops parked on socket readiness, per descriptor and direction (FIFO each). Entries are
    /// dropped when both queues empty.
    fds: std.AutoHashMapUnmanaged(c_int, Waiters) = .empty,
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
        const n = c.kevent(k.kq, &k.changes, @intCast(k.nchanges), &errs, errs.len, &zero);
        k.nchanges = 0;
        if (n <= 0) return;
        for (errs[0..@intCast(n)]) |ev| k.failWaiters(ev);
    }

    /// If `ev` reports a failed registration (`EV_ERROR`), completes that descriptor's waiters.
    fn failWaiters(k: *Kq, ev: c.Kevent) void {
        if (ev.flags & c.EV.ERROR == 0 or ev.data == 0) return;
        const w = k.fds.getPtr(@intCast(ev.ident)) orelse return;
        const q = w.queue(ev.filter == c.EVFILT.WRITE);
        while (q.pop()) |op| finishLocal(k, op, -@as(i64, ev.data));
        k.dropIfIdle(@intCast(ev.ident));
    }

    fn dropIfIdle(k: *Kq, fd: c_int) void {
        const w = k.fds.getPtr(fd) orelse return;
        if (w.read.isEmpty() and w.write.isEmpty()) _ = k.fds.remove(fd);
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

fn ecanceled() i64 {
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
    const entry = k.fds.getOrPut(k.allocator, fd) catch return errno(.NOMEM);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    const write = waitsForWrite(op.kind);
    entry.value_ptr.queue(write).push(op);
    setState(op, .waiting);
    k.watch(fd, write);
    return null;
}

/// Removes a parked op from its descriptor's queue.
fn unwait(k: *Kq, op: *Op) void {
    const fd: c_int = @intCast(op.fd);
    if (k.fds.getPtr(fd)) |w| _ = w.queue(waitsForWrite(op.kind)).remove(op);
    k.dropIfIdle(fd);
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
    const w = k.fds.getPtr(fd) orelse return;
    const q = w.queue(write);
    const op = q.head orelse return;
    if (attemptSocket(op)) |res| {
        _ = q.pop();
        op.result = res;
        handOut(op, out);
    }
    if (!q.isEmpty()) k.watch(fd, write);
    k.dropIfIdle(fd);
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
    var wit = k.fds.iterator();
    while (wit.next()) |entry| {
        inline for (.{ &entry.value_ptr.read, &entry.value_ptr.write }) |q| {
            while (q.pop()) |op| {
                op.result = ecanceled();
                handOut(op, out);
            }
        }
    }
    k.fds.deinit(k.allocator);
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

// ---------------------------------------------------------------------------------------------
// Tests (drive the vtable directly)
// ---------------------------------------------------------------------------------------------

const testing = std.testing;
const scratch = "/tmp";

fn nowNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn sleepNs(ns: u64) void {
    var ts: c.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    _ = c.nanosleep(&ts, null);
}

/// Polls (blocking) until `want` ops completed; returns them in completion order.
fn collect(b: backend.Backend, want: usize, buf: []*Op) !usize {
    var n: usize = 0;
    var tries: usize = 0;
    while (n < want) {
        var d: Drained = .{};
        b.vtable.poll(b.ctx, true, &d);
        while (d.done.pop()) |op| {
            buf[n] = op;
            n += 1;
        }
        tries += 1;
        if (tries > 1000) return error.Stuck;
    }
    return n;
}

fn runOne(b: backend.Backend, op: *Op) !i64 {
    try b.vtable.submit(b.ctx, op);
    var buf: [1]*Op = undefined;
    _ = try collect(b, 1, &buf);
    try testing.expectEqual(op, buf[0]);
    return op.result;
}

test "write/read round trip" {
    if (!supported) return error.SkipZigTest;
    const b = try create(testing.allocator, .{});
    const path = scratch ++ "/kq_roundtrip.bin";

    var open_op: Op = .{ .kind = .open, .path = path, .aux = op_mod.O.RDWR | op_mod.O.CREAT | op_mod.O.TRUNC | (@as(u64, 0o644) << 32) };
    const fd = try runOne(b, &open_op);
    try testing.expect(fd >= 0);

    const msg = "hello kqueue";
    var w: Op = .{ .kind = .write, .fd = fd, .offset = 0, .buf = @constCast(msg.ptr), .len = msg.len };
    try testing.expectEqual(@as(i64, msg.len), try runOne(b, &w));

    var rbuf: [32]u8 = undefined;
    var r: Op = .{ .kind = .read, .fd = fd, .offset = 0, .buf = &rbuf, .len = rbuf.len };
    try testing.expectEqual(@as(i64, msg.len), try runOne(b, &r));
    try testing.expectEqualStrings(msg, rbuf[0..msg.len]);

    var st: op_mod.Stat = undefined;
    var f: Op = .{ .kind = .fstat, .fd = fd, .buf = &st };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &f));
    try testing.expectEqual(@as(u64, msg.len), st.size);
    try testing.expectEqual(@as(u32, 1), st.kind);

    var cl: Op = .{ .kind = .close, .fd = fd };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &cl));

    var un: Op = .{ .kind = .unlink, .path = path };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &un));
    // Second unlink fails with -ENOENT.
    var un2: Op = .{ .kind = .unlink, .path = path };
    try testing.expectEqual(-@as(i64, @backingInt(c.E.NOENT)), try runOne(b, &un2));

    var d: Drained = .{};
    b.vtable.destroy(b.ctx, &d);
    try testing.expect(d.done.isEmpty());
}

test "completions out of order" {
    if (!supported) return error.SkipZigTest;
    const b = try create(testing.allocator, .{});
    const t0 = nowNs();

    var slow: Op = .{ .kind = .timeout, .aux = 150 * std.time.ns_per_ms };
    var fast: Op = .{ .kind = .nop };
    try b.vtable.submit(b.ctx, &slow);
    try b.vtable.submit(b.ctx, &fast);

    var buf: [2]*Op = undefined;
    _ = try collect(b, 2, &buf);
    try testing.expectEqual(&fast, buf[0]);
    try testing.expectEqual(&slow, buf[1]);
    try testing.expectEqual(@as(i64, 0), slow.result);
    try testing.expect(nowNs() - t0 >= 140 * std.time.ns_per_ms);

    var d: Drained = .{};
    b.vtable.destroy(b.ctx, &d);
}

test "cancel" {
    if (!supported) return error.SkipZigTest;
    const b = try create(testing.allocator, .{});
    const t0 = nowNs();

    // Timer: cancelled immediately.
    var t: Op = .{ .kind = .timeout, .aux = 30 * std.time.ns_per_s };
    try b.vtable.submit(b.ctx, &t);
    try testing.expect(b.vtable.cancel(b.ctx, &t));
    var buf: [1]*Op = undefined;
    _ = try collect(b, 1, &buf);
    try testing.expectEqual(&t, buf[0]);
    try testing.expectEqual(ecanceled(), t.result);
    try testing.expect(nowNs() - t0 < 5 * std.time.ns_per_s);
    // No longer outstanding.
    try testing.expect(!b.vtable.cancel(b.ctx, &t));

    // GCD op: cancel races with start; result is either -ECANCELED or the real result.
    var bad: Op = .{ .kind = .unlink, .path = scratch ++ "/kq_does_not_exist" };
    try b.vtable.submit(b.ctx, &bad);
    try testing.expect(b.vtable.cancel(b.ctx, &bad));
    _ = try collect(b, 1, &buf);
    try testing.expect(bad.result == ecanceled() or bad.result == -@as(i64, @backingInt(c.E.NOENT)));

    var d: Drained = .{};
    b.vtable.destroy(b.ctx, &d);
}

const WakeArgs = struct { b: backend.Backend, do_post: bool };
var post_hits: usize = 0;

fn postFn(ud: ?*anyopaque) callconv(.c) void {
    _ = ud;
    post_hits += 1;
}

fn waker(a: *const WakeArgs) void {
    sleepNs(50 * std.time.ns_per_ms);
    if (a.do_post) {
        a.b.vtable.post(a.b.ctx, postFn, null) catch unreachable;
    } else {
        a.b.vtable.wake(a.b.ctx);
    }
}

test "wake and post from another thread unblock poll" {
    if (!supported) return error.SkipZigTest;
    const b = try create(testing.allocator, .{});
    // Keep a far timer alive so poll has something to block on.
    var t: Op = .{ .kind = .timeout, .aux = 30 * std.time.ns_per_s };
    try b.vtable.submit(b.ctx, &t);

    for ([_]bool{ false, true }) |do_post| {
        const args: WakeArgs = .{ .b = b, .do_post = do_post };
        const t0 = nowNs();
        const th = try std.Thread.spawn(.{}, waker, .{&args});
        var d: Drained = .{};
        b.vtable.poll(b.ctx, true, &d);
        th.join();
        try testing.expect(nowNs() - t0 < 5 * std.time.ns_per_s);
        try testing.expect(d.done.isEmpty());
        if (do_post) {
            const n = d.posts_head orelse return error.TestUnexpectedResult;
            n.func(n.ud);
            try testing.expectEqual(@as(usize, 1), post_hits);
            // Nodes are released by the next poll.
            var d2: Drained = .{};
            b.vtable.poll(b.ctx, false, &d2);
            try testing.expect(d2.posts_head == null);
        } else {
            try testing.expect(d.posts_head == null);
        }
    }
    try testing.expect(b.vtable.pollable(b.ctx) >= 0);

    var d: Drained = .{};
    b.vtable.destroy(b.ctx, &d);
    try testing.expectEqual(&t, d.done.head.?);
    try testing.expectEqual(ecanceled(), t.result);
}

test "destroy with ops in flight" {
    if (!supported) return error.SkipZigTest;
    const b = try create(testing.allocator, .{});
    var ops: [32]Op = undefined;
    for (&ops) |*o| {
        o.* = .{ .kind = .unlink, .path = scratch ++ "/kq_does_not_exist" };
        try b.vtable.submit(b.ctx, o);
    }
    var timer: Op = .{ .kind = .timeout, .aux = 30 * std.time.ns_per_s };
    try b.vtable.submit(b.ctx, &timer);
    var nop: Op = .{ .kind = .nop };
    try b.vtable.submit(b.ctx, &nop);

    var d: Drained = .{};
    b.vtable.destroy(b.ctx, &d);
    var count: usize = 0;
    while (d.done.pop()) |_| count += 1;
    try testing.expectEqual(ops.len + 2, count);
    try testing.expectEqual(ecanceled(), timer.result);
    // Queued ops are cancelled by destroy; ones that already started report their real result.
    for (&ops) |*o| try testing.expect(o.result == ecanceled() or o.result == -@as(i64, @backingInt(c.E.NOENT)));
}

// ----- tests for the extended op set -----

fn negE(e: c.E) i64 {
    return -@as(i64, @backingInt(e));
}

fn openOp(b: backend.Backend, path: [*:0]const u8, flags: u64) !i64 {
    var o: Op = .{ .kind = .open, .path = path, .aux = flags | (@as(u64, 0o644) << 32) };
    const fd = try runOne(b, &o);
    try testing.expect(fd >= 0);
    return fd;
}

fn closeOp(b: backend.Backend, fd: i64) !void {
    var o: Op = .{ .kind = .close, .fd = fd };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &o));
}

fn unlinkQuiet(path: [*:0]const u8) void {
    _ = c.unlink(path);
}

fn destroyClean(b: backend.Backend) !void {
    var d: Drained = .{};
    b.vtable.destroy(b.ctx, &d);
    try testing.expect(d.done.isEmpty());
}

test "fsync after write, both modes" {
    if (!supported) return error.SkipZigTest;
    const b = try create(testing.allocator, .{});
    const path = scratch ++ "/kq_fsync.bin";
    defer unlinkQuiet(path);
    const fd = try openOp(b, path, op_mod.O.RDWR | op_mod.O.CREAT | op_mod.O.TRUNC);
    var w: Op = .{ .kind = .write, .fd = fd, .buf = @constCast("abc"), .len = 3 };
    try testing.expectEqual(@as(i64, 3), try runOne(b, &w));
    var f: Op = .{ .kind = .fsync, .fd = fd };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &f));
    var fd2: Op = .{ .kind = .fsync, .fd = fd, .flags = 1 };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &fd2));
    var bad: Op = .{ .kind = .fsync, .fd = 9999 };
    try testing.expectEqual(negE(.BADF), try runOne(b, &bad));
    try closeOp(b, fd);
    try destroyClean(b);
}

test "fallocate grows file unless KEEP_SIZE" {
    if (!supported) return error.SkipZigTest;
    const b = try create(testing.allocator, .{});
    const path = scratch ++ "/kq_falloc.bin";
    defer unlinkQuiet(path);
    const fd = try openOp(b, path, op_mod.O.RDWR | op_mod.O.CREAT | op_mod.O.TRUNC);
    var fa: Op = .{ .kind = .fallocate, .fd = fd, .offset = 0, .len = 8192 };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &fa));
    var st: op_mod.Stat = undefined;
    var f: Op = .{ .kind = .fstat, .fd = fd, .buf = &st };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &f));
    try testing.expectEqual(@as(u64, 8192), st.size);

    var keep: Op = .{ .kind = .fallocate, .fd = fd, .offset = 8192, .len = 4096, .aux = op_mod.FallocFlags.KEEP_SIZE };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &keep));
    try testing.expectEqual(@as(i64, 0), try runOne(b, &f));
    try testing.expectEqual(@as(u64, 8192), st.size);

    var zero: Op = .{ .kind = .fallocate, .fd = fd, .offset = 0, .len = 0 };
    try testing.expectEqual(negE(.INVAL), try runOne(b, &zero));
    try closeOp(b, fd);
    try destroyClean(b);
}

test "readv/writev round trip with offsets" {
    if (!supported) return error.SkipZigTest;
    const b = try create(testing.allocator, .{});
    const path = scratch ++ "/kq_vec.bin";
    defer unlinkQuiet(path);
    const fd = try openOp(b, path, op_mod.O.RDWR | op_mod.O.CREAT | op_mod.O.TRUNC);

    var wiov = [_]op_mod.Iovec{
        .{ .base = @constCast("hello "), .len = 6 },
        .{ .base = @constCast("world"), .len = 5 },
    };
    var w: Op = .{ .kind = .writev, .fd = fd, .buf = &wiov, .len = 2 }; // current position
    try testing.expectEqual(@as(i64, 11), try runOne(b, &w));

    var a: [5]u8 = undefined;
    var bb: [3]u8 = undefined;
    var riov = [_]op_mod.Iovec{ .{ .base = &a, .len = a.len }, .{ .base = &bb, .len = bb.len } };
    var r: Op = .{ .kind = .readv, .fd = fd, .buf = &riov, .len = 2, .offset = 3 }; // preadv at 3
    try testing.expectEqual(@as(i64, 8), try runOne(b, &r));
    try testing.expectEqualStrings("lo wo", &a);
    try testing.expectEqualStrings("rld", &bb);

    var pw: Op = .{ .kind = .writev, .fd = fd, .buf = &wiov[1], .len = 1, .offset = 0 }; // pwritev
    try testing.expectEqual(@as(i64, 5), try runOne(b, &pw));
    var rb: [11]u8 = undefined;
    var one = [_]op_mod.Iovec{.{ .base = &rb, .len = rb.len }};
    var r2: Op = .{ .kind = .readv, .fd = fd, .buf = &one, .len = 1, .offset = 0 };
    try testing.expectEqual(@as(i64, 11), try runOne(b, &r2));
    try testing.expectEqualStrings("world worl", rb[0..10]);
    try closeOp(b, fd);
    try destroyClean(b);
}

test "stat path, nofollow, link, rename via fd2" {
    if (!supported) return error.SkipZigTest;
    const b = try create(testing.allocator, .{});
    const dir_a = scratch ++ "/kq_dir_a";
    const dir_b = scratch ++ "/kq_dir_b";
    _ = c.rmdir(dir_a);
    _ = c.rmdir(dir_b);
    const file = dir_a ++ "/f.txt";
    const sym = dir_a ++ "/sym";
    const hard = dir_a ++ "/hard";
    const moved = dir_b ++ "/moved";
    defer {
        unlinkQuiet(file);
        unlinkQuiet(sym);
        unlinkQuiet(hard);
        unlinkQuiet(moved);
        _ = c.rmdir(dir_a);
        _ = c.rmdir(dir_b);
    }
    var mk: Op = .{ .kind = .mkdir, .path = dir_a, .aux = 0o755 };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &mk));
    var mk2: Op = .{ .kind = .mkdir, .path = dir_b, .aux = 0o755 };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &mk2));

    const fd = try openOp(b, file, op_mod.O.WRONLY | op_mod.O.CREAT | op_mod.O.TRUNC);
    var w: Op = .{ .kind = .write, .fd = fd, .buf = @constCast("0123456789"), .len = 10 };
    _ = try runOne(b, &w);
    try closeOp(b, fd);
    try testing.expectEqual(@as(c_int, 0), c.symlink("f.txt", sym));

    var st: op_mod.Stat = undefined;
    var s1: Op = .{ .kind = .stat, .path = sym, .buf = &st };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &s1));
    try testing.expectEqual(@as(u32, 1), st.kind);
    try testing.expectEqual(@as(u64, 10), st.size);
    var s2: Op = .{ .kind = .stat, .path = sym, .buf = &st, .flags = 1 };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &s2));
    try testing.expectEqual(@as(u32, 3), st.kind);
    var s3: Op = .{ .kind = .stat, .path = scratch ++ "/kq_no_such_file", .buf = &st };
    try testing.expectEqual(negE(.NOENT), try runOne(b, &s3));

    var lk: Op = .{ .kind = .link, .path = file, .path2 = hard };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &lk));
    var s4: Op = .{ .kind = .stat, .path = hard, .buf = &st };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &s4));
    try testing.expectEqual(@as(u64, 10), st.size);
    var lk2: Op = .{ .kind = .link, .path = file, .path2 = hard };
    try testing.expectEqual(negE(.EXIST), try runOne(b, &lk2));

    // rename: old relative to dir A (fd), new relative to dir B (fd2).
    const da = try openOp(b, dir_a, op_mod.O.RDONLY | op_mod.O.DIRECTORY);
    const db = try openOp(b, dir_b, op_mod.O.RDONLY | op_mod.O.DIRECTORY);
    var rn: Op = .{ .kind = .rename, .fd = da, .path = "hard", .fd2 = db, .path2 = "moved" };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &rn));
    var s5: Op = .{ .kind = .stat, .path = moved, .buf = &st };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &s5));
    var s6: Op = .{ .kind = .stat, .fd = da, .path = "hard", .buf = &st };
    try testing.expectEqual(negE(.NOENT), try runOne(b, &s6));
    var rm: Op = .{ .kind = .unlink, .fd = db, .path = "moved" };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &rm));
    try closeOp(b, da);
    try closeOp(b, db);
    try destroyClean(b);
}

fn setNonblock(fd: c_int) void {
    _ = sc.fcntl(fd, 4, O_NONBLOCK); // F_SETFL
}

extern "c" fn socketpair(domain: c_int, ty: c_int, proto: c_int, sv: *[2]c_int) c_int;
extern "c" fn socket(domain: c_int, ty: c_int, proto: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: u32) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn getsockname(fd: c_int, addr: *anyopaque, len: *u32) c_int;

/// Loopback listener on an ephemeral port; fills `addr` (sockaddr_in, 16 bytes).
fn listener(addr: *[16]u8) !c_int {
    const fd = socket(2, 1, 0);
    try testing.expect(fd >= 0);
    addr.* = .{ 16, 2, 0, 0, 127, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqual(@as(c_int, 0), bind(fd, addr, 16));
    try testing.expectEqual(@as(c_int, 0), listen(fd, 8));
    var len: u32 = 16;
    try testing.expectEqual(@as(c_int, 0), getsockname(fd, addr, &len));
    return fd;
}

fn tcpRoundTrip(nonblock: bool) !void {
    const b = try create(testing.allocator, .{});
    var addr: [16]u8 = undefined;
    const lfd = try listener(&addr);
    defer _ = c.close(lfd);
    const cfd = socket(2, 1, 0);
    try testing.expect(cfd >= 0);
    defer _ = c.close(cfd);
    if (nonblock) {
        setNonblock(lfd);
        setNonblock(cfd);
    }

    var peer: [16]u8 = undefined;
    var acc: Op = .{ .kind = .accept, .fd = lfd, .buf = &peer, .len = peer.len };
    var con: Op = .{ .kind = .connect, .fd = cfd, .buf = &addr, .len = addr.len };
    try b.vtable.submit(b.ctx, &acc); // non-blocking: parks on EVFILT_READ before any client exists
    try b.vtable.submit(b.ctx, &con);
    var done: [2]*Op = undefined;
    _ = try collect(b, 2, &done);
    try testing.expectEqual(@as(i64, 0), con.result);
    try testing.expect(acc.result >= 0);
    const sfd: c_int = @intCast(acc.result);
    defer _ = c.close(sfd);
    try testing.expectEqual(@as(u64, 16), acc.aux);
    try testing.expectEqual(@as(u8, 2), peer[1]); // AF_INET
    try testing.expect((sc.fcntl(sfd, 1, @as(c_int, 0)) & FD_CLOEXEC) != 0); // F_GETFD
    if (nonblock) setNonblock(sfd);

    // recv posted before the data exists, then send.
    var rbuf: [16]u8 = undefined;
    var rv: Op = .{ .kind = .recv, .fd = sfd, .buf = &rbuf, .len = rbuf.len };
    try b.vtable.submit(b.ctx, &rv);
    var sd: Op = .{ .kind = .send, .fd = cfd, .buf = @constCast("ping"), .len = 4 };
    try b.vtable.submit(b.ctx, &sd);
    _ = try collect(b, 2, &done);
    try testing.expectEqual(@as(i64, 4), sd.result);
    try testing.expectEqual(@as(i64, 4), rv.result);
    try testing.expectEqualStrings("ping", rbuf[0..4]);

    // connect to a closed port reports ECONNREFUSED.
    if (nonblock) {
        const lfd2 = try listener(&addr);
        _ = c.close(lfd2);
        const cfd2 = socket(2, 1, 0);
        defer _ = c.close(cfd2);
        setNonblock(cfd2);
        var bad: Op = .{ .kind = .connect, .fd = cfd2, .buf = &addr, .len = addr.len };
        try testing.expectEqual(negE(.CONNREFUSED), try runOne(b, &bad));
    }
    try destroyClean(b);
}

test "tcp connect/accept/send/recv, blocking fds" {
    if (!supported) return error.SkipZigTest;
    try tcpRoundTrip(false);
}

test "tcp connect/accept/send/recv, non-blocking fds" {
    if (!supported) return error.SkipZigTest;
    try tcpRoundTrip(true);
}

test "non-blocking wait can be cancelled and destroy cancels waits" {
    if (!supported) return error.SkipZigTest;
    const b = try create(testing.allocator, .{});
    var sv: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), socketpair(1, 1, 0, &sv));
    defer _ = c.close(sv[0]);
    defer _ = c.close(sv[1]);
    setNonblock(sv[0]);
    var buf: [8]u8 = undefined;
    var rv: Op = .{ .kind = .recv, .fd = sv[0], .buf = &buf, .len = buf.len };
    try b.vtable.submit(b.ctx, &rv);
    try testing.expect(b.vtable.cancel(b.ctx, &rv));
    var one: [1]*Op = undefined;
    _ = try collect(b, 1, &one);
    try testing.expectEqual(ecanceled(), rv.result);

    // Two waiters on the same fd both get served (each has its own registration).
    var r1: Op = .{ .kind = .recv, .fd = sv[0], .buf = &buf, .len = 2 };
    var buf2: [8]u8 = undefined;
    var r2: Op = .{ .kind = .recv, .fd = sv[0], .buf = &buf2, .len = 2 };
    try b.vtable.submit(b.ctx, &r1);
    try b.vtable.submit(b.ctx, &r2);
    _ = c.write(sv[1], "abcd", 4);
    var two: [2]*Op = undefined;
    _ = try collect(b, 2, &two);
    try testing.expect(r1.result + r2.result == 4 or r1.result == 2 or r2.result == 2);

    // Left outstanding at destroy: completes with -ECANCELED in `out`.
    var r3: Op = .{ .kind = .recv, .fd = sv[0], .buf = &buf, .len = 2 };
    try b.vtable.submit(b.ctx, &r3);
    var d: Drained = .{};
    b.vtable.destroy(b.ctx, &d);
    try testing.expectEqual(&r3, d.done.head.?);
    try testing.expectEqual(ecanceled(), r3.result);
}

test "sendmsg/recvmsg with one iovec" {
    if (!supported) return error.SkipZigTest;
    const b = try create(testing.allocator, .{});
    var sv: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), socketpair(1, 1, 0, &sv));
    defer _ = c.close(sv[0]);
    defer _ = c.close(sv[1]);

    const msg = "datagram";
    var siov = [_]c.iovec_const{.{ .base = msg.ptr, .len = msg.len }};
    var smh = std.mem.zeroes(c.msghdr_const);
    smh.iov = &siov;
    smh.iovlen = 1;
    var sm: Op = .{ .kind = .sendmsg, .fd = sv[0], .buf = &smh };
    try testing.expectEqual(@as(i64, msg.len), try runOne(b, &sm));

    var rbuf: [32]u8 = undefined;
    var riov = [_]c.iovec{.{ .base = &rbuf, .len = rbuf.len }};
    var rmh = std.mem.zeroes(c.msghdr);
    rmh.iov = &riov;
    rmh.iovlen = 1;
    var rm: Op = .{ .kind = .recvmsg, .fd = sv[1], .buf = &rmh };
    try testing.expectEqual(@as(i64, msg.len), try runOne(b, &rm));
    try testing.expectEqualStrings(msg, rbuf[0..msg.len]);
    try destroyClean(b);
}

var futex_word: u32 align(4) = 0;

/// One blocking poll; returns how many ops completed.
fn collectAny(b: backend.Backend) !usize {
    var d: Drained = .{};
    b.vtable.poll(b.ctx, true, &d);
    var n: usize = 0;
    while (d.done.pop()) |_| n += 1;
    return n;
}

/// Submits `op` and waits for it; other completions seen meanwhile are added to `others`.
fn runWake(b: backend.Backend, op: *Op, others: *usize) !i64 {
    try b.vtable.submit(b.ctx, op);
    var tries: usize = 0;
    while (tries < 1000) : (tries += 1) {
        var d: Drained = .{};
        b.vtable.poll(b.ctx, true, &d);
        var found = false;
        while (d.done.pop()) |o| {
            if (o == op) found = true else others.* += 1;
        }
        if (found) return op.result;
    }
    return error.Stuck;
}

test "futex wait/wake" {
    if (!supported) return error.SkipZigTest;
    if (!os_sync.available()) return error.SkipZigTest;
    const b = try create(testing.allocator, .{});
    try testing.expect(b.vtable.caps & backend.Caps.futex != 0);
    futex_word = 0;

    var mism: Op = .{ .kind = .futex_wait, .buf = &futex_word, .aux = 1, .offset = -1 };
    try testing.expectEqual(negE(.AGAIN), try runOne(b, &mism));

    const t0 = nowNs();
    var to: Op = .{ .kind = .futex_wait, .buf = &futex_word, .aux = 0, .offset = 50 * std.time.ns_per_ms };
    try testing.expectEqual(negE(.TIMEDOUT), try runOne(b, &to));
    try testing.expect(nowNs() - t0 >= 40 * std.time.ns_per_ms);

    // No waiter: wake reports 0.
    var w0: Op = .{ .kind = .futex_wake, .buf = &futex_word, .aux = 1 };
    try testing.expectEqual(@as(i64, 0), try runOne(b, &w0));

    var waiters: [3]Op = undefined;
    for (&waiters) |*w| {
        w.* = .{ .kind = .futex_wait, .buf = &futex_word, .aux = 0, .offset = -1 };
        try b.vtable.submit(b.ctx, w);
    }
    sleepNs(100 * std.time.ns_per_ms);
    var wk: Op = .{ .kind = .futex_wake, .buf = &futex_word, .aux = 2 };
    var woke_seen: usize = 0;
    try testing.expectEqual(@as(i64, 2), try runWake(b, &wk, &woke_seen));
    while (woke_seen < 2) woke_seen += try collectAny(b);
    var wk2: Op = .{ .kind = .futex_wake, .buf = &futex_word, .aux = 1 };
    try testing.expectEqual(@as(i64, 1), try runWake(b, &wk2, &woke_seen));
    while (woke_seen < 3) woke_seen += try collectAny(b);
    for (&waiters) |*w| try testing.expectEqual(@as(i64, 0), w.result);
    try destroyClean(b);
}

test "futex wake result is exact for tracked waiters" {
    if (!supported) return error.SkipZigTest;
    if (!os_sync.available()) return error.SkipZigTest;
    const b = try create(testing.allocator, .{});
    futex_word = 0;
    var seen: usize = 0;

    var w0: Op = .{ .kind = .futex_wake, .buf = &futex_word, .aux = 10 };
    try testing.expectEqual(@as(i64, 0), try runWake(b, &w0, &seen));

    // One waiter, wake(10) == 1, and a second wake finds nobody.
    var one: Op = .{ .kind = .futex_wait, .buf = &futex_word, .aux = 0, .offset = -1 };
    try b.vtable.submit(b.ctx, &one);
    sleepNs(50 * std.time.ns_per_ms);
    var wk: Op = .{ .kind = .futex_wake, .buf = &futex_word, .aux = 10 };
    try testing.expectEqual(@as(i64, 1), try runWake(b, &wk, &seen));
    while (seen < 1) seen += try collectAny(b);
    var wk_again: Op = .{ .kind = .futex_wake, .buf = &futex_word, .aux = 10 };
    try testing.expectEqual(@as(i64, 0), try runWake(b, &wk_again, &seen));

    // Three waiters: wake(2) == 2, then wake(10) == 1 (woken-but-unreported not recounted).
    var ws: [3]Op = undefined;
    for (&ws) |*w| {
        w.* = .{ .kind = .futex_wait, .buf = &futex_word, .aux = 0, .offset = -1 };
        try b.vtable.submit(b.ctx, w);
    }
    sleepNs(100 * std.time.ns_per_ms);
    seen = 0;
    var wk2: Op = .{ .kind = .futex_wake, .buf = &futex_word, .aux = 2 };
    try testing.expectEqual(@as(i64, 2), try runWake(b, &wk2, &seen));
    var wk3: Op = .{ .kind = .futex_wake, .buf = &futex_word, .aux = 10 };
    try testing.expectEqual(@as(i64, 1), try runWake(b, &wk3, &seen));
    while (seen < 3) seen += try collectAny(b);

    // A timed-out waiter is not counted.
    var to: Op = .{ .kind = .futex_wait, .buf = &futex_word, .aux = 0, .offset = 30 * std.time.ns_per_ms };
    try testing.expectEqual(negE(.TIMEDOUT), try runOne(b, &to));
    var wk4: Op = .{ .kind = .futex_wake, .buf = &futex_word, .aux = 10 };
    try testing.expectEqual(@as(i64, 0), try runWake(b, &wk4, &seen));

    // A waiter cancelled before it started is not counted.
    var cw: Op = .{ .kind = .futex_wait, .buf = &futex_word, .aux = 0, .offset = 30 * std.time.ns_per_ms };
    try b.vtable.submit(b.ctx, &cw);
    _ = b.vtable.cancel(b.ctx, &cw);
    var wk5: Op = .{ .kind = .futex_wake, .buf = &futex_word, .aux = 10 };
    const r5 = try runWake(b, &wk5, &seen);
    try testing.expect(r5 == 0 or r5 == 1); // 1 only if it had already started
    try destroyClean(b);
}

test "sendfile file to socket and file to file" {
    if (!supported) return error.SkipZigTest;
    const b = try create(testing.allocator, .{});
    const src = scratch ++ "/kq_sf_src.bin";
    const dst = scratch ++ "/kq_sf_dst.bin";
    defer unlinkQuiet(src);
    defer unlinkQuiet(dst);
    const infd = try openOp(b, src, op_mod.O.RDWR | op_mod.O.CREAT | op_mod.O.TRUNC);
    const content = "sendfile payload 0123456789";
    var w: Op = .{ .kind = .write, .fd = infd, .buf = @constCast(content), .len = content.len };
    _ = try runOne(b, &w);

    var sv: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), socketpair(1, 1, 0, &sv));
    defer _ = c.close(sv[0]);
    defer _ = c.close(sv[1]);
    // Explicit offset 9: "payload 0123456789".
    var sf: Op = .{ .kind = .sendfile, .fd = sv[0], .fd2 = infd, .offset = 9, .len = 100 };
    try testing.expectEqual(@as(i64, content.len - 9), try runOne(b, &sf));
    var rbuf: [64]u8 = undefined;
    var rv: Op = .{ .kind = .recv, .fd = sv[1], .buf = &rbuf, .len = rbuf.len };
    try testing.expectEqual(@as(i64, content.len - 9), try runOne(b, &rv));
    try testing.expectEqualStrings(content[9..], rbuf[0 .. content.len - 9]);

    // File to file, input position (-1): start at 0 via lseek, check it advances.
    _ = sc.lseek(@intCast(infd), 0, SEEK_SET);
    const outfd = try openOp(b, dst, op_mod.O.RDWR | op_mod.O.CREAT | op_mod.O.TRUNC);
    var ff: Op = .{ .kind = .sendfile, .fd = outfd, .fd2 = infd, .offset = -1, .len = 8 };
    try testing.expectEqual(@as(i64, 8), try runOne(b, &ff));
    try testing.expectEqual(@as(i64, 8), sc.lseek(@intCast(infd), 0, SEEK_CUR));
    var ff2: Op = .{ .kind = .sendfile, .fd = outfd, .fd2 = infd, .offset = -1, .len = 1000 };
    try testing.expectEqual(@as(i64, content.len - 8), try runOne(b, &ff2));
    var chk: Op = .{ .kind = .read, .fd = outfd, .offset = 0, .buf = &rbuf, .len = rbuf.len };
    try testing.expectEqual(@as(i64, content.len), try runOne(b, &chk));
    try testing.expectEqualStrings(content, rbuf[0..content.len]);

    // Socket with current position (-1) as well.
    _ = sc.lseek(@intCast(infd), 5, SEEK_SET);
    var sf2: Op = .{ .kind = .sendfile, .fd = sv[0], .fd2 = infd, .offset = -1, .len = 4 };
    try testing.expectEqual(@as(i64, 4), try runOne(b, &sf2));
    try testing.expectEqual(@as(i64, 9), sc.lseek(@intCast(infd), 0, SEEK_CUR));
    try closeOp(b, infd);
    try closeOp(b, outfd);
    try destroyClean(b);
}

// ----- readdir / ftruncate -----

fn mkdirQuiet(path: [*:0]const u8) void {
    _ = c.mkdir(path, 0o755);
}

fn touch(path: [*:0]const u8) void {
    const fd = openat(c.AT.FDCWD, path, @bitCast(@as(u32, 0x200 | 2 | O_CLOEXEC)), @as(c_uint, 0o644));
    if (fd >= 0) _ = c.close(fd);
}

fn rmTree(dir: [*:0]const u8) void {
    var buf: [256]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "rm -rf {s}\x00", .{dir}) catch return;
    _ = system(@ptrCast(cmd.ptr));
}
extern "c" fn system(cmd: [*:0]const u8) c_int;

const Seen = std.StringHashMap(u8);

/// Parses a packed buffer, asserting each name is new.
fn unpack(seen: *Seen, buf: []const u8) !void {
    var i: usize = 0;
    while (i < buf.len) {
        const kind = buf[i];
        const nl = std.mem.readInt(u16, buf[i + 1 ..][0..2], .little);
        const name = try testing.allocator.dupe(u8, buf[i + 3 ..][0..nl]);
        const gop = try seen.getOrPut(name);
        try testing.expect(!gop.found_existing);
        gop.value_ptr.* = kind;
        i += 3 + nl;
    }
}

fn freeSeen(seen: *Seen) void {
    var it = seen.keyIterator();
    while (it.next()) |k| testing.allocator.free(k.*);
    seen.deinit();
}

/// Reads the whole directory in `bufsize`-byte pieces, returns number of calls.
fn readAll(b: backend.Backend, fd: i64, seen: *Seen, bufsize: usize) !usize {
    const buf = try testing.allocator.alloc(u8, bufsize);
    defer testing.allocator.free(buf);
    var cookie: u64 = 0;
    var calls: usize = 0;
    while (true) {
        var o: Op = .{ .kind = .readdir, .fd = fd, .buf = buf.ptr, .len = buf.len, .offset = @intCast(cookie) };
        const r = try runOne(b, &o);
        try testing.expect(r >= 0);
        calls += 1;
        if (r == 0) return calls;
        try unpack(seen, buf[0..@intCast(r)]);
        cookie = o.aux;
        if (calls > 100000) return error.Stuck;
    }
}

test "ftruncate shrink and grow" {
    if (!supported) return error.SkipZigTest;
    const b = try create(testing.allocator, .{});
    const path = scratch ++ "/kq_ftrunc.bin";
    defer unlinkQuiet(path);
    const fd = try openOp(b, path, op_mod.O.RDWR | op_mod.O.CREAT | op_mod.O.TRUNC);
    var w: Op = .{ .kind = .write, .fd = fd, .buf = @constCast("0123456789"), .len = 10 };
    try testing.expectEqual(@as(i64, 10), try runOne(b, &w));
    var st: op_mod.Stat = undefined;
    for ([_]i64{ 4, 100, 0 }) |len| {
        var t: Op = .{ .kind = .ftruncate, .fd = fd, .offset = len };
        try testing.expectEqual(@as(i64, 0), try runOne(b, &t));
        var f: Op = .{ .kind = .fstat, .fd = fd, .buf = &st };
        try testing.expectEqual(@as(i64, 0), try runOne(b, &f));
        try testing.expectEqual(@as(u64, @intCast(len)), st.size);
    }
    var bad: Op = .{ .kind = .ftruncate, .fd = 9999, .offset = 0 };
    try testing.expectEqual(negE(.BADF), try runOne(b, &bad));
    try closeOp(b, fd);
    try destroyClean(b);
}

test "readdir kinds, cookie continuation, ERANGE" {
    if (!supported) return error.SkipZigTest;
    const b = try create(testing.allocator, .{});
    const dir = scratch ++ "/kq_rd_dir";
    rmTree(dir);
    mkdirQuiet(dir);
    defer rmTree(dir);
    touch(dir ++ "/f1");
    touch(dir ++ "/f2");
    touch(dir ++ "/file_three_long_name");
    mkdirQuiet(dir ++ "/d1");
    mkdirQuiet(dir ++ "/d2");
    try testing.expectEqual(@as(c_int, 0), c.symlink("f1", dir ++ "/lnk"));

    const fd = try openOp(b, dir, op_mod.O.RDONLY | op_mod.O.DIRECTORY);

    const expected = [_]struct { []const u8, u8 }{
        .{ "f1", 1 }, .{ "f2", 1 }, .{ "file_three_long_name", 1 },
        .{ "d1", 2 }, .{ "d2", 2 }, .{ "lnk", 3 },
    };
    for ([_]usize{ 4096, 128, 64 }) |sz| {
        var seen = Seen.init(testing.allocator);
        defer freeSeen(&seen);
        const calls = try readAll(b, fd, &seen, sz);
        if (sz == 4096) try testing.expectEqual(@as(usize, 2), calls);
        if (sz < 4096) try testing.expect(calls >= 2);
        try testing.expectEqual(expected.len, seen.count());
        for (expected) |e| try testing.expectEqual(e[1], seen.get(e[0]) orelse return error.TestUnexpectedResult);
        try testing.expect(seen.get(".") == null and seen.get("..") == null);
    }

    var tiny: [20]u8 = undefined;
    var o: Op = .{ .kind = .readdir, .fd = fd, .buf = &tiny, .len = tiny.len, .offset = 0 };
    try testing.expectEqual(negE(.RANGE), try runOne(b, &o));

    try closeOp(b, fd);
    try destroyClean(b);
}

test "readdir 2000 entries with 4096-byte buffer" {
    if (!supported) return error.SkipZigTest;
    const b = try create(testing.allocator, .{});
    const dir = scratch ++ "/kq_rd_big";
    rmTree(dir);
    mkdirQuiet(dir);
    defer rmTree(dir);
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        var nb: [64]u8 = undefined;
        const p = try std.fmt.bufPrint(&nb, dir ++ "/entry_with_a_longish_name_{d:0>5}\x00", .{i});
        touch(@ptrCast(p.ptr));
    }
    const fd = try openOp(b, dir, op_mod.O.RDONLY | op_mod.O.DIRECTORY);
    var seen = Seen.init(testing.allocator);
    defer freeSeen(&seen);
    _ = try readAll(b, fd, &seen, 4096);
    try testing.expectEqual(@as(usize, 2000), seen.count());
    try closeOp(b, fd);
    try destroyClean(b);
}
