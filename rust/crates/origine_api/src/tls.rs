//! `native.tls.*`: TLS on the io loop, built on `origine_tls`.
//!
//! Values that are parsed once and reused (roots, identities, client authentication, session caches,
//! client and server configurations) are Rust-defined classes (`#[class]`, see `class`) owned by the
//! garbage collector; the guest gets them from `native.tls.<Class>` installers.
//!
//! A TLS stream is made over a stream (`sockstream::StreamArg`) by `TlsClient.connect` / `TlsServer.accept`. A
//! native stream (TCP or TLS, unshaped or an idle shaped one) is **consumed** (the object answers `BadHandle`
//! afterwards) and the handshake runs on its runtime, in Rust, without entering JS; any other object is a duck-typed
//! stream (`sockstream::JsStream`) read and written through its JS methods on the `io` the caller passes. The result
//! is a `TlsStreamUnshaped` whose reads and writes carry plaintext; `.pulling()` / `.evented()` make it a
//! `PullTlsStream` / `EventTlsStream`, with the members of the TCP classes plus `info()`. TLS over TLS is a TLS
//! stream given to `connect`.

use std::future::Future;
use std::io;
use std::rc::Rc;

use origine_api_core::{ArgError, NativeError, errno};
use origine_tls::{CertProblem, ClientOptions, ServerOptions, TlsError, TlsStream, Version};

use crate::class::Releasable;
use crate::conn::{Conn, Front, Kind};
use crate::decode::ArrayBufferArg;
use crate::fs::{AllocRead, ReadInto};
use crate::io::{Io, IoCore};
use crate::native::{Op, host_ref};
use crate::net::{SockAddr, Socket};
use crate::sockstream::{JsStream, SocketTransport, StreamArg, Under};
use crate::stream::{self, ShapeOptions, Side};
use crate::{FromJs, HostState, IntoJs, class, native};

/// How `origine_tls` failures reach the guest: one errno per meaning, the detail in `subject`.
pub(crate) fn tls_error(e: TlsError) -> NativeError {
    tls_error_of(&e)
}

/// [`tls_error`] for a borrowed error (one found inside an `io::Error` of a stacked transport).
pub(crate) fn tls_error_of(e: &TlsError) -> NativeError {
    let detailed = |code: u32, subject: String| NativeError::Errno(code).with_subject(subject);
    match e {
        // A duck-typed stream underneath failed: its own errno.
        TlsError::Io(e) if let Some(inner) = e.get_ref().and_then(|inner| inner.downcast_ref::<crate::sockstream::JsStreamError>()) => {
            inner.native()
        }
        // A TLS stream underneath failed (TLS over TLS).
        TlsError::Io(e) if let Some(inner) = e.get_ref().and_then(|inner| inner.downcast_ref::<TlsError>()) => tls_error_of(inner),
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

/// `{ servername, io? }` of `TlsClient.connect`.
#[derive(FromJs)]
struct ConnectOptions<'s> {
    servername: String,
    io: Option<&'s Io>,
}

/// `{ io? }` of `TlsServer.accept`.
#[derive(FromJs)]
struct AcceptOptions<'s> {
    io: Option<&'s Io>,
}

/// Runs a handshake over `stream` and makes the TLS stream: a `TlsStreamUnshaped` whose bytes are plaintext. A
/// native stream is consumed and runs on its own runtime (`io`, if given, must be that one); any other object is a
/// duck-typed stream and needs `io`. A failed handshake closes what is underneath.
fn handshake<'s, F, Fut>(
    scope: &mut v8::PinScope<'s, '_>,
    stream: StreamArg<'s>,
    io: Option<&Io>,
    run: F,
) -> Result<Op<'static, impl Future<Output = Result<TlsStreamUnshaped, NativeError>> + use<F, Fut>>, NativeError>
where
    F: FnOnce(Rc<Under>) -> Fut + 'static,
    Fut: Future<Output = Result<TlsStream<Rc<Under>>, TlsError>> + 'static,
{
    let (core, under): (Rc<IoCore>, Under) = match stream {
        StreamArg::Native(stream) => {
            let conn = stream.conn()?;
            if io.is_some_and(|io| !Rc::ptr_eq(&io.0, &conn.io)) {
                return Err(NativeError::type_error("options.io must be the Io of the stream (a native stream runs on its own)"));
            }
            let lp = conn.io.lp(host_ref(scope)?)?;
            let (core, socket) = stream.take()?;
            (core, Under::Socket(SocketTransport { socket, lp }))
        }
        StreamArg::Js(object) => {
            let io = io.ok_or_else(|| NativeError::type_error("options.io (an Io) is required for a stream that is not native"))?;
            io.0.lp(host_ref(scope)?)?;
            let js = JsStream::adopt(scope, object, &io.0)?;
            (Rc::clone(&io.0), Under::Js(js))
        }
    };
    let under = Rc::new(under);
    Ok(Op::new(core.runtime, async move {
        let tls = match run(Rc::clone(&under)).await {
            Ok(tls) => tls,
            Err(e) => {
                under.shutdown();
                return Err(tls_error(e));
            }
        };
        Ok(TlsStreamUnshaped(Front::new(Conn::new(&core, Kind::Stream, Socket::over_tls(tls, under)))))
    }))
}

