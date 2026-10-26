//! One event loop instance. Several may coexist; each is driven by the thread calling `run`.
//! Thread rules: submit/cancel/run/destroy on the loop thread only; `wake` and `post` from any.
const std = @import("std");
const safe = @import("@safe");
const builtin = @import("builtin");
const op_mod = @import("op.zig");
const backend_mod = @import("backend.zig");

pub const Op = op_mod.Op;
pub const Kind = op_mod.Kind;
pub const Callback = op_mod.Callback;
pub const Options = backend_mod.Options;
pub const Mode = backend_mod.Mode;
pub const PostFn = backend_mod.PostFn;

pub const Loop = struct {
    allocator: std.mem.Allocator,
    backend: backend_mod.Backend,
    /// Submitted ops whose callback has not run yet.
    active: u32 = 0,
    dispatching: bool = false,
    /// Set once `destroy` has torn the backend down: callbacks running its cancellations must
    /// not reach the (freed) backend.
    closing: bool = false,

    pub fn create(allocator: std.mem.Allocator, options: Options) !*Loop {
        const loop = try allocator.create(Loop);
        errdefer allocator.destroy(loop);
        loop.* = .{ .allocator = allocator, .backend = try createBackend(allocator, options) };
        return loop;
    }

    /// Cancels everything outstanding, runs the cancellation callbacks, and frees the loop.
    pub fn destroy(loop: *Loop) void {
        var drained: backend_mod.Drained = .{};
        loop.closing = true;
        loop.backend.vtable.destroy(loop.backend.ctx, &drained);
        loop.dispatch(&drained);
        const allocator = loop.allocator;
        allocator.destroy(loop);
    }

    pub fn submit(loop: *Loop, op: *Op) !void {
        if (loop.closing) return error.Unsupported; // callbacks of `destroy` cannot start new work
        // Backends narrow descriptors to the kernel's `int`; a wider value is a caller bug that an
        // unchecked cast would turn into some other descriptor.
        if (op.fd < -1 or op.fd > std.math.maxInt(i32) or op.fd2 < -1 or op.fd2 > std.math.maxInt(i32)) return error.InvalidArgument;
        op.result = 0;
        try loop.backend.vtable.submit(loop.backend.ctx, op);
        loop.active += 1;
    }

    /// Asks the backend to finish `op` early; its callback still runs, usually with -ECANCELED.
    pub fn cancel(loop: *Loop, op: *Op) bool {
        if (loop.closing) return false;
        return loop.backend.vtable.cancel(loop.backend.ctx, op);
    }

    /// Returns the number of ops still active. `once` blocks until at least one event (a
    /// completion, `wake`, or posted function) has been handled; `until_idle` runs until no op
    /// is active.
    pub fn run(loop: *Loop, mode: Mode) u32 {
        switch (mode) {
            .nowait => loop.step(false),
            .once => loop.step(true),
            .until_idle => while (loop.active > 0) loop.step(true),
        }
        return loop.active;
    }

    fn step(loop: *Loop, block: bool) void {
        var drained: backend_mod.Drained = .{};
        loop.backend.vtable.poll(loop.backend.ctx, block, &drained);
        loop.dispatch(&drained);
    }

    fn dispatch(loop: *Loop, drained: *backend_mod.Drained) void {
        while (drained.done.pop()) |op| {
            // A backend that completes an op twice (or one never submitted) would wrap this counter
            // in ReleaseFast and make `run(.until_idle)` spin forever.
            safe.ensure(loop.active > 0, "io: completion without an active op");
            loop.active -= 1;
            if (op.cb) |cb| cb(op, op.result);
        }
        var node = drained.posts_head;
        while (node) |n| {
            node = n.next;
            const func = n.func;
            const ud = n.ud;
            std.heap.c_allocator.destroy(n);
            func(ud);
        }
    }

    /// Any thread.
    pub fn wake(loop: *Loop) void {
        loop.backend.vtable.wake(loop.backend.ctx);
    }

    /// Any thread. Runs `func(ud)` on the loop thread during a later `run`.
    pub fn post(loop: *Loop, func: PostFn, ud: ?*anyopaque) !void {
        try loop.backend.vtable.post(loop.backend.ctx, func, ud);
    }

    pub fn pollable(loop: *Loop) isize {
        return loop.backend.vtable.pollable(loop.backend.ctx);
    }

    pub fn caps(loop: *Loop) u64 {
        return loop.backend.vtable.caps;
    }

    // Convenience submitters; each fills `op` and submits it.

    pub fn nop(loop: *Loop, op: *Op, cb: Callback, user: ?*anyopaque) !void {
        op.* = .{ .cb = cb, .user = user, .kind = .nop };
        try loop.submit(op);
    }

    pub fn open(loop: *Loop, op: *Op, dir: op_mod.Fd, path: [*:0]const u8, flags: u64, mode: u32, cb: Callback, user: ?*anyopaque) !void {
        op.* = .{ .cb = cb, .user = user, .kind = .open, .fd = dir, .path = path, .aux = flags | (@as(u64, mode) << 32) };
        try loop.submit(op);
    }

    pub fn close(loop: *Loop, op: *Op, fd: op_mod.Fd, cb: Callback, user: ?*anyopaque) !void {
        op.* = .{ .cb = cb, .user = user, .kind = .close, .fd = fd };
        try loop.submit(op);
    }

    pub fn read(loop: *Loop, op: *Op, fd: op_mod.Fd, buf: []u8, offset: i64, cb: Callback, user: ?*anyopaque) !void {
        op.* = .{ .cb = cb, .user = user, .kind = .read, .fd = fd, .buf = buf.ptr, .len = buf.len, .offset = offset };
        try loop.submit(op);
    }

    pub fn write(loop: *Loop, op: *Op, fd: op_mod.Fd, buf: []const u8, offset: i64, cb: Callback, user: ?*anyopaque) !void {
        op.* = .{ .cb = cb, .user = user, .kind = .write, .fd = fd, .buf = @constCast(buf.ptr), .len = buf.len, .offset = offset };
        try loop.submit(op);
    }

    pub fn fstat(loop: *Loop, op: *Op, fd: op_mod.Fd, out: *op_mod.Stat, cb: Callback, user: ?*anyopaque) !void {
        op.* = .{ .cb = cb, .user = user, .kind = .fstat, .fd = fd, .buf = out };
        try loop.submit(op);
    }

    pub fn timeout(loop: *Loop, op: *Op, ns: u64, cb: Callback, user: ?*anyopaque) !void {
        op.* = .{ .cb = cb, .user = user, .kind = .timeout, .aux = ns };
        try loop.submit(op);
    }

    /// Fills `op` from `fields` (whose `cb`/`user` are overwritten) and submits it. The typed
    /// helpers below are thin wrappers; use this directly for anything not covered.
    pub fn start(loop: *Loop, op: *Op, fields: Op, cb: Callback, user: ?*anyopaque) !void {
        op.* = fields;
        op.cb = cb;
        op.user = user;
        try loop.submit(op);
    }

    pub fn fsync(loop: *Loop, op: *Op, fd: op_mod.Fd, datasync: bool, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .fsync, .fd = fd, .flags = @intFromBool(datasync) }, cb, user);
    }

    /// Copies up to `count` bytes from `in` (at `in_offset`, -1 = current) to `out`.
    pub fn sendfile(loop: *Loop, op: *Op, out: op_mod.Fd, in: op_mod.Fd, in_offset: i64, count: usize, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .sendfile, .fd = out, .fd2 = in, .offset = in_offset, .len = count }, cb, user);
    }

    pub fn fallocate(loop: *Loop, op: *Op, fd: op_mod.Fd, offset: i64, len: usize, flags: u64, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .fallocate, .fd = fd, .offset = offset, .len = len, .aux = flags }, cb, user);
    }

    pub fn send(loop: *Loop, op: *Op, fd: op_mod.Fd, buf: []const u8, msg_flags: u32, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .send, .fd = fd, .buf = @constCast(buf.ptr), .len = buf.len, .flags = msg_flags }, cb, user);
    }

    pub fn recv(loop: *Loop, op: *Op, fd: op_mod.Fd, buf: []u8, msg_flags: u32, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .recv, .fd = fd, .buf = buf.ptr, .len = buf.len, .flags = msg_flags }, cb, user);
    }

    /// `msg` is the platform `struct msghdr *`; it and everything it points to must outlive the op.
    pub fn sendmsg(loop: *Loop, op: *Op, fd: op_mod.Fd, msg: *anyopaque, msg_flags: u32, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .sendmsg, .fd = fd, .buf = msg, .flags = msg_flags }, cb, user);
    }

    pub fn recvmsg(loop: *Loop, op: *Op, fd: op_mod.Fd, msg: *anyopaque, msg_flags: u32, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .recvmsg, .fd = fd, .buf = msg, .flags = msg_flags }, cb, user);
    }

    /// Waits while `*addr == expected`; `timeout_ns < 0` waits forever.
    pub fn futexWait(loop: *Loop, op: *Op, addr: *const u32, expected: u32, timeout_ns: i64, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .futex_wait, .buf = @constCast(addr), .aux = expected, .offset = timeout_ns }, cb, user);
    }

    pub fn futexWake(loop: *Loop, op: *Op, addr: *const u32, count: u32, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .futex_wake, .buf = @constCast(addr), .aux = count }, cb, user);
    }

    pub fn stat(loop: *Loop, op: *Op, dir: op_mod.Fd, path: [*:0]const u8, nofollow: bool, out: *op_mod.Stat, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .stat, .fd = dir, .path = path, .flags = @intFromBool(nofollow), .buf = out }, cb, user);
    }

    pub fn connect(loop: *Loop, op: *Op, fd: op_mod.Fd, addr: *const anyopaque, addr_len: usize, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .connect, .fd = fd, .buf = @constCast(addr), .len = addr_len }, cb, user);
    }

    /// Result is the new fd. `addr`/`addr_cap` optionally receive the peer address; its size is
    /// written to `op.aux` on completion.
    pub fn accept(loop: *Loop, op: *Op, fd: op_mod.Fd, addr: ?*anyopaque, addr_cap: usize, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .accept, .fd = fd, .buf = addr, .len = addr_cap }, cb, user);
    }

    pub fn link(loop: *Loop, op: *Op, old_dir: op_mod.Fd, old: [*:0]const u8, new_dir: op_mod.Fd, new: [*:0]const u8, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .link, .fd = old_dir, .path = old, .fd2 = new_dir, .path2 = new }, cb, user);
    }

    pub fn unlink(loop: *Loop, op: *Op, dir: op_mod.Fd, path: [*:0]const u8, rmdir: bool, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .unlink, .fd = dir, .path = path, .flags = @intFromBool(rmdir) }, cb, user);
    }

    pub fn rename(loop: *Loop, op: *Op, old_dir: op_mod.Fd, old: [*:0]const u8, new_dir: op_mod.Fd, new: [*:0]const u8, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .rename, .fd = old_dir, .path = old, .fd2 = new_dir, .path2 = new }, cb, user);
    }

    /// See `Kind.readdir`. `cookie` is 0 for the first call, then the previous completion's `op.aux`.
    pub fn readdir(loop: *Loop, op: *Op, fd: op_mod.Fd, buf: []u8, cookie: u64, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .readdir, .fd = fd, .buf = buf.ptr, .len = buf.len, .offset = @intCast(cookie) }, cb, user);
    }

    pub fn ftruncate(loop: *Loop, op: *Op, fd: op_mod.Fd, len: u64, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .ftruncate, .fd = fd, .offset = @intCast(len) }, cb, user);
    }

    /// `offset` -1 = current position, otherwise preadv.
    pub fn readv(loop: *Loop, op: *Op, fd: op_mod.Fd, iov: []const op_mod.Iovec, offset: i64, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .readv, .fd = fd, .buf = @constCast(iov.ptr), .len = iov.len, .offset = offset }, cb, user);
    }

    pub fn writev(loop: *Loop, op: *Op, fd: op_mod.Fd, iov: []const op_mod.Iovec, offset: i64, cb: Callback, user: ?*anyopaque) !void {
        try loop.start(op, .{ .kind = .writev, .fd = fd, .buf = @constCast(iov.ptr), .len = iov.len, .offset = offset }, cb, user);
    }
};

fn createBackend(allocator: std.mem.Allocator, options: Options) !backend_mod.Backend {
    const threaded = @import("backend/threaded.zig");
    const choice: backend_mod.Kind = @fromBackingInt(@intCast(options.backend));
    switch (choice) {
        .threaded => return threaded.create(allocator, options),
        .uring => {
            const uring = @import("backend/uring.zig");
            if (!uring.supported) return error.Unsupported;
            return uring.create(allocator, options);
        },
        .kqueue_gcd => {
            const kqueue = @import("backend/kqueue.zig");
            if (!kqueue.supported) return error.Unsupported;
            return kqueue.create(allocator, options);
        },
        .iocp => return error.Unsupported,
        .auto => {
            if (builtin.os.tag == .linux) {
                const uring = @import("backend/uring.zig");
                if (uring.create(allocator, options)) |b| return b else |_| {}
            } else if (builtin.os.tag.isDarwin() or builtin.os.tag.isBSD()) {
                const kqueue = @import("backend/kqueue.zig");
                return kqueue.create(allocator, options);
            }
            return threaded.create(allocator, options);
        },
    }
}
