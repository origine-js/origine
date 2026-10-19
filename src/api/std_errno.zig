//! `origine:@std/errno`: the errno table, generated from `Errno` (see errno.zig).
const Module = @import("module.zig").Module;
const errno = @import("errno.zig");

pub fn modules() [1]Module {
    return .{.{ .id = "origine:@std/errno", .source = errno.module_source }};
}
