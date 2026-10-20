//! The `Errno` numbers, in a file with no dependencies besides std so `src/gen_contracts.zig`
//! can import it.
//!
//! CONTRACT (docs/contracts.md, surface D): this enum is the single source of truth for the error
//! codes. The guest tables (`origine:@std/errno`, `native.errors`) are generated from it at
//! compile time (errno.zig). The Rust table `rust/crates/origine_api_core/src/errno_table.rs`
//! is generated from it by `just gen-contracts`; `just check-contracts` fails when it is stale.
//! Adding or renumbering a member: edit it here, add it to `Error` in errno.zig (and the
//! Rust `ErrorKind` mapping in rust/crates/origine_api_core/src/errno.rs if a kind maps to it),
//! then `just gen-contracts`. Numbers are never reused (docs/async-host-contract.md).

/// Names match Zig error names so errors map by name.
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
    /// An async operation was canceled (runtime closed, grant revoked).
    Canceled = 14,
    TimedOut = 15,
    WouldBlock = 16,
    ConnectionRefused = 17,
    ConnectionReset = 18,
    BrokenPipe = 19,
    AddressInUse = 20,
    NotConnected = 21,
    DirNotEmpty = 22,
    Unexpected = 255,
};
