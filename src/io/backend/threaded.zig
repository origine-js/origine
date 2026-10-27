//! Portable POSIX fallback backend: a pool of worker threads running blocking libc calls.
//!
//! Locking: `mu` guards `work`, `done`, `posts`, `stop`, `woken` and every op's `priv[1]` state
//! while the op is owned by the pool. Workers touch nothing but the op and those queues. Timers
//! live in a loop-thread-only heap (timers.zig, heap index in `op.priv[4]`).
//! `PostNode`s are allocated with `std.heap.c_allocator`; whoever runs them must free them there.
const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig");
const op_mod = @import("../op.zig");
const tm = @import("../timers.zig");
const Op = op_mod.Op;
const c = std.c;

const default_workers = 4;
/// Upper bound the pool grows to when every worker is blocked and ops are queued.
const max_workers = 64;

/// Values of `op.priv[1]` while the pool owns an op.
const State = enum(usize) { none = 0, queued = 1, running = 2, running_cancelled = 3, done = 4 };

fn getState(op: *Op) State {
    return @fromBackingInt(@intCast(@intFromPtr(op.priv[1])));
}

fn setState(op: *Op, s: State) void {
    op.priv[1] = @ptrFromInt(@backingInt(s));
}

const Self = struct {
    allocator: std.mem.Allocator,
    mu: c.pthread_mutex_t = .{},
    work_cv: c.pthread_cond_t = .{},
    loop_cv: c.pthread_cond_t = .{},
    work: op_mod.Queue = .{},
    done: op_mod.Queue = .{},
    posts_head: ?*backend.PostNode = null,
    posts_tail: ?*backend.PostNode = null,
    stop: bool = false,
    woken: bool = false,
    /// Self-pipe behind `pollable()`: non-blocking, close-on-exec. Readable iff `signalled`
    /// (guarded by `mu`); one byte is written when the loop has pending work, `poll` drains it.
    pipe_r: c_int = -1,
    pipe_w: c_int = -1,
    signalled: bool = false,
    /// Loop-thread only.
    timers: tm.Timers = .{ .slot = 4 },
    /// Loop-thread only (grown by `submit`, joined by `destroy`).
    threads: std.ArrayList(std.Thread) = .empty,
    /// Guarded by `mu`: queued ops and workers parked on `work_cv`.
    nqueued: usize = 0,
    idle: usize = 0,
    /// Pool growth cap (loop thread only).
    cap: usize = max_workers,

    fn lock(s: *Self) void {
        _ = c.pthread_mutex_lock(&s.mu);
    }
    fn unlock(s: *Self) void {
        _ = c.pthread_mutex_unlock(&s.mu);
    }
    /// Caller holds `mu`. Makes `pipe_r` readable (coalesced).
    fn signalLocked(s: *Self) void {
        if (s.signalled) return;
        s.signalled = true;
        const b: [1]u8 = .{1};
        _ = c.write(s.pipe_w, &b, 1);
    }
    /// Caller holds `mu`. Makes `pipe_r` not readable.
    fn drainLocked(s: *Self) void {
        if (!s.signalled) return;
        s.signalled = false;
        var b: [64]u8 = undefined;
        _ = c.read(s.pipe_r, &b, b.len);
    }
};

const vtable: backend.VTable = .{
    .submit = submit,
    .cancel = cancel,
    .poll = poll,
    .wake = wake,
    .post = post,
    .pollable = pollable,
    .caps = .{
        .nop = true,
        .file_io = true,
        .timeout = true,
        .cancel = true,
        .vectored = true,
        .sockets = true,
        .sendfile = true,
        .fallocate = true,
        .link = true,
        .sync = true,
        .pollable = true,
        .readdir = readdir_supported,
        .ftruncate = true,
        .futex = builtin.os.tag == .linux or builtin.os.tag.isDarwin(),
    },
    .destroy = destroy,
};

pub fn create(allocator: std.mem.Allocator, opts: backend.Options) !backend.Backend {
    const n: usize = @min(if (opts.entries == 0) default_workers else opts.entries, max_workers);
    const s = try allocator.create(Self);
    errdefer allocator.destroy(s);
    s.* = .{ .allocator = allocator };
    try makePipe(s);
    errdefer {
        _ = c.close(s.pipe_r);
        _ = c.close(s.pipe_w);
    }
    try s.threads.ensureTotalCapacity(allocator, max_workers);
    errdefer s.threads.deinit(allocator);

    errdefer {
        s.lock();
        s.stop = true;
        s.unlock();
        _ = c.pthread_cond_broadcast(&s.work_cv);
        for (s.threads.items) |t| t.join();
    }
    while (s.threads.items.len < n) {
        const t = try std.Thread.spawn(.{}, worker, .{s});
        s.threads.appendAssumeCapacity(t);
    }
    return .{ .ctx = s, .vtable = &vtable };
}

fn makePipe(s: *Self) !void {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.SystemResources;
    const F_GETFL = 3;
    const F_SETFL = 4;
    const F_SETFD = 2;
    const FD_CLOEXEC = 1;
    const nonblock: c_int = @bitCast(c.O{ .NONBLOCK = true });
    for (fds) |fd| {
        _ = c.fcntl(fd, F_SETFD, @as(c_int, FD_CLOEXEC));
        const fl = c.fcntl(fd, F_GETFL);
        _ = c.fcntl(fd, F_SETFL, fl | nonblock);
    }
    s.pipe_r = fds[0];
    s.pipe_w = fds[1];
}

fn ctxOf(ctx: *anyopaque) *Self {
    return @ptrCast(@alignCast(ctx));
}

// ---- time ---------------------------------------------------------------------------------

fn nowNs(clock: c.clockid_t) u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(clock, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// ---- vtable -------------------------------------------------------------------------------

fn submit(ctx: *anyopaque, op: *Op) anyerror!void {
    const s = ctxOf(ctx);
    op.priv[0] = null;
    switch (op.kind) {
        .timeout => {
            op.priv[4] = null;
            try s.timers.push(s.allocator, op, tm.deadlineAfter(nowNs(.MONOTONIC), op.aux));
            setState(op, .none);
        },
        .nop => {
            s.lock();
            op.result = 0;
            setState(op, .done);
            s.done.push(op);
            s.signalLocked();
            s.unlock();
        },
        else => {
            s.lock();
            setState(op, .queued);
            s.work.push(op);
            s.nqueued += 1;
            // Every worker is busy (possibly blocked in accept/recv/futex_wait): grow the pool so
            // the queued op can still run, up to `max_workers`.
            const grow = s.nqueued > s.idle and s.threads.items.len < s.cap;
            s.unlock();
            if (grow) {
                if (std.Thread.spawn(.{}, worker, .{s})) |t| s.threads.appendAssumeCapacity(t) else |_| {}
            }
            _ = c.pthread_cond_signal(&s.work_cv);
        },
    }
}

fn cancel(ctx: *anyopaque, op: *Op) bool {
    const s = ctxOf(ctx);
    if (s.timers.remove(op)) {
        s.lock();
        op.result = -ecancelled;
        setState(op, .done);
        s.done.push(op);
        s.signalLocked();
        s.unlock();
        return true;
    }
    s.lock();
    defer s.unlock();
    switch (getState(op)) {
        .queued => {
            if (s.work.remove(op)) {
                s.nqueued -= 1;
                op.result = -ecancelled;
                setState(op, .done);
                s.done.push(op);
                s.signalLocked();
            }
            return true;
        },
        .running => {
            setState(op, .running_cancelled);
            return true;
        },
        .running_cancelled, .done => return true,
        .none => return false,
    }
}

const ecancelled: i64 = @backingInt(c.E.CANCELED);

fn poll(ctx: *anyopaque, block: bool, out: *backend.Drained) void {
    const s = ctxOf(ctx);
    s.lock();
    while (s.done.isEmpty() and s.posts_head == null and !s.woken) {
        if (!block) break;
        if (earliest(s)) |dl| {
            const now = nowNs(.MONOTONIC);
            if (dl <= now) break;
            var ts: c.timespec = undefined;
            _ = c.clock_gettime(.REALTIME, &ts);
            const abs: u64 = @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec)) + (dl - now);
            ts = .{ .sec = @intCast(abs / std.time.ns_per_s), .nsec = @intCast(abs % std.time.ns_per_s) };
            _ = c.pthread_cond_timedwait(&s.loop_cv, &s.mu, &ts);
        } else {
            _ = c.pthread_cond_wait(&s.loop_cv, &s.mu);
        }
        // Re-check expiry after every wake (timedwait may return early or late).
        if (earliest(s)) |dl| if (dl <= nowNs(.MONOTONIC)) break;
    }
    s.drainLocked();
    moveDone(s, out);
    var p = s.posts_head;
    s.posts_head = null;
    s.posts_tail = null;
    s.woken = false;
    s.unlock();
    while (p) |node| {
        p = node.next;
        out.pushPost(node);
    }

    if (!s.timers.isEmpty()) {
        const now = nowNs(.MONOTONIC);
        while (s.timers.popDue(now)) |op| {
            op.result = 0;
            setState(op, .none);
            out.done.push(op);
        }
    }
}

fn earliest(s: *Self) ?u64 {
    return s.timers.peek();
}

/// Caller holds `mu`.
fn moveDone(s: *Self, out: *backend.Drained) void {
    while (s.done.pop()) |op| {
        setState(op, .none);
        out.done.push(op);
    }
}

fn wake(ctx: *anyopaque) void {
    const s = ctxOf(ctx);
    s.lock();
    s.woken = true;
    s.signalLocked();
    s.unlock();
    _ = c.pthread_cond_signal(&s.loop_cv);
}

