//! UDP over loopback through the loop's `sendmsg` / `recvmsg`, on every backend and with both
//! blocking and non-blocking descriptors. DNS and QUIC (docs/http-design.md) need datagram
//! semantics from these two ops: boundaries, the sender's address, truncation, empty datagrams,
//! cancellation. The stream tests elsewhere do not show any of that.
const std = @import("std");
const builtin = @import("builtin");
const io = @import("io.zig");
const c = std.c;

const backends = [_]io.backend.Kind{ .auto, .threaded };

const sys = struct {
    extern "c" fn socket(domain: c_int, kind: c_int, protocol: c_int) c_int;
    extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: u32) c_int;
    extern "c" fn getsockname(fd: c_int, addr: *anyopaque, len: *u32) c_int;
    extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    extern "c" fn close(fd: c_int) c_int;
};

const AF_INET = 2;
const AF_INET6: c_int = if (builtin.os.tag == .linux) 10 else 30;
const SOCK_DGRAM = 2;
const F_GETFL = 3;
const F_SETFL = 4;
const O_NONBLOCK: c_int = if (builtin.os.tag == .linux) 0x800 else 0x4;
const MSG_TRUNC: u32 = if (builtin.os.tag == .linux) 0x20 else 0x10;

const Probe = struct {
    op: io.Op = .{},
    result: i64 = std.math.minInt(i64),
};

fn onDone(op: *io.Op, result: i64) callconv(.c) void {
    const probe: *Probe = @fieldParentPtr("op", op);
    probe.result = result;
}

const Socket = struct {
    fd: c_int,
    /// Host order.
    port: u16,
    v6: bool,

    fn open(v6: bool, nonblock: bool) !Socket {
        const fd = sys.socket(if (v6) AF_INET6 else AF_INET, SOCK_DGRAM, 0);
        if (fd < 0) return error.SocketUnavailable;
        errdefer _ = sys.close(fd);
        if (nonblock) {
            const flags = sys.fcntl(fd, F_GETFL);
            try std.testing.expect(sys.fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0);
        }
        var port: u16 = undefined;
        if (v6) {
            var a = std.mem.zeroes(c.sockaddr.in6);
            a.family = AF_INET6;
            a.addr[15] = 1;
            if (sys.bind(fd, &a, @sizeOf(c.sockaddr.in6)) != 0) return error.SocketUnavailable;
            var len: u32 = @sizeOf(c.sockaddr.in6);
            try std.testing.expectEqual(@as(c_int, 0), sys.getsockname(fd, &a, &len));
            port = std.mem.bigToNative(u16, a.port);
        } else {
            var a = std.mem.zeroes(c.sockaddr.in);
            a.family = AF_INET;
            a.addr = std.mem.nativeToBig(u32, 0x7f000001);
            try std.testing.expectEqual(@as(c_int, 0), sys.bind(fd, &a, @sizeOf(c.sockaddr.in)));
            var len: u32 = @sizeOf(c.sockaddr.in);
            try std.testing.expectEqual(@as(c_int, 0), sys.getsockname(fd, &a, &len));
            port = std.mem.bigToNative(u16, a.port);
        }
        return .{ .fd = fd, .port = port, .v6 = v6 };
    }

    fn close(s: Socket) void {
        _ = sys.close(s.fd);
    }
};

