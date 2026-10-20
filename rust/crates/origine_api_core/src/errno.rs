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
/// leaves uncategorized, else `Unexpected`.
pub fn errno_of(err: &io::Error) -> u32 {
    use io::ErrorKind as K;
    match err.kind() {
        K::NotFound => FILE_NOT_FOUND,
        K::PermissionDenied => ACCESS_DENIED,
        K::NotADirectory => NOT_DIR,
        K::IsADirectory => IS_DIR,
        K::AlreadyExists => PATH_ALREADY_EXISTS,
        K::InvalidInput => INVALID_PATH,
        K::StorageFull => NO_SPACE_LEFT,
        K::Unsupported => UNSUPPORTED,
        K::FileTooLarge => FILE_TOO_BIG,
        K::InvalidData => INVALID_DATA,
        K::TimedOut => TIMED_OUT,
        K::WouldBlock => WOULD_BLOCK,
        K::ConnectionRefused => CONNECTION_REFUSED,
        K::ConnectionReset => CONNECTION_RESET,
        K::BrokenPipe => BROKEN_PIPE,
        K::AddrInUse => ADDRESS_IN_USE,
        K::NotConnected => NOT_CONNECTED,
        K::DirectoryNotEmpty => DIR_NOT_EMPTY,
        _ => err.raw_os_error().map_or(UNEXPECTED, errno_of_raw),
    }
}

/// `ECANCELED`: 125 on Linux, 89 on macOS.
const ECANCELED: i32 = if cfg!(target_os = "linux") { 125 } else { 89 };

/// POSIX errno values shared by Linux and macOS, for errors `io::ErrorKind` does not classify.
fn errno_of_raw(raw: i32) -> u32 {
    match raw {
        raw if raw == ECANCELED => CANCELED,
        1 | 13 => ACCESS_DENIED,
        2 => FILE_NOT_FOUND,
        17 => PATH_ALREADY_EXISTS,
        20 => NOT_DIR,
        21 => IS_DIR,
        22 => INVALID_PATH,
        27 => FILE_TOO_BIG,
        28 => NO_SPACE_LEFT,
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
            (K::NotFound, 1),
            (K::PermissionDenied, 2),
            (K::NotADirectory, 3),
            (K::IsADirectory, 4),
            (K::AlreadyExists, 5),
            (K::InvalidInput, 8),
            (K::StorageFull, 9),
            (K::Unsupported, 10),
            (K::FileTooLarge, 11),
            (K::InvalidData, 12),
            (K::Other, 255),
            (K::TimedOut, 15),
            (K::WouldBlock, 16),
            (K::ConnectionRefused, 17),
            (K::ConnectionReset, 18),
            (K::BrokenPipe, 19),
            (K::AddrInUse, 20),
            (K::NotConnected, 21),
            (K::Interrupted, 255),
            (K::DirectoryNotEmpty, 22),
        ];
        for (kind, code) in cases {
            assert_eq!(errno_of(&io::Error::from(kind)), code, "{kind:?}");
        }
    }

    #[test]
    fn raw_errors_use_the_kind_then_the_raw_table() {
        assert_eq!(errno_of(&io::Error::from_raw_os_error(2)), FILE_NOT_FOUND);
        assert_eq!(errno_of(&io::Error::from_raw_os_error(28)), NO_SPACE_LEFT);
        assert_eq!(errno_of_raw(27), FILE_TOO_BIG);
        assert_eq!(errno_of(&io::Error::from_raw_os_error(ECANCELED)), CANCELED);
        assert_eq!(errno_of_raw(9999), UNEXPECTED);
        assert_eq!(errno_of(&io::Error::other("boom")), UNEXPECTED);
    }

    #[test]
    fn names_follow_the_zig_enum() {
        assert_eq!(name_of(FILE_NOT_FOUND), "FileNotFound");
        assert_eq!(name_of(STALE_HANDLE), "StaleHandle");
        assert_eq!(name_of(JAVA_SCRIPT_EXCEPTION), "JavaScriptException");
        assert_eq!(name_of(14), "Canceled");
        assert_eq!(name_of(15), "TimedOut");
        assert_eq!(name_of(16), "WouldBlock");
        assert_eq!(name_of(17), "ConnectionRefused");
        assert_eq!(name_of(18), "ConnectionReset");
        assert_eq!(name_of(19), "BrokenPipe");
        assert_eq!(name_of(20), "AddressInUse");
        assert_eq!(name_of(21), "NotConnected");
        assert_eq!(name_of(4242), "Unexpected");
    }
}
