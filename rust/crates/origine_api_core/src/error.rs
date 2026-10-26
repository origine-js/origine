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
    /// An `Errno` failure: the frozen value `{ errno, name }` (the same shape `glue/util.js`
    /// `failure(code)` builds).
    Errno(u32),
    /// A plain `TypeError`.
    Type(String),
    /// A plain `RangeError`.
    Range(String),
    /// A plain `Error`.
    Error(String),
}

impl NativeError {
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
        NativeError::Errno(errno::errno_of(&err))
    }
}

impl fmt::Display for NativeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            NativeError::Arg(err) => err.fmt(f),
            NativeError::Errno(code) => write!(f, "errno {code} ({})", errno::name_of(*code)),
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
        assert!(matches!(err, NativeError::Errno(errno::NOT_FOUND)));
        assert_eq!(err.to_string(), "errno 10 (NotFound)");
    }

    #[test]
    fn arg_errors_keep_their_message() {
        let err = NativeError::from(ArgError::new(0, "an object"));
        assert_eq!(err.to_string(), "argument 0: expected an object");
    }
}
