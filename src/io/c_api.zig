//! C ABI over `Loop` (header: include/origine_io.h). Functions return 0 or a value >= 0 on
//! success and -errno on failure. Same thread rules as `Loop`.
//!
//! CONTRACT (docs/contracts.md, surface A): the header is the source of truth; `contract_test.zig`
//! (`zig build test-io`) fails when a function, struct or constant here or in op.zig / backend.zig
//! differs from it. Exports must be `pub export fn` so the test can see them.
const std = @import("std");
const loop_mod = @import("loop.zig");
const op_mod = @import("op.zig");
const backend_mod = @import("backend.zig");

const Loop = loop_mod.Loop;
const Op = op_mod.Op;

const ENOMEM: c_int = @intFromEnum(std.c.E.NOMEM);
const EINVAL: c_int = @intFromEnum(std.c.E.INVAL);
const ENOSYS: c_int = @intFromEnum(std.c.E.NOSYS);
const EAGAIN: c_int = @intFromEnum(std.c.E.AGAIN);

fn fail(err: anyerror) c_int {
    return -switch (err) {
        // Resource exhaustion (pipe/eventfd/thread creation) is not a caller bug; a full
        // submission queue is transient and the caller may retry after polling.
        error.OutOfMemory, error.SystemResources => ENOMEM,
        error.SubmissionQueueFull => EAGAIN,
        error.Unsupported, error.UnsupportedOp => ENOSYS,
        else => EINVAL,
    };
}

pub export fn oio_loop_create(options: ?*const backend_mod.Options, out: *?*Loop) c_int {
    const loop = Loop.create(std.heap.c_allocator, if (options) |o| o.* else .{}) catch |e| return fail(e);
    out.* = loop;
    return 0;
}

pub export fn oio_loop_destroy(loop: *Loop) void {
    loop.destroy();
}

pub export fn oio_loop_run(loop: *Loop, mode: c_int) c_int {
    const m: backend_mod.Mode = switch (mode) {
        0 => .once,
        1 => .nowait,
        2 => .until_idle,
        else => return -EINVAL,
    };
    return @intCast(loop.run(m));
}

pub export fn oio_loop_wake(loop: *Loop) void {
    loop.wake();
}

pub export fn oio_loop_post(loop: *Loop, func: backend_mod.PostFn, ud: ?*anyopaque) c_int {
    loop.post(func, ud) catch |e| return fail(e);
    return 0;
}

pub export fn oio_loop_pollable(loop: *Loop) isize {
    return loop.pollable();
}

pub export fn oio_loop_active(loop: *Loop) u32 {
    return loop.active;
}

pub export fn oio_loop_caps(loop: *Loop) u64 {
    return loop.caps();
}

