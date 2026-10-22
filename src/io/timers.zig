//! Loop-thread timer heap shared by the backends that do not get timeouts from the kernel
//! per op (kqueue, threaded). Arming and cancelling a timeout is a heap operation with no
//! syscall, and the backend blocks in its wait primitive with the earliest deadline as the
//! timeout, so any number of pending timeouts costs one kernel timer.
//!
//! Same idea as uSockets, which keeps one coarse sweep timer and per-socket tick stamps instead
//! of a kernel timer per socket. A heap keeps nanosecond precision, which `timeout` ops promise.
//!
//! The heap index of a queued op lives in `op.priv[slot]` (index + 1, 0 = not queued), so remove
//! is O(log n). Not thread-safe.
const std = @import("std");
const op_mod = @import("op.zig");
const Op = op_mod.Op;

pub fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Deadline for a timeout of `ns` nanoseconds from `now`, saturating.
pub fn deadlineAfter(now: u64, ns: u64) u64 {
    return std.math.add(u64, now, ns) catch std.math.maxInt(u64);
}

const Entry = struct { deadline: u64, op: *Op };

pub const Timers = struct {
    items: std.ArrayList(Entry) = .empty,
    /// Which `op.priv` slot holds the heap index of a queued op.
    slot: usize,

    pub fn init(slot: usize) Timers {
        return .{ .slot = slot };
    }

    pub fn deinit(t: *Timers, allocator: std.mem.Allocator) void {
        t.items.deinit(allocator);
    }

    pub fn isEmpty(t: *const Timers) bool {
        return t.items.items.len == 0;
    }

    /// Earliest deadline, if any.
    pub fn peek(t: *const Timers) ?u64 {
        return if (t.items.items.len == 0) null else t.items.items[0].deadline;
    }

    pub fn push(t: *Timers, allocator: std.mem.Allocator, op: *Op, deadline: u64) !void {
        try t.items.append(allocator, .{ .deadline = deadline, .op = op });
        const i = t.items.items.len - 1;
        t.setIndex(i);
        t.siftUp(i);
    }

    /// Removes and returns the earliest op whose deadline is <= `now`.
    pub fn popDue(t: *Timers, now: u64) ?*Op {
        const first = t.peek() orelse return null;
        if (first > now) return null;
        return t.popFirst();
    }

    /// Removes and returns the earliest op regardless of its deadline.
    pub fn popFirst(t: *Timers) ?*Op {
        if (t.items.items.len == 0) return null;
        return t.removeAt(0);
    }

    /// Removes `op` if queued; returns whether it was.
    pub fn remove(t: *Timers, op: *Op) bool {
        const raw = @intFromPtr(op.priv[t.slot]);
        if (raw == 0) return false;
        _ = t.removeAt(raw - 1);
        return true;
    }

    fn removeAt(t: *Timers, i: usize) *Op {
        const items = t.items.items;
        const op = items[i].op;
        const last = items.len - 1;
        items[i] = items[last];
        t.items.items.len = last;
        op.priv[t.slot] = null;
        if (i < last) {
            t.setIndex(i);
            t.siftDown(i);
            t.siftUp(i);
        }
        return op;
    }

    fn setIndex(t: *Timers, i: usize) void {
        t.items.items[i].op.priv[t.slot] = @ptrFromInt(i + 1);
    }

    fn swap(t: *Timers, a: usize, b: usize) void {
        std.mem.swap(Entry, &t.items.items[a], &t.items.items[b]);
        t.setIndex(a);
        t.setIndex(b);
    }

    fn siftUp(t: *Timers, start: usize) void {
        var i = start;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (t.items.items[parent].deadline <= t.items.items[i].deadline) break;
            t.swap(parent, i);
            i = parent;
        }
    }

    fn siftDown(t: *Timers, start: usize) void {
        const items = t.items.items;
        var i = start;
        while (true) {
            const l = 2 * i + 1;
            if (l >= items.len) break;
            const r = l + 1;
            const child = if (r < items.len and items[r].deadline < items[l].deadline) r else l;
            if (items[i].deadline <= items[child].deadline) break;
            t.swap(i, child);
            i = child;
        }
    }
};

const testing = std.testing;

test "pops in deadline order and removes by handle" {
    var t = Timers.init(4);
    defer t.deinit(testing.allocator);
    var ops: [32]Op = undefined;
    for (&ops) |*o| o.* = .{};
    // Deadlines in a scrambled order: (i * 7) % 32 is a permutation of 0..31.
    for (&ops, 0..) |*o, i| try t.push(testing.allocator, o, (i * 7) % 32);
    try testing.expectEqual(@as(?u64, 0), t.peek());

    // Remove three arbitrary entries; they report not-queued afterwards.
    try testing.expect(t.remove(&ops[5]));
    try testing.expect(t.remove(&ops[17]));
    try testing.expect(t.remove(&ops[0]));
    try testing.expect(!t.remove(&ops[5]));

    var prev: u64 = 0;
    var n: usize = 0;
    while (t.popFirst()) |o| {
        const idx = @divExact(@intFromPtr(o) - @intFromPtr(&ops[0]), @sizeOf(Op));
        const dl = (idx * 7) % 32;
        try testing.expect(dl >= prev);
        prev = dl;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 29), n);
    try testing.expect(t.isEmpty());
}

test "popDue only returns expired entries" {
    var t = Timers.init(4);
    defer t.deinit(testing.allocator);
    var a: Op = .{};
    var b: Op = .{};
    try t.push(testing.allocator, &a, 100);
    try t.push(testing.allocator, &b, 200);
    try testing.expectEqual(@as(?*Op, null), t.popDue(99));
    try testing.expectEqual(@as(?*Op, &a), t.popDue(150));
    try testing.expectEqual(@as(?*Op, null), t.popDue(150));
    try testing.expectEqual(@as(?*Op, &b), t.popDue(200));
}
