//! Direct vtable tests for the Darwin kqueue backend.
const std = @import("std");
const op_mod = @import("../../op.zig");
const backend = @import("../../backend.zig");
const kqueue = @import("../kqueue.zig");
const Op = op_mod.Op;
const Drained = backend.Drained;
const c = kqueue.c;
const sc = kqueue.sc;
const os_sync = kqueue.os_sync;
const supported = kqueue.supported;
const create = kqueue.create;
const ecanceled = kqueue.ecanceled;
const O_CLOEXEC = kqueue.O_CLOEXEC;
const O_NONBLOCK = kqueue.O_NONBLOCK;
const FD_CLOEXEC = kqueue.FD_CLOEXEC;
const SEEK_SET = kqueue.SEEK_SET;
const SEEK_CUR = kqueue.SEEK_CUR;

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
    const fd = kqueue.openat(c.AT.FDCWD, path, @bitCast(@as(u32, 0x200 | 2 | O_CLOEXEC)), @as(c_uint, 0o644));
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
