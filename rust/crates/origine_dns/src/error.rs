use std::fmt;
use std::io;

use hickory_proto::ProtoError;
use hickory_proto::op::ResponseCode;

/// One meaning per variant (docs/api-guidelines.md); `origine_api` maps each to its own guest error.
#[derive(Debug)]
#[non_exhaustive]
pub enum DnsError {
    /// The name does not exist, or has no address of the asked family (NXDOMAIN, or NOERROR with no answer).
    NotFound,
    /// Every server was tried every time and none answered in time.
    TimedOut,
    /// A server answered, but with a failure.
    ServerFailure(Failure),
    /// The transport failed (the last error, when every server failed that way).
    Io(io::Error),
    /// The name is not a name this resolver can ask about (empty, too long, a bad label, not ASCII): the
    /// name as given.
    InvalidName(String),
    /// A response that does not answer the question asked, or is not DNS.
    BadResponse(BadResponse),
}

/// How a server failed to answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Failure {
    /// The DNS response code (`SERVFAIL`, `REFUSED`, ...).
    Code(ResponseCode),
    /// A DNS over HTTPS server answered with this HTTP status (not 200).
    Http(u16),
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Failure::Code(code) => code.fmt(f),
            Failure::Http(status) => write!(f, "HTTP status {status}"),
        }
    }
}

/// Why a response is not the answer to our question.
#[derive(Debug)]
#[non_exhaustive]
pub enum BadResponse {
    /// The id, or the response bit, is not that of our query.
    NotOurQuery,
    /// The question section is not ours.
    NotOurQuestion,
    /// The bytes are not a DNS message.
    Wire(Box<ProtoError>),
    /// A DNS over HTTPS response that is not a DNS message.
    Doh(DohError),
}

impl fmt::Display for BadResponse {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BadResponse::NotOurQuery => f.write_str("not the answer to our query"),
            BadResponse::NotOurQuestion => f.write_str("the question is not ours"),
            BadResponse::Wire(e) => e.fmt(f),
            BadResponse::Doh(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for BadResponse {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            BadResponse::Wire(e) => Some(e.as_ref()),
            BadResponse::Doh(e) => Some(e),
            _ => None,
        }
    }
}

impl fmt::Display for DnsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DnsError::NotFound => f.write_str("no such name"),
            DnsError::TimedOut => f.write_str("no server answered in time"),
            DnsError::ServerFailure(failure) => write!(f, "server failure: {failure}"),
            DnsError::Io(e) => write!(f, "transport error: {e}"),
            DnsError::InvalidName(name) => write!(f, "invalid name {name:?}"),
            DnsError::BadResponse(why) => write!(f, "bad response: {why}"),
        }
    }
}

impl std::error::Error for DnsError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            DnsError::Io(e) => Some(e),
            DnsError::BadResponse(e) => Some(e),
            _ => None,
        }
    }
}

/// How a DNS over HTTPS exchange failed above the transport. An `Exchange` carries it inside an
/// `io::Error` (`io::Error::other`); the resolver gives it its own [`DnsError`].
#[derive(Debug, PartialEq, Eq)]
pub enum DohError {
    /// The HTTP status was not 200 (redirects are not followed).
    Status(u16),
    /// The `content-type` is not `application/dns-message`.
    ContentType,
    /// The body is longer than any DNS message (65535 bytes).
    TooLarge,
}

impl fmt::Display for DohError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DohError::Status(code) => write!(f, "HTTP status {code}"),
            DohError::ContentType => f.write_str("the response is not application/dns-message"),
            DohError::TooLarge => f.write_str("the response is larger than a DNS message can be"),
        }
    }
}

impl std::error::Error for DohError {}
