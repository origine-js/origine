//! Maps Rust I/O errors onto origine's `Errno` codes.
//!
//! CONTRACT (docs/contracts.md, surface D): the numbers and names are generated from the `Errno`
//! enum in src/api/errno_codes.zig (the single source of truth) into `errno_table.rs` by
//! `just gen-contracts`; `just check-contracts` fails when that file is stale. Only the
//! `io::ErrorKind` / raw-errno policy below is written by hand: when a new `Errno` member should
//! be produced from a Rust error, add its arm here and a case to the tests.

use std::io;

#[path = "errno_table.rs"]
mod table;

pub use table::*;

/// The `Errno` code for `err`: the `io::ErrorKind` first, then the raw OS error for kinds std
/// leaves uncategorized, else `Unexpected`. This is the Rust half of the canonical table (the Zig
/// half is `errno.zig`'s `lookup`); the names are Rust's own kind names wherever one exists.
pub fn errno_of(err: &io::Error) -> u32 {
    use io::ErrorKind as K;
    match err.kind() {
        K::NotFound => NOT_FOUND,
        K::PermissionDenied => PERMISSION_DENIED,
        K::NotADirectory => NOT_A_DIRECTORY,
        K::IsADirectory => IS_A_DIRECTORY,
        K::AlreadyExists => ALREADY_EXISTS,
        K::InvalidInput => INVALID_INPUT,
        K::StorageFull => STORAGE_FULL,
        K::Unsupported => UNSUPPORTED,
        K::FileTooLarge => FILE_TOO_LARGE,
        K::InvalidData => INVALID_DATA,
        K::TimedOut => TIMED_OUT,
        K::WouldBlock => WOULD_BLOCK,
        K::ConnectionRefused => CONNECTION_REFUSED,
        K::ConnectionReset => CONNECTION_RESET,
        K::BrokenPipe => BROKEN_PIPE,
        K::AddrInUse => ADDRESS_IN_USE,
        K::NotConnected => NOT_CONNECTED,
        K::DirectoryNotEmpty => DIRECTORY_NOT_EMPTY,
        K::ReadOnlyFilesystem => READ_ONLY_FILESYSTEM,
        K::ResourceBusy | K::ExecutableFileBusy => RESOURCE_BUSY,
        K::CrossesDevices => CROSSES_DEVICES,
        K::QuotaExceeded => QUOTA_EXCEEDED,
        K::InvalidFilename => INVALID_FILENAME,
        _ => err.raw_os_error().map_or(UNEXPECTED, errno_of_raw),
    }
}

/// `ECANCELED`: 125 on Linux, 89 on macOS.
const ECANCELED: i32 = if cfg!(target_os = "linux") { 125 } else { 89 };
/// `ELOOP`: 40 on Linux, 62 on macOS (`ErrorKind::FilesystemLoop` is not stable).
const ELOOP: i32 = if cfg!(target_os = "linux") { 40 } else { 62 };