/// A msghdr, its single iovec and its address storage, built in place (the header points into the struct).
const Msg = struct {
    hdr: c.msghdr,
    iov: [1]io.op.Iovec,
    addr: c.sockaddr.storage,

    fn forSend(m: *Msg, to: Socket, data: []const u8) void {
        m.* = std.mem.zeroes(Msg);
        m.iov[0] = .{ .base = @constCast(data.ptr), .len = data.len };
        m.hdr.iov = @ptrCast(&m.iov);
        m.hdr.iovlen = 1;
        m.hdr.name = @ptrCast(&m.addr);
        if (to.v6) {
            const a: *c.sockaddr.in6 = @ptrCast(&m.addr);
            a.family = AF_INET6;
            a.addr[15] = 1;
            a.port = std.mem.nativeToBig(u16, to.port);
            m.hdr.namelen = @sizeOf(c.sockaddr.in6);
        } else {
            const a: *c.sockaddr.in = @ptrCast(&m.addr);
            a.family = AF_INET;
            a.addr = std.mem.nativeToBig(u32, 0x7f000001);
            a.port = std.mem.nativeToBig(u16, to.port);
            m.hdr.namelen = @sizeOf(c.sockaddr.in);
        }
    }

    fn forRecv(m: *Msg, buf: []u8) void {
        m.* = std.mem.zeroes(Msg);
        m.iov[0] = .{ .base = buf.ptr, .len = buf.len };
        m.hdr.iov = @ptrCast(&m.iov);
        m.hdr.iovlen = 1;
        m.hdr.name = @ptrCast(&m.addr);
        m.hdr.namelen = @sizeOf(c.sockaddr.storage);
    }

    fn truncated(m: *const Msg) bool {
        return @as(u32, @intCast(m.hdr.flags)) & MSG_TRUNC != 0;
    }

    /// The sender's port (host order) after a receive.
    fn from(m: *const Msg) u16 {
        const a: *const c.sockaddr.in = @ptrCast(&m.addr);
        const b: *const c.sockaddr.in6 = @ptrCast(&m.addr);
        const big = if (m.hdr.namelen >= @sizeOf(c.sockaddr.in6)) b.port else a.port;
        return std.mem.bigToNative(u16, big);
    }
};

fn sendTo(loop: *io.Loop, probe: *Probe, msg: *Msg, from: Socket) !void {
    probe.* = .{};
    try loop.sendmsg(&probe.op, from.fd, msg, 0, onDone, null);
}

fn recvOn(loop: *io.Loop, probe: *Probe, msg: *Msg, on: Socket) !void {
    probe.* = .{};
    try loop.recvmsg(&probe.op, on.fd, msg, 0, onDone, null);
}

test "datagrams keep their boundaries and report the sender" {
    for (backends) |kind| for ([_]bool{ true, false }) |nonblock| {
        const loop = try io.Loop.create(std.testing.allocator, .{ .backend = @backingInt(kind) });
        defer loop.destroy();
        const rx = try Socket.open(false, nonblock);
        defer rx.close();
        const tx = try Socket.open(false, nonblock);
        defer tx.close();

        // Send first: with a blocking descriptor a receive posted first would hold a worker.
        var out1: Msg = undefined;
        var out2: Msg = undefined;
        var s1: Probe = .{};
        var s2: Probe = .{};
        out1.forSend(rx, "five5");
        out2.forSend(rx, "x");
        // One at a time: ops in flight on one fd are not ordered on the worker-thread paths (see the
        // "concurrent sends" test below).
        try sendTo(loop, &s1, &out1, tx);
        _ = loop.run(.until_idle);
        try sendTo(loop, &s2, &out2, tx);
        _ = loop.run(.until_idle);
        try std.testing.expectEqual(@as(i64, 5), s1.result);
        try std.testing.expectEqual(@as(i64, 1), s2.result);

        var buf1: [64]u8 = undefined;
        var buf2: [64]u8 = undefined;
        var in1: Msg = undefined;
        var in2: Msg = undefined;
        var r1: Probe = .{};
        var r2: Probe = .{};
        in1.forRecv(&buf1);
        in2.forRecv(&buf2);
        try recvOn(loop, &r1, &in1, rx);
        _ = loop.run(.until_idle);
        try recvOn(loop, &r2, &in2, rx);
        _ = loop.run(.until_idle);
        // One recvmsg is one datagram, however large the buffer.
        try std.testing.expectEqual(@as(i64, 5), r1.result);
        try std.testing.expectEqualStrings("five5", buf1[0..5]);
        try std.testing.expectEqual(@as(i64, 1), r2.result);
        try std.testing.expectEqual(@as(u8, 'x'), buf2[0]);
        try std.testing.expectEqual(tx.port, in1.from());
        try std.testing.expectEqual(tx.port, in2.from());
        try std.testing.expect(!in1.truncated());
    };
}

