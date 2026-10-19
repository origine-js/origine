//! Error codes shared between native bindings and the guest (`IoError` in
//! src/js/std_io.js). A failing binding writes one of these into the scope's errno
//! cell; the guest reads it from a `Uint32Array`.
//!
//! Two error domains feed it, both concrete Zig error sets resolved at compile time:
//! - **Binding errors** (`Error`): everything natives raise themselves (env, scope,
//!   argument decoding, encoding). A closed set; `of` maps it strictly.
//! - **fs errors**: whatever `std.Io` returns. These sets are large and shifting, so
//!   `ofFs` maps them by name and sends the unknown to `Unexpected`.
//!
//! `error.OutOfMemory` is never an errno: it panics where it is mapped. Non-fs code
//! narrows its internal errors to `Error` explicitly (`narrow`, the one boundary that
//! also accepts the managed layer's `anyerror`-typed callbacks) and asserts it at
//! compile time (`requireBinding`).
const std = @import("std");
const v8 = @import("@v8");
const binding = @import("binding.zig");

/// Names match Zig error names so errors map by name. This enum is the single source
/// of truth: the guest-side tables are generated from it (`module_source` for
/// `origine:@std/errno`, `table` for `native.errors`), never written by hand.
pub const Errno = enum(u32) {
    ok = 0,
    FileNotFound = 1,
    AccessDenied = 2,
    NotDir = 3,
    IsDir = 4,
    PathAlreadyExists = 5,
    BadHandle = 6,
    StaleHandle = 7,
    InvalidPath = 8,
    NoSpaceLeft = 9,
    Unsupported = 10,
    FileTooBig = 11,
    InvalidData = 12,
    JavaScriptException = 13,
    Unexpected = 255,
};

/// The closed error set of the binding layer: one error per `Errno` (except `ok`) plus
/// `InvalidArgument`, a missing or mistyped JS argument (reported as `InvalidPath`).
pub const Error = error{
    FileNotFound,
    AccessDenied,
    NotDir,
    IsDir,
    PathAlreadyExists,
    BadHandle,
    StaleHandle,
    InvalidPath,
    NoSpaceLeft,
    Unsupported,
    FileTooBig,
    InvalidData,
    JavaScriptException,
    Unexpected,
    InvalidArgument,
};

/// Exact `Errno` names first, then the aliases std and the binding layer use.
fn lookup(name: []const u8) ?Errno {
    inline for (std.enums.values(Errno)) |tag| {
        if (tag != .ok and std.mem.eql(u8, @tagName(tag), name)) return tag;
    }
    if (std.mem.eql(u8, name, "InvalidArgument")) return .InvalidPath;
    if (std.mem.eql(u8, name, "PermissionDenied") or std.mem.eql(u8, name, "ReadOnlyFileSystem")) return .AccessDenied;
    return null;
}

/// Maps a binding error to its `Errno`. Total by construction: every member of
/// `Error` has a code, checked at compile time.
pub fn of(err: Error) Errno {
    @setEvalBranchQuota(10_000);
    return switch (err) {
        inline else => |member| comptime lookup(@errorName(member)) orelse
            @compileError("errno.Error." ++ @errorName(member) ++ " has no Errno"),
    };
}

/// Maps a `std.Io` fs error to an `Errno`. Takes a concrete error set, resolved at
/// compile time for every member (`anyerror` is rejected); a member without a code
/// becomes `Unexpected`, and `error.OutOfMemory` panics.
pub fn ofFs(err: anytype) Errno {
    const Set = @TypeOf(err);
    comptime {
        if (@typeInfo(Set) != .error_set) @compileError("errno.ofFs takes an error set value, found " ++ @typeName(Set));
        if (@typeInfo(Set).error_set.error_names == null) @compileError("errno.ofFs needs a concrete error set; narrow to errno.Error first");
    }
    @setEvalBranchQuota(10_000);
    return switch (err) {
        inline else => |member| blk: {
            if (comptime std.mem.eql(u8, @errorName(member), "OutOfMemory")) @panic("OutOfMemory");
            break :blk comptime (lookup(@errorName(member)) orelse .Unexpected);
        },
    };
}

/// Narrows any error to the binding set by name; unknown errors become
/// `error.Unexpected` and `error.OutOfMemory` panics. The explicit boundary where
/// non-fs code (scope creation, module loading, ...) turns its internal errors,
/// including the managed layer's `anyerror`-typed results, into `Error`.
pub fn narrow(err: anytype) Error {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "OutOfMemory")) @panic("OutOfMemory");
    inline for (@typeInfo(Error).error_set.error_names.?) |member| {
        if (std.mem.eql(u8, name, member)) return @field(Error, member);
    }
    return error.Unexpected;
}

/// True when `Set` is a concrete error set whose members are all in `Error`.
pub fn isBinding(comptime Set: type) bool {
    if (@typeInfo(Set) != .error_set) return false;
    const names = @typeInfo(Set).error_set.error_names orelse return false;
    @setEvalBranchQuota(20_000);
    inline for (names) |name| {
        var found = false;
        inline for (@typeInfo(Error).error_set.error_names.?) |member| {
            if (std.mem.eql(u8, name, member)) found = true;
        }
        if (!found) return false;
    }
    return true;
}

/// Compile-time assertion that the native `func` returns only binding errors, so
/// non-fs natives cannot leak arbitrary std errors. Use in a `comptime` block next to
/// the natives it guards.
pub fn requireBinding(comptime func: anytype) void {
    const info = @typeInfo(@TypeOf(func)).@"fn";
    const Result = info.return_type orelse @compileError("native has a generic return type");
    const set = switch (@typeInfo(Result)) {
        .error_union => |union_info| union_info.error_set,
        else => return,
    };
    if (!isBinding(set)) @compileError(@typeName(@TypeOf(func)) ++ " must return errno.Error, not " ++ @typeName(set) ++ " (narrow with errno.narrow)");
}

/// Source of the synthetic `origine:@std/errno` module, generated from `Errno` at
/// compile time: `export const ERRNO = { FileNotFound: 1, ... }` (every member but `ok`).
pub const module_source: []const u8 = blk: {
    @setEvalBranchQuota(10_000);
    var out: []const u8 = "// @generated from `Errno` in src/api/errno.zig; do not edit.\nexport const ERRNO = Object.freeze({\n";
    for (std.enums.values(Errno)) |tag| {
        if (tag == .ok) continue;
        out = out ++ std.fmt.comptimePrint("  {s}: {d},\n", .{ @tagName(tag), @intFromEnum(tag) });
    }
    break :blk out ++ "});\n";
};

/// A new JS object `{ FileNotFound: 1, ... }` generated from `Errno`, for the glue
/// (`native.errors`). Needs an entered context and live handle scope.
pub fn table(env: binding.Env) !v8.Object {
    const target = v8.Object.init(env.isolate);
    inline for (std.enums.values(Errno)) |tag| {
        if (tag != .ok) try binding.set(env, target, @tagName(tag), @intFromEnum(tag));
    }
    return target;
}