/// POSIX errno values for errors `io::ErrorKind` does not classify (Linux and macOS agree on the
/// small numbers; the others are named above). The kinds std does decode (EROFS, EBUSY, EXDEV,
/// EDQUOT, ENAMETOOLONG, ...) are in [`errno_of`]; the raw arms for them are only a fallback.
fn errno_of_raw(raw: i32) -> u32 {
    match raw {
        raw if raw == ECANCELED => CANCELED,
        raw if raw == ELOOP => FILESYSTEM_LOOP,
        1 | 13 => PERMISSION_DENIED,
        2 => NOT_FOUND,
        5 => IO,
        16 | 26 => RESOURCE_BUSY,
        17 => ALREADY_EXISTS,
        20 => NOT_A_DIRECTORY,
        21 => IS_A_DIRECTORY,
        22 => INVALID_INPUT,
        23 | 24 => TOO_MANY_OPEN_FILES,
        27 => FILE_TOO_LARGE,
        28 => STORAGE_FULL,
        30 => READ_ONLY_FILESYSTEM,
        _ => UNEXPECTED,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use io::ErrorKind as K;

    #[test]
    fn kinds_map_to_their_codes() {
        let cases = [
            (K::NotFound, NOT_FOUND),
            (K::PermissionDenied, PERMISSION_DENIED),
            (K::NotADirectory, NOT_A_DIRECTORY),
            (K::IsADirectory, IS_A_DIRECTORY),
            (K::AlreadyExists, ALREADY_EXISTS),
            (K::InvalidInput, INVALID_INPUT),
            (K::StorageFull, STORAGE_FULL),
            (K::Unsupported, UNSUPPORTED),
            (K::FileTooLarge, FILE_TOO_LARGE),
            (K::InvalidData, INVALID_DATA),
            (K::Other, UNEXPECTED),
            (K::TimedOut, TIMED_OUT),
            (K::WouldBlock, WOULD_BLOCK),
            (K::ConnectionRefused, CONNECTION_REFUSED),
            (K::ConnectionReset, CONNECTION_RESET),
            (K::BrokenPipe, BROKEN_PIPE),
            (K::AddrInUse, ADDRESS_IN_USE),
            (K::NotConnected, NOT_CONNECTED),
            (K::Interrupted, UNEXPECTED),
            (K::DirectoryNotEmpty, DIRECTORY_NOT_EMPTY),
            (K::ReadOnlyFilesystem, READ_ONLY_FILESYSTEM),
            (K::ResourceBusy, RESOURCE_BUSY),
            (K::ExecutableFileBusy, RESOURCE_BUSY),
            (K::CrossesDevices, CROSSES_DEVICES),
            (K::QuotaExceeded, QUOTA_EXCEEDED),
            (K::InvalidFilename, INVALID_FILENAME),
        ];
        for (kind, code) in cases {
            assert_eq!(errno_of(&io::Error::from(kind)), code, "{kind:?}");
        }
    }

    /// The OS errors the guest can provoke through `fs`, on the raw numbers of this platform (the
    /// kind first, the raw table for what std leaves uncategorized).
    #[test]
    fn raw_errors_use_the_kind_then_the_raw_table() {
        let (eloop, erofs, ebusy, exdev, edquot, enametoolong) =
            if cfg!(target_os = "linux") { (40, 30, 16, 18, 122, 36) } else { (62, 30, 16, 18, 69, 63) };
        let cases = [
            (2, NOT_FOUND),
            (1, PERMISSION_DENIED),
            (13, PERMISSION_DENIED),
            (5, IO),
            (24, TOO_MANY_OPEN_FILES),
            (23, TOO_MANY_OPEN_FILES),
            (28, STORAGE_FULL),
            (27, FILE_TOO_LARGE),
            (eloop, FILESYSTEM_LOOP),
            (erofs, READ_ONLY_FILESYSTEM),
            (ebusy, RESOURCE_BUSY),
            (exdev, CROSSES_DEVICES),
            (edquot, QUOTA_EXCEEDED),
            (enametoolong, INVALID_FILENAME),
            (ECANCELED, CANCELED),
            (9999, UNEXPECTED),
        ];
        for (raw, code) in cases {
            assert_eq!(errno_of(&io::Error::from_raw_os_error(raw)), code, "raw {raw}");
        }
        assert_eq!(errno_of_raw(27), FILE_TOO_LARGE);
        assert_eq!(errno_of(&io::Error::other("boom")), UNEXPECTED);
    }

    #[test]
    fn names_follow_the_zig_enums() {
        assert_eq!(name_of(NOT_FOUND), "NotFound");
        assert_eq!(name_of(PERMISSION_DENIED), "PermissionDenied");
        assert_eq!(name_of(INVALID_INPUT), "InvalidInput");
        assert_eq!(name_of(STALE_HANDLE), "StaleHandle");
        assert_eq!(name_of(CANCELED), "Canceled");
        assert_eq!(name_of(ADDRESS_IN_USE), "AddressInUse");
        assert_eq!(name_of(FILESYSTEM_LOOP), "FilesystemLoop");
        assert_eq!(name_of(UNEXPECTED), "Unexpected");
        assert_eq!(name_of(4242), "Unexpected");
    }

    /// The numbering is readable: host codes are 1-9, I/O codes 10 and up, and `ALL` has each once.
    #[test]
    fn domains_are_disjoint_blocks() {
        assert!(HOST_CODES.iter().all(|&(code, _)| (1..10).contains(&code) && is_host(code)));
        assert!(IO_CODES.iter().all(|&(code, _)| code >= 10 && !is_host(code)));
        assert_eq!(ALL.len(), HOST_CODES.len() + IO_CODES.len());
        assert!(ALL.windows(2).all(|pair| pair[0].0 < pair[1].0), "ascending, no duplicates");
        assert!(ALL.iter().all(|&(code, name)| name_of(code) == name));
    }
}
