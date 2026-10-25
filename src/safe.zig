//! Checks that survive every optimize mode.
//!
//! `std.debug.assert(ok)` is `if (!ok) unreachable`: in ReleaseFast and ReleaseSmall the
//! compiler is told the condition always holds and may delete the check and everything that
//! depends on it, so a violated invariant becomes undefined behavior. The functions here
//! compile to a real branch that panics, in every mode, so a broken invariant stops the
//! process instead. Use them for invariants whose violation would corrupt memory or state
//! (counters that would wrap, casts of external values, indexes from the kernel), and keep
//! `std.debug.assert` for cheap development-only checks.
//!
//! The checks are not free: each is one predictable branch, and the failure path is cold and
//! out of line. None of these functions allocates or retains anything.
const std = @import("std");

/// Panics with `message` in every optimize mode when `ok` is false. Never optimized away on the
/// assumption that `ok` holds. Out of line and cold, so the passing path is one branch.
pub inline fn ensure(ok: bool, comptime message: []const u8) void {
    if (!ok) fail(message);
}

/// Panics with `message`. Cold and never inlined; unlike `unreachable` it is never treated as
/// impossible by the optimizer.
pub fn fail(comptime message: []const u8) noreturn {
    @branchHint(.cold);
    @panic(message);
}

/// `@intCast` that panics instead of being undefined behavior when `value` does not fit in `T`,
/// in every optimize mode. Use it for values that come from outside the module.
pub inline fn cast(comptime T: type, value: anytype) T {
    return std.math.cast(T, value) orelse fail("safe.cast: value does not fit the destination type");
}

/// `a + b` that panics instead of wrapping (or being undefined behavior) on overflow.
pub inline fn add(comptime T: type, a: T, b: T) T {
    return std.math.add(T, a, b) catch fail("safe.add: overflow");
}

/// `a - b` that panics instead of wrapping (or being undefined behavior) on underflow.
pub inline fn sub(comptime T: type, a: T, b: T) T {
    return std.math.sub(T, a, b) catch fail("safe.sub: underflow");
}

/// `slice[index]` that panics when out of bounds in every optimize mode.
pub inline fn at(slice: anytype, index: usize) @TypeOf(slice[0]) {
    ensure(index < slice.len, "safe.at: index out of bounds");
    return slice[index];
}

test "checks hold and fail in every mode" {
    ensure(true, "unused");
    try std.testing.expectEqual(@as(u8, 200), cast(u8, @as(u32, 200)));
    try std.testing.expectEqual(@as(u32, 5), add(u32, 2, 3));
    try std.testing.expectEqual(@as(u32, 1), sub(u32, 3, 2));
    try std.testing.expectEqual(@as(u8, 3), at(&[_]u8{ 1, 2, 3 }, 2));
}