fn post(ctx: *anyopaque, func: backend.PostFn, ud: ?*anyopaque) anyerror!void {
    const s = ctxOf(ctx);
    const node = try std.heap.c_allocator.create(backend.PostNode);
    node.* = .{ .func = func, .ud = ud };
    s.lock();
    if (s.posts_tail) |t| t.next = node else s.posts_head = node;
    s.posts_tail = node;
    s.signalLocked();
    s.unlock();
    _ = c.pthread_cond_signal(&s.loop_cv);
}

fn pollable(ctx: *anyopaque) isize {
    return ctxOf(ctx).pipe_r;
}

fn destroy(ctx: *anyopaque, out: *backend.Drained) void {
    const s = ctxOf(ctx);
    s.lock();
    s.stop = true;
    while (s.work.pop()) |op| {
        s.nqueued -= 1;
        op.result = -ecancelled;
        setState(op, .done);
        s.done.push(op);
    }
    s.unlock();
    while (s.timers.popFirst()) |op| {
        op.result = -ecancelled;
        setState(op, .none);
        out.done.push(op);
    }
    _ = c.pthread_cond_broadcast(&s.work_cv);
    for (s.threads.items) |t| t.join();

    // Workers are gone; no locking needed, but keep the discipline anyway.
    s.lock();
    moveDone(s, out);
    var p = s.posts_head;
    s.posts_head = null;
    s.posts_tail = null;
    s.unlock();
    while (p) |node| {
        p = node.next;
        out.pushPost(node);
    }

    _ = c.close(s.pipe_r);
    _ = c.close(s.pipe_w);
    _ = c.pthread_cond_destroy(&s.work_cv);
    _ = c.pthread_cond_destroy(&s.loop_cv);
    _ = c.pthread_mutex_destroy(&s.mu);
    const allocator = s.allocator;
    s.threads.deinit(allocator);
    s.timers.deinit(allocator);
    allocator.destroy(s);
}

// ---- workers ------------------------------------------------------------------------------

fn worker(s: *Self) void {
    while (true) {
        s.lock();
        while (s.work.isEmpty() and !s.stop) {
            s.idle += 1;
            _ = c.pthread_cond_wait(&s.work_cv, &s.mu);
            s.idle -= 1;
        }
        const op = s.work.pop() orelse {
            s.unlock();
            return; // stop requested and nothing queued
        };
        s.nqueued -= 1;
        setState(op, .running);
        s.unlock();

        var r = execute(op);
        // A non-blocking socket reports EAGAIN instead of waiting: wait for readiness here (in
        // slices, so a cancel is noticed) and retry, which is what a blocking socket would do.
        while (r == -eagain and isSocketWait(op.kind)) {
            if (!waitReady(s, op)) break;
            r = execute(op);
        }
        // A non-blocking connect returns EINPROGRESS: like the other backends, complete once the
        // socket is writable and report the connection's own error.
        if (r == -einprogress and op.kind == .connect and waitReady(s, op)) r = connectResult(op);

        s.lock();
        // A cancel only replaces a result the syscall did not produce (the readiness wait gave up);
        // a completed accept/recv/write must report its real result or its fd/bytes would be lost.
        if (getState(op) == .running_cancelled and (r == -eagain or r == eintr)) r = -ecancelled;
        op.result = r;
        setState(op, .done);
        s.done.push(op);
        s.signalLocked();
        s.unlock();
        _ = c.pthread_cond_signal(&s.loop_cv);
    }
}

const eagain: i64 = @backingInt(c.E.AGAIN);
const einprogress: i64 = @backingInt(c.E.INPROGRESS);

/// The outcome of a connect that has become writable: 0, or the negated SO_ERROR.
fn connectResult(op: *Op) i64 {
    var err: c_int = 0;
    var len: u32 = @sizeOf(c_int);
    if (sys.getsockopt(@intCast(op.fd), sol_socket, so_error, &err, &len) < 0) return errResult();
    return -@as(i64, err);
}

fn isSocketWait(kind: op_mod.Kind) bool {
    return switch (kind) {
        .send, .recv, .sendmsg, .recvmsg, .accept => true,
        else => false,
    };
}

/// Blocks (in 25 ms slices) until `op`'s descriptor is ready; false if the op was cancelled or the backend is shutting down.
fn waitReady(s: *Self, op: *Op) bool {
    const events: i16 = switch (op.kind) {
        .send, .sendmsg, .connect => c.POLL.OUT,
        else => c.POLL.IN,
    };
    while (true) {
        var pfd = [_]c.pollfd{.{ .fd = @intCast(op.fd), .events = events, .revents = 0 }};
        if (c.poll(&pfd, 1, 25) != 0) return true; // ready, or an error the retry will report
        s.lock();
        const cancelled = getState(op) == .running_cancelled or s.stop;
        s.unlock();
        if (cancelled) return false;
    }
}

fn errResult() i64 {
    return -@as(i64, @intCast(c._errno().*));
}

/// Maps a libc return value (-1 on failure) to the op result, retrying EINTR via `again`.
fn fin(rc: anytype) i64 {
    return if (rc == -1) errResult() else @intCast(rc);
}

fn dirfdOf(fd: op_mod.Fd) c_int {
    return if (fd == op_mod.fd_cwd) c.AT.FDCWD else @intCast(fd);
}

fn translateOpen(aux: u64) c.O {
    var o: c.O = .{};
    o.ACCMODE = switch (aux & 3) {
        1 => .WRONLY,
        2 => .RDWR,
        else => .RDONLY,
    };
    o.CREAT = aux & op_mod.O.CREAT != 0;
    o.TRUNC = aux & op_mod.O.TRUNC != 0;
    o.APPEND = aux & op_mod.O.APPEND != 0;
    o.EXCL = aux & op_mod.O.EXCL != 0;
    o.DIRECTORY = aux & op_mod.O.DIRECTORY != 0;
    o.CLOEXEC = true;
    return o;
}

fn execute(op: *Op) i64 {
    const enosys: i64 = -@as(i64, @backingInt(c.E.NOSYS));
    const einval: i64 = -@as(i64, @backingInt(c.E.INVAL));
    while (true) {
        const r: i64 = switch (op.kind) {
            .open => blk: {
                const path = op.path orelse break :blk einval;
                const mode: c_uint = @truncate(op.aux >> 32);
                break :blk fin(c.openat(dirfdOf(op.fd), path, translateOpen(op.aux), mode));
            },
            .close => fin(c.close(@intCast(op.fd))),
            .read => blk: {
                const buf: [*]u8 = @ptrCast(op.buf orelse break :blk if (op.len == 0) 0 else einval);
                break :blk if (op.offset == -1)
                    fin(c.read(@intCast(op.fd), buf, op.len))
                else
                    fin(c.pread(@intCast(op.fd), buf, op.len, @intCast(op.offset)));
            },
            .write => blk: {
                const buf: [*]const u8 = @ptrCast(op.buf orelse break :blk if (op.len == 0) 0 else einval);
                break :blk if (op.offset == -1)
                    fin(c.write(@intCast(op.fd), buf, op.len))
                else
                    fin(c.pwrite(@intCast(op.fd), buf, op.len, @intCast(op.offset)));
            },
            .fstat => doFstat(op, einval),
            .mkdir => blk: {
                const path = op.path orelse break :blk einval;
                break :blk fin(c.mkdirat(dirfdOf(op.fd), path, @intCast(op.aux)));
            },
            .unlink => blk: {
                const path = op.path orelse break :blk einval;
                const flags: c_uint = if (op.flags & 1 != 0) c.AT.REMOVEDIR else 0;
                break :blk fin(c.unlinkat(dirfdOf(op.fd), path, flags));
            },
            .rename => blk: {
                const old = op.path orelse break :blk einval;
                const new = op.path2 orelse break :blk einval;
                break :blk fin(c.renameat(dirfdOf(op.fd), old, dirfdOf(op.fd2), new));
            },
            .fsync => doFsync(op),
            .fallocate => doFallocate(op, einval),
            .send => blk: {
                const buf = op.buf orelse break :blk if (op.len == 0) 0 else einval;
                break :blk fin(sys.send(@intCast(op.fd), buf, op.len, @bitCast(op.flags)));
            },
            .recv => blk: {
                const buf = op.buf orelse break :blk if (op.len == 0) 0 else einval;
                break :blk fin(sys.recv(@intCast(op.fd), buf, op.len, @bitCast(op.flags)));
            },
            .sendmsg => blk: {
                const m = op.buf orelse break :blk einval;
                break :blk fin(sys.sendmsg(@intCast(op.fd), m, @bitCast(op.flags)));
            },
            .recvmsg => blk: {
                const m = op.buf orelse break :blk einval;
                break :blk fin(sys.recvmsg(@intCast(op.fd), m, @bitCast(op.flags)));
            },
            .connect => doConnect(op, einval),
            .accept => doAccept(op),
            .stat => doStat(op, einval),
            .link => blk: {
                const old = op.path orelse break :blk einval;
                const new = op.path2 orelse break :blk einval;
                break :blk fin(sys.linkat(dirfdOf(op.fd), old, dirfdOf(op.fd2), new, 0));
            },
            .readv => blk: {
                const iov = op.buf orelse break :blk if (op.len == 0) 0 else einval;
                const cnt: c_int = std.math.cast(c_int, op.len) orelse break :blk einval;
                break :blk if (op.offset == -1)
                    fin(sys.readv(@intCast(op.fd), iov, cnt))
                else
                    fin(sys.preadv(@intCast(op.fd), iov, cnt, op.offset));
            },
            .writev => blk: {
                const iov = op.buf orelse break :blk if (op.len == 0) 0 else einval;
                const cnt: c_int = std.math.cast(c_int, op.len) orelse break :blk einval;
                break :blk if (op.offset == -1)
                    fin(sys.writev(@intCast(op.fd), iov, cnt))
                else
                    fin(sys.pwritev(@intCast(op.fd), iov, cnt, op.offset));
            },
            .sendfile => doSendfile(op),
            .futex_wait => doFutexWait(op, einval),
            .futex_wake => doFutexWake(op, einval),
            .readdir => doReaddir(op, einval),
            .ftruncate => blk: {
                if (op.offset < 0) break :blk einval;
                break :blk fin(sys.ftruncate(@intCast(op.fd), op.offset));
            },
            else => enosys,
        };
        // close(2) must not be retried (the descriptor is already released, and the number may
        // have been reused), and a futex wait would restart its whole relative timeout.
        if (r == eintr and op.kind != .close and op.kind != .futex_wait) continue;
        return r;
    }
}

