use std::fmt;
use std::io;

/// Why a peer certificate was refused. Kept apart from [`TlsError::Protocol`] because the right
/// reaction (fix the trust roots, the name or the clock) is different.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CertProblem {
    UnknownIssuer,
    Expired,
    NotYetValid,
    NotValidForName,
    Revoked,
    BadSignature,
    Other(String),
}

/// One meaning per variant (docs/api-guidelines.md): `origine_api` maps each to its own guest error.
#[derive(Debug)]
#[non_exhaustive]
pub enum TlsError {
    /// The transport failed.
    Io(io::Error),
    /// The transport ended without the peer's `close_notify`: the data may have been cut.
    UnexpectedEof,
    /// The peer's certificate was refused (ours, when we are the server and ask for one).
    Certificate(CertProblem),
    /// The peer sent a fatal alert (its name, e.g. `HandshakeFailure`).
    Alert(String),
    /// The two sides share no ALPN protocol.
    NoApplicationProtocol,
    /// Any other violation or incompatibility.
    Protocol(String),
    /// A certificate or root could not be read.
    BadCertificate(String),
    /// A private key could not be read, or does not belong to the certificate.
    BadKey(String),
    /// The server name is neither a DNS name nor an IP address.
    InvalidServerName(String),
    /// An earlier write was dropped half way, so the record stream is no longer in step.
    Poisoned,
}

impl fmt::Display for TlsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TlsError::Io(e) => write!(f, "transport error: {e}"),
            TlsError::UnexpectedEof => f.write_str("connection ended without close_notify"),
            TlsError::Certificate(p) => write!(f, "certificate refused: {p:?}"),
            TlsError::Alert(a) => write!(f, "peer sent alert {a}"),
            TlsError::NoApplicationProtocol => f.write_str("no ALPN protocol in common"),
            TlsError::Protocol(m) => write!(f, "TLS protocol error: {m}"),
            TlsError::BadCertificate(m) => write!(f, "bad certificate: {m}"),
            TlsError::BadKey(m) => write!(f, "bad private key: {m}"),
            TlsError::InvalidServerName(n) => write!(f, "invalid server name {n:?}"),
            TlsError::Poisoned => f.write_str("stream broken by a dropped write"),
        }
    }
}

impl std::error::Error for TlsError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            TlsError::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<io::Error> for TlsError {
    fn from(e: io::Error) -> TlsError {
        TlsError::Io(e)
    }
}

impl From<rustls::Error> for TlsError {
    fn from(e: rustls::Error) -> TlsError {
        use rustls::CertificateError as C;
        use rustls::Error as E;
        match e {
            E::InvalidCertificate(c) => TlsError::Certificate(match c {
                C::UnknownIssuer => CertProblem::UnknownIssuer,
                C::Expired | C::ExpiredContext { .. } => CertProblem::Expired,
                C::NotValidYet | C::NotValidYetContext { .. } => CertProblem::NotYetValid,
                C::NotValidForName | C::NotValidForNameContext { .. } => CertProblem::NotValidForName,
                C::Revoked => CertProblem::Revoked,
                C::BadSignature => CertProblem::BadSignature,
                other => CertProblem::Other(format!("{other:?}")),
            }),
            E::AlertReceived(a) => TlsError::Alert(format!("{a:?}")),
            E::NoApplicationProtocol => TlsError::NoApplicationProtocol,
            other => TlsError::Protocol(other.to_string()),
        }
    }
}

impl From<TlsError> for io::Error {
    /// For stacking: a `TlsStream` is itself a `Transport`, whose errors are `io::Error`.
    fn from(e: TlsError) -> io::Error {
        match e {
            TlsError::Io(e) => e,
            TlsError::UnexpectedEof => io::Error::new(io::ErrorKind::UnexpectedEof, e),
            TlsError::Poisoned => io::Error::new(io::ErrorKind::BrokenPipe, e),
            TlsError::Certificate(_) | TlsError::Alert(_) | TlsError::NoApplicationProtocol | TlsError::Protocol(_) => {
                io::Error::new(io::ErrorKind::InvalidData, e)
            }
            other => io::Error::other(other),
        }
    }
}
