//! `native.http.*`: HTTP/2 sessions on the io loop, built on `origine_h2`.
//!
//! A session is made from a plain `api.net` stream socket or a TLS stream (`api.tls`), either of which it
//! **consumes**; one task per session (`Driver::run`) moves the bytes, spawned on the socket's runtime.
//! Streams are `Exchange`s kept in the session's table by stream id. Everything the guest does is a short
//! synchronous call or one promise on that table. Pull mode only: the guest asks for each event with
//! `next`. A session keeps the program alive until the guest destroys it or the connection ends (its
//! driver's pending read counts as work): lifetime is visible, `destroy` is the release.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::future::Future;
use std::io;
use std::rc::Rc;

use origine_api_core::{NativeError, errno};
use origine_h2::{Body, ConnError, Connection, Exchange, FieldList, H2Error, HeaderKind, Limits, RequestHead, Role, StreamEvent, connect};
use origine_io::rt::AbortHandle;

use crate::HostState;
use crate::decode::ArrayBufferArg;
use crate::native;
use crate::native::{Op, ScopeKey};
use crate::net::Socket;
use crate::sockstream::{SocketTransport, StreamArg};

struct Conn {
    owner: ScopeKey,
    runtime: u32,
    connection: Connection,
    exchanges: RefCell<HashMap<u32, Rc<Exchange>>>,
    abort: AbortHandle,
    socket: Rc<Socket>,
}

impl Conn {
    fn exchange(&self, stream: u32) -> Result<Rc<Exchange>, NativeError> {
        self.exchanges.borrow().get(&stream).cloned().ok_or(NativeError::Errno(errno::BAD_HANDLE))
    }

    fn insert(&self, exchange: Exchange) -> u32 {
        let id = exchange.id();
        self.exchanges.borrow_mut().insert(id, Rc::new(exchange));
        id
    }
}

/// The Host's HTTP/2 sessions. Ids are never reused while the table lives.
#[derive(Default)]
pub(crate) struct HttpState {
    next: u32,
    conns: BTreeMap<u32, Rc<Conn>>,
}

impl HttpState {
    pub(crate) fn clear(&mut self) {
        for conn in std::mem::take(&mut self.conns).into_values() {
            conn.abort.abort();
            conn.socket.shutdown();
        }
    }

    fn conn(&self, owner: ScopeKey, id: u32) -> Result<Rc<Conn>, NativeError> {
        match self.conns.get(&id) {
            Some(conn) if conn.owner == owner => Ok(Rc::clone(conn)),
            _ => Err(NativeError::Errno(errno::BAD_HANDLE)),
        }
    }
}

// ---- errors ----

fn h2_error(e: H2Error) -> NativeError {
    let detailed = |code: u32, subject: String| NativeError::Errno(code).with_subject(subject);
    match e {
        H2Error::InvalidField(m) => detailed(errno::INVALID_INPUT, m),
        // "stream closed", "body already finished", "connection closed": the stream or session is over.
        H2Error::InvalidState(m) if m.contains("closed") || m.contains("finished") || m.contains("closing") => {
            detailed(errno::BROKEN_PIPE, m.into())
        }
        H2Error::InvalidState(m) => detailed(errno::INVALID_INPUT, m.into()),
        H2Error::BadPacking => detailed(errno::INVALID_INPUT, "malformed header list".into()),
        H2Error::Flooded => detailed(errno::PROTOCOL_ERROR, "flood".into()),
        H2Error::BadPreface => detailed(errno::PROTOCOL_ERROR, "not an HTTP/2 preface".into()),
        H2Error::Library(_, m) => detailed(errno::PROTOCOL_ERROR, m),
        _ => NativeError::Errno(errno::UNEXPECTED),
    }
}

fn conn_error(e: ConnError) -> NativeError {
    match e {
        ConnError::Transport(kind, message) => NativeError::from(io::Error::new(kind, message.clone())).with_subject(message),
        ConnError::Protocol(e) => h2_error(e),
        ConnError::Closed => NativeError::Errno(errno::NOT_CONNECTED),
    }
}

fn body_of(mode: u32) -> Result<Body, NativeError> {
    match mode {
        0 => Ok(Body::None),
        1 => Ok(Body::Stream),
        _ => Err(NativeError::Errno(errno::INVALID_INPUT)),
    }
}

