//! `native.tls.*`: TLS on the io loop, built on `origine_tls`.
//!
//! Values that are parsed once and reused (roots, identities, client authentication, session caches,
//! client and server configurations) are Rust-defined classes (`#[class]`, see `class`) owned by the
//! garbage collector; the guest gets them from `native.tls.<Class>` installers. A TLS
//! stream is made from a native stream (`sockstream::StreamArg`): `TlsClient.connect` / `TlsServer.accept`
//! **consume** it (the object answers `BadHandle` afterwards) and the handshake runs on its runtime, in Rust,
//! without entering JS. The result is a new `TcpStreamUnshaped` whose reads and writes carry plaintext, so
//! `.pulling()`, `.evented()` and the whole write side work on it.

use std::future::Future;
use std::io;
use std::rc::Rc;

use origine_api_core::{ArgError, NativeError, errno};
use origine_tls::{CertProblem, ClientOptions, ServerOptions, TlsError, TlsStream, Version};

use crate::class::Releasable;
use crate::conn::{Conn, Front, Kind};
use crate::decode::ArrayBufferArg;
use crate::native::Op;
use crate::net::Socket;
use crate::sockstream::{SocketTransport, StreamArg};
use crate::stream::TcpStreamUnshaped;
use crate::{FromJs, HostState, IntoJs, class, native};

/// How `origine_tls` failures reach the guest: one errno per meaning, the detail in `subject`.
pub(crate) fn tls_error(e: TlsError) -> NativeError {
    tls_error_of(&e)
}

/// [`tls_error`] for a borrowed error (one found inside an `io::Error` of a stacked transport).
pub(crate) fn tls_error_of(e: &TlsError) -> NativeError {
    let detailed = |code: u32, subject: String| NativeError::Errno(code).with_subject(subject);
    match e {
        TlsError::Io(e) => NativeError::from(io::Error::new(e.kind(), e.to_string())),
        TlsError::UnexpectedEof => NativeError::Errno(errno::UNEXPECTED_EOF),
        TlsError::Certificate(problem) => detailed(
            errno::CERTIFICATE_REJECTED,
            match problem {
                CertProblem::UnknownIssuer => "UnknownIssuer".into(),
                CertProblem::Expired => "Expired".into(),
                CertProblem::NotYetValid => "NotYetValid".into(),
                CertProblem::NotValidForName => "NotValidForName".into(),
                CertProblem::Revoked => "Revoked".into(),
                CertProblem::BadSignature => "BadSignature".into(),
                CertProblem::Other(text) => text.clone(),
            },
        ),
        TlsError::Alert(name) => detailed(errno::TLS_ALERT, name.clone()),
        TlsError::NoApplicationProtocol => NativeError::Errno(errno::NO_APPLICATION_PROTOCOL),
        TlsError::Protocol(text) => detailed(errno::PROTOCOL_ERROR, text.clone()),
        TlsError::BadCertificate(text) | TlsError::BadKey(text) => detailed(errno::INVALID_DATA, text.clone()),
        TlsError::InvalidServerName(name) => detailed(errno::INVALID_INPUT, name.clone()),
        TlsError::Poisoned => NativeError::Errno(errno::BROKEN_PIPE),
        _ => NativeError::Errno(errno::UNEXPECTED),
    }
}

// ---- values ----
//
// Roots, identities, client authentication, session caches and configurations are Rust-defined classes (see
// `class`): each instance owns its value in the cppgc heap, and the value is dropped when the instance is
// collected or `release()`d. What is built from a value holds its own copy (they are `Arc`-backed).

/// The authorities a peer is checked against (`api.tls.RootPki`).
pub(crate) struct RootPki(Releasable<origine_tls::RootPki>);

#[class(path = "tls.RootPki", side_effect = "any", needs = "runtime")]
impl RootPki {
    /// The Mozilla roots compiled into the binary.
    #[static_method]
    fn bundled() -> RootPki {
        RootPki(Releasable::new(origine_tls::RootPki::bundled()))
    }