/// An immutable client configuration (`api.tls.TlsClient`).
pub(crate) struct TlsClient(Releasable<origine_tls::TlsClient>);

#[class(path = "tls.TlsClient", side_effect = "any", needs = "runtime")]
impl TlsClient {
    /// Handshakes over `stream` and resolves a `TlsStreamUnshaped` whose bytes are plaintext; `servername` is what the
    /// certificate must be valid for (and the SNI sent). A native stream nothing is using is consumed (a refused call
    /// leaves it usable); any other object is a duck-typed stream and needs `io`.
    #[method(promise)]
    fn connect<'s>(
        &self,
        scope: &mut v8::PinScope<'s, '_>,
        stream: StreamArg<'s>,
        options: ConnectOptions<'s>,
    ) -> Result<Op<'static, impl Future<Output = Result<TlsStreamUnshaped, NativeError>> + use<>>, NativeError> {
        if options.servername.is_empty() {
            return Err(ArgError::new(1, "property `servername` to be a non-empty string").into());
        }
        // The handshake outlives the call: it holds its own copy of the configuration.
        let client = self.0.get()?;
        let servername = options.servername;
        handshake(scope, stream, options.io, move |transport| async move { TlsStream::connect(&client, transport, &servername).await })
    }

    fn release(&self) {
        self.0.release();
    }
}

/// An immutable server configuration (`api.tls.TlsServer`).
pub(crate) struct TlsServer(Releasable<origine_tls::TlsServer>);

#[class(path = "tls.TlsServer", side_effect = "any", needs = "runtime")]
impl TlsServer {
    /// Handshakes over `stream` as the server; see `TlsClient.connect`.
    #[method(promise)]
    fn accept<'s>(
        &self,
        scope: &mut v8::PinScope<'s, '_>,
        stream: StreamArg<'s>,
        options: Option<AcceptOptions<'s>>,
    ) -> Result<Op<'static, impl Future<Output = Result<TlsStreamUnshaped, NativeError>> + use<>>, NativeError> {
        let server = self.0.get()?;
        let io = options.and_then(|options| options.io);
        handshake(scope, stream, io, move |transport| async move { TlsStream::accept(&server, transport).await })
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

/// What the handshake of the TLS stream behind `front` settled: `{ alpn, version ('tls1.2' | 'tls1.3'), servername,
/// resumed, peer }`, `peer` the peer's certificates in DER, leaf first. `BadHandle` once closed or consumed.
fn info<'s>(scope: &mut v8::PinScope<'s, '_>, front: &Front) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let socket = front.get()?.socket()?;
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

/// A TLS stream that flows nothing yet (what `TlsClient.connect` / `TlsServer.accept` resolve).
pub(crate) struct TlsStreamUnshaped(pub(crate) Front);

#[class(path = "tls.TlsStreamUnshaped", side_effect = "any", needs = "runtime")]
impl TlsStreamUnshaped {
    /// Consumes this object: a `PullTlsStream` over the connection.
    fn pulling<'s>(
        &self,
        scope: &mut v8::PinScope<'s, '_>,
        options: Option<ShapeOptions>,
    ) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        stream::pulling(scope, &self.0, options)
    }

    /// Consumes this object: an `EventTlsStream` over the connection.
    fn evented<'s>(
        &self,
        scope: &mut v8::PinScope<'s, '_>,
        options: Option<ShapeOptions>,
    ) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        stream::evented(scope, &self.0, options)
    }

    /// What the handshake settled (a new frozen object each call).
    fn info<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        info(scope, &self.0)
    }

    fn close<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        stream::close(scope, &self.0)
    }

    #[getter]
    fn closed(&self, host: &HostState) -> bool {
        self.0.closed(host)
    }

    #[getter(name = "localAddr")]
    fn local_addr(&self) -> Result<SockAddr, NativeError> {
        self.0.local_addr()
    }

    #[getter(name = "peerAddr")]
    fn peer_addr(&self) -> Result<SockAddr, NativeError> {
        self.0.peer_addr()
    }
}

