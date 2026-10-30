//! Embedded std wrappers with private JS class factories; validation stays in JS.
const Module = @import("../module.zig").Module;

pub fn modules() [1]Module {
    return .{.{ .id = "origine:@std/fs", .source = @embedFile("../../js/std/fs.js") }};
}
