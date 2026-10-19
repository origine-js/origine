//! The default TypeScript transformer: `.ts`, `.mts` and `.cts` through oxc (types erased,
//! enums, namespaces and parameter properties lowered, ESNext output).
const transformer = @import("transformer.zig");
const oxc = @import("oxc.zig");

pub const options: oxc.Options = .{};
pub const transformer_value: transformer.Transformer = .{ .data = @constCast(&options), .run = oxc.run };

pub const entries = [_]transformer.Entry{
    .{ .ext = ".ts", .transformer = transformer_value },
    .{ .ext = ".mts", .transformer = transformer_value },
    .{ .ext = ".cts", .transformer = transformer_value },
};
