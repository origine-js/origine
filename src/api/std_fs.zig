//! `origine:@std/fs`: Rust `std::fs`-style API over an `io`. Pure JS; the authority
//! lives in the grant natives behind `api.fs` (see fs.zig).
const Module = @import("module.zig").Module;

pub fn modules() [1]Module {
    return .{.{ .id = "origine:@std/fs", .source = @embedFile("../js/std_fs.js") }};
}
