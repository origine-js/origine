//! Error codes shared between native bindings and the guest (`IoError` in
//! src/js/std/io.js). A failing binding writes one of these into the scope's errno
//! cell; the guest reads it from a `Uint32Array`.
//!
//! Two error domains feed it, both concrete Zig error sets resolved at compile time:
//! - **Binding errors** (`Error`): everything natives raise themselves (env, scope,
//!   argument decoding, encoding). A closed set; `of` maps it strictly.
//! - **fs errors**: whatever the host file-system layer (`managed/sys.zig`) returns. These sets are large and shifting, so
//!   `ofFs` maps them by name and sends the unknown to `Unexpected`.
//!
//! `error.OutOfMemory` is never an errno: it panics where it is mapped. Non-fs code
//! narrows its internal errors to `Error` explicitly (`narrow`, the one boundary that
//! also accepts the managed layer's `anyerror`-typed callbacks) and asserts it at
//! compile time (`requireBinding`).
const std = @import("std");
const v8 = @import("@v8");
const eu = @import("@util");
const binding = @import("binding.zig");

/// Names match Zig error names so errors map by name. The enum lives in errno_codes.zig, the
/// single source of truth: the guest-side tables are generated from it (`module_source` for
/// `origine:@std/errno`, `table` for `native.errors`) and so is the Rust table (docs/contracts.md).
const codes = @import("errno_codes.zig");
pub const Errno = codes.Errno;
pub const IoErrno = codes.IoErrno;
pub const HostErrno = codes.HostErrno;
pub const domain = codes.domain;

/// The closed error set of the binding layer: one error per `Errno` (except `ok`) plus
/// `InvalidArgument`, a missing or mistyped JS argument (reported as `InvalidInput`), and
/// `JavaScriptException`, which has no code (`record` leaves the pending exception alone).
pub const Error = error{
    Unexpected,
    BadHandle,
    StaleHandle,
    Canceled,
    NotFound,
    AlreadyExists,
    NotADirectory,
    IsADirectory,
    DirectoryNotEmpty,
    FilesystemLoop,
    InvalidFilename,
    CrossesDevices,
    PermissionDenied,
    ReadOnlyFilesystem,
    ResourceBusy,
    Unsupported,
    InvalidInput,
    InvalidData,
    StorageFull,
    FileTooLarge,
    QuotaExceeded,
    TooManyOpenFiles,
    Io,
    TimedOut,
    WouldBlock,
    ConnectionRefused,
    ConnectionReset,
    BrokenPipe,
    AddressInUse,
    NotConnected,
    /// A JS exception is pending in V8 (a V8 call returned null). Zig-internal: no errno, see `record`.
    JavaScriptException,
    InvalidArgument,
};

// CONTRACT (docs/contracts.md, surface D): `Error` mirrors `Errno` by hand; keep them in step.
comptime {
    @setEvalBranchQuota(10_000);
    for (std.enums.values(Errno)) |tag| {
        if (tag == .ok) continue;
        var found = false;
        for (@typeInfo(Error).error_set.error_names.?) |name| {
            if (std.mem.eql(u8, name, @tagName(tag))) found = true;
        }
        if (!found) @compileError("errno.Error has no member for Errno." ++ @tagName(tag));
    }
}

/// The Zig std names (Zig std fs errors, kept for tests and callers that still use them) that are not `Errno` names, by canonical member.
/// Anything else is `Unexpected`. This is the Zig half of the one table; the Rust half is
/// `errno_of` in rust/crates/origine_api_core/src/errno.rs, and `src/tests/managed/api.zig`
/// provokes the same failures through both backends and compares.
const aliases = [_]struct { []const u8, Errno }{
    .{ "InvalidArgument", .InvalidInput },
    .{ "FileNotFound", .NotFound },
    .{ "AccessDenied", .PermissionDenied },
    .{ "NotDir", .NotADirectory },
    .{ "IsDir", .IsADirectory },
    .{ "PathAlreadyExists", .AlreadyExists },
    .{ "NoSpaceLeft", .StorageFull },
    .{ "FileTooBig", .FileTooLarge },
    .{ "DirNotEmpty", .DirectoryNotEmpty },
    .{ "ReadOnlyFileSystem", .ReadOnlyFilesystem },
    .{ "SymLinkLoop", .FilesystemLoop },
    .{ "FileBusy", .ResourceBusy },
    .{ "DeviceBusy", .ResourceBusy },
    .{ "PipeBusy", .ResourceBusy },
    .{ "CrossDevice", .CrossesDevices },
    .{ "RenameAcrossMountPoints", .CrossesDevices },
    .{ "DiskQuota", .QuotaExceeded },
    .{ "NameTooLong", .InvalidFilename },
    .{ "BadPathName", .InvalidFilename },
    .{ "InvalidWtf8", .InvalidFilename },
    .{ "ProcessFdQuotaExceeded", .TooManyOpenFiles },
    .{ "SystemFdQuotaExceeded", .TooManyOpenFiles },
    .{ "InputOutput", .Io },
    .{ "HardwareFailure", .Io },
    .{ "Timeout", .TimedOut },
    .{ "ConnectionResetByPeer", .ConnectionReset },
    .{ "SocketNotConnected", .NotConnected },
};