test "a receive posted before the datagram arrives completes when it does" {
    for (backends) |kind| {
        // Non-blocking only: a blocking descriptor would hold a worker for the whole wait.
        const loop = try io.Loop.create(std.testing.allocator, .{ .backend = @backingInt(kind) });
        defer loop.destroy();
        const rx = try Socket.open(false, true);
        defer rx.close();
        const tx = try Socket.open(false, true);
        defer tx.close();

        var buf: [32]u8 = undefined;
        var in: Msg = undefined;
        var r: Probe = .{};
        in.forRecv(&buf);
        try recvOn(loop, &r, &in, rx);
        // Nothing yet: the receive parks without a result.
        _ = loop.run(.nowait);
        try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), r.result);

        var out: Msg = undefined;
        var s: Probe = .{};
        out.forSend(rx, "late");
        try sendTo(loop, &s, &out, tx);
        _ = loop.run(.until_idle);
        try std.testing.expectEqual(@as(i64, 4), r.result);
        try std.testing.expectEqualStrings("late", buf[0..4]);
    }
}

test "an empty datagram completes with 0, which is not an end of stream" {
    for (backends) |kind| {
        const loop = try io.Loop.create(std.testing.allocator, .{ .backend = @backingInt(kind) });
        defer loop.destroy();
        const rx = try Socket.open(false, true);
        defer rx.close();
        const tx = try Socket.open(false, true);
        defer tx.close();

        var out: Msg = undefined;
        var s: Probe = .{};
        out.forSend(rx, "");
        try sendTo(loop, &s, &out, tx);
        _ = loop.run(.until_idle);
        try std.testing.expectEqual(@as(i64, 0), s.result);

        var buf: [8]u8 = undefined;
        var in: Msg = undefined;
        var r: Probe = .{};
        in.forRecv(&buf);
        try recvOn(loop, &r, &in, rx);
        _ = loop.run(.until_idle);
        // The callers (DNS, QUIC) must not treat this 0 like the 0 of a stream's shutdown.
        try std.testing.expectEqual(@as(i64, 0), r.result);
        try std.testing.expectEqual(tx.port, in.from());
    }
}

test "a datagram larger than the buffer is cut and flagged" {
    for (backends) |kind| {
        const loop = try io.Loop.create(std.testing.allocator, .{ .backend = @backingInt(kind) });
        defer loop.destroy();
        const rx = try Socket.open(false, true);
        defer rx.close();
        const tx = try Socket.open(false, true);
        defer tx.close();

        var big: [100]u8 = undefined;
        for (&big, 0..) |*b, i| b.* = @intCast(i);
        var out: Msg = undefined;
        var s: Probe = .{};
        out.forSend(rx, &big);
        try sendTo(loop, &s, &out, tx);
        _ = loop.run(.until_idle);
        try std.testing.expectEqual(@as(i64, 100), s.result);

        var buf: [10]u8 = undefined;
        var in: Msg = undefined;
        var r: Probe = .{};
        in.forRecv(&buf);
        try recvOn(loop, &r, &in, rx);
        _ = loop.run(.until_idle);
        try std.testing.expectEqual(@as(i64, 10), r.result);
        try std.testing.expectEqualSlices(u8, big[0..10], &buf);
        try std.testing.expect(in.truncated());
    }
}

test "a pending receive can be canceled" {
    for (backends) |kind| {
        const loop = try io.Loop.create(std.testing.allocator, .{ .backend = @backingInt(kind) });
        defer loop.destroy();
        const rx = try Socket.open(false, true);
        defer rx.close();

        var buf: [8]u8 = undefined;
        var in: Msg = undefined;
        var r: Probe = .{};
        in.forRecv(&buf);
        try recvOn(loop, &r, &in, rx);
        _ = loop.run(.nowait);
        try std.testing.expect(loop.cancel(&r.op));
        _ = loop.run(.until_idle);
        try std.testing.expectEqual(-@as(i64, @backingInt(c.E.CANCELED)), r.result);
    }
}