    /// Every certificate of a PEM bundle; `InvalidData` when none parse.
    #[static_method(name = "fromPem")]
    fn from_pem(pem: ArrayBufferArg<'_>) -> Result<RootPki, NativeError> {
        pem.with_bytes(origine_tls::RootPki::from_pem).map(|roots| RootPki(Releasable::new(roots))).map_err(tls_error)
    }

    /// DER certificates, at least one.
    #[static_method(name = "fromDer")]
    fn from_der(certs: Vec<Vec<u8>>) -> Result<RootPki, NativeError> {
        origine_tls::RootPki::from_der(&certs).map(|roots| RootPki(Releasable::new(roots))).map_err(tls_error)
    }

    /// Lets go of the value now; what was built from it keeps working.
    fn release(&self) {
        self.0.release();
    }
}

impl RootPki {
    /// A copy of the roots; `BadHandle` once released.
    pub(crate) fn get(&self) -> Result<origine_tls::RootPki, NativeError> {
        self.0.get()
    }
}

/// `{ cert: Uint8Array[] (DER, leaf first), key: Uint8Array (DER) }`.
#[derive(FromJs)]
struct DerIdentity {
    cert: Vec<Vec<u8>>,
    key: Vec<u8>,
}

/// A certificate chain with the private key of its leaf (`api.tls.Identity`).
pub(crate) struct Identity(Releasable<origine_tls::Identity>);

#[class(path = "tls.Identity", side_effect = "any", needs = "runtime")]
impl Identity {
    /// A PEM chain (leaf first) and its PEM private key; `InvalidData` for a bad pair.
    #[static_method(name = "fromPem")]
    fn from_pem(cert: ArrayBufferArg<'_>, private_key: ArrayBufferArg<'_>) -> Result<Identity, NativeError> {
        cert.with_bytes(|cert| private_key.with_bytes(|private_key| origine_tls::Identity::from_pem(cert, private_key)))
            .map(|identity| Identity(Releasable::new(identity)))
            .map_err(tls_error)
    }

    /// A DER chain (leaf first) and its DER private key.
    #[static_method(name = "fromDer")]
    fn from_der(options: DerIdentity) -> Result<Identity, NativeError> {
        origine_tls::Identity::from_der(&options.cert, &options.key).map(|identity| Identity(Releasable::new(identity))).map_err(tls_error)
    }

    fn release(&self) {
        self.0.release();
    }
}

/// Whether a server asks the client for a certificate (`api.tls.ClientAuth`): the roots it must be issued by.
pub(crate) struct ClientAuth(Option<origine_tls::RootPki>);

#[class(path = "tls.ClientAuth", side_effect = "any", needs = "runtime")]
impl ClientAuth {
    /// Clients are not asked.
    #[static_method]
    fn none() -> ClientAuth {
        ClientAuth(None)
    }

    /// Clients must present a certificate issued by one of `roots`.
    #[static_method]
    fn require(roots: &RootPki) -> Result<ClientAuth, NativeError> {
        Ok(ClientAuth(Some(roots.get()?)))
    }
}

/// `{ limit }`: how many server names a session cache remembers.
#[derive(FromJs)]
struct SessionsOptions {
    limit: u32,
}

/// A client-side resumption cache (`api.tls.TlsSessions`).
pub(crate) struct TlsSessions(Releasable<origine_tls::TlsSessions>);

#[class(path = "tls.TlsSessions", side_effect = "any", needs = "runtime")]
impl TlsSessions {
    /// Remembers at most `limit` (a positive integer) server names.
    #[static_method]
    fn create(options: SessionsOptions) -> Result<TlsSessions, NativeError> {
        if options.limit == 0 {
            return Err(ArgError::new(0, "property `limit` to be a positive integer").into());
        }
        Ok(TlsSessions(Releasable::new(origine_tls::TlsSessions::create(options.limit as usize))))
    }

    fn release(&self) {
        self.0.release();
    }
}

/// `{ servername }` of `TlsClient.connect`.
#[derive(FromJs)]
struct ConnectOptions {
    servername: String,
}