fn fields_of(packed: &ArrayBufferArg<'_>) -> Result<FieldList, NativeError> {
    FieldList::from_packed(packed.to_vec()).and_then(|list| list.checked()).map_err(h2_error)
}

// ---- sessions ----

/// `native.http.session(stream, role, streams, headers, window, connection, batch)`: starts an HTTP/2 session over
/// `stream` (a native stream, plain or TLS, nothing is using), which it consumes; `role` is 0 for a client and 1 for
/// a server; the rest are the `Limits`. Returns the session id.
#[native(side_effect = "any", path = "http.session", needs = "runtime")]
#[allow(clippy::too_many_arguments)]
fn http_session(
    host: &mut HostState,
    key: ScopeKey,
    stream: StreamArg<'_>,
    role: u32,
    streams: u32,
    headers: u32,
    window: u32,
    connection: u32,
    batch: u32,
) -> Result<u32, NativeError> {
    let role = match role {
        0 => Role::Client,
        1 => Role::Server,
        _ => return Err(NativeError::Errno(errno::INVALID_INPUT)),
    };
    let lp = stream.conn()?.io.lp(host)?;
    let (io, socket) = stream.take()?;
    if io.owner != key {
        socket.shutdown();
        return Err(NativeError::Errno(errno::BAD_HANDLE));
    }
    let transport = SocketTransport { socket: Rc::clone(&socket), lp };
    let (handle, driver) = connect(role, Limits { streams, headers, window, connection, batch }, transport).map_err(h2_error)?;
    let session = host.http.next.checked_add(1).ok_or(NativeError::Errno(errno::PERMISSION_DENIED))?;
    host.http.next = session;
    let closing = Rc::clone(&socket);
    let abort = host.spawn_detached(
        io.runtime,
        Box::pin(async move {
            let _ = driver.run().await;
            closing.shutdown();
        }),
    )?;
    host.http.conns.insert(
        session,
        Rc::new(Conn { owner: key, runtime: io.runtime, connection: handle, exchanges: RefCell::default(), abort, socket }),
    );
    Ok(session)
}

/// `native.http.ready(session)`: Promise resolved once the peer's SETTINGS arrived (open streams after this).
#[native(side_effect = "any", path = "http.ready", needs = "runtime", promise)]
fn http_ready(
    host: &mut HostState,
    key: ScopeKey,
    session: u32,
) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    let conn = host.http.conn(key, session)?;
    Ok(Op::new(conn.runtime, async move { conn.connection.ready().await.map_err(conn_error) }))
}

/// `native.http.ping(session)`: Promise of the round trip in milliseconds.
#[native(side_effect = "any", path = "http.ping", needs = "runtime", promise)]
fn http_ping(
    host: &mut HostState,
    key: ScopeKey,
    session: u32,
) -> Result<Op<'static, impl Future<Output = Result<f64, NativeError>> + use<>>, NativeError> {
    let conn = host.http.conn(key, session)?;
    Ok(Op::new(conn.runtime, async move { conn.connection.ping().await.map(|d| d.as_secs_f64() * 1000.0).map_err(conn_error) }))
}

/// `native.http.peer(session)`: the number of streams the peer allows at once (`2**32 - 1` while it set no limit; valid
/// after `ready`), or -1 when no new stream can be opened (the peer sent GOAWAY or the connection ended).
#[native(side_effect = "none", path = "http.peer", needs = "runtime")]
fn http_peer(host: &mut HostState, key: ScopeKey, session: u32) -> Result<f64, NativeError> {
    let conn = host.http.conn(key, session)?;
    if conn.connection.going_away() || conn.connection.error().is_some() {
        return Ok(-1.0);
    }
    Ok(f64::from(conn.connection.peer_streams()))
}

/// `native.http.goaway(session)`: starts a graceful close (GOAWAY); streams in flight finish.
#[native(side_effect = "any", path = "http.goaway", needs = "runtime")]
fn http_goaway(host: &mut HostState, key: ScopeKey, session: u32) -> Result<(), NativeError> {
    host.http.conn(key, session)?.connection.close();
    Ok(())
}

