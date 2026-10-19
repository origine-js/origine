//! The host's default extension-to-transformer map. Add a transformer by writing a
//! `transform_*.zig` with an `entries` array and concatenating it here.
const transformer = @import("transformer.zig");
const oxc = @import("oxc.zig");
const transform_ts = @import("ts.zig");
const transform_jsx = @import("jsx.zig");

const all = transform_ts.entries ++ transform_jsx.entries;

/// Empty when built with `-Dtypescript=false`. Static storage.
pub const defaults: []const transformer.Entry = if (oxc.enabled) &all else &.{};
