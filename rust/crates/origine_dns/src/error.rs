use std::fmt;
use std::io;

/// One meaning per variant (docs/api-guidelines.md); `origine_api` maps each to its own guest error.
#[derive(Debug)]
#[non_exhaustive]
pub enum DnsError {
    /// The name does not exist, or has no address of the asked family (NXDOMAIN, or NOERROR with no answer).
    NotFound,
    /// Every server was tried every time and none answered in time.
    TimedOut,
    /// A server answered, but with a failure (`SERVFAIL`, `REFUSED`, ...): its response code.
    ServerFailure(String),
    /// The transport failed (the last error, when every server failed that way).
    Io(io::Error),
    /// The name is not a name this resolver can ask about (empty, too long, a bad label, not ASCII).
    InvalidName(String),
    /// A response that does not answer the question asked, or is not DNS.
    BadResponse(String),
}

impl fmt::Display for DnsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DnsError::NotFound => f.write_str("no such name"),
            DnsError::TimedOut => f.write_str("no server answered in time"),
            DnsError::ServerFailure(code) => write!(f, "server failure: {code}"),
            DnsError::Io(e) => write!(f, "transport error: {e}"),
            DnsError::InvalidName(name) => write!(f, "invalid name {name:?}"),
            DnsError::BadResponse(why) => write!(f, "bad response: {why}"),
        }
    }
}

impl std::error::Error for DnsError {}