fn kindOfMode(mode: u32) u32 {
    return switch (mode & 0o170000) {
        0o100000 => 1,
        0o040000 => 2,
        0o120000 => 3,
        else => 0,
    };
}

fn doFstat(op: *Op, einval: i64) i64 {
    const out: *op_mod.Stat = @ptrCast(@alignCast(op.buf orelse return einval));
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        const rc = linux.statx(@intCast(op.fd), "", linux.AT.EMPTY_PATH, @bitCast(@as(u32, 0x7ff)), &sx);
        const e = linux.errno(rc);
        if (e != .SUCCESS) return -@as(i64, @backingInt(e));
        out.* = .{ .size = sx.size, .mode = sx.mode, .kind = kindOfMode(sx.mode) };
        return 0;
    } else {
        var st: c.Stat = undefined;
        const rc = c.fstat(@intCast(op.fd), &st);
        if (rc != 0) return errResult();
        const mode: u32 = @intCast(st.mode);
        out.* = .{ .size = @intCast(st.size), .mode = mode, .kind = kindOfMode(mode) };
        return 0;
    }
}

// ---- raw libc declarations (pointer types kept opaque so the ABI is identical everywhere) ------

const sys = struct {
    extern "c" fn send(fd: c_int, buf: *const anyopaque, len: usize, flags: c_int) isize;
    extern "c" fn recv(fd: c_int, buf: *anyopaque, len: usize, flags: c_int) isize;
    extern "c" fn sendmsg(fd: c_int, msg: *const anyopaque, flags: c_int) isize;
    extern "c" fn recvmsg(fd: c_int, msg: *anyopaque, flags: c_int) isize;
    extern "c" fn readv(fd: c_int, iov: *const anyopaque, cnt: c_int) isize;
    extern "c" fn writev(fd: c_int, iov: *const anyopaque, cnt: c_int) isize;
    extern "c" fn preadv(fd: c_int, iov: *const anyopaque, cnt: c_int, off: i64) isize;
    extern "c" fn pwritev(fd: c_int, iov: *const anyopaque, cnt: c_int, off: i64) isize;
    extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: u32) c_int;
    extern "c" fn getsockopt(fd: c_int, level: c_int, name: c_int, val: *anyopaque, len: *u32) c_int;
    extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
    extern "c" fn accept4(fd: c_int, addr: ?*anyopaque, len: ?*u32, flags: c_int) c_int;
    extern "c" fn linkat(oldfd: c_int, old: [*:0]const u8, newfd: c_int, new: [*:0]const u8, flags: c_int) c_int;
    extern "c" fn fsync(fd: c_int) c_int;
    extern "c" fn fdatasync(fd: c_int) c_int;
    extern "c" fn posix_fallocate(fd: c_int, off: i64, len: i64) c_int;
    extern "c" fn ftruncate(fd: c_int, len: i64) c_int;
    extern "c" fn lseek(fd: c_int, off: i64, whence: c_int) i64;
    extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
};

const eintr: i64 = -@as(i64, @backingInt(c.E.INTR));
const sol_socket: c_int = if (builtin.os.tag == .linux) 1 else 0xffff;
const so_error: c_int = if (builtin.os.tag == .linux) 4 else 0x1007;

fn neg(e: c.E) i64 {
    return -@as(i64, @backingInt(e));
}

// ---- fsync / fallocate ------------------------------------------------------------------------

fn doFsync(op: *Op) i64 {
    const fd: c_int = @intCast(op.fd);
    const data_only = op.flags & 1 != 0;
    if (builtin.os.tag.isDarwin()) {
        if (!data_only) {
            const F_FULLFSYNC = 51;
            if (c.fcntl(fd, F_FULLFSYNC) != -1) return 0;
            // Not supported by the filesystem: fall back to plain fsync.
        }
        return fin(sys.fsync(fd));
    }
    if (data_only and (builtin.os.tag == .linux or builtin.os.tag == .freebsd))
        return fin(sys.fdatasync(fd));
    return fin(sys.fsync(fd));
}

fn doFallocate(op: *Op, einval: i64) i64 {
    if (op.offset < 0) return einval;
    const fd: c_int = @intCast(op.fd);
    const keep = op.aux & op_mod.FallocFlags.KEEP_SIZE != 0;
    const len: i64 = std.math.cast(i64, op.len) orelse return einval;
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.fallocate(fd, if (keep) 1 else 0, op.offset, len);
        const e = std.os.linux.errno(rc);
        return if (e == .SUCCESS) 0 else neg(@fromBackingInt(@intCast(@backingInt(e))));
    } else if (builtin.os.tag.isDarwin()) {
        const end = std.math.add(i64, op.offset, len) catch return einval;
        var st: c.Stat = undefined;
        if (c.fstat(fd, &st) != 0) return errResult();
        const size: i64 = @intCast(st.size);
        if (end <= size) return 0;
        const Fstore = extern struct { flags: u32, posmode: c_int, offset: i64, length: i64, bytesalloc: i64 };
        const F_PREALLOCATE = 42;
        const F_ALLOCATECONTIG = 2;
        const F_ALLOCATEALL = 4;
        const F_PEOFPOSMODE = 3;
        var fs: Fstore = .{ .flags = F_ALLOCATECONTIG | F_ALLOCATEALL, .posmode = F_PEOFPOSMODE, .offset = 0, .length = end - size, .bytesalloc = 0 };
        if (c.fcntl(fd, F_PREALLOCATE, &fs) == -1) {
            fs.flags = F_ALLOCATEALL; // contiguous space not available
            if (c.fcntl(fd, F_PREALLOCATE, &fs) == -1) return errResult();
        }
        if (!keep) return fin(sys.ftruncate(fd, end));
        return 0;
    } else if (builtin.os.tag == .freebsd) {
        const rc = sys.posix_fallocate(fd, op.offset, len);
        return if (rc == 0) 0 else -@as(i64, rc);
    }
    return neg(.NOSYS);
}

// ---- sockets ----------------------------------------------------------------------------------

fn doConnect(op: *Op, einval: i64) i64 {
    const addr = op.buf orelse return einval;
    const alen: u32 = std.math.cast(u32, op.len) orelse return einval;
    var retried = false;
    while (true) {
        const rc = sys.connect(@intCast(op.fd), addr, alen);
        if (rc == 0) return 0;
        const r = errResult();
        if (r == eintr) {
            retried = true;
            continue;
        }
        // A retry after EINTR may observe the already-established connection.
        if (retried and r == neg(.ISCONN)) return 0;
        return r;
    }
}

fn doAccept(op: *Op) i64 {
    var alen: u32 = @intCast(@min(op.len, std.math.maxInt(u32)));
    const lenp: ?*u32 = if (op.buf != null) &alen else null;
    const rc: c_int = if (builtin.os.tag == .linux)
        sys.accept4(@intCast(op.fd), op.buf, lenp, @intCast(std.os.linux.SOCK.CLOEXEC))
    else
        sys.accept(@intCast(op.fd), op.buf, lenp);
    if (rc == -1) return errResult();
    if (builtin.os.tag != .linux) {
        const F_SETFD = 2;
        const FD_CLOEXEC = 1;
        _ = c.fcntl(rc, F_SETFD, @as(c_int, FD_CLOEXEC));
    }
    if (op.buf != null) op.aux = alen;
    return rc;
}

// ---- sendfile ---------------------------------------------------------------------------------

fn doSendfile(op: *Op) i64 {
    const out: c_int = @intCast(op.fd);
    const in: c_int = @intCast(op.fd2);
    if (op.len == 0) return 0;
    if (builtin.os.tag == .linux) {
        const L = struct {
            extern "c" fn sendfile(out: c_int, in: c_int, off: ?*i64, count: usize) isize;
        };
        var off: i64 = op.offset;
        const rc = L.sendfile(out, in, if (op.offset >= 0) &off else null, op.len);
        if (rc >= 0) return rc;
        const r = errResult();
        if (r != neg(.INVAL) and r != neg(.NOSYS)) return r;
    } else if (builtin.os.tag.isDarwin()) {
        var st: c.Stat = undefined;
        if (c.fstat(out, &st) == 0 and (@as(u32, st.mode) & 0o170000) == 0o140000) {
            const D = struct {
                extern "c" fn sendfile(fd: c_int, s: c_int, off: i64, len: *i64, hdtr: ?*anyopaque, flags: c_int) c_int;
            };
            const start: i64 = if (op.offset >= 0) op.offset else sys.lseek(in, 0, 1);
            if (start < 0) return errResult();
            var n: i64 = @intCast(@min(op.len, std.math.maxInt(i64)));
            const rc = D.sendfile(in, out, start, &n, null, 0);
            if (rc == -1) {
                const r = errResult();
                if (n == 0 or r != neg(.INTR) and r != neg(.AGAIN)) return r;
            }
            if (op.offset < 0) _ = sys.lseek(in, start + n, 0);
            return n;
        }
    }
    return copyLoop(op, out, in);
}

