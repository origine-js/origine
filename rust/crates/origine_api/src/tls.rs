//! `native.tls.*`: TLS on the io loop, built on `origine_tls`.
//!
//! Values that are parsed once and reused (roots, identities, session caches, client and server
//! configurations) live in the Host's TLS table as ids, bound to the scope that made them. A TLS
//! stream is made from a plain `api.net` stream socket: `connect` / `accept` **consume** the socket
//! (it leaves the socket table, so the old id is `BadHandle`) and the handshake runs on the socket's
//! runtime. The result is a new socket of the same table whose reads and writes carry plaintext, so
//! every `net.*` native (pull reads, `subscribe` and the write lanes, `close`) works on it.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::future::Future;
use std::io;
use std::rc::Rc;

use origine_api_core::{NativeError, errno};
use origine_tls::{
    CertProblem, ClientAuth, ClientOptions, Identity, RootPki, ServerOptions, TlsClient, TlsError, TlsServer, TlsSessions, TlsStream,
    Version,
};

use crate::HostState;
use crate::decode::ArrayBufferArg;
use crate::native;
use crate::native::{Op, ScopeKey, host_mut};
use crate::net::Socket;
use crate::sockstream::{SocketTransport, take_socket};

enum Value {
    Roots(RootPki),
    Identity(Identity),
    Sessions(TlsSessions),
    Client(TlsClient),
    Server(TlsServer),
}

/// The Host's TLS tables. Ids are never reused while the table lives.
#[derive(Default)]
pub(crate) struct TlsState {
    next_value: u32,
    values: BTreeMap<u32, (ScopeKey, Rc<Value>)>,
}

impl TlsState {
    pub(crate) fn clear(&mut self) {
        self.values.clear();
    }

    fn add_value(&mut self, owner: ScopeKey, value: Value) -> Result<u32, NativeError> {
        self.next_value = self.next_value.checked_add(1).ok_or(NativeError::Errno(errno::PERMISSION_DENIED))?;
        self.values.insert(self.next_value, (owner, Rc::new(value)));
        Ok(self.next_value)
    }

    fn value(&self, owner: ScopeKey, id: u32) -> Result<Rc<Value>, NativeError> {
        match self.values.get(&id) {
            Some((o, value)) if *o == owner => Ok(Rc::clone(value)),
            _ => Err(NativeError::Errno(errno::BAD_HANDLE)),
        }
    }
}

pub(crate) fn roots_of(host: &HostState, key: ScopeKey, id: u32) -> Result<RootPki, NativeError> {
    match &*host.tls.value(key, id)? {
        Value::Roots(roots) => Ok(roots.clone()),
        _ => Err(NativeError::Errno(errno::BAD_HANDLE)),
    }
}

fn identity_of(host: &HostState, key: ScopeKey, id: u32) -> Result<Identity, NativeError> {
    match &*host.tls.value(key, id)? {
        Value::Identity(identity) => Ok(identity.clone()),
        _ => Err(NativeError::Errno(errno::BAD_HANDLE)),
    }
}

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

/// Splits `[u32 LE length | bytes]*` (how the glue passes a list of DER blobs in one buffer).
fn unpack(packed: &[u8]) -> Result<Vec<&[u8]>, NativeError> {
    let bad = || NativeError::Errno(errno::INVALID_INPUT);
    let mut items = Vec::new();
    let mut rest = packed;
    while !rest.is_empty() {
        let (head, tail) = rest.split_at_checked(4).ok_or_else(bad)?;
        let len = u32::from_le_bytes([head[0], head[1], head[2], head[3]]) as usize;
        let (item, tail) = tail.split_at_checked(len).ok_or_else(bad)?;
        items.push(item);
        rest = tail;
    }
    Ok(items)
}

fn alpn_list(text: &str) -> Vec<String> {
    text.split('\n').filter(|name| !name.is_empty()).map(str::to_owned).collect()
}

// ---- values ----

/// `native.tls.rootsBundled()`: id of the Mozilla roots compiled into the binary.
#[native(side_effect = "any", path = "tls.rootsBundled", needs = "runtime")]
fn tls_roots_bundled(host: &mut HostState, key: ScopeKey) -> Result<u32, NativeError> {
    host.tls.add_value(key, Value::Roots(RootPki::bundled()))
}

/// `native.tls.rootsPem(pem)`: id of the certificates of a PEM bundle. `InvalidData` when none parse.
#[native(side_effect = "any", path = "tls.rootsPem", needs = "runtime")]
fn tls_roots_pem(host: &mut HostState, key: ScopeKey, pem: ArrayBufferArg<'_>) -> Result<u32, NativeError> {
    let roots = pem.with_bytes(RootPki::from_pem).map_err(tls_error)?;
    host.tls.add_value(key, Value::Roots(roots))
}

/// `native.tls.rootsDer(packed)`: `packed` is `[u32 LE length | DER certificate]*`.
#[native(side_effect = "any", path = "tls.rootsDer", needs = "runtime")]
fn tls_roots_der(host: &mut HostState, key: ScopeKey, packed: ArrayBufferArg<'_>) -> Result<u32, NativeError> {
    let roots = packed.with_bytes(|bytes| unpack(bytes).and_then(|certs| RootPki::from_der(&certs).map_err(tls_error)))?;
    host.tls.add_value(key, Value::Roots(roots))
}