/// `native.http.destroy(session)`: ends the session now: stops its task, shuts the transport down and forgets
/// every stream. `BadHandle` if unknown.
#[native(side_effect = "any", path = "http.destroy", needs = "runtime")]
fn http_destroy(host: &mut HostState, key: ScopeKey, session: u32) -> Result<(), NativeError> {
    let conn = host.http.conn(key, session)?;
    host.http.conns.remove(&session);
    conn.abort.abort();
    conn.socket.shutdown();
    conn.exchanges.borrow_mut().clear();
    Ok(())
}

// ---- streams ----

/// `native.http.open(session, method, scheme, authority, path, fields, body)`: opens a request stream and queues
/// its head; `fields` is a packed header list, `body` 0 for none and 1 for a streamed body. Returns the stream id.
#[native(side_effect = "any", path = "http.open", needs = "runtime")]
#[allow(clippy::too_many_arguments)]
fn http_open(
    host: &mut HostState,
    key: ScopeKey,
    session: u32,
    method: String,
    scheme: String,
    authority: String,
    path: String,
    fields: ArrayBufferArg<'_>,
    body: u32,
) -> Result<u32, NativeError> {
    let conn = host.http.conn(key, session)?;
    let fields = fields_of(&fields)?;
    let head = RequestHead { method: &method, scheme: &scheme, authority: &authority, path: &path };
    let exchange = conn.connection.open(&head, &fields, body_of(body)?).map_err(h2_error)?;
    Ok(conn.insert(exchange))
}

/// `native.http.accept(session)`: Promise of the next request stream id (server side), `undefined` once the
/// session is over.
#[native(side_effect = "any", path = "http.accept", needs = "runtime", promise)]
fn http_accept(
    host: &mut HostState,
    key: ScopeKey,
    session: u32,
) -> Result<Op<'static, impl Future<Output = Result<Option<u32>, NativeError>> + use<>>, NativeError> {
    let conn = host.http.conn(key, session)?;
    Ok(Op::new(conn.runtime, async move { Ok(conn.connection.accept().await.map(|exchange| conn.insert(exchange))) }))
}

/// One event of a stream, as the guest gets it. `kind`: 0 headers, 1 data, 2 end, 3 closed (`code` is 0 or the
/// reset code). For headers, `head` is 0 request, 1 response, 2 trailers; `status` is 0 when absent.
#[derive(crate::IntoJs)]
pub struct Ev {
    kind: u32,
    head: u32,
    status: u32,
    method: Option<String>,
    scheme: Option<String>,
    authority: Option<String>,
    path: Option<String>,
    fields: Option<Vec<u8>>,
    last: bool,
    end_stream: bool,
    data: Option<Vec<u8>>,
    code: u32,
}

impl Ev {
    fn of(kind: u32) -> Ev {
        Ev {
            kind,
            head: 0,
            status: 0,
            method: None,
            scheme: None,
            authority: None,
            path: None,
            fields: None,
            last: false,
            end_stream: false,
            data: None,
            code: 0,
        }
    }
}

fn event_of(event: StreamEvent) -> Result<Ev, NativeError> {
    Ok(match event {
        StreamEvent::Headers { kind, pseudo, fields, last, end_stream } => Ev {
            head: match kind {
                HeaderKind::Request => 0,
                HeaderKind::Response => 1,
                HeaderKind::Trailers => 2,
            },
            status: pseudo.status.map_or(0, u32::from),
            method: pseudo.method,
            scheme: pseudo.scheme,
            authority: pseudo.authority,
            path: pseudo.path,
            fields: Some(fields.into_bytes()),
            last,
            end_stream,
            ..Ev::of(0)
        },
        StreamEvent::Data(data) => Ev { data: Some(data), ..Ev::of(1) },
        StreamEvent::End => Ev::of(2),
        StreamEvent::Closed(code) => Ev { code, ..Ev::of(3) },
        StreamEvent::Aborted(e) => return Err(conn_error(e)),
    })
}