/// pread/pwrite (or read/write for offset -1) copy, used when no kernel offload applies.
fn copyLoop(op: *Op, out: c_int, in: c_int) i64 {
    var buf: [64 * 1024]u8 = undefined;
    var total: usize = 0;
    var off: i64 = op.offset;
    while (total < op.len) {
        const want = @min(buf.len, op.len - total);
        const n = if (op.offset >= 0) c.pread(in, &buf, want, off) else c.read(in, &buf, want);
        if (n == -1) {
            const r = errResult();
            if (r == eintr) continue;
            return if (total > 0) @intCast(total) else r;
        }
        if (n == 0) break;
        const got: usize = @intCast(n);
        var done: usize = 0;
        while (done < got) {
            const w = c.write(out, buf[done..].ptr, got - done);
            if (w == -1) {
                const r = errResult();
                if (r == eintr) continue;
                return if (total > 0) @intCast(total) else r;
            }
            done += @intCast(w);
        }
        total += got;
        if (op.offset >= 0) off += @intCast(got);
    }
    return @intCast(total);
}

// ---- futex ------------------------------------------------------------------------------------

const OsSyncWait = *const fn (addr: *anyopaque, value: u64, size: usize, flags: u32) callconv(.c) c_int;
const OsSyncWaitTimeout = *const fn (addr: *anyopaque, value: u64, size: usize, flags: u32, clock: u32, ns: u64) callconv(.c) c_int;
const OsSyncWake = *const fn (addr: *anyopaque, size: usize, flags: u32) callconv(.c) c_int;

fn darwinSym(comptime T: type, name: [*:0]const u8) ?T {
    const rtld_default: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize) - 1); // (void *)-2
    const p = sys.dlsym(rtld_default, name) orelse return null;
    return @ptrCast(@alignCast(p));
}

fn doFutexWait(op: *Op, einval: i64) i64 {
    const addr: *u32 = @ptrCast(@alignCast(op.buf orelse return einval));
    const expected: u32 = @truncate(op.aux);
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var ts: linux.timespec = .{
            .sec = @intCast(@divTrunc(op.offset, std.time.ns_per_s)),
            .nsec = @intCast(@rem(op.offset, std.time.ns_per_s)),
        };
        const rc = linux.futex_4arg(addr, .{ .cmd = .WAIT, .private = true }, expected, if (op.offset >= 0) &ts else null);
        const e = linux.errno(rc);
        return if (e == .SUCCESS) 0 else neg(@fromBackingInt(@intCast(@backingInt(e))));
    } else if (builtin.os.tag.isDarwin()) {
        if (@atomicLoad(u32, addr, .seq_cst) != expected) return neg(.AGAIN);
        const rc: c_int = if (op.offset >= 0) blk: {
            const f = darwinSym(OsSyncWaitTimeout, "os_sync_wait_on_address_with_timeout") orelse return neg(.NOSYS);
            const OS_CLOCK_MACH_ABSOLUTE_TIME = 32;
            break :blk f(addr, expected, 4, 0, OS_CLOCK_MACH_ABSOLUTE_TIME, @intCast(op.offset));
        } else blk: {
            const f = darwinSym(OsSyncWait, "os_sync_wait_on_address") orelse return neg(.NOSYS);
            break :blk f(addr, expected, 4, 0);
        };
        return if (rc >= 0) 0 else errResult();
    }
    return neg(.NOSYS);
}

fn doFutexWake(op: *Op, einval: i64) i64 {
    const addr: *u32 = @ptrCast(@alignCast(op.buf orelse return einval));
    const count: u64 = op.aux;
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const n: u32 = @intCast(@min(count, std.math.maxInt(i32)));
        const rc = linux.futex_3arg(addr, .{ .cmd = .WAKE, .private = true }, n);
        const e = linux.errno(rc);
        return if (e == .SUCCESS) @intCast(rc) else neg(@fromBackingInt(@intCast(@backingInt(e))));
    } else if (builtin.os.tag.isDarwin()) {
        // Darwin cannot report how many waiters were woken: count == 1 uses the "any" variant
        // (result 1 or 0); larger counts wake everyone and report 1 if there was any waiter, else 0.
        const f = darwinSym(OsSyncWake, if (count == 1) "os_sync_wake_by_address_any" else "os_sync_wake_by_address_all") orelse return neg(.NOSYS);
        if (f(addr, 4, 0) == 0) return 1;
        const r = errResult();
        return if (r == neg(.NOENT)) 0 else r;
    }
    return neg(.NOSYS);
}

fn doStat(op: *Op, einval: i64) i64 {
    const path = op.path orelse return einval;
    const out: *op_mod.Stat = @ptrCast(@alignCast(op.buf orelse return einval));
    const nofollow = op.flags & 1 != 0;
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        const rc = linux.statx(dirfdOf(op.fd), path, if (nofollow) linux.AT.SYMLINK_NOFOLLOW else 0, @bitCast(@as(u32, 0x7ff)), &sx);
        const e = linux.errno(rc);
        if (e != .SUCCESS) return neg(@fromBackingInt(@intCast(@backingInt(e))));
        out.* = .{ .size = sx.size, .mode = sx.mode, .kind = kindOfMode(sx.mode) };
        return 0;
    } else {
        var st: c.Stat = undefined;
        if (c.fstatat(dirfdOf(op.fd), path, &st, if (nofollow) c.AT.SYMLINK_NOFOLLOW else 0) != 0) return errResult();
        const mode: u32 = @intCast(st.mode);
        out.* = .{ .size = @intCast(st.size), .mode = mode, .kind = kindOfMode(mode) };
        return 0;
    }
}

// ---- readdir ----------------------------------------------------------------------------------

const readdir_supported = builtin.os.tag == .linux or builtin.os.tag.isDarwin();

const sysd = struct {
    extern "c" fn __getdirentries64(fd: c_int, buf: [*]u8, len: usize, basep: *i64) c_int;
};

fn kindOfDirent(fd: c_int, name: [*:0]const u8, d_type: u8) u32 {
    switch (d_type) {
        8 => return 1,
        4 => return 2,
        10 => return 3,
        0 => {},
        else => return 0,
    }
    // DT_UNKNOWN: ask the filesystem, without following symlinks.
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        const rc = linux.statx(fd, name, linux.AT.SYMLINK_NOFOLLOW, @bitCast(@as(u32, 0x7ff)), &sx);
        return if (linux.errno(rc) == .SUCCESS) kindOfMode(sx.mode) else 0;
    } else {
        var st: c.Stat = undefined;
        if (c.fstatat(fd, name, &st, c.AT.SYMLINK_NOFOLLOW) != 0) return 0;
        return kindOfMode(@intCast(st.mode));
    }
}

/// Raw native directory read into `buf[0..len]`: bytes read, 0 at end, or -errno.
fn readNative(fd: c_int, buf: []u8, len: usize) i64 {
    if (builtin.os.tag == .linux) {
        const rc = std.os.linux.getdents64(fd, buf.ptr, @intCast(len));
        const e = std.os.linux.errno(rc);
        return if (e == .SUCCESS) @intCast(rc) else neg(@fromBackingInt(@intCast(@backingInt(e))));
    } else {
        var base: i64 = 0;
        const rc = sysd.__getdirentries64(fd, buf.ptr, len, &base);
        return if (rc < 0) errResult() else rc;
    }
}

fn doReaddir(op: *Op, einval: i64) i64 {
    if (!readdir_supported) return neg(.NOSYS);
    const out: [*]u8 = @ptrCast(op.buf orelse return einval);
    if (op.len == 0 or op.offset < 0) return einval;
    const fd: c_int = @intCast(op.fd);
    const darwin = builtin.os.tag.isDarwin();
    var cookie: i64 = op.offset;
    if (sys.lseek(fd, cookie, 0) < 0) return errResult();
    var sbuf: [32 * 1024]u8 align(8) = undefined;
    var w: usize = 0;
    var full = false;
    while (true) {
        // Darwin cannot seek to the middle of a batch, so make sure a batch always packs whole:
        // a native entry is always larger than its packed form, hence native size <= len suffices.
        const want = if (darwin) @min(op.len, sbuf.len) else sbuf.len;
        const n = readNative(fd, &sbuf, want);
        if (n < 0) {
            if (darwin and w == 0 and n == neg(.INVAL)) return neg(.RANGE);
            return n;
        }
        if (n == 0) {
            if (darwin) cookie = sys.lseek(fd, 0, 1);
            break;
        }
        const used: usize = @intCast(n);
        var off: usize = 0;
        while (off < used) {
            const reclen = std.mem.readInt(u16, sbuf[off + 16 ..][0..2], .little);
            var d_type: u8 = undefined;
            var name_off: usize = undefined;
            var next_cookie: i64 = undefined;
            var name_len: usize = undefined;
            if (darwin) {
                name_len = std.mem.readInt(u16, sbuf[off + 18 ..][0..2], .little);
                d_type = sbuf[off + 20];
                name_off = off + 21;
                next_cookie = 0;
            } else {
                // linux_dirent64: ino u64, off i64, reclen u16, type u8, name[]
                d_type = sbuf[off + 18];
                name_off = off + 19;
                next_cookie = std.mem.readInt(i64, sbuf[off + 8 ..][0..8], .little);
                name_len = std.mem.indexOfScalar(u8, sbuf[name_off .. off + reclen], 0) orelse (off + reclen - name_off);
            }
            const name = sbuf[name_off .. name_off + name_len];
            const is_dot = std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
            if (!is_dot) {
                const need = 3 + name_len;
                if (w + need > op.len) {
                    full = true;
                    break;
                }
                // Names are NUL-terminated in the native record.
                const kind = kindOfDirent(fd, @ptrCast(sbuf[name_off..].ptr), d_type);
                out[w] = @intCast(kind);
                std.mem.writeInt(u16, out[w + 1 ..][0..2], @intCast(name_len), .little);
                @memcpy(out[w + 3 ..][0..name_len], name);
                w += need;
            }
            if (!darwin) cookie = next_cookie;
            off += reclen;
        }
        if (darwin and !full) cookie = sys.lseek(fd, 0, 1);
        if (full or w > 0) break;
    }
    if (full and w == 0) return neg(.RANGE);
    if (full) {
        // Linux only (Darwin batches always pack whole): continue right after the last entry.
        if (sys.lseek(fd, cookie, 0) < 0) return errResult();
    }
    op.aux = @bitCast(cookie);
    return @intCast(w);
}