/// `native.tls.identityPem(cert, key)`: a certificate chain (PEM, leaf first) and its private key (PEM).
#[native(side_effect = "any", path = "tls.identityPem", needs = "runtime")]
fn tls_identity_pem(
    host: &mut HostState,
    key: ScopeKey,
    cert: ArrayBufferArg<'_>,
    private_key: ArrayBufferArg<'_>,
) -> Result<u32, NativeError> {
    let identity =
        cert.with_bytes(|cert| private_key.with_bytes(|private_key| Identity::from_pem(cert, private_key))).map_err(tls_error)?;
    host.tls.add_value(key, Value::Identity(identity))
}

/// `native.tls.identityDer(chain, key)`: `chain` is `[u32 LE length | DER certificate]*`, leaf first; `key` a DER private key.
#[native(side_effect = "any", path = "tls.identityDer", needs = "runtime")]
fn tls_identity_der(
    host: &mut HostState,
    key: ScopeKey,
    chain: ArrayBufferArg<'_>,
    private_key: ArrayBufferArg<'_>,
) -> Result<u32, NativeError> {
    let identity = chain.with_bytes(|chain| {
        unpack(chain).and_then(|certs| private_key.with_bytes(|private_key| Identity::from_der(&certs, private_key)).map_err(tls_error))
    })?;
    host.tls.add_value(key, Value::Identity(identity))
}

/// `native.tls.sessions(limit)`: a client-side resumption cache for at most `limit` server names.
#[native(side_effect = "any", path = "tls.sessions", needs = "runtime")]
fn tls_sessions(host: &mut HostState, key: ScopeKey, limit: u32) -> Result<u32, NativeError> {
    host.tls.add_value(key, Value::Sessions(TlsSessions::create(limit as usize)))
}

/// `native.tls.client(roots, identity, alpn, sessions)`: ids (0 = none for identity and sessions); `alpn` is names joined by `\n`.
#[native(side_effect = "any", path = "tls.client", needs = "runtime")]
fn tls_client(host: &mut HostState, key: ScopeKey, roots: u32, identity: u32, alpn: String, sessions: u32) -> Result<u32, NativeError> {
    let roots = roots_of(host, key, roots)?;
    let identity = (identity != 0).then(|| identity_of(host, key, identity)).transpose()?;
    let sessions = (sessions != 0)
        .then(|| match &*host.tls.value(key, sessions)? {
            Value::Sessions(sessions) => Ok(sessions.clone()),
            _ => Err(NativeError::Errno(errno::BAD_HANDLE)),
        })
        .transpose()?;
    let client = TlsClient::new(ClientOptions { roots, identity, alpn: alpn_list(&alpn), sessions }).map_err(tls_error)?;
    host.tls.add_value(key, Value::Client(client))
}

/// `native.tls.server(identities, clientRoots, alpn)`: `identities` is `u32 LE` identity ids (at least one);
/// `clientRoots` is a roots id that requires client certificates, 0 for none; `alpn` is names joined by `\n`.
#[native(side_effect = "any", path = "tls.server", needs = "runtime")]
fn tls_server(
    host: &mut HostState,
    key: ScopeKey,
    identities: ArrayBufferArg<'_>,
    client_roots: u32,
    alpn: String,
) -> Result<u32, NativeError> {
    let ids: Vec<u32> = identities.with_bytes(|bytes| bytes.as_chunks::<4>().0.iter().map(|chunk| u32::from_le_bytes(*chunk)).collect());
    let identities = ids.into_iter().map(|id| identity_of(host, key, id)).collect::<Result<Vec<_>, _>>()?;
    let client_auth = if client_roots == 0 { ClientAuth::none() } else { ClientAuth::require(roots_of(host, key, client_roots)?) };
    let server = TlsServer::new(ServerOptions { identities, client_auth, alpn: alpn_list(&alpn) }).map_err(tls_error)?;
    host.tls.add_value(key, Value::Server(server))
}

/// `native.tls.release(id)`: forgets a value. Streams made from it keep working. `BadHandle` if unknown.
#[native(side_effect = "any", path = "tls.release", needs = "runtime")]
fn tls_release(host: &mut HostState, key: ScopeKey, id: u32) -> Result<(), NativeError> {
    host.tls.value(key, id)?;
    host.tls.values.remove(&id);
    Ok(())
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

/// `native.tls.connect(io, config, socket, servername)`: Promise `Opened`. Consumes the stream socket
/// `socket` (a failed handshake closes it) and answers a new socket id. `config` is a client configuration id.
#[native(side_effect = "any", path = "tls.connect", needs = "runtime", promise)]
fn tls_connect(
    host: &mut HostState,
    key: ScopeKey,
    io: u32,
    config: u32,
    socket: u32,
    servername: String,
) -> Result<Op<'static, impl Future<Output = Result<Opened, NativeError>> + use<>>, NativeError> {
    let client = match &*host.tls.value(key, config)? {
        Value::Client(client) => client.clone(),
        _ => return Err(NativeError::Errno(errno::BAD_HANDLE)),
    };
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

/// `native.tls.accept(io, config, socket)`: Promise `Opened`. Consumes the accepted stream socket.
/// `config` is a server configuration id.
#[native(side_effect = "any", path = "tls.accept", needs = "runtime", promise)]
fn tls_accept(
    host: &mut HostState,
    key: ScopeKey,
    io: u32,
    config: u32,
    socket: u32,
) -> Result<Op<'static, impl Future<Output = Result<Opened, NativeError>> + use<>>, NativeError> {
    let server = match &*host.tls.value(key, config)? {
        Value::Server(server) => server.clone(),
        _ => return Err(NativeError::Errno(errno::BAD_HANDLE)),
    };
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