test "a burst arrives in order with every byte" {
    for (backends) |kind| {
        const loop = try io.Loop.create(std.testing.allocator, .{ .backend = @backingInt(kind) });
        defer loop.destroy();
        const rx = try Socket.open(false, true);
        defer rx.close();
        const tx = try Socket.open(false, true);
        defer tx.close();

        const n = 64;
        var payload: [n][32]u8 = undefined;
        var out: [n]Msg = undefined;
        var sends: [n]Probe = undefined;
        for (0..n) |i| {
            @memset(&payload[i], @intCast(i));
            out[i].forSend(rx, &payload[i]);
            try sendTo(loop, &sends[i], &out[i], tx);
            _ = loop.run(.until_idle);
            try std.testing.expectEqual(@as(i64, 32), sends[i].result);
        }
        for (0..n) |i| {
            var buf: [64]u8 = undefined;
            var in: Msg = undefined;
            var r: Probe = .{};
            in.forRecv(&buf);
            try recvOn(loop, &r, &in, rx);
            _ = loop.run(.until_idle);
            try std.testing.expectEqual(@as(i64, 32), r.result);
            try std.testing.expectEqual(@as(u8, @intCast(i)), buf[0]);
            try std.testing.expectEqual(@as(u8, @intCast(i)), buf[31]);
        }
    }
}

test "IPv6 loopback" {
    for (backends) |kind| {
        const rx = Socket.open(true, true) catch return error.SkipZigTest;
        defer rx.close();
        const tx = Socket.open(true, true) catch return error.SkipZigTest;
        defer tx.close();
        const loop = try io.Loop.create(std.testing.allocator, .{ .backend = @backingInt(kind) });
        defer loop.destroy();

        var out: Msg = undefined;
        var s: Probe = .{};
        out.forSend(rx, "six");
        try sendTo(loop, &s, &out, tx);
        _ = loop.run(.until_idle);
        var buf: [8]u8 = undefined;
        var in: Msg = undefined;
        var r: Probe = .{};
        in.forRecv(&buf);
        try recvOn(loop, &r, &in, rx);
        _ = loop.run(.until_idle);
        try std.testing.expectEqual(@as(i64, 3), r.result);
        try std.testing.expectEqualStrings("six", buf[0..3]);
        try std.testing.expectEqual(tx.port, in.from());
    }
}

test "concurrent sends on one socket all arrive, in no promised order" {
    for (backends) |kind| for ([_]bool{ true, false }) |nonblock| {
        const loop = try io.Loop.create(std.testing.allocator, .{ .backend = @backingInt(kind) });
        defer loop.destroy();
        const rx = try Socket.open(false, nonblock);
        defer rx.close();
        const tx = try Socket.open(false, nonblock);
        defer tx.close();

        const n = 16;
        var payload: [n][8]u8 = undefined;
        var out: [n]Msg = undefined;
        var sends: [n]Probe = undefined;
        for (0..n) |i| {
            @memset(&payload[i], @intCast(i));
            out[i].forSend(rx, &payload[i]);
            try sendTo(loop, &sends[i], &out[i], tx);
        }
        _ = loop.run(.until_idle);
        for (sends) |s| try std.testing.expectEqual(@as(i64, 8), s.result);

        var seen: [n]bool = @splat(false);
        var in_order = true;
        for (0..n) |i| {
            var buf: [16]u8 = undefined;
            var in: Msg = undefined;
            var r: Probe = .{};
            in.forRecv(&buf);
            try recvOn(loop, &r, &in, rx);
            _ = loop.run(.until_idle);
            try std.testing.expectEqual(@as(i64, 8), r.result);
            seen[buf[0]] = true;
            if (buf[0] != i) in_order = false;
        }
        for (seen) |s| try std.testing.expect(s);
        // Recorded, not asserted: reordering is the finding docs/http-design.md acts on.
        std.debug.print("udp concurrent sends: backend {s}, {s}: {s}\n", .{ @tagName(kind), if (nonblock) "nonblocking" else "blocking", if (in_order) "in order" else "REORDERED" });
    };
}