// ---- tests --------------------------------------------------------------------------------

const testing = std.testing;
const scratch = "/tmp";

fn sleepMs(ms: u64) void {
    var ts: c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = c.nanosleep(&ts, null);
}

/// Poll (blocking) until `want` ops are collected, returning them in completion order.
fn collect(be: backend.Backend, want: usize, buf: []*Op) usize {
    var n: usize = 0;
    while (n < want) {
        var d: backend.Drained = .{};
        be.vtable.poll(be.ctx, true, &d);
        while (d.done.pop()) |op| {
            buf[n] = op;
            n += 1;
        }
    }
    return n;
}

fn cb(op: *Op, r: i64) callconv(.c) void {
    _ = op;
    _ = r;
}

test "write + read round trip, stat, unlink" {
    const be = try create(testing.allocator, .{ .entries = 2 });
    var sink: backend.Drained = .{};
    defer be.vtable.destroy(be.ctx, &sink);
    var got: [4]*Op = undefined;
    const path = scratch ++ "/threaded_roundtrip.tmp";

    var open: Op = .{ .kind = .open, .path = path, .aux = op_mod.O.RDWR | op_mod.O.CREAT | op_mod.O.TRUNC | (@as(u64, 0o644) << 32) };
    try be.vtable.submit(be.ctx, &open);
    _ = collect(be, 1, &got);
    try testing.expect(open.result >= 0);
    const fd: op_mod.Fd = @intCast(open.result);

    var msg = "hello threaded".*;
    var w: Op = .{ .kind = .write, .fd = fd, .offset = 0, .buf = &msg, .len = msg.len };
    try be.vtable.submit(be.ctx, &w);
    _ = collect(be, 1, &got);
    try testing.expectEqual(@as(i64, msg.len), w.result);

    var rbuf: [32]u8 = undefined;
    var r: Op = .{ .kind = .read, .fd = fd, .offset = 6, .buf = &rbuf, .len = rbuf.len };
    try be.vtable.submit(be.ctx, &r);
    _ = collect(be, 1, &got);
    try testing.expectEqual(@as(i64, msg.len - 6), r.result);
    try testing.expectEqualStrings("threaded", rbuf[0..@intCast(r.result)]);

    var st: op_mod.Stat = undefined;
    var f: Op = .{ .kind = .fstat, .fd = fd, .buf = &st };
    try be.vtable.submit(be.ctx, &f);
    _ = collect(be, 1, &got);
    try testing.expectEqual(@as(i64, 0), f.result);
    try testing.expectEqual(@as(u64, msg.len), st.size);
    try testing.expectEqual(@as(u32, 1), st.kind);

    var cl: Op = .{ .kind = .close, .fd = fd };
    try be.vtable.submit(be.ctx, &cl);
    _ = collect(be, 1, &got);
    try testing.expectEqual(@as(i64, 0), cl.result);

    var un: Op = .{ .kind = .unlink, .path = path };
    try be.vtable.submit(be.ctx, &un);
    _ = collect(be, 1, &got);
    try testing.expectEqual(@as(i64, 0), un.result);
}

test "open missing file yields -ENOENT; nop completes" {
    const be = try create(testing.allocator, .{});
    var sink: backend.Drained = .{};
    defer be.vtable.destroy(be.ctx, &sink);
    var got: [2]*Op = undefined;
    var open: Op = .{ .kind = .open, .path = scratch ++ "/definitely_missing.tmp" };
    var nop: Op = .{ .kind = .nop };
    try be.vtable.submit(be.ctx, &open);
    try be.vtable.submit(be.ctx, &nop);
    _ = collect(be, 2, &got);
    try testing.expectEqual(-@as(i64, @backingInt(c.E.NOENT)), open.result);
    try testing.expectEqual(@as(i64, 0), nop.result);
}

test "out-of-order completion: quick op beats long timeout" {
    const be = try create(testing.allocator, .{});
    var sink: backend.Drained = .{};
    defer be.vtable.destroy(be.ctx, &sink);
    var got: [2]*Op = undefined;
    var slow: Op = .{ .kind = .timeout, .aux = 150 * std.time.ns_per_ms };
    var quick: Op = .{ .kind = .open, .path = scratch ++ "/missing2.tmp" };
    try be.vtable.submit(be.ctx, &slow);
    try be.vtable.submit(be.ctx, &quick);
    const start = nowNs(.MONOTONIC);
    _ = collect(be, 2, &got);
    try testing.expect(got[0] == &quick);
    try testing.expect(got[1] == &slow);
    try testing.expectEqual(@as(i64, 0), slow.result);
    try testing.expect(nowNs(.MONOTONIC) - start >= 140 * std.time.ns_per_ms);
}

test "cancel a timer" {
    const be = try create(testing.allocator, .{ .entries = 1 });
    var sink: backend.Drained = .{};
    defer be.vtable.destroy(be.ctx, &sink);
    var got: [1]*Op = undefined;
    var t: Op = .{ .kind = .timeout, .aux = 60 * std.time.ns_per_s };
    try be.vtable.submit(be.ctx, &t);
    try testing.expect(be.vtable.cancel(be.ctx, &t));
    _ = collect(be, 1, &got);
    try testing.expect(got[0] == &t);
    try testing.expectEqual(-ecancelled, t.result);
    // Already reported: no longer known to the backend.
    try testing.expect(!be.vtable.cancel(be.ctx, &t));
}

test "cancel of a queued op is deterministic" {
    const be = try create(testing.allocator, .{ .entries = 1 });
    var sink: backend.Drained = .{};
    defer be.vtable.destroy(be.ctx, &sink);
    const s = ctxOf(be.ctx);
    s.cap = 1; // no growth, so the victim really stays queued
    var got: [1]*Op = undefined;
    // Block the worker on a read from an empty pipe.
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    var b: [1]u8 = undefined;
    var blocker: Op = .{ .kind = .read, .fd = fds[0], .buf = &b, .len = 1 };
    try be.vtable.submit(be.ctx, &blocker);
    while (true) { // wait until the worker has started it
        s.lock();
        const st = getState(&blocker);
        s.unlock();
        if (st == .running) break;
        sleepMs(1);
    }
    var victim: Op = .{ .kind = .close, .fd = 12345 };
    try be.vtable.submit(be.ctx, &victim);
    try testing.expect(be.vtable.cancel(be.ctx, &victim));
    _ = collect(be, 1, &got);
    try testing.expect(got[0] == &victim);
    try testing.expectEqual(-ecancelled, victim.result);

    // Cancel the running read, then release the worker so it finishes. A blocking read cannot
    // be interrupted, so it consumes the byte: the op must report that real result (1) rather
    // than -ECANCELED, or the byte would be lost.
    try testing.expect(be.vtable.cancel(be.ctx, &blocker));
    _ = c.write(fds[1], "x", 1);
    _ = collect(be, 1, &got);
    try testing.expect(got[0] == &blocker);
    try testing.expectEqual(@as(i64, 1), blocker.result);
    _ = c.close(fds[0]);
    _ = c.close(fds[1]);
}

const Waker = struct {
    be: backend.Backend,
    use_post: bool,
    hit: bool = false,
    fn run(w: *Waker) void {
        sleepMs(50);
        if (w.use_post) w.be.vtable.post(w.be.ctx, onPost, w) catch unreachable else w.be.vtable.wake(w.be.ctx);
    }
    fn onPost(ud: ?*anyopaque) callconv(.c) void {
        const w: *Waker = @ptrCast(@alignCast(ud.?));
        w.hit = true;
    }
};

test "wake and post from another thread unblock a sleeping poll" {
    const be = try create(testing.allocator, .{ .entries = 1 });
    var sink: backend.Drained = .{};
    defer be.vtable.destroy(be.ctx, &sink);

    var w1: Waker = .{ .be = be, .use_post = false };
    const t1 = try std.Thread.spawn(.{}, Waker.run, .{&w1});
    var d1: backend.Drained = .{};
    be.vtable.poll(be.ctx, true, &d1);
    t1.join();
    try testing.expect(d1.done.isEmpty() and d1.posts_head == null);

    var w2: Waker = .{ .be = be, .use_post = true };
    const t2 = try std.Thread.spawn(.{}, Waker.run, .{&w2});
    var d2: backend.Drained = .{};
    be.vtable.poll(be.ctx, true, &d2);
    t2.join();
    const node = d2.posts_head orelse return error.TestUnexpectedResult;
    node.func(node.ud);
    try testing.expect(w2.hit);
    std.heap.c_allocator.destroy(node);

    // Non-blocking poll with nothing ready returns immediately.
    var d3: backend.Drained = .{};
    be.vtable.poll(be.ctx, false, &d3);
    try testing.expect(d3.done.isEmpty());
}