/// A TLS stream read with promises (the members of `PullTcpStream`, plus `info()`).
pub(crate) struct PullTlsStream(pub(crate) Front);

#[class(path = "tls.PullTlsStream", side_effect = "any", needs = "runtime")]
impl PullTlsStream {
    /// One read: a `Uint8Array` of 1 to `length` bytes (allocated), empty after the peer's `close_notify`.
    #[method(promise)]
    fn read(
        &self,
        scope: &mut v8::PinScope<'_, '_>,
        length: f64,
    ) -> Result<Op<'static, impl Future<Output = Result<AllocRead, NativeError>> + use<>>, NativeError> {
        stream::read(scope, &self.0, length)
    }

    /// One read straight into `buffer` (detached while it runs): `{ bytes, buffer }`.
    #[method(promise, name = "readInto")]
    fn read_into<'s>(
        &self,
        host: &mut HostState,
        buffer: ArrayBufferArg<'s>,
    ) -> Result<Op<'s, impl Future<Output = Result<ReadInto, NativeError>> + 'static + use<>>, NativeError> {
        stream::read_into(host, &self.0, buffer)
    }

    /// One read into `buffer` by copy: the byte count, 0 at end of stream.
    #[method(promise, name = "readCopy")]
    fn read_copy<'s>(
        &self,
        host: &mut HostState,
        buffer: ArrayBufferArg<'s>,
    ) -> Result<Op<'s, impl Future<Output = Result<usize, NativeError>> + 'static + use<>>, NativeError> {
        stream::read_copy(host, &self.0, buffer)
    }

    /// Consumes this object: an `EventTlsStream`. `WouldBlock` while a read is pending.
    #[method(name = "toEvented")]
    fn to_evented<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        stream::to_evented(scope, &self.0)
    }

    fn info<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        info(scope, &self.0)
    }

    /// `'write'` sends `close_notify`, then ends what is underneath (a half close).
    #[method(promise)]
    fn end(
        &self,
        host: &mut HostState,
        side: Side,
    ) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
        stream::end(host, &self.0, side)
    }

    fn close<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        stream::close(scope, &self.0)
    }

    #[getter]
    fn closed(&self, host: &HostState) -> bool {
        self.0.closed(host)
    }

    #[getter(name = "localAddr")]
    fn local_addr(&self) -> Result<SockAddr, NativeError> {
        self.0.local_addr()
    }

    #[getter(name = "peerAddr")]
    fn peer_addr(&self) -> Result<SockAddr, NativeError> {
        self.0.peer_addr()
    }
}

/// A TLS stream that pushes events to handlers held natively (the members of `EventTcpStream`, plus `info()`).
pub(crate) struct EventTlsStream(pub(crate) Front);

#[class(path = "tls.EventTlsStream", side_effect = "any", needs = "runtime")]
impl EventTlsStream {
    /// Subscribes `handler` to `data`, `end`, `error`, `drain` or `close`; returns a `Registration`.
    fn register<'s>(
        &self,
        scope: &mut v8::PinScope<'s, '_>,
        event: String,
        handler: v8::Local<'s, v8::Function>,
    ) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        stream::register(scope, &self.0, &event, handler)
    }

    fn pause(&self, scope: &mut v8::PinScope<'_, '_>) -> Result<(), NativeError> {
        stream::set_paused(scope, &self.0, true)
    }

    fn resume(&self, scope: &mut v8::PinScope<'_, '_>) -> Result<(), NativeError> {
        stream::set_paused(scope, &self.0, false)
    }

    #[getter]
    fn paused(&self) -> Result<bool, NativeError> {
        stream::paused(&self.0)
    }

    /// Consumes this object: a `PullTlsStream`. `Unsupported` once a `data` handler started the flow.
    #[method(name = "toPulling")]
    fn to_pulling<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        stream::to_pulling(scope, &self.0)
    }

    fn info<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        info(scope, &self.0)
    }

    #[method(promise)]
    fn end(
        &self,
        host: &mut HostState,
        side: Side,
    ) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
        stream::end(host, &self.0, side)
    }

    fn close<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        stream::close(scope, &self.0)
    }

    #[getter]
    fn closed(&self, host: &HostState) -> bool {
        self.0.closed(host)
    }

    #[getter(name = "localAddr")]
    fn local_addr(&self) -> Result<SockAddr, NativeError> {
        self.0.local_addr()
    }

    #[getter(name = "peerAddr")]
    fn peer_addr(&self) -> Result<SockAddr, NativeError> {
        self.0.peer_addr()
    }
}
