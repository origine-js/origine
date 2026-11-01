use crate::sys;
use std::ffi::CStr;
use std::fmt;

/// One meaning per variant (docs/api-guidelines.md).
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum H2Error {
    /// A header name or value that HTTP/2 does not allow (uppercase name, forbidden connection header,
    /// control byte, pseudo header in the list).
    InvalidField(String),
    /// The call does not fit the stream's state (unknown stream, no body to feed, already finished).
    InvalidState(&'static str),
    /// A packed field list that is not well formed.
    BadPacking,
    /// The peer is sending too fast for our limits (reset or settings flood). The session is dead.
    Flooded,
    /// The first bytes of a client were not the HTTP/2 preface.
    BadPreface,
    /// Any other nghttp2 error: its code and message. After a fatal one the session is closed; send
    /// what is queued (a GOAWAY) and drop the transport.
    Library(i32, String),
}

impl H2Error {
    pub(crate) fn from_code(code: i32) -> H2Error {
        match code {
            sys::ERR_FLOODED => H2Error::Flooded,
            sys::ERR_BAD_CLIENT_MAGIC => H2Error::BadPreface,
            _ => H2Error::Library(code, strerror(code)),
        }
    }
}

fn strerror(code: i32) -> String {
    // SAFETY: nghttp2_strerror returns a pointer to a static NUL-terminated string for any code.
    let text = unsafe { sys::nghttp2_strerror(code) };
    if text.is_null() {
        return format!("nghttp2 error {code}");
    }
    // SAFETY: non-null and NUL-terminated, as above.
    unsafe { CStr::from_ptr(text) }.to_string_lossy().into_owned()
}

impl fmt::Display for H2Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            H2Error::InvalidField(m) => write!(f, "invalid header field: {m}"),
            H2Error::InvalidState(m) => write!(f, "invalid state: {m}"),
            H2Error::BadPacking => f.write_str("malformed packed header list"),
            H2Error::Flooded => f.write_str("peer flooded the session"),
            H2Error::BadPreface => f.write_str("not an HTTP/2 client preface"),
            H2Error::Library(code, m) => write!(f, "nghttp2 error {code}: {m}"),
        }
    }
}

impl std::error::Error for H2Error {}
