//! `origine:@std/graph/*`: the data side of the module graph (recipes, sources, import handlers,
//! resolver layers, providers, caches). Pure JS; no natives. The graph that consumes them
//! (`api.graph`) is not implemented yet; see docs/graph-api.md.
const Module = @import("../module.zig").Module;

pub fn modules() [6]Module {
    return .{
        .{ .id = "origine:@std/graph/module", .source = @embedFile("../../js/std/graph/module.js") },
        .{ .id = "origine:@std/graph/import", .source = @embedFile("../../js/std/graph/import.js") },
        .{ .id = "origine:@std/graph/resolve", .source = @embedFile("../../js/std/graph/resolve.js") },
        .{ .id = "origine:@std/graph/resolve/layers", .source = @embedFile("../../js/std/graph/resolve/layers.js") },
        .{ .id = "origine:@std/graph/providers", .source = @embedFile("../../js/std/graph/providers.js") },
        .{ .id = "origine:@std/graph/cache", .source = @embedFile("../../js/std/graph/cache.js") },
    };
}
