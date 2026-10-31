//! The `ErrorDetail` object: what a failure knows besides its errno. A plain object of a fixed
//! shape, every field always present (`undefined` when unset), so V8 gives all of them one map and
//! never sees a field appear or change place. The keys are `detail_fields` in errno_codes.zig, which
//! the Rust side builds from the same generated list.
//!
//! The sync scope has one, made with the glue (`native.detail`) and overwritten by the native that
//! fails; the glue copies it onto the error it throws and resets it. It carries no brand: only the
//! glue can reach it.
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const binding = @import("binding.zig");
const codes = @import("errno_codes.zig");

/// The values of the fields, in `detail_fields` order.
pub const Fields = struct {
    /// A name the caller supplied or an id the guest already holds; never an absolute host path.
    subject: ?[]const u8 = null,
    /// The raw OS error code, where the backend has one.
    os: ?u32 = null,
};

comptime {
    const names = @typeInfo(Fields).@"struct".field_names;
    std.debug.assert(names.len == codes.detail_fields.len);
    for (names, codes.detail_fields) |name, field| std.debug.assert(std.mem.eql(u8, name, field));
}

/// A new detail object with every field unset.
pub fn create(env: binding.Env) !v8.Object {
    const object = eu.v.object(env.isolate);
    try fill(env, object, .{});
    return object;
}

/// Overwrites every field of `detail` (the ones `fields` leaves out become unset).
pub fn fill(env: binding.Env, detail: v8.Object, fields: Fields) !void {
    inline for (@typeInfo(Fields).@"struct".field_names) |name| try binding.set(env, detail, name, @field(fields, name));
}
