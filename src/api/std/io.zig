//! Embedded std wrappers with private JS class factories; validation stays in JS.
const Module = @import("../module.zig").Module;

pub const id = "origine:@std/io";
pub const source = @embedFile("../../js/std/io.js");

pub fn modules() [1]Module {
    return .{.{ .id = id, .source = source }};
}
