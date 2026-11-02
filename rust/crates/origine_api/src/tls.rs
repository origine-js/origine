//! `native.tls.*`: TLS on the io loop, built on `origine_tls`.
//!
//! Values that are parsed once and reused (roots, identities, client authentication, session caches,
//! client and server configurations) are Rust-defined classes (`#[class]`, see `class`) owned by the
//! garbage collector; the guest gets them from `native.tls.<Class>` installers. A TLS
//! stream is made from a plain `api.net` stream socket: `connect` / `accept` **consume** the socket
//! (it leaves the socket table, so the old id is `BadHandle`) and the handshake runs on the socket's
//! runtime. The result is a new socket of the same table whose reads and writes carry plaintext, so
//! every `net.*` native (pull reads, `subscribe` and the write lanes, `close`) works on it.

use std::cell::RefCell;
use std::future::Future;
use std::io;
use std::rc::Rc;

use origine_api_core::{ArgError, NativeError, errno};
use origine_tls::{CertProblem, ClientOptions, ServerOptions, TlsError, TlsStream, Version};

use crate::class::Releasable;
use crate::decode::ArrayBufferArg;
use crate::native::{Op, ScopeKey, host_mut};
use crate::net::Socket;
use crate::sockstream::{SocketTransport, take_socket};
use crate::{FromJs, HostState, class, native};

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

/// An immutable client configuration (`api.tls.TlsClient`). `connect` is a glue member: it takes and makes
/// `api.net` sockets (`tls.connect`).
pub(crate) struct TlsClient(Releasable<origine_tls::TlsClient>);

#[class(path = "tls.TlsClient", side_effect = "any", needs = "runtime")]
impl TlsClient {
    fn release(&self) {
        self.0.release();
    }
}

/// An immutable server configuration (`api.tls.TlsServer`). `accept` is a glue member (`tls.accept`).
pub(crate) struct TlsServer(Releasable<origine_tls::TlsServer>);

#[class(path = "tls.TlsServer", side_effect = "any", needs = "runtime")]
impl TlsServer {
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

/// `{ id, alpn, version, servername, resumed }`: a new TLS socket and what its handshake settled
/// (`version` is 12 or 13; `alpn` and `servername` are absent when not negotiated).
#[derive(crate::IntoJs)]
pub struct Opened {
    id: u32,
    alpn: Option<String>,
    version: u32,
    servername: Option<String>,
    resumed: bool,
}

fn opened(id: u32, tls: &TlsStream<SocketTransport>) -> Opened {
    let info = tls.info();
    Opened {
        id,
        alpn: info.alpn,
        version: if info.version == Version::Tls12 { 12 } else { 13 },
        servername: info.servername,
        resumed: info.resumed,
    }
}

type Slot = Rc<RefCell<Option<Socket>>>;

/// Registers a finished handshake: runs on the isolate thread before the promise resolves.
fn registrar(slot: Slot, id: u32) -> crate::native::Hook {
    Box::new(move |scope: &mut v8::PinScope<'_, '_>| {
        let socket = slot.borrow_mut().take().ok_or(NativeError::Errno(errno::CANCELED))?;
        host_mut(scope)?.insert_socket(id, socket)
    })
}

/// `native.tls.connect(io, client, socket, servername)`: Promise `Opened`. Consumes the stream socket
/// `socket` (a failed handshake closes it) and answers a new socket id. `client` is a `TlsClient`.
#[native(side_effect = "any", path = "tls.connect", needs = "runtime", promise)]
fn tls_connect(
    host: &mut HostState,
    key: ScopeKey,
    io: u32,
    client: &TlsClient,
    socket: u32,
    servername: String,
) -> Result<Op<'static, impl Future<Output = Result<Opened, NativeError>> + use<>>, NativeError> {
    // The handshake outlives the call: it holds its own copy of the configuration.
    let client = client.0.get()?;
    let (plain, lp) = take_socket(host, key, io, socket)?;
    let id = host.reserve_socket()?;
    let slot: Slot = Rc::default();
    let filled = Rc::clone(&slot);
    let future = async move {
        let transport = SocketTransport { socket: Rc::clone(&plain), lp };
        let tls = match TlsStream::connect(&client, transport, &servername).await {
            Ok(tls) => tls,
            Err(e) => {
                plain.shutdown();
                return Err(tls_error(e));
            }
        };
        let result = opened(id, &tls);
        *filled.borrow_mut() = Some(Socket::over_tls(key, io, tls, plain));
        Ok(result)
    };
    Ok(Op::new(io, future).with_hook(registrar(slot, id)))
}

/// `native.tls.accept(io, server, socket)`: Promise `Opened`. Consumes the accepted stream socket.
/// `server` is a `TlsServer`.
#[native(side_effect = "any", path = "tls.accept", needs = "runtime", promise)]
fn tls_accept(
    host: &mut HostState,
    key: ScopeKey,
    io: u32,
    server: &TlsServer,
    socket: u32,
) -> Result<Op<'static, impl Future<Output = Result<Opened, NativeError>> + use<>>, NativeError> {
    let server = server.0.get()?;
    let (plain, lp) = take_socket(host, key, io, socket)?;
    let id = host.reserve_socket()?;
    let slot: Slot = Rc::default();
    let filled = Rc::clone(&slot);
    let future = async move {
        let transport = SocketTransport { socket: Rc::clone(&plain), lp };
        let tls = match TlsStream::accept(&server, transport).await {
            Ok(tls) => tls,
            Err(e) => {
                plain.shutdown();
                return Err(tls_error(e));
            }
        };
        let result = opened(id, &tls);
        *filled.borrow_mut() = Some(Socket::over_tls(key, io, tls, plain));
        Ok(result)
    };
    Ok(Op::new(io, future).with_hook(registrar(slot, id)))
}

/// `native.tls.peer(id)`: the peer's certificates of TLS socket `id` as `[u32 LE length | DER]*`, leaf first
/// (empty if it sent none). `BadHandle` for a socket that is not a TLS one.
#[native(side_effect = "any", path = "tls.peer", needs = "runtime")]
fn tls_peer(host: &mut HostState, key: ScopeKey, id: u32) -> Result<Vec<u8>, NativeError> {
    let (socket, _) = host.socket(key, id)?;
    let (tls, _) = socket.tls().ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
    let mut packed = Vec::new();
    for cert in tls.info().peer {
        packed.extend_from_slice(&(cert.len() as u32).to_le_bytes());
        packed.extend_from_slice(&cert);
    }
    Ok(packed)
}
