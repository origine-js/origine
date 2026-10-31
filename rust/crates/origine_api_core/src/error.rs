//! The error a native reports to JS. Converted to a JS value by `origine_api`.

use std::fmt;
use std::io;

use crate::arg::ArgError;
use crate::errno;

/// How a native fails. Sync natives throw it; async natives reject their promise with it.
#[derive(Debug)]
pub enum NativeError {
    /// A bad argument: a `TypeError` with the message `argument N: expected X`.
    Arg(ArgError),
    /// An `Errno` failure: the shared OrigineError subclass instance that
    /// `glue/util.js` `failure(code)` builds.
    Errno(u32),
    /// An `Errno` failure with its `ErrorDetail` (the raw OS code, the name of what it was about).
    Detailed(Detail),
    /// A plain `TypeError`.
    Type(String),
    /// A plain `RangeError`.
    Range(String),
    /// A plain `Error`.
    Error(String),
}

/// What a failure knows besides its errno: the fields of `ErrorDetail` (`errno::DETAIL_FIELDS`).
#[derive(Debug)]
pub struct Detail {
    pub code: u32,
    /// The raw OS error code, when the failure came from the OS.
    pub os: Option<i32>,
    /// A name the caller supplied or an id the guest already holds; never an absolute host path.
    pub subject: Option<String>,
}

impl NativeError {
    /// The errno of an `Errno` failure, with or without a detail.
    pub fn code(&self) -> Option<u32> {
        match self {
            NativeError::Errno(code) => Some(*code),
            NativeError::Detailed(detail) => Some(detail.code),
            _ => None,
        }
    }

    /// Names what an `Errno` failure was about (`ErrorDetail.subject`); any other failure is unchanged.
    pub fn with_subject(self, subject: impl Into<String>) -> NativeError {
        match self {
            NativeError::Errno(code) => NativeError::Detailed(Detail { code, os: None, subject: Some(subject.into()) }),
            NativeError::Detailed(detail) => NativeError::Detailed(Detail { subject: Some(subject.into()), ..detail }),
            other => other,
        }
    }

    /// A `TypeError` with `message`.
    pub fn type_error(message: impl Into<String>) -> NativeError {
        NativeError::Type(message.into())
    }

    /// A `RangeError` with `message`.
    pub fn range_error(message: impl Into<String>) -> NativeError {
        NativeError::Range(message.into())
    }

    /// An `Error` with `message`.
    pub fn error(message: impl Into<String>) -> NativeError {
        NativeError::Error(message.into())
    }
}

impl From<ArgError> for NativeError {
    fn from(err: ArgError) -> NativeError {
        NativeError::Arg(err)
    }
}

impl From<io::Error> for NativeError {
    fn from(err: io::Error) -> NativeError {
        NativeError::Detailed(Detail { code: errno::errno_of(&err), os: err.raw_os_error(), subject: None })
    }
}

impl fmt::Display for NativeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            NativeError::Arg(err) => err.fmt(f),
            NativeError::Errno(code) => write!(f, "errno {code} ({})", errno::name_of(*code)),
            NativeError::Detailed(detail) => match &detail.subject {
                Some(subject) => write!(f, "errno {} ({}): {subject}", detail.code, errno::name_of(detail.code)),
                None => write!(f, "errno {} ({})", detail.code, errno::name_of(detail.code)),
            },
            NativeError::Type(message) | NativeError::Range(message) | NativeError::Error(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for NativeError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn io_errors_become_errno_values() {
        let err = NativeError::from(io::Error::from(io::ErrorKind::NotFound));
        assert_eq!(err.code(), Some(errno::NOT_FOUND));
        assert_eq!(err.to_string(), "errno 10 (NotFound)");
    }

    #[test]
    fn io_errors_keep_the_os_code() {
        let err = NativeError::from(io::Error::from_raw_os_error(2));
        assert!(matches!(&err, NativeError::Detailed(Detail { code: errno::NOT_FOUND, os: Some(2), subject: None })));
    }

    #[test]
    fn a_subject_names_what_the_failure_was_about() {
        let err = NativeError::from(io::Error::from(io::ErrorKind::NotFound)).with_subject("a/b.txt");
        assert_eq!(err.code(), Some(errno::NOT_FOUND));
        assert_eq!(err.to_string(), "errno 10 (NotFound): a/b.txt");
        let plain = NativeError::Errno(errno::BAD_HANDLE).with_subject("x");
        assert_eq!(plain.code(), Some(errno::BAD_HANDLE));
        assert!(matches!(NativeError::type_error("t").with_subject("x"), NativeError::Type(_)));
    }

    #[test]
    fn the_detail_fields_are_the_generated_layout() {
        assert_eq!(errno::DETAIL_FIELDS, ["subject", "os"]);
    }

    #[test]
    fn arg_errors_keep_their_message() {
        let err = NativeError::from(ArgError::new(0, "an object"));
        assert_eq!(err.to_string(), "argument 0: expected an object");
    }
}
