//! The default JSX transformer: `.tsx` and `.jsx` through oxc, with the automatic runtime
//! (`react/jsx-runtime` unless a `@jsxImportSource` pragma or the options say otherwise).
const transformer = @import("transformer.zig");
const oxc = @import("oxc.zig");

pub const options: oxc.Options = .{};
pub const transformer_value: transformer.Transformer = .{ .data = @constCast(&options), .run = oxc.run };

pub const entries = [_]transformer.Entry{
    .{ .ext = ".tsx", .transformer = transformer_value },
    .{ .ext = ".jsx", .transformer = transformer_value },
};
