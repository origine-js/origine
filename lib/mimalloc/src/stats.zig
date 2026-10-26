//! Statistics: mimalloc counts allocations per thread and merges them into the process totals.
const std = @import("std");
const c = @import("c.zig");

/// Prints the process statistics to stderr.
pub fn print() void {
    c.mi_stats_print_out(null, null);
}

/// Prints the options and their values to stderr.
pub fn printOptions() void {
    c.mi_options_print_out(null, null);
}

/// Zeroes the counters.
pub fn reset() void {
    c.mi_stats_reset();
}

/// Folds this thread's counters into the process totals (mimalloc does so on thread exit).
pub fn merge() void {
    c.mi_stats_merge();
}

/// The process statistics as JSON, owned by the caller (`gpa.free`).
pub fn json(gpa: std.mem.Allocator) error{OutOfMemory}![]u8 {
    const text = c.mi_stats_get_json(0, null) orelse return error.OutOfMemory;
    defer c.mi_free(text);
    return gpa.dupe(u8, std.mem.span(text));
}

test "json statistics are an object" {
    const text = try json(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(text.len > 2 and text[0] == '{');
}