/// Exact `Errno` names first, then the aliases std and the binding layer use.
fn lookup(name: []const u8) ?Errno {
    inline for (std.enums.values(Errno)) |tag| {
        if (tag != .ok and std.mem.eql(u8, @tagName(tag), name)) return tag;
    }
    inline for (aliases) |alias| {
        if (std.mem.eql(u8, alias[0], name)) return alias[1];
    }
    return null;
}

/// Maps a binding error to its `Errno`. Total by construction: every member of
/// `Error` has a code, checked at compile time.
pub fn of(err: Error) Errno {
    @setEvalBranchQuota(10_000);
    return switch (err) {
        // Never recorded (see `isPending`); a total mapping for callers of `of` all the same.
        error.JavaScriptException => .Unexpected,
        inline else => |member| comptime lookup(@errorName(member)) orelse
            @compileError("errno.Error." ++ @errorName(member) ++ " has no Errno"),
    };
}

/// True for `error.JavaScriptException`: a JS exception is pending in V8 and the native must leave
/// it to propagate, not write a guest errno.
pub fn isPending(err: anytype) bool {
    return std.mem.eql(u8, @errorName(err), "JavaScriptException");
}

/// Maps a file-system error (`sys.Error` or a std one) to an `Errno`. Takes a concrete error set, resolved at
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
    // The managed layer reports a JS exception it already captured (its error info is discarded
    // here), so none is pending for the guest: the source it was given is malformed.
    if (std.mem.eql(u8, name, "JavaScriptException")) return error.InvalidData;
    inline for (@typeInfo(Error).error_set.error_names.?) |member| {
        if (std.mem.eql(u8, name, member)) return @field(Error, member);
    }
    // A std name for a canonical member (`error.FileNotFound`): same table as `ofFs`.
    inline for (std.enums.values(Errno)) |tag| {
        if (tag != .ok and (lookup(name) orelse .ok) == tag) return @field(Error, @tagName(tag));
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

/// Source of the synthetic `origine:@std/errno` module, generated from `IoErrno` and `HostErrno` at
/// compile time: `export const ERRNO = { io: { NotFound: 10, ... }, host: { Unexpected: 1, ... } }`.
pub const module_source: []const u8 = blk: {
    @setEvalBranchQuota(10_000);
    var out: []const u8 = "// @generated from `IoErrno` and `HostErrno` in src/api/errno_codes.zig; do not edit.\nexport const ERRNO = Object.freeze({\n";
    for (.{ .{ "io", codes.IoErrno }, .{ "host", codes.HostErrno } }) |dom| {
        out = out ++ "  " ++ dom[0] ++ ": Object.freeze({\n";
        for (std.enums.values(dom[1])) |tag| {
            out = out ++ std.fmt.comptimePrint("    {s}: {d},\n", .{ @tagName(tag), @backingInt(tag) });
        }
        out = out ++ "  }),\n";
    }
    break :blk out ++ "});\n";
};

/// A new JS object `{ io: { NotFound: 10, ... }, host: { BadHandle: 2, ... } }` generated from the two
/// domains, for the glue (`native.errors`). Needs an entered context and live handle scope.
pub fn table(env: binding.Env) !v8.Object {
    const target = eu.v.object(env.isolate);
    inline for (.{ .{ "io", codes.IoErrno }, .{ "host", codes.HostErrno } }) |dom| {
        const part = eu.v.object(env.isolate);
        inline for (std.enums.values(dom[1])) |tag| try binding.set(env, part, @tagName(tag), @backingInt(tag));
        try binding.set(env, target, dom[0], part);
    }
    return target;
}
