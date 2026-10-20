//! `origine:@std/quansync`: write once, run sync or async. Pure JS; no natives.
const Module = @import("../module.zig").Module;

pub fn modules() [1]Module {
    return .{.{ .id = "origine:@std/quansync", .source = @embedFile("../../js/std/quansync.js") }};
}