test "destroy with ops in flight completes everything and leaks nothing" {
    const be = try create(testing.allocator, .{ .entries = 1 });
    ctxOf(be.ctx).cap = 1;
    var out: backend.Drained = .{};
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    var b: [1]u8 = undefined;
    var running: Op = .{ .kind = .read, .fd = fds[0], .buf = &b, .len = 1 };
    var queued: Op = .{ .kind = .close, .fd = 12345 };
    var timer: Op = .{ .kind = .timeout, .aux = 60 * std.time.ns_per_s };
    try be.vtable.submit(be.ctx, &running);
    try be.vtable.submit(be.ctx, &queued);
    try be.vtable.submit(be.ctx, &timer);
    try be.vtable.post(be.ctx, Waker.onPost, null);
    sleepMs(30);
    // Let the blocked read finish shortly after destroy starts joining.
    const rel = try std.Thread.spawn(.{}, struct {
        fn f(fd: c_int) void {
            sleepMs(50);
            _ = c.write(fd, "x", 1);
        }
    }.f, .{fds[1]});
    be.vtable.destroy(be.ctx, &out);
    rel.join();

    var n: usize = 0;
    while (out.done.pop()) |op| : (n += 1) {
        if (op == &queued or op == &timer) try testing.expectEqual(-ecancelled, op.result);
    }
    try testing.expectEqual(@as(usize, 3), n);
    const node = out.posts_head orelse return error.TestUnexpectedResult;
    std.heap.c_allocator.destroy(node);
    _ = c.close(fds[0]);
    _ = c.close(fds[1]);
}

// ---- tests for the extended ops -----------------------------------------------------------

const tx = struct {
    extern "c" fn socket(d: c_int, t: c_int, p: c_int) c_int;
    extern "c" fn socketpair(d: c_int, t: c_int, p: c_int, sv: *[2]c_int) c_int;
    extern "c" fn bind(fd: c_int, a: *const anyopaque, l: u32) c_int;
    extern "c" fn listen(fd: c_int, n: c_int) c_int;
    extern "c" fn getsockname(fd: c_int, a: *anyopaque, l: *u32) c_int;
};

fn run(be: backend.Backend, op: *Op) !i64 {
    var got: [1]*Op = undefined;
    try be.vtable.submit(be.ctx, op);
    _ = collect(be, 1, &got);
    return op.result;
}

fn newBackend(n: u32) !backend.Backend {
    return create(testing.allocator, .{ .entries = n });
}

fn openRw(be: backend.Backend, path: [*:0]const u8) !op_mod.Fd {
    var o: Op = .{ .kind = .open, .path = path, .aux = op_mod.O.RDWR | op_mod.O.CREAT | op_mod.O.TRUNC | (@as(u64, 0o644) << 32) };
    const r = try run(be, &o);
    try testing.expect(r >= 0);
    return @intCast(r);
}

test "fsync, fallocate, readv/writev/preadv" {
    const be = try newBackend(2);
    var sink: backend.Drained = .{};
    defer be.vtable.destroy(be.ctx, &sink);
    const path = scratch ++ "/threaded_vec.tmp";
    const fd = try openRw(be, path);
    defer _ = c.unlink(path);
    defer _ = c.close(@intCast(fd));

    var a = "hello ".*;
    var b = "world".*;
    var wv = [_]op_mod.Iovec{ .{ .base = &a, .len = a.len }, .{ .base = &b, .len = b.len } };
    var w: Op = .{ .kind = .writev, .fd = fd, .buf = &wv, .len = 2 };
    try testing.expectEqual(@as(i64, 11), try run(be, &w));

    var fs: Op = .{ .kind = .fsync, .fd = fd };
    try testing.expectEqual(@as(i64, 0), try run(be, &fs));
    var fd2: Op = .{ .kind = .fsync, .fd = fd, .flags = 1 };
    try testing.expectEqual(@as(i64, 0), try run(be, &fd2));

    var x: [5]u8 = undefined;
    var y: [3]u8 = undefined;
    var rv = [_]op_mod.Iovec{ .{ .base = &x, .len = x.len }, .{ .base = &y, .len = y.len } };
    var r: Op = .{ .kind = .readv, .fd = fd, .buf = &rv, .len = 2, .offset = 3 };
    try testing.expectEqual(@as(i64, 8), try run(be, &r));
    try testing.expectEqualStrings("lo wo", &x);
    try testing.expectEqualStrings("rld", &y);

    // pwritev at an offset does not move the (end-of-write) position semantics: verify content.
    var z = "WO".*;
    var pv = [_]op_mod.Iovec{.{ .base = &z, .len = 2 }};
    var pw: Op = .{ .kind = .writev, .fd = fd, .buf = &pv, .len = 1, .offset = 6 };
    try testing.expectEqual(@as(i64, 2), try run(be, &pw));
    var all: [11]u8 = undefined;
    var rd: Op = .{ .kind = .read, .fd = fd, .offset = 0, .buf = &all, .len = all.len };
    try testing.expectEqual(@as(i64, 11), try run(be, &rd));
    try testing.expectEqualStrings("hello WOrld", &all);

    var fa: Op = .{ .kind = .fallocate, .fd = fd, .offset = 0, .len = 8192 };
    try testing.expectEqual(@as(i64, 0), try run(be, &fa));
    var st: op_mod.Stat = undefined;
    var f: Op = .{ .kind = .fstat, .fd = fd, .buf = &st };
    try testing.expectEqual(@as(i64, 0), try run(be, &f));
    try testing.expectEqual(@as(u64, 8192), st.size);
    // KEEP_SIZE beyond the end leaves the size alone.
    var fk: Op = .{ .kind = .fallocate, .fd = fd, .offset = 0, .len = 65536, .aux = op_mod.FallocFlags.KEEP_SIZE };
    try testing.expectEqual(@as(i64, 0), try run(be, &fk));
    try testing.expectEqual(@as(i64, 0), try run(be, &f));
    try testing.expectEqual(@as(u64, 8192), st.size);
}

test "stat nofollow, link, rename via fd2" {
    const be = try newBackend(2);
    var sink: backend.Drained = .{};
    defer be.vtable.destroy(be.ctx, &sink);
    const base = scratch ++ "/threaded_dirs";
    _ = c.rmdir(base ++ "/b");
    _ = c.rmdir(base ++ "/a");
    _ = c.unlink(base ++ "/a/file");
    _ = c.unlink(base ++ "/a/file2");
    _ = c.unlink(base ++ "/a/sym");
    _ = c.unlink(base ++ "/b/moved");
    _ = c.rmdir(base);
    var m: Op = .{ .kind = .mkdir, .path = base, .aux = 0o755 };
    try testing.expectEqual(@as(i64, 0), try run(be, &m));
    var ma: Op = .{ .kind = .mkdir, .path = base ++ "/a", .aux = 0o755 };
    try testing.expectEqual(@as(i64, 0), try run(be, &ma));
    var mb: Op = .{ .kind = .mkdir, .path = base ++ "/b", .aux = 0o755 };
    try testing.expectEqual(@as(i64, 0), try run(be, &mb));
    defer {
        _ = c.unlink(base ++ "/a/file");
        _ = c.unlink(base ++ "/a/file2");
        _ = c.unlink(base ++ "/a/sym");
        _ = c.unlink(base ++ "/b/moved");
        _ = c.rmdir(base ++ "/a");
        _ = c.rmdir(base ++ "/b");
        _ = c.rmdir(base);
    }
    const fd = try openRw(be, base ++ "/a/file");
    _ = c.close(@intCast(fd));
    try testing.expectEqual(@as(c_int, 0), c.symlink("file", base ++ "/a/sym"));

    var st: op_mod.Stat = undefined;
    var s1: Op = .{ .kind = .stat, .path = base ++ "/a/sym", .buf = &st };
    try testing.expectEqual(@as(i64, 0), try run(be, &s1));
    try testing.expectEqual(@as(u32, 1), st.kind);
    var s2: Op = .{ .kind = .stat, .path = base ++ "/a/sym", .buf = &st, .flags = 1 };
    try testing.expectEqual(@as(i64, 0), try run(be, &s2));
    try testing.expectEqual(@as(u32, 3), st.kind);

    var lk: Op = .{ .kind = .link, .path = base ++ "/a/file", .path2 = base ++ "/a/file2" };
    try testing.expectEqual(@as(i64, 0), try run(be, &lk));
    var s3: Op = .{ .kind = .stat, .path = base ++ "/a/file2", .buf = &st };
    try testing.expectEqual(@as(i64, 0), try run(be, &s3));
    try testing.expectEqual(@as(u32, 1), st.kind);

    // rename a/file2 -> b/moved using directory fds on both sides.
    var oa: Op = .{ .kind = .open, .path = base ++ "/a", .aux = op_mod.O.DIRECTORY };
    const da = try run(be, &oa);
    var ob: Op = .{ .kind = .open, .path = base ++ "/b", .aux = op_mod.O.DIRECTORY };
    const db = try run(be, &ob);
    try testing.expect(da >= 0 and db >= 0);
    var rn: Op = .{ .kind = .rename, .fd = da, .path = "file2", .fd2 = db, .path2 = "moved" };
    try testing.expectEqual(@as(i64, 0), try run(be, &rn));
    var s4: Op = .{ .kind = .stat, .path = base ++ "/b/moved", .buf = &st };
    try testing.expectEqual(@as(i64, 0), try run(be, &s4));
    var s5: Op = .{ .kind = .stat, .path = base ++ "/a/file2", .buf = &st };
    try testing.expectEqual(-@as(i64, @backingInt(c.E.NOENT)), try run(be, &s5));
    _ = c.close(@intCast(da));
    _ = c.close(@intCast(db));
}