pub export fn oio_nop(loop: *Loop, op: *Op, cb: op_mod.Callback) c_int {
    loop.nop(op, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_open(loop: *Loop, op: *Op, dirfd: op_mod.Fd, path: [*:0]const u8, flags: u64, mode: u32, cb: op_mod.Callback) c_int {
    loop.open(op, dirfd, path, flags, mode, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_close(loop: *Loop, op: *Op, fd: op_mod.Fd, cb: op_mod.Callback) c_int {
    loop.close(op, fd, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_read(loop: *Loop, op: *Op, fd: op_mod.Fd, buf: [*]u8, len: usize, offset: i64, cb: op_mod.Callback) c_int {
    loop.read(op, fd, buf[0..len], offset, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_write(loop: *Loop, op: *Op, fd: op_mod.Fd, buf: [*]const u8, len: usize, offset: i64, cb: op_mod.Callback) c_int {
    loop.write(op, fd, buf[0..len], offset, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_fstat(loop: *Loop, op: *Op, fd: op_mod.Fd, out: *op_mod.Stat, cb: op_mod.Callback) c_int {
    loop.fstat(op, fd, out, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_mkdir(loop: *Loop, op: *Op, dirfd: op_mod.Fd, path: [*:0]const u8, mode: u32, cb: op_mod.Callback) c_int {
    const user = op.user;
    op.* = .{ .cb = cb, .user = user, .kind = .mkdir, .fd = dirfd, .path = path, .aux = mode };
    loop.submit(op) catch |e| return fail(e);
    return 0;
}

/// `rmdir` != 0 removes a directory.
pub export fn oio_unlink(loop: *Loop, op: *Op, dirfd: op_mod.Fd, path: [*:0]const u8, rmdir: u32, cb: op_mod.Callback) c_int {
    loop.unlink(op, dirfd, path, rmdir != 0, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_rename(loop: *Loop, op: *Op, old_dirfd: op_mod.Fd, from: [*:0]const u8, new_dirfd: op_mod.Fd, to: [*:0]const u8, cb: op_mod.Callback) c_int {
    loop.rename(op, old_dirfd, from, new_dirfd, to, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_link(loop: *Loop, op: *Op, old_dirfd: op_mod.Fd, old: [*:0]const u8, new_dirfd: op_mod.Fd, new: [*:0]const u8, cb: op_mod.Callback) c_int {
    loop.link(op, old_dirfd, old, new_dirfd, new, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_stat_at(loop: *Loop, op: *Op, dirfd: op_mod.Fd, path: [*:0]const u8, nofollow: u32, out: *op_mod.Stat, cb: op_mod.Callback) c_int {
    loop.stat(op, dirfd, path, nofollow != 0, out, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_fsync(loop: *Loop, op: *Op, fd: op_mod.Fd, datasync: u32, cb: op_mod.Callback) c_int {
    loop.fsync(op, fd, datasync != 0, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_sendfile(loop: *Loop, op: *Op, out_fd: op_mod.Fd, in_fd: op_mod.Fd, in_offset: i64, count: usize, cb: op_mod.Callback) c_int {
    loop.sendfile(op, out_fd, in_fd, in_offset, count, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_fallocate(loop: *Loop, op: *Op, fd: op_mod.Fd, offset: i64, len: usize, flags: u64, cb: op_mod.Callback) c_int {
    loop.fallocate(op, fd, offset, len, flags, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_send(loop: *Loop, op: *Op, fd: op_mod.Fd, buf: [*]const u8, len: usize, msg_flags: u32, cb: op_mod.Callback) c_int {
    loop.send(op, fd, buf[0..len], msg_flags, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_recv(loop: *Loop, op: *Op, fd: op_mod.Fd, buf: [*]u8, len: usize, msg_flags: u32, cb: op_mod.Callback) c_int {
    loop.recv(op, fd, buf[0..len], msg_flags, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_sendmsg(loop: *Loop, op: *Op, fd: op_mod.Fd, msg: *anyopaque, msg_flags: u32, cb: op_mod.Callback) c_int {
    loop.sendmsg(op, fd, msg, msg_flags, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_recvmsg(loop: *Loop, op: *Op, fd: op_mod.Fd, msg: *anyopaque, msg_flags: u32, cb: op_mod.Callback) c_int {
    loop.recvmsg(op, fd, msg, msg_flags, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_futex_wait(loop: *Loop, op: *Op, addr: *const u32, expected: u32, timeout_ns: i64, cb: op_mod.Callback) c_int {
    loop.futexWait(op, addr, expected, timeout_ns, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_futex_wake(loop: *Loop, op: *Op, addr: *const u32, count: u32, cb: op_mod.Callback) c_int {
    loop.futexWake(op, addr, count, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_connect(loop: *Loop, op: *Op, fd: op_mod.Fd, addr: *const anyopaque, addr_len: usize, cb: op_mod.Callback) c_int {
    loop.connect(op, fd, addr, addr_len, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_accept(loop: *Loop, op: *Op, fd: op_mod.Fd, addr: ?*anyopaque, addr_cap: usize, cb: op_mod.Callback) c_int {
    loop.accept(op, fd, addr, addr_cap, cb, op.user) catch |e| return fail(e);
    return 0;
}

/// `offset` -1 = current position, otherwise preadv. `iov` is an array of `iov_count` iovecs.
pub export fn oio_readv(loop: *Loop, op: *Op, fd: op_mod.Fd, iov: [*]const op_mod.Iovec, iov_count: usize, offset: i64, cb: op_mod.Callback) c_int {
    loop.readv(op, fd, iov[0..iov_count], offset, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_writev(loop: *Loop, op: *Op, fd: op_mod.Fd, iov: [*]const op_mod.Iovec, iov_count: usize, offset: i64, cb: op_mod.Callback) c_int {
    loop.writev(op, fd, iov[0..iov_count], offset, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_timeout(loop: *Loop, op: *Op, ns: u64, cb: op_mod.Callback) c_int {
    loop.timeout(op, ns, cb, op.user) catch |e| return fail(e);
    return 0;
}

/// 1 if the op was still cancellable, 0 otherwise. The callback runs either way.
pub export fn oio_cancel(loop: *Loop, op: *Op) c_int {
    return @intFromBool(loop.cancel(op));
}

/// `cookie` is 0 first, then the previous completion's `op->aux`. See the header for the packing.
pub export fn oio_readdir(loop: *Loop, op: *Op, fd: op_mod.Fd, buf: [*]u8, len: usize, cookie: u64, cb: op_mod.Callback) c_int {
    loop.readdir(op, fd, buf[0..len], cookie, cb, op.user) catch |e| return fail(e);
    return 0;
}

pub export fn oio_ftruncate(loop: *Loop, op: *Op, fd: op_mod.Fd, len: u64, cb: op_mod.Callback) c_int {
    loop.ftruncate(op, fd, len, cb, op.user) catch |e| return fail(e);
    return 0;
}