/// Runs a handshake over the socket of `stream` (consumed) and makes the TLS stream: a new `TcpStreamUnshaped`
/// whose bytes are plaintext. A failed handshake closes the socket.
fn handshake<F, Fut>(
    host: &HostState,
    stream: StreamArg<'_>,
    run: F,
) -> Result<Op<'static, impl Future<Output = Result<TcpStreamUnshaped, NativeError>> + use<F, Fut>>, NativeError>
where
    F: FnOnce(SocketTransport) -> Fut + 'static,
    Fut: Future<Output = Result<TlsStream<SocketTransport>, TlsError>> + 'static,
{
    let conn = stream.conn()?;
    let lp = conn.io.lp(host)?;
    let (io, plain) = stream.take()?;
    let runtime = io.runtime;
    Ok(Op::new(runtime, async move {
        let tls = match run(SocketTransport { socket: Rc::clone(&plain), lp }).await {
            Ok(tls) => tls,
            Err(e) => {
                plain.shutdown();
                return Err(tls_error(e));
            }
        };
        Ok(TcpStreamUnshaped::new(Conn::new(&io, Kind::Stream, Socket::over_tls(tls, plain))))
    }))
}

/// An immutable client configuration (`api.tls.TlsClient`).
pub(crate) struct TlsClient(Releasable<origine_tls::TlsClient>);

#[class(path = "tls.TlsClient", side_effect = "any", needs = "runtime")]
impl TlsClient {
    /// Handshakes over `stream` (a native stream nothing is using, consumed: a refused call leaves it usable) and
    /// resolves a new `TcpStreamUnshaped` whose bytes are plaintext; `servername` is what the certificate must be
    /// valid for (and the SNI sent).
    #[method(promise)]
    fn connect(
        &self,
        host: &mut HostState,
        stream: StreamArg<'_>,
        options: ConnectOptions,
    ) -> Result<Op<'static, impl Future<Output = Result<TcpStreamUnshaped, NativeError>> + use<>>, NativeError> {
        if options.servername.is_empty() {
            return Err(ArgError::new(1, "property `servername` to be a non-empty string").into());
        }
        // The handshake outlives the call: it holds its own copy of the configuration.
        let client = self.0.get()?;
        let servername = options.servername;
        handshake(host, stream, move |transport| async move { TlsStream::connect(&client, transport, &servername).await })
    }

    fn release(&self) {
        self.0.release();
    }
}

/// An immutable server configuration (`api.tls.TlsServer`).
pub(crate) struct TlsServer(Releasable<origine_tls::TlsServer>);

#[class(path = "tls.TlsServer", side_effect = "any", needs = "runtime")]
impl TlsServer {
    /// Handshakes over `stream` (consumed) as the server; see `TlsClient.connect`.
    #[method(promise)]
    fn accept(
        &self,
        host: &mut HostState,
        stream: StreamArg<'_>,
    ) -> Result<Op<'static, impl Future<Output = Result<TcpStreamUnshaped, NativeError>> + use<>>, NativeError> {
        let server = self.0.get()?;
        handshake(host, stream, move |transport| async move { TlsStream::accept(&server, transport).await })
    }

    fn release(&self) {
        self.0.release();
    }
}

/// An ALPN protocol name: a non-empty string.
struct Protocol(String);

impl<'s> FromJs<'s> for Protocol {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        match String::from_js(scope, value, index) {
            Ok(name) if !name.is_empty() => Ok(Protocol(name)),
            _ => Err(ArgError::new(index, "a protocol name (a non-empty string)")),
        }
    }
}

fn protocols(alpn: Option<Vec<Protocol>>) -> Vec<String> {
    alpn.unwrap_or_default().into_iter().map(|Protocol(name)| name).collect()
}

/// `tls.client`'s options.
#[derive(FromJs)]
struct ClientConfig<'s> {
    roots: &'s RootPki,
    identity: Option<&'s Identity>,
    alpn: Option<Vec<Protocol>>,
    sessions: Option<&'s TlsSessions>,
}

