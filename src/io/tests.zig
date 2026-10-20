//! Loop-level behavior, run against every backend available on the host.
const std = @import("std");
const builtin = @import("builtin");
const io = @import("io.zig");

const backends = [_]io.backend.Kind{ .auto, .threaded };

const Probe = struct {
    op: io.Op = .{},
    result: i64 = std.math.minInt(i64),
    order: ?*Order = null,
    tag: u8 = 0,
};

const Order = struct {
    seen: [8]u8 = undefined,
    len: usize = 0,
};

fn onDone(op: *io.Op, result: i64) callconv(.c) void {
    const probe: *Probe = @fieldParentPtr("op", op);
    probe.result = result;
    if (probe.order) |o| {
        o.seen[o.len] = probe.tag;
        o.len += 1;
    }
}

const scratch = "/tmp";

test "write then read through a loop" {
    for (backends) |kind| {
        const loop = try io.Loop.create(std.testing.allocator, .{ .backend = @intFromEnum(kind) });
        defer loop.destroy();

        var open: Probe = .{};
        try loop.open(&open.op, io.fd_cwd, scratch ++ "/loop-roundtrip.txt", io.O.RDWR | io.O.CREAT | io.O.TRUNC, 0o644, onDone, null);
        _ = loop.run(.until_idle);
        try std.testing.expect(open.result >= 0);
        const fd: io.Fd = @intCast(open.result);

        var write: Probe = .{};
        try loop.write(&write.op, fd, "hello", 0, onDone, null);
        _ = loop.run(.until_idle);
        try std.testing.expectEqual(@as(i64, 5), write.result);

        var buf: [8]u8 = undefined;
        var read: Probe = .{};
        try loop.read(&read.op, fd, &buf, 0, onDone, null);
        _ = loop.run(.until_idle);
        try std.testing.expectEqual(@as(i64, 5), read.result);
        try std.testing.expectEqualStrings("hello", buf[0..5]);

        var st: io.Stat = undefined;
        var stat: Probe = .{};
        try loop.fstat(&stat.op, fd, &st, onDone, null);
        _ = loop.run(.until_idle);
        try std.testing.expectEqual(@as(u64, 5), st.size);

        var close: Probe = .{};
        try loop.close(&close.op, fd, onDone, null);
        _ = loop.run(.until_idle);
        try std.testing.expectEqual(@as(i64, 0), close.result);
    }
}

test "missing file reports -ENOENT" {
    const loop = try io.Loop.create(std.testing.allocator, .{});
    defer loop.destroy();
    var open: Probe = .{};
    try loop.open(&open.op, io.fd_cwd, scratch ++ "/definitely/missing", io.O.RDONLY, 0, onDone, null);
    _ = loop.run(.until_idle);
    try std.testing.expectEqual(-@as(i64, @intFromEnum(std.c.E.NOENT)), open.result);
}

test "short timeout completes before a long one" {
    for (backends) |kind| {
        const loop = try io.Loop.create(std.testing.allocator, .{ .backend = @intFromEnum(kind) });
        defer loop.destroy();
        var order: Order = .{};
        var slow: Probe = .{ .order = &order, .tag = 'S' };
        var fast: Probe = .{ .order = &order, .tag = 'F' };
        try loop.timeout(&slow.op, 80 * std.time.ns_per_ms, onDone, null);
        try loop.timeout(&fast.op, 5 * std.time.ns_per_ms, onDone, null);
        try std.testing.expectEqual(@as(u32, 0), loop.run(.until_idle));
        try std.testing.expectEqualStrings("FS", order.seen[0..order.len]);
    }
}

test "cancel reports -ECANCELED" {
    const loop = try io.Loop.create(std.testing.allocator, .{});
    defer loop.destroy();
    var t: Probe = .{};
    try loop.timeout(&t.op, 10 * std.time.ns_per_s, onDone, null);
    try std.testing.expect(loop.cancel(&t.op));
    _ = loop.run(.until_idle);
    try std.testing.expectEqual(-@as(i64, @intFromEnum(std.c.E.CANCELED)), t.result);
}

test "post from another thread wakes a blocked run" {
    const loop = try io.Loop.create(std.testing.allocator, .{});
    defer loop.destroy();
    const State = struct {
        var hit: bool = false;
        fn fire(_: ?*anyopaque) callconv(.c) void {
            hit = true;
        }
        fn poster(l: *io.Loop) void {
            const ts: std.c.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            l.post(fire, null) catch unreachable;
        }
    };
    State.hit = false;
    const t = try std.Thread.spawn(.{}, State.poster, .{loop});
    _ = loop.run(.once);
    t.join();
    try std.testing.expect(State.hit);
}

test "destroy with ops in flight cancels them" {
    const loop = try io.Loop.create(std.testing.allocator, .{});
    var t: Probe = .{};
    try loop.timeout(&t.op, 10 * std.time.ns_per_s, onDone, null);
    loop.destroy();
    try std.testing.expectEqual(-@as(i64, @intFromEnum(std.c.E.CANCELED)), t.result);
}

test "independent loops do not share state" {
    const a = try io.Loop.create(std.testing.allocator, .{});
    defer a.destroy();
    const b = try io.Loop.create(std.testing.allocator, .{});
    defer b.destroy();
    var t: Probe = .{};
    try a.timeout(&t.op, 5 * std.time.ns_per_ms, onDone, null);
    try std.testing.expectEqual(@as(u32, 0), b.run(.nowait));
    try std.testing.expectEqual(@as(u32, 1), a.active);
    _ = a.run(.until_idle);
    try std.testing.expect(t.result >= 0);
}
