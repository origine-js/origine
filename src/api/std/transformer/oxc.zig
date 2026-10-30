//! `origine:@std/transformer/oxc`: descriptors of the oxc TypeScript/JSX transformer (see
//! src/js/std/transformer/oxc.js). JS validates options; private JS factories construct
//! snapshot-safe handles that the host runs through `graph.zig`. With `-Dtypescript=false` the module
//! is absent.
const module = @import("../../module.zig");
const oxc = @import("../../transform/oxc.zig");

pub fn modules() [if (oxc.enabled) 1 else 0]module.Module {
    if (!oxc.enabled) return .{};
    return .{.{ .id = "origine:@std/transformer/oxc", .source = @embedFile("../../../js/std/transformer/oxc.js") }};
}