/// `native.http.next(session, stream)`: Promise of the stream's next event, `undefined` after its last one. The
/// connection dying with the stream open rejects with the transport's or protocol's error.
#[native(side_effect = "any", path = "http.next", needs = "runtime", promise)]
fn http_next(
    host: &mut HostState,
    key: ScopeKey,
    session: u32,
    stream: u32,
) -> Result<Op<'static, impl Future<Output = Result<Option<Ev>, NativeError>> + use<>>, NativeError> {
    let conn = host.http.conn(key, session)?;
    let exchange = conn.exchange(stream)?;
    Ok(Op::new(conn.runtime, async move {
        match exchange.next().await {
            Some(event) => event_of(event).map(Some),
            None => Ok(None),
        }
    }))
}

/// `native.http.consume(session, stream, bytes)`: gives received body bytes back to the peer's window.
#[native(side_effect = "any", path = "http.consume", needs = "runtime")]
fn http_consume(host: &mut HostState, key: ScopeKey, session: u32, stream: u32, bytes: u32) -> Result<(), NativeError> {
    host.http.conn(key, session)?.exchange(stream)?.consume(bytes as usize);
    Ok(())
}

/// `native.http.respond(session, stream, status, fields, body)`: queues the response head (`body` as in `open`).
#[native(side_effect = "any", path = "http.respond", needs = "runtime")]
fn http_respond(
    host: &mut HostState,
    key: ScopeKey,
    session: u32,
    stream: u32,
    status: u32,
    fields: ArrayBufferArg<'_>,
    body: u32,
) -> Result<(), NativeError> {
    let status = u16::try_from(status).map_err(|_| NativeError::Errno(errno::INVALID_INPUT))?;
    let exchange = host.http.conn(key, session)?.exchange(stream)?;
    exchange.respond(status, &fields_of(&fields)?, body_of(body)?).map_err(h2_error)
}

/// `native.http.send(session, stream, data)`: Promise resolved once `data` (copied now) is queued; it waits while
/// the stream already has more than the window queued and unsent.
#[native(side_effect = "any", path = "http.send", needs = "runtime", promise)]
fn http_send(
    host: &mut HostState,
    key: ScopeKey,
    session: u32,
    stream: u32,
    data: ArrayBufferArg<'_>,
) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    let conn = host.http.conn(key, session)?;
    let exchange = conn.exchange(stream)?;
    let data = data.to_vec();
    Ok(Op::new(conn.runtime, async move { exchange.send(data).await.map_err(h2_error) }))
}

/// `native.http.queued(session, stream)`: bytes accepted by `send` and not yet sent.
#[native(side_effect = "any", path = "http.queued", needs = "runtime")]
fn http_queued(host: &mut HostState, key: ScopeKey, session: u32, stream: u32) -> Result<u32, NativeError> {
    let queued = host.http.conn(key, session)?.exchange(stream)?.queued();
    Ok(u32::try_from(queued).unwrap_or(u32::MAX))
}

/// `native.http.finish(session, stream, trailers)`: ends the body; `trailers` is a packed header list, empty for none.
#[native(side_effect = "any", path = "http.finish", needs = "runtime")]
fn http_finish(host: &mut HostState, key: ScopeKey, session: u32, stream: u32, trailers: ArrayBufferArg<'_>) -> Result<(), NativeError> {
    let trailers = fields_of(&trailers)?;
    let exchange = host.http.conn(key, session)?.exchange(stream)?;
    exchange.finish((!trailers.is_empty()).then_some(trailers)).map_err(h2_error)
}

/// `native.http.reset(session, stream, code)`: RST_STREAM with an HTTP/2 error code.
#[native(side_effect = "any", path = "http.reset", needs = "runtime")]
fn http_reset(host: &mut HostState, key: ScopeKey, session: u32, stream: u32, code: u32) -> Result<(), NativeError> {
    host.http.conn(key, session)?.exchange(stream)?.reset(code);
    Ok(())
}

/// `native.http.release(session, stream)`: forgets the stream. One whose own side is still being written is
/// cancelled (RST `CANCEL`); one whose side is complete finishes quietly.
#[native(side_effect = "any", path = "http.release", needs = "runtime")]
fn http_release(host: &mut HostState, key: ScopeKey, session: u32, stream: u32) -> Result<(), NativeError> {
    let conn = host.http.conn(key, session)?;
    conn.exchange(stream)?;
    conn.exchanges.borrow_mut().remove(&stream);
    Ok(())
}