test "socketpair send/recv and sendmsg/recvmsg" {
    const be = try newBackend(2);
    var sink: backend.Drained = .{};
    defer be.vtable.destroy(be.ctx, &sink);
    var sv: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), tx.socketpair(1, 1, 0, &sv)); // AF_UNIX, SOCK_STREAM
    defer _ = c.close(sv[0]);
    defer _ = c.close(sv[1]);

    var msg = "ping".*;
    var s: Op = .{ .kind = .send, .fd = sv[0], .buf = &msg, .len = 4 };
    try testing.expectEqual(@as(i64, 4), try run(be, &s));
    var buf: [8]u8 = undefined;
    var r: Op = .{ .kind = .recv, .fd = sv[1], .buf = &buf, .len = buf.len };
    try testing.expectEqual(@as(i64, 4), try run(be, &r));
    try testing.expectEqualStrings("ping", buf[0..4]);

    // Native msghdr with a single iovec (Linux and Darwin layouts differ, so build per OS).
    var out = "pong!".*;
    var iov: [1]op_mod.Iovec = .{.{ .base = &out, .len = out.len }};
    var mh = std.mem.zeroes(c.msghdr);
    mh.iov = @ptrCast(&iov);
    mh.iovlen = 1;
    var sm: Op = .{ .kind = .sendmsg, .fd = sv[0], .buf = &mh, .len = 0 };
    try testing.expectEqual(@as(i64, 5), try run(be, &sm));

    var inb: [8]u8 = undefined;
    var iov2: [1]op_mod.Iovec = .{.{ .base = &inb, .len = inb.len }};
    var mh2 = std.mem.zeroes(c.msghdr);
    mh2.iov = @ptrCast(&iov2);
    mh2.iovlen = 1;
    var rm: Op = .{ .kind = .recvmsg, .fd = sv[1], .buf = &mh2 };
    try testing.expectEqual(@as(i64, 5), try run(be, &rm));
    try testing.expectEqualStrings("pong!", inb[0..5]);
}

test "loopback connect + accept + send/recv" {
    const be = try newBackend(2);
    var sink: backend.Drained = .{};
    defer be.vtable.destroy(be.ctx, &sink);
    const AF_INET = 2;
    const lfd = tx.socket(AF_INET, 1, 0);
    try testing.expect(lfd >= 0);
    defer _ = c.close(lfd);
    var addr: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
    addr.family = AF_INET;
    addr.addr = std.mem.nativeToBig(u32, 0x7f000001);
    try testing.expectEqual(@as(c_int, 0), tx.bind(lfd, &addr, @sizeOf(c.sockaddr.in)));
    try testing.expectEqual(@as(c_int, 0), tx.listen(lfd, 4));
    var alen: u32 = @sizeOf(c.sockaddr.in);
    try testing.expectEqual(@as(c_int, 0), tx.getsockname(lfd, &addr, &alen));

    const cfd = tx.socket(AF_INET, 1, 0);
    defer _ = c.close(cfd);
    // accept blocks a worker; submit it first, then connect on another.
    var peer: c.sockaddr.in = undefined;
    var acc: Op = .{ .kind = .accept, .fd = lfd, .buf = &peer, .len = @sizeOf(c.sockaddr.in) };
    var con: Op = .{ .kind = .connect, .fd = cfd, .buf = &addr, .len = @sizeOf(c.sockaddr.in) };
    var got: [2]*Op = undefined;
    try be.vtable.submit(be.ctx, &acc);
    try be.vtable.submit(be.ctx, &con);
    _ = collect(be, 2, &got);
    try testing.expectEqual(@as(i64, 0), con.result);
    try testing.expect(acc.result >= 0);
    try testing.expectEqual(@as(u64, @sizeOf(c.sockaddr.in)), acc.aux);
    const afd: c_int = @intCast(acc.result);
    defer _ = c.close(afd);

    var msg = "hi".*;
    var s: Op = .{ .kind = .send, .fd = cfd, .buf = &msg, .len = 2 };
    try testing.expectEqual(@as(i64, 2), try run(be, &s));
    var b: [4]u8 = undefined;
    var r: Op = .{ .kind = .recv, .fd = afd, .buf = &b, .len = 4 };
    try testing.expectEqual(@as(i64, 2), try run(be, &r));
    try testing.expectEqualStrings("hi", b[0..2]);
}

fn futexSupported(be: backend.Backend) !bool {
    var v: u32 = 0;
    var w: Op = .{ .kind = .futex_wake, .buf = &v, .aux = 1 };
    return (try run(be, &w)) != -@as(i64, @backingInt(c.E.NOSYS));
}

test "futex wait/wake/-EAGAIN/-ETIMEDOUT" {
    const be = try newBackend(2);
    var sink: backend.Drained = .{};
    defer be.vtable.destroy(be.ctx, &sink);
    if (!try futexSupported(be)) return error.SkipZigTest;
    var v: u32 = 0;
    var mismatch: Op = .{ .kind = .futex_wait, .buf = &v, .aux = 1 };
    try testing.expectEqual(-@as(i64, @backingInt(c.E.AGAIN)), try run(be, &mismatch));
    var to: Op = .{ .kind = .futex_wait, .buf = &v, .aux = 0, .offset = 20 * std.time.ns_per_ms };
    try testing.expectEqual(-@as(i64, @backingInt(c.E.TIMEDOUT)), try run(be, &to));

    var waiter: Op = .{ .kind = .futex_wait, .buf = &v, .aux = 0 };
    try be.vtable.submit(be.ctx, &waiter);
    sleepMs(50);
    var wk: Op = .{ .kind = .futex_wake, .buf = &v, .aux = 1 };
    var got: [2]*Op = undefined;
    try be.vtable.submit(be.ctx, &wk);
    _ = collect(be, 2, &got);
    try testing.expectEqual(@as(i64, 0), waiter.result);
    try testing.expectEqual(@as(i64, 1), wk.result);
}

test "pool grows so N blocked futex waiters cannot starve the wake" {
    const be = try newBackend(2);
    var sink: backend.Drained = .{};
    defer be.vtable.destroy(be.ctx, &sink);
    if (!try futexSupported(be)) return error.SkipZigTest;
    var v: u32 = 0;
    var waiters: [6]Op = undefined;
    for (&waiters) |*w| {
        w.* = .{ .kind = .futex_wait, .buf = &v, .aux = 0 };
        try be.vtable.submit(be.ctx, w);
    }
    sleepMs(100);
    try testing.expect(ctxOf(be.ctx).threads.items.len > 2);
    var wk: Op = .{ .kind = .futex_wake, .buf = &v, .aux = 100 };
    try be.vtable.submit(be.ctx, &wk);
    var got: [7]*Op = undefined;
    _ = collect(be, 7, &got);
    for (&waiters) |*w| try testing.expectEqual(@as(i64, 0), w.result);
    // Darwin only reports "some waiter woken" (1); Linux reports the exact count.
    try testing.expectEqual(@as(i64, if (builtin.os.tag == .linux) 6 else 1), wk.result);
}

test "sendfile file->file and file->socket" {
    const be = try newBackend(2);
    var sink: backend.Drained = .{};
    defer be.vtable.destroy(be.ctx, &sink);
    const p1 = scratch ++ "/threaded_sf_in.tmp";
    const p2 = scratch ++ "/threaded_sf_out.tmp";
    defer _ = c.unlink(p1);
    defer _ = c.unlink(p2);
    const in = try openRw(be, p1);
    const out = try openRw(be, p2);
    defer _ = c.close(@intCast(in));
    defer _ = c.close(@intCast(out));
    var data = "0123456789abcdef".*;
    var w: Op = .{ .kind = .write, .fd = in, .offset = 0, .buf = &data, .len = data.len };
    try testing.expectEqual(@as(i64, 16), try run(be, &w));

    var sf: Op = .{ .kind = .sendfile, .fd = out, .fd2 = in, .offset = 4, .len = 8 };
    try testing.expectEqual(@as(i64, 8), try run(be, &sf));
    var back: [8]u8 = undefined;
    var rd: Op = .{ .kind = .read, .fd = out, .offset = 0, .buf = &back, .len = 8 };
    try testing.expectEqual(@as(i64, 8), try run(be, &rd));
    try testing.expectEqualStrings("456789ab", &back);

    var sv: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), tx.socketpair(1, 1, 0, &sv));
    defer _ = c.close(sv[0]);
    defer _ = c.close(sv[1]);
    var sf2: Op = .{ .kind = .sendfile, .fd = sv[0], .fd2 = in, .offset = 0, .len = 16 };
    try testing.expectEqual(@as(i64, 16), try run(be, &sf2));
    var rb: [16]u8 = undefined;
    var rc: Op = .{ .kind = .recv, .fd = sv[1], .buf = &rb, .len = 16 };
    try testing.expectEqual(@as(i64, 16), try run(be, &rc));
    try testing.expectEqualStrings("0123456789abcdef", &rb);
}

// ---- tests: ftruncate, readdir, pollable ------------------------------------------------------

test "ftruncate shrink and grow" {
    const be = try newBackend(2);
    var sink: backend.Drained = .{};
    defer be.vtable.destroy(be.ctx, &sink);
    const path = scratch ++ "/threaded_trunc.tmp";
    const fd = try openRw(be, path);
    defer _ = c.unlink(path);
    defer _ = c.close(@intCast(fd));
    var data = "0123456789".*;
    var w: Op = .{ .kind = .write, .fd = fd, .offset = 0, .buf = &data, .len = data.len };
    try testing.expectEqual(@as(i64, 10), try run(be, &w));
    var st: op_mod.Stat = undefined;
    var f: Op = .{ .kind = .fstat, .fd = fd, .buf = &st };

    var t1: Op = .{ .kind = .ftruncate, .fd = fd, .offset = 4 };
    try testing.expectEqual(@as(i64, 0), try run(be, &t1));
    try testing.expectEqual(@as(i64, 0), try run(be, &f));
    try testing.expectEqual(@as(u64, 4), st.size);

    var t2: Op = .{ .kind = .ftruncate, .fd = fd, .offset = 9000 };
    try testing.expectEqual(@as(i64, 0), try run(be, &t2));
    try testing.expectEqual(@as(i64, 0), try run(be, &f));
    try testing.expectEqual(@as(u64, 9000), st.size);

    var t3: Op = .{ .kind = .ftruncate, .fd = fd, .offset = -5 };
    try testing.expectEqual(-@as(i64, @backingInt(c.E.INVAL)), try run(be, &t3));
}

