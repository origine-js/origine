//! `origine:@std/net`: `IpAddr` and `SocketAddr`, value types with no authority. Pure JS; the classes are the
//! realm's own, taken from the glue through `origine:@internal/handles` (importing it makes sure the glue exists).
const Module = @import("../module.zig").Module;

pub fn modules() [1]Module {
    return .{.{ .id = "origine:@std/net", .source = @embedFile("../../js/std/net.js") }};
}
