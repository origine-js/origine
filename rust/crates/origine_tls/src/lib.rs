//! TLS 1.2/1.3 over any byte transport: rustls (aws-lc-rs) driven through [`Transport`].
//!
//! The crate does no I/O of its own. A [`TlsStream`] reads and writes encrypted bytes through the
//! [`Transport`] it was given (an `api.net` socket in production, an in-memory pipe in tests) and
//! offers plaintext `read` / `write` / `shutdown` on top. Everything is single-threaded and `!Send`
//! like the rest of the runtime. Values that are parsed once and reused ([`RootPki`], [`Identity`],
//! [`ClientAuth`], [`TlsSessions`], [`TlsClient`], [`TlsServer`]) are built by named constructors, so
//! a bad certificate fails there with its own error.

mod config;
mod error;
mod gate;
mod pki;
mod stream;
mod transport;

#[cfg(test)]
mod tests;

pub use config::{ClientOptions, ServerOptions, TlsClient, TlsServer};
pub use error::{CertProblem, TlsError};
pub use pki::{ClientAuth, Identity, RootPki, TlsSessions};
pub use stream::{Info, TlsStream, Version};
pub use transport::Transport;
