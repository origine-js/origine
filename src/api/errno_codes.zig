//! The error codes, in a file with no dependencies besides std so `src/gen_contracts.zig` can
//! import it.
//!
//! CONTRACT (docs/contracts.md, surface D): `IoErrno` and `HostErrno` are the single source of truth
//! for the error codes. The guest tables (`origine:@std/errno`, `native.errors`), the Rust table
//! `rust/crates/origine_api_core/src/errno_table.rs` and `types/generated/errno.d.ts` are generated
//! from them (`rust/scripts/contracts.sh gen`; `check` fails when one is stale). Adding a member:
//! edit it here, add it to `Error` in errno.zig (and the std aliases in `lookup` and the Rust
//! `ErrorKind` mapping in rust/crates/origine_api_core/src/errno.rs when a kind maps to it), then
//! regenerate.
//!
//! # Two domains
//! * `IoErrno`: everything Rust's `std::io::ErrorKind` has a name for, plus the two OS errors Rust
//!   leaves uncategorized (`TooManyOpenFiles`, `Io`). Names are Rust's. Raised by fs and net, by
//!   both backends (Zig `std.Io`, Rust).
//! * `HostErrno`: origine's own runtime concepts, which exist only because of the runtime (a handle
//!   that is gone, a canceled operation). Raised by any native.
//! Rule for a new code: if Rust's `ErrorKind` has a name for it, it is an `IoErrno` with that name;
//! if it exists only because of origine's runtime, it is a `HostErrno`.
//!
//! # Numbering
//! The domain and category are readable from the number, in disjoint contiguous blocks with gaps for
//! growth; `ok = 0`:
//!
//! | Block | Domain | Category |
//! | --- | --- | --- |
//! | 1-9 | host | runtime (`Unexpected` 1, handles 2-3, `Canceled` 4) |
//! | 10-19 | io | path and file system objects (names, kinds, links) |
//! | 20-29 | io | permission and state (denied, read-only, busy, unsupported) |
//! | 30-39 | io | arguments and data (`InvalidInput`, `InvalidData`) |
//! | 40-49 | io | resources (space, size, quota, descriptors, device) |
//! | 50-59 | io | network and timing |
//!
//! `domain` tells a code's domain. The names are the contract; the numbers are NOT
//! guaranteed stable until a few stable versions have shipped (the layout was already renumbered once, at
//! the draft stage). Look a code up by name (`ERRNO.io.NotFound`, the generated tables) and never
//! persist or hard-code a number. Rust's `ErrorKind` names are not expected to change, so the names
//! should not either (docs/async-host-contract.md).
//!
//! `JavaScriptException` is not a code: it means "a JS exception is pending in V8", which is
//! Zig-internal (errno.zig `record` leaves the errno cell untouched so the pending exception
//! propagates). No guest code has it.
const std = @import("std");

/// What Rust's `std::io::ErrorKind` names, plus `TooManyOpenFiles` and `Io`. See the module docs.
pub const IoErrno = enum(u32) {
    // 10-19: path and file system objects
    NotFound = 10,
    AlreadyExists = 11,
    NotADirectory = 12,
    IsADirectory = 13,
    DirectoryNotEmpty = 14,
    /// ELOOP: too many symbolic links.
    FilesystemLoop = 15,
    /// ENAMETOOLONG or a name the file system cannot encode.
    InvalidFilename = 16,
    /// EXDEV: a rename across file systems.
    CrossesDevices = 17,
    // 20-29: permission and state
    /// Every denial: the grant's own (`..`, absolute paths, `__oricache__`, an access or ceiling that
    /// does not allow the call) and the OS's (EACCES, EPERM).
    PermissionDenied = 20,
    /// EROFS.
    ReadOnlyFilesystem = 21,
    /// EBUSY, ETXTBSY.
    ResourceBusy = 22,
    Unsupported = 23,
    // 30-39: arguments and data
    /// A malformed argument or path: a NUL byte, an empty entry name, a missing or unknown option.
    InvalidInput = 30,
    InvalidData = 31,
    // 40-49: resources
    StorageFull = 40,
    FileTooLarge = 41,
    /// EDQUOT.
    QuotaExceeded = 42,
    /// EMFILE, ENFILE (no Rust kind).
    TooManyOpenFiles = 43,
    /// EIO: a low-level I/O failure (no Rust kind).
    Io = 44,
    // 50-59: network and timing
    TimedOut = 50,
    WouldBlock = 51,
    ConnectionRefused = 52,
    ConnectionReset = 53,
    BrokenPipe = 54,
    AddressInUse = 55,
    NotConnected = 56,
};

/// origine's own runtime concepts: no Rust `ErrorKind` has a name for them. See the module docs.
pub const HostErrno = enum(u32) {
    /// Anything else (Rust's `Other`; also the name of an unknown code).
    Unexpected = 1,
    /// A handle that was never issued, was closed, or belongs to another grant, scope or runtime.
    BadHandle = 2,
    /// A handle that is closing, or a buffer that was already detached.
    StaleHandle = 3,
    /// An async operation was canceled (runtime closed, grant revoked).
    Canceled = 4,
};

pub const Domain = enum { io, host };

/// Every code of both domains, plus `ok`: the order of the guest tables. Built from the two enums,
/// so a member exists in exactly one place.
pub const Errno = blk: {
    const io = std.enums.values(IoErrno);
    const host = std.enums.values(HostErrno);
    var names: [2 + io.len + host.len][]const u8 = undefined;
    var values: [names.len]u32 = undefined;
    names[0] = "ok";
    values[0] = 0;
    var n: usize = 1;
    for (host) |tag| {
        names[n] = @tagName(tag);
        values[n] = @backingInt(tag);
        n += 1;
    }
    for (io) |tag| {
        names[n] = @tagName(tag);
        values[n] = @backingInt(tag);
        n += 1;
    }
    break :blk @Enum(u32, .exhaustive, names[0..n], values[0..n]);
};

/// The domain of a non-`ok` code.
pub fn domain(code: Errno) Domain {
    return if (std.enums.fromInt(HostErrno, @backingInt(code)) != null) .host else .io;
}