/// `native.tls.client({ roots, identity?, alpn?, sessions? })`: a client configuration.
#[native(side_effect = "any", path = "tls.client", needs = "runtime")]
fn tls_client(options: ClientConfig<'_>) -> Result<TlsClient, NativeError> {
    let identity = options.identity.map(Identity::get).transpose()?;
    let sessions = options.sessions.map(|sessions| sessions.0.get()).transpose()?;
    let options = ClientOptions { roots: options.roots.get()?, identity, alpn: protocols(options.alpn), sessions };
    origine_tls::TlsClient::new(options).map(|client| TlsClient(Releasable::new(client))).map_err(tls_error)
}

impl Identity {
    fn get(&self) -> Result<origine_tls::Identity, NativeError> {
        self.0.get()
    }
}

/// `tls.server`'s options.
#[derive(FromJs)]
struct ServerConfig<'s> {
    identities: Vec<&'s Identity>,
    client_auth: &'s ClientAuth,
    alpn: Option<Vec<Protocol>>,
}

/// `native.tls.server({ identities, clientAuth, alpn? })`: a server configuration; `identities` has at least one.
#[native(side_effect = "any", path = "tls.server", needs = "runtime")]
fn tls_server(options: ServerConfig<'_>) -> Result<TlsServer, NativeError> {
    if options.identities.is_empty() {
        return Err(ArgError::new(0, "property `identities` to be a non-empty array of Identity").into());
    }
    let identities = options.identities.into_iter().map(Identity::get).collect::<Result<Vec<_>, _>>()?;
    let client_auth = options.client_auth.0.clone().map_or_else(origine_tls::ClientAuth::none, origine_tls::ClientAuth::require);
    let options = ServerOptions { identities, client_auth, alpn: protocols(options.alpn) };
    origine_tls::TlsServer::new(options).map(|server| TlsServer(Releasable::new(server))).map_err(tls_error)
}

// ---- streams ----

/// `native.tls.info(stream)`: what the handshake of a TLS stream settled: `{ alpn, version ('tls1.2' | 'tls1.3'),
/// servername, resumed, peer }`, `peer` the peer's certificates in DER, leaf first. `BadHandle` for a stream that
/// is not TLS (or is closed).
#[native(side_effect = "any", path = "tls.info", needs = "runtime")]
fn tls_info<'s>(scope: &mut v8::PinScope<'s, '_>, stream: AnyStream<'s>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let socket = stream.0.get()?.socket()?;
    let tls = socket.tls().ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
    let info = tls.info();
    let object = crate::encode::new_object(scope);
    crate::encode::set(scope, object, "alpn", info.alpn)?;
    crate::encode::set(scope, object, "version", if info.version == Version::Tls12 { "tls1.2" } else { "tls1.3" })?;
    crate::encode::set(scope, object, "servername", info.servername)?;
    crate::encode::set(scope, object, "resumed", info.resumed)?;
    let mut certs = Vec::with_capacity(info.peer.len());
    for cert in info.peer {
        certs.push(cert.into_js(scope)?);
    }
    let peer = v8::Array::new_with_elements(scope, &certs);
    peer.set_integrity_level(scope, v8::IntegrityLevel::Frozen);
    crate::encode::set(scope, object, "peer", peer)?;
    crate::encode::freeze(scope, object)
}

/// Any TCP stream object, borrowed for the call (without the checks of a handover).
struct AnyStream<'s>(&'s Front);

impl<'s> FromJs<'s> for AnyStream<'s> {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        let isolate: &mut v8::Isolate = scope;
        if let Some(stream) = crate::gc::unwrap_ref::<TcpStreamUnshaped>(isolate, value) {
            return Ok(AnyStream(&stream.0));
        }
        if let Some(stream) = crate::gc::unwrap_ref::<crate::stream::PullTcpStream>(isolate, value) {
            return Ok(AnyStream(stream.front()));
        }
        if let Some(stream) = crate::gc::unwrap_ref::<crate::stream::EventTcpStream>(isolate, value) {
            return Ok(AnyStream(stream.front()));
        }
        Err(ArgError::new(index, "a TLS stream"))
    }
}
