//! `origine:@std/dns/presets`: well-known public resolvers as data. Pure JS; it reaches the realm's `DnsServer`
//! through `origine:@internal/handles`, so it holds no authority of its own.
const Module = @import("../module.zig").Module;

pub fn modules() [1]Module {
    return .{.{ .id = "origine:@std/dns/presets", .source = @embedFile("../../js/std/dns/presets.js") }};
}
