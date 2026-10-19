//! `origine:@std/io`: Zig-style Io vocabulary. Pure JS; no natives.
const Module = @import("module.zig").Module;

pub const id = "origine:@std/io";
pub const source = @embedFile("../js/std_io.js");

pub fn modules() [1]Module {
    return .{.{ .id = id, .source = source }};
}