const Entry = struct { kind: u8, name: []const u8 };

/// Appends the entries packed in `buf` to `list` (names are copied).
fn unpack(buf: []const u8, list: *std.ArrayList(Entry)) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const kind = buf[off];
        const nl = std.mem.readInt(u16, buf[off + 1 ..][0..2], .little);
        const name = try testing.allocator.dupe(u8, buf[off + 3 ..][0..nl]);
        try list.append(testing.allocator, .{ .kind = kind, .name = name });
        off += 3 + nl;
    }
    try testing.expectEqual(buf.len, off);
}

fn freeEntries(list: *std.ArrayList(Entry)) void {
    for (list.items) |e| testing.allocator.free(e.name);
    list.deinit(testing.allocator);
}

fn entryLess(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn openDir(be: backend.Backend, path: [*:0]const u8) !op_mod.Fd {
    var o: Op = .{ .kind = .open, .path = path, .aux = op_mod.O.DIRECTORY };
    const r = try run(be, &o);
    try testing.expect(r >= 0);
    return @intCast(r);
}

/// Reads a whole directory through readdir ops using `bufsize`-byte buffers.
fn readAll(be: backend.Backend, dfd: op_mod.Fd, bufsize: usize, list: *std.ArrayList(Entry)) !void {
    const buf = try testing.allocator.alloc(u8, bufsize);
    defer testing.allocator.free(buf);
    var cookie: i64 = 0;
    while (true) {
        var rd: Op = .{ .kind = .readdir, .fd = dfd, .buf = buf.ptr, .len = buf.len, .offset = cookie };
        const r = try run(be, &rd);
        try testing.expect(r >= 0);
        if (r == 0) break;
        try unpack(buf[0..@intCast(r)], list);
        cookie = @bitCast(rd.aux);
    }
}

fn cleanDir(path: [:0]const u8, count: usize) void {
    var b: [128]u8 = undefined;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const p = std.fmt.bufPrintSentinel(&b, "{s}/f{d:0>4}", .{ path, i }, 0) catch return;
        _ = c.unlink(p);
    }
    for ([_][]const u8{ "file_a", "file_b", "file_c", "link_x", "dir_1", "dir_2" }) |n| {
        const p = std.fmt.bufPrintSentinel(&b, "{s}/{s}", .{ path, n }, 0) catch return;
        _ = c.unlink(p);
        _ = c.rmdir(p);
    }
    _ = c.rmdir(path);
}

test "readdir: kinds, no dots, cookie continuation, -ERANGE" {
    if (!readdir_supported) return error.SkipZigTest;
    const be = try newBackend(2);
    var sink: backend.Drained = .{};
    defer be.vtable.destroy(be.ctx, &sink);
    const dir = scratch ++ "/threaded_readdir";
    cleanDir(dir, 0);
    try testing.expectEqual(@as(c_int, 0), c.mkdir(dir, 0o755));
    defer cleanDir(dir, 0);
    inline for (.{ "file_a", "file_b", "file_c" }) |n| {
        const fd = try openRw(be, dir ++ "/" ++ n);
        _ = c.close(@intCast(fd));
    }
    try testing.expectEqual(@as(c_int, 0), c.mkdir(dir ++ "/dir_1", 0o755));
    try testing.expectEqual(@as(c_int, 0), c.mkdir(dir ++ "/dir_2", 0o755));
    try testing.expectEqual(@as(c_int, 0), c.symlink("file_a", dir ++ "/link_x"));

    const dfd = try openDir(be, dir);
    defer _ = c.close(@intCast(dfd));
    const expected = [_]Entry{
        .{ .kind = 2, .name = "dir_1" },  .{ .kind = 2, .name = "dir_2" },
        .{ .kind = 1, .name = "file_a" }, .{ .kind = 1, .name = "file_b" },
        .{ .kind = 1, .name = "file_c" }, .{ .kind = 3, .name = "link_x" },
    };
    for ([_]usize{ 4096, 64 }) |bs| {
        var list: std.ArrayList(Entry) = .empty;
        defer freeEntries(&list);
        try readAll(be, dfd, bs, &list);
        std.mem.sort(Entry, list.items, {}, entryLess);
        try testing.expectEqual(expected.len, list.items.len);
        for (expected, list.items) |e, g| {
            try testing.expectEqualStrings(e.name, g.name);
            try testing.expectEqual(e.kind, g.kind);
        }
    }

    // First entry cannot fit (1 byte buffer).
    var tiny: [1]u8 = undefined;
    var rd: Op = .{ .kind = .readdir, .fd = dfd, .buf = &tiny, .len = 1, .offset = 0 };
    try testing.expectEqual(-@as(i64, @backingInt(c.E.RANGE)), try run(be, &rd));
}

test "readdir: 2000 entries through a 4096-byte buffer" {
    if (!readdir_supported) return error.SkipZigTest;
    const be = try newBackend(2);
    var sink: backend.Drained = .{};
    defer be.vtable.destroy(be.ctx, &sink);
    const dir = scratch ++ "/threaded_readdir_big";
    cleanDir(dir, 2000);
    try testing.expectEqual(@as(c_int, 0), c.mkdir(dir, 0o755));
    defer cleanDir(dir, 2000);
    var nb: [128]u8 = undefined;
    for (0..2000) |i| {
        const p = try std.fmt.bufPrintSentinel(&nb, dir ++ "/f{d:0>4}", .{i}, 0);
        const fd = c.open(p, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c.mode_t, 0o644));
        try testing.expect(fd >= 0);
        _ = c.close(fd);
    }
    const dfd = try openDir(be, dir);
    defer _ = c.close(@intCast(dfd));
    var list: std.ArrayList(Entry) = .empty;
    defer freeEntries(&list);
    try readAll(be, dfd, 4096, &list);
    try testing.expectEqual(@as(usize, 2000), list.items.len);
    std.mem.sort(Entry, list.items, {}, entryLess);
    for (list.items, 0..) |e, i| {
        const want = try std.fmt.bufPrint(&nb, "f{d:0>4}", .{i});
        try testing.expectEqualStrings(want, e.name);
        try testing.expectEqual(@as(u8, 1), e.kind);
    }
}

fn fdReadable(fd: isize, timeout_ms: c_int) !bool {
    var pfd = [_]c.pollfd{.{ .fd = @intCast(fd), .events = c.POLL.IN, .revents = 0 }};
    const n = c.poll(&pfd, 1, timeout_ms);
    try testing.expect(n >= 0);
    return n > 0;
}

test "pollable fd: worker completion, poll drains, wake and post" {
    const be = try newBackend(2);
    var sink: backend.Drained = .{};
    defer be.vtable.destroy(be.ctx, &sink);
    const pfd = be.vtable.pollable(be.ctx);
    try testing.expect(pfd >= 0);
    try testing.expect(be.vtable.caps.pollable);
    try testing.expect(!try fdReadable(pfd, 0));

    // A worker op that completes after a delay (read from a pipe written by another thread).
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    var b: [1]u8 = undefined;
    var rd: Op = .{ .kind = .read, .fd = fds[0], .buf = &b, .len = 1 };
    try be.vtable.submit(be.ctx, &rd);
    try testing.expect(!try fdReadable(pfd, 40)); // blocks, nothing completes
    const t = try std.Thread.spawn(.{}, struct {
        fn f(fd: c_int) void {
            sleepMs(30);
            _ = c.write(fd, "x", 1);
        }
    }.f, .{fds[1]});
    try testing.expect(try fdReadable(pfd, 5000));
    t.join();
    // Level triggered: stays readable until poll() drains it.
    try testing.expect(try fdReadable(pfd, 0));
    var d: backend.Drained = .{};
    be.vtable.poll(be.ctx, false, &d);
    try testing.expect(d.done.pop() == &rd);
    try testing.expect(!try fdReadable(pfd, 0));

    // wake()
    be.vtable.wake(be.ctx);
    be.vtable.wake(be.ctx); // coalesced
    try testing.expect(try fdReadable(pfd, 0));
    var d2: backend.Drained = .{};
    be.vtable.poll(be.ctx, false, &d2);
    try testing.expect(!try fdReadable(pfd, 0));

    // post()
    var w: Waker = .{ .be = be, .use_post = true };
    try be.vtable.post(be.ctx, Waker.onPost, &w);
    try testing.expect(try fdReadable(pfd, 0));
    var d3: backend.Drained = .{};
    be.vtable.poll(be.ctx, false, &d3);
    try testing.expect(!try fdReadable(pfd, 0));
    const node = d3.posts_head orelse return error.TestUnexpectedResult;
    node.func(node.ud);
    try testing.expect(w.hit);
    std.heap.c_allocator.destroy(node);

    // A nop completes inline: readable again, and not after draining.
    var nop: Op = .{ .kind = .nop };
    try be.vtable.submit(be.ctx, &nop);
    try testing.expect(try fdReadable(pfd, 0));
    var d4: backend.Drained = .{};
    be.vtable.poll(be.ctx, true, &d4);
    try testing.expect(d4.done.pop() == &nop);
    try testing.expect(!try fdReadable(pfd, 0));
}
