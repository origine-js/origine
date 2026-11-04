//! TCP as Rust-defined classes: what `io.tcp.connect` / `io.tcp.listen` return and the shapes they take.
//!
//! A factory returns an **unshaped** object (`TcpStreamUnshaped`, `TcpListenerUnshaped`) that owns the descriptor
//! and flows nothing. `.pulling()` or `.evented()` consumes it (it answers `BadHandle` afterwards) and returns the
//! shaped class: `PullTcpStream` (promise reads) or `EventTcpStream` (`register`), `PullTcpListener` (`accept()`)
//! or `EventTcpListener` (`register('connection')`). An accepted connection is again unshaped. A shaped stream
//! carries the write side (`queued`, `direct`, `end`, `close`); `toEvented()` / `toPulling()` move the connection
//! into the other shape and consume the object. Every object is a cppgc instance owning a [`Front`] over its
//! [`Conn`]: no id reaches JS.

use std::future::Future;
use std::rc::Rc;

use origine_api_core::{ArgError, NativeError, errno};

use crate::conn::{Busy, Conn, Front, Kind};
use crate::decode::ArrayBufferArg;
use crate::fs::{AllocRead, ReadInto};
use crate::native::{Op, host_mut, host_ref};
use crate::net::SockAddr;
use crate::{FromJs, HostState, class, native, pinned, sub};

/// Longest single `read(length)`.
const MAX_READ: f64 = (1u64 << 28) as f64;

/// `{ queued?: { limit } }` of `pulling()` / `evented()`.
#[derive(FromJs)]
pub(crate) struct ShapeOptions {
    queued: Option<QueuedOptions>,
}

#[derive(FromJs)]
struct QueuedOptions {
    limit: Option<u64>,
}

/// The `queued.limit` an options bag asks for (a positive integer), if any.
fn limit_of(options: Option<ShapeOptions>) -> Result<Option<usize>, NativeError> {
    match options.and_then(|options| options.queued).and_then(|queued| queued.limit) {
        Some(0) => Err(ArgError::new(0, "property `queued.limit` to be a positive integer").into()),
        Some(limit) => Ok(Some(usize::try_from(limit).unwrap_or(usize::MAX))),
        None => Ok(None),
    }
}

/// A promise already resolved with `undefined`.
pub(crate) fn resolved<'s>(scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let resolver = v8::PromiseResolver::new(scope).ok_or(NativeError::Errno(errno::UNEXPECTED))?;
    let undefined = v8::undefined(scope).into();
    resolver.resolve(scope, undefined);
    Ok(resolver.get_promise(scope).into())
}

/// Wraps a shaped stream and gives it its own `queued` and `direct` (frozen data properties, so they keep their
/// identity), then freezes it.
fn shaped<'s, T: class::Class>(
    scope: &mut v8::PinScope<'s, '_>,
    value: T,
    conn: &Rc<Conn>,
) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let object = class::wrap(scope, value)?;
    let object = v8::Local::<v8::Object>::try_from(object).map_err(|_| NativeError::Errno(errno::UNEXPECTED))?;
    let queued = class::wrap(scope, SendQueue(Rc::clone(conn)))?;
    let direct = class::wrap(scope, Direct(Rc::clone(conn)))?;
    crate::encode::set(scope, object, "queued", queued)?;
    crate::encode::set(scope, object, "direct", direct)?;
    crate::encode::freeze(scope, object)
}

/// A `PullTcpStream` over `conn`, or a `PullTlsStream` when the conn carries TLS.
fn make_pull<'s>(scope: &mut v8::PinScope<'s, '_>, conn: Rc<Conn>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    #[cfg(feature = "tls")]
    if conn.socket()?.is_tls() {
        return shaped(scope, crate::tls::PullTlsStream(Front::new(Rc::clone(&conn))), &conn);
    }
    shaped(scope, PullTcpStream(Front::new(Rc::clone(&conn))), &conn)
}

/// An `EventTcpStream` over `conn`, or an `EventTlsStream` when the conn carries TLS.
fn make_event<'s>(scope: &mut v8::PinScope<'s, '_>, conn: Rc<Conn>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    #[cfg(feature = "tls")]
    if conn.socket()?.is_tls() {
        return shaped(scope, crate::tls::EventTlsStream(Front::new(Rc::clone(&conn))), &conn);
    }
    shaped(scope, EventTcpStream(Front::new(Rc::clone(&conn))), &conn)
}

// ---- the members of the stream classes ----
//
// The TCP classes here and the TLS classes of `tls.rs` have the same members over a `Front`; these are their bodies.

/// `pulling(options)` of an unshaped stream: consumes it.
pub(crate) fn pulling<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    front: &Front,
    options: Option<ShapeOptions>,
) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let limit = limit_of(options)?;
    let conn = front.take(|_| Ok(()))?;
    if let Some(limit) = limit {
        conn.limit.set(limit);
    }
    make_pull(scope, conn)
}

/// `evented(options)` of an unshaped stream: consumes it.
pub(crate) fn evented<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    front: &Front,
    options: Option<ShapeOptions>,
) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let limit = limit_of(options)?;
    let conn = front.take(|_| Ok(()))?;
    if let Some(limit) = limit {
        conn.limit.set(limit);
    }
    make_event(scope, conn)
}

/// `close()`: frees the descriptor now; an already resolved promise.
pub(crate) fn close<'s>(scope: &mut v8::PinScope<'s, '_>, front: &Front) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    front.close();
    resolved(scope)
}

/// `end(side)`: 'write', 'read' or 'both'.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Side {
    Write,
    Read,
    Both,
}

impl<'s> FromJs<'s> for Side {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        match String::from_js(scope, value, index).as_deref() {
            Ok("write") => Ok(Side::Write),
            Ok("read") => Ok(Side::Read),
            Ok("both") => Ok(Side::Both),
            _ => Err(ArgError::new(index, "'write', 'read' or 'both'")),
        }
    }
}

/// `end(side)` of a shaped stream (see `types/net.d.ts`).
pub(crate) fn end(
    host: &mut HostState,
    front: &Front,
    side: Side,
) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    let conn = front.get()?;
    let lp = conn.io.lp(host)?;
    let runtime = conn.io.runtime;
    Ok(Op::new(runtime, async move {
        if side == Side::Read {
            conn.end_read();
            return Ok(());
        }
        Rc::clone(&conn).end_write(lp).await?;
        if side == Side::Both {
            conn.end_read();
        }
        Ok(())
    }))
}

/// `read(length)` of a pull stream: a `Uint8Array` of 1 to `length` bytes (allocated), empty at end of stream.
pub(crate) fn read(
    scope: &mut v8::PinScope<'_, '_>,
    front: &Front,
    length: f64,
) -> Result<Op<'static, impl Future<Output = Result<AllocRead, NativeError>> + use<>>, NativeError> {
    if length.fract() != 0.0 || !(1.0..=MAX_READ).contains(&length) {
        return Err(NativeError::type_error("length must be an integer in 1..2**28"));
    }
    let len = length as usize;
    let conn = front.get()?;
    let socket = conn.socket()?;
    let lp = conn.io.lp(host_ref(scope)?)?;
    let isolate: &mut v8::Isolate = scope;
    let buf = pinned::alloc_for_read(isolate, len)?;
    let busy = Busy::new(&conn);
    Ok(Op::new(conn.io.runtime, async move {
        let _busy = busy;
        if conn.read_ended.get() {
            return Ok(AllocRead::new(0, None));
        }
        let (read, buf) = socket.recv(&lp, buf).await;
        let n = read?;
        if n == 0 {
            conn.peer_end();
        }
        Ok(AllocRead::new(n, buf.into_store()))
    }))
}

/// `readInto(buffer)` of a pull stream: one read straight into `buffer` (detached while it runs).
pub(crate) fn read_into<'s>(
    host: &mut HostState,
    front: &Front,
    buffer: ArrayBufferArg<'s>,
) -> Result<Op<'s, impl Future<Output = Result<ReadInto, NativeError>> + 'static + use<>>, NativeError> {
    if buffer.is_empty() {
        return Err(NativeError::type_error("buffer must not be empty"));
    }
    let conn = front.get()?;
    let socket = conn.socket()?;
    let lp = conn.io.lp(host)?;
    let (buf, copied) = pinned::pin_for_read(&buffer)?;
    if copied {
        return Err(NativeError::Errno(errno::UNSUPPORTED));
    }
    let busy = Busy::new(&conn);
    Ok(Op::new(conn.io.runtime, async move {
        let _busy = busy;
        let (bytes, buf) = if conn.read_ended.get() {
            (0, buf)
        } else {
            let (read, buf) = socket.recv(&lp, buf).await;
            (read?, buf)
        };
        if bytes == 0 {
            conn.peer_end();
        }
        let store = buf.into_store().ok_or(NativeError::Errno(errno::UNEXPECTED))?;
        Ok(ReadInto::Pinned { bytes, store })
    }))
}

/// `readCopy(buffer)` of a pull stream: one read into `buffer` by copy; the byte count, 0 at end of stream.
pub(crate) fn read_copy<'s>(
    host: &mut HostState,
    front: &Front,
    buffer: ArrayBufferArg<'s>,
) -> Result<Op<'s, impl Future<Output = Result<usize, NativeError>> + 'static + use<>>, NativeError> {
    // 0 means end of stream here: an empty buffer could not tell it from nothing read.
    if buffer.is_empty() {
        return Err(NativeError::type_error("buffer must not be empty"));
    }
    let conn = front.get()?;
    let socket = conn.socket()?;
    let lp = conn.io.lp(host)?;
    let len = buffer.len();
    let busy = Busy::new(&conn);
    let runtime = conn.io.runtime;
    Ok(Op::reading(
        runtime,
        async move {
            let _busy = busy;
            if conn.read_ended.get() {
                return Ok(Vec::new());
            }
            let (read, mut data) = socket.recv(&lp, vec![0u8; len]).await;
            let n = read?;
            if n == 0 {
                conn.peer_end();
            }
            data.truncate(n);
            Ok(data)
        },
        buffer,
    ))
}

/// `toEvented()` of a pull stream: consumes it. `WouldBlock` while a read is pending.
pub(crate) fn to_evented<'s>(scope: &mut v8::PinScope<'s, '_>, front: &Front) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let conn = front.take(|conn| if conn.pending.get() > 0 { Err(NativeError::Errno(errno::WOULD_BLOCK)) } else { Ok(()) })?;
    make_event(scope, conn)
}

/// `toPulling()` of an event stream: consumes it. `Unsupported` once a `data` handler started the flow.
pub(crate) fn to_pulling<'s>(scope: &mut v8::PinScope<'s, '_>, front: &Front) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let conn = front.get()?;
    sub::unsubscribe(host_mut(scope)?, &conn)?;
    let conn = front.take(|_| Ok(()))?;
    make_pull(scope, conn)
}

/// `register(event, handler)` of an event object: returns a `Registration`.
pub(crate) fn register<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    front: &Front,
    event: &str,
    handler: v8::Local<'s, v8::Function>,
) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let conn = front.get()?;
    sub::register(scope, &conn, event, handler)
}

/// `pause()` (`paused` true) or `resume()` of an event object.
pub(crate) fn set_paused(scope: &mut v8::PinScope<'_, '_>, front: &Front, paused: bool) -> Result<(), NativeError> {
    sub::set_paused(scope, &front.conn()?, paused)
}

/// `paused` of an event object.
pub(crate) fn paused(front: &Front) -> Result<bool, NativeError> {
    Ok(front.conn()?.flow.paused())
}

/// A connected stream that flows nothing yet (`io.tcp.connect`, an accepted connection).
pub(crate) struct TcpStreamUnshaped(pub(crate) Front);

impl TcpStreamUnshaped {
    pub(crate) fn new(conn: Rc<Conn>) -> TcpStreamUnshaped {
        TcpStreamUnshaped(Front::new(conn))
    }
}

#[class(path = "net.TcpStreamUnshaped", side_effect = "any", needs = "runtime")]
impl TcpStreamUnshaped {
    /// Consumes this object: a `PullTcpStream` over the connection.
    fn pulling<'s>(
        &self,
        scope: &mut v8::PinScope<'s, '_>,
        options: Option<ShapeOptions>,
    ) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        pulling(scope, &self.0, options)
    }

    /// Consumes this object: an `EventTcpStream` over the connection.
    fn evented<'s>(
        &self,
        scope: &mut v8::PinScope<'s, '_>,
        options: Option<ShapeOptions>,
    ) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        evented(scope, &self.0, options)
    }

    fn close<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        close(scope, &self.0)
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

/// A stream read with promises: `read`, `readInto`, `readCopy`.
pub(crate) struct PullTcpStream(Front);

#[class(path = "net.PullTcpStream", side_effect = "any", needs = "runtime")]
impl PullTcpStream {
    /// One read: a `Uint8Array` of 1 to `length` bytes (allocated), empty at end of stream.
    #[method(promise)]
    fn read(
        &self,
        scope: &mut v8::PinScope<'_, '_>,
        length: f64,
    ) -> Result<Op<'static, impl Future<Output = Result<AllocRead, NativeError>> + use<>>, NativeError> {
        read(scope, &self.0, length)
    }

    /// One read straight into `buffer` (detached while it runs): `{ bytes, buffer }`, `buffer` a new ArrayBuffer over
    /// the same memory. `Unsupported` for a buffer that cannot be detached.
    #[method(promise, name = "readInto")]
    fn read_into<'s>(
        &self,
        host: &mut HostState,
        buffer: ArrayBufferArg<'s>,
    ) -> Result<Op<'s, impl Future<Output = Result<ReadInto, NativeError>> + 'static + use<>>, NativeError> {
        read_into(host, &self.0, buffer)
    }

    /// One read into `buffer` by copy (it is not detached): the byte count, 0 at end of stream.
    #[method(promise, name = "readCopy")]
    fn read_copy<'s>(
        &self,
        host: &mut HostState,
        buffer: ArrayBufferArg<'s>,
    ) -> Result<Op<'s, impl Future<Output = Result<usize, NativeError>> + 'static + use<>>, NativeError> {
        read_copy(host, &self.0, buffer)
    }

    /// Consumes this object: an `EventTcpStream` over the connection. `WouldBlock` while a read is pending.
    #[method(name = "toEvented")]
    fn to_evented<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        to_evented(scope, &self.0)
    }

    #[method(promise)]
    fn end(
        &self,
        host: &mut HostState,
        side: Side,
    ) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
        end(host, &self.0, side)
    }

    fn close<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        close(scope, &self.0)
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

/// A stream that pushes events to handlers held natively.
pub(crate) struct EventTcpStream(Front);

impl PullTcpStream {
    pub(crate) fn front(&self) -> &Front {
        &self.0
    }
}

impl EventTcpStream {
    pub(crate) fn front(&self) -> &Front {
        &self.0
    }
}

#[class(path = "net.EventTcpStream", side_effect = "any", needs = "runtime")]
impl EventTcpStream {
    /// Subscribes `handler` to `data`, `end`, `error`, `drain` or `close`; returns a `Registration`.
    fn register<'s>(
        &self,
        scope: &mut v8::PinScope<'s, '_>,
        event: String,
        handler: v8::Local<'s, v8::Function>,
    ) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        register(scope, &self.0, &event, handler)
    }

    fn pause(&self, scope: &mut v8::PinScope<'_, '_>) -> Result<(), NativeError> {
        set_paused(scope, &self.0, true)
    }

    fn resume(&self, scope: &mut v8::PinScope<'_, '_>) -> Result<(), NativeError> {
        set_paused(scope, &self.0, false)
    }

    #[getter]
    fn paused(&self) -> Result<bool, NativeError> {
        paused(&self.0)
    }

    /// Consumes this object: a `PullTcpStream`. `Unsupported` once a `data` handler started the flow.
    #[method(name = "toPulling")]
    fn to_pulling<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        to_pulling(scope, &self.0)
    }

    #[method(promise)]
    fn end(
        &self,
        host: &mut HostState,
        side: Side,
    ) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
        end(host, &self.0, side)
    }

    fn close<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        close(scope, &self.0)
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

/// `stream.queued`: the send queue. Its bytes leave in call order, before `direct`'s.
pub(crate) struct SendQueue(Rc<Conn>);

/// `limit` as a positive safe integer.
fn positive(value: f64) -> Result<usize, NativeError> {
    if value.fract() != 0.0 || !(1.0..=9_007_199_254_740_991.0).contains(&value) {
        return Err(NativeError::type_error("limit must be a positive integer"));
    }
    Ok(value as usize)
}

impl SendQueue {
    fn spawner(host: &HostState, runtime: u32) -> impl Fn(crate::host::Task) -> Result<origine_io::rt::AbortHandle, NativeError> + '_ {
        move |task| host.spawn_detached(runtime, task)
    }
}

#[class(path = "net.SendQueue", side_effect = "any", needs = "runtime")]
impl SendQueue {
    /// Bytes queued that the kernel has not taken yet.
    #[getter]
    fn bytes(&self) -> usize {
        if self.0.is_closed() { 0 } else { self.0.out.borrow().bytes }
    }

    /// Sends (and ends) waiting for their turn.
    #[getter]
    fn waiting(&self) -> usize {
        if self.0.is_closed() { 0 } else { self.0.out.borrow().waiting() }
    }

    #[getter]
    fn limit(&self) -> usize {
        self.0.limit.get()
    }

    #[setter(name = "limit")]
    fn set_limit(&self, value: f64) -> Result<(), NativeError> {
        self.0.limit.set(positive(value)?);
        Ok(())
    }

    /// Queues as much of `data` as fits under `limit` (copied) and returns the bytes taken; 0 while sends wait.
    fn put(&self, host: &mut HostState, data: ArrayBufferArg<'_>) -> Result<usize, NativeError> {
        let lp = self.0.io.lp(host)?;
        let spawn = SendQueue::spawner(host, self.0.io.runtime);
        data.with_bytes(|bytes| self.0.put(&lp, bytes, &spawn))
    }

    /// Sends all of `data` (copied now) in turn; resolves once it reached the kernel.
    #[method(promise)]
    fn send(
        &self,
        host: &mut HostState,
        data: ArrayBufferArg<'_>,
    ) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
        let lp = self.0.io.lp(host)?;
        if self.0.is_closed() {
            return Err(NativeError::Errno(errno::BAD_HANDLE));
        }
        Ok(Op::new(self.0.io.runtime, Rc::clone(&self.0).send(lp, data.to_vec())))
    }

    /// Resolves once no send waits and the queue is empty.
    #[method(promise)]
    fn drained(&self, host: &mut HostState) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
        self.0.io.lp(host)?;
        if self.0.is_closed() {
            return Err(NativeError::Errno(errno::BAD_HANDLE));
        }
        Ok(Op::new(self.0.io.runtime, Rc::clone(&self.0).drained()))
    }
}

/// `stream.direct`: one non-blocking write with no copy; never overtakes `queued`.
pub(crate) struct Direct(Rc<Conn>);

#[class(path = "net.Direct", side_effect = "any", needs = "runtime")]
impl Direct {
    /// The bytes the kernel took (0 to `data.byteLength`; 0 while the queue is busy).
    fn write(&self, host: &HostState, data: ArrayBufferArg<'_>) -> Result<usize, NativeError> {
        self.0.io.lp(host)?;
        data.with_bytes(|bytes| self.0.direct_write(bytes))
    }
}

/// The `data` event of an `EventTcpStream`, reused for every chunk: valid while its handlers run.
pub(crate) struct DataEvent(pub(crate) Rc<Conn>);

#[class(path = "net.DataEvent", side_effect = "any", needs = "runtime")]
impl DataEvent {
    /// Bytes received (0 once the event is over).
    #[getter]
    fn length(&self, host: &HostState) -> usize {
        sub::current_length(host, &self.0)
    }
}

/// `native.net.take(event)`: the `ArrayBuffer` of the chunk of a `DataEvent` (see `sub::take`), which the glue's
/// `DataEvent.prototype.buffer` wraps in a `Lease`.
#[native(side_effect = "any", path = "net.take", needs = "runtime")]
fn net_take<'s>(scope: &mut v8::PinScope<'s, '_>, event: &DataEvent) -> Result<v8::Local<'s, v8::ArrayBuffer>, NativeError> {
    let conn = Rc::clone(&event.0);
    sub::take(scope, &conn)
}

/// `native.net.release(buffer)`: detaches a lease, which drops its hold on the slab at once (the slab is freed
/// with its last lease). Idempotent for a detached buffer; `Unsupported` for a buffer that is shared or
/// undetachable.
#[native(side_effect = "any", path = "net.release", needs = "runtime")]
fn net_release(buffer: v8::Local<'_, v8::Value>) -> Result<(), NativeError> {
    let buffer = v8::Local::<v8::ArrayBuffer>::try_from(buffer).map_err(|_| NativeError::type_error("buffer must be an ArrayBuffer"))?;
    if buffer.was_detached() {
        return Ok(());
    }
    let store = buffer.get_backing_store();
    if store.is_shared() || store.is_resizable_by_user_javascript() || !buffer.is_detachable() {
        return Err(NativeError::Errno(errno::UNSUPPORTED));
    }
    if buffer.detach(None) != Some(true) || !buffer.was_detached() {
        return Err(NativeError::Errno(errno::UNEXPECTED));
    }
    Ok(())
}

/// What `register` returns.
pub(crate) struct Registration {
    pub(crate) conn: Rc<Conn>,
    pub(crate) hub: u32,
    pub(crate) entry: u64,
    pub(crate) flows: bool,
}

#[class(path = "net.Registration", side_effect = "any", needs = "runtime")]
impl Registration {
    /// Removes the handler; `true` if it was registered.
    fn unregister(&self, host: &mut HostState) -> bool {
        sub::unregister(host, &self.conn, self.hub, self.entry, self.flows)
    }
}

// ---- listeners ----

/// A listening socket that accepts nothing yet (`io.tcp.listen`).
pub(crate) struct TcpListenerUnshaped(pub(crate) Front);

#[class(path = "net.TcpListenerUnshaped", side_effect = "any", needs = "runtime")]
impl TcpListenerUnshaped {
    /// Consumes this object: a `PullTcpListener`.
    fn pulling(&self) -> Result<PullTcpListener, NativeError> {
        Ok(PullTcpListener(Front::new(self.0.take(|_| Ok(()))?)))
    }

    /// Consumes this object: an `EventTcpListener`.
    fn evented(&self) -> Result<EventTcpListener, NativeError> {
        Ok(EventTcpListener(Front::new(self.0.take(|_| Ok(()))?)))
    }

    fn close<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        self.0.close();
        resolved(scope)
    }

    #[getter]
    fn closed(&self, host: &HostState) -> bool {
        self.0.closed(host)
    }

    #[getter(name = "localAddr")]
    fn local_addr(&self) -> Result<SockAddr, NativeError> {
        self.0.local_addr()
    }
}

/// A listener whose connections are awaited.
pub(crate) struct PullTcpListener(Front);

#[class(path = "net.PullTcpListener", side_effect = "any", needs = "runtime")]
impl PullTcpListener {
    /// The next connection, unshaped. Rejects `Canceled` when the listener closes first.
    #[method(promise)]
    fn accept(
        &self,
        host: &mut HostState,
    ) -> Result<Op<'static, impl Future<Output = Result<TcpStreamUnshaped, NativeError>> + use<>>, NativeError> {
        let conn = self.0.get()?;
        let socket = conn.socket()?;
        let lp = conn.io.lp(host)?;
        let busy = Busy::new(&conn);
        Ok(Op::new(conn.io.runtime, async move {
            let _busy = busy;
            let accepted = sub::accept_one(&socket, &lp).await;
            // Let go of the descriptor first: `close()` waits for every accept to have done so.
            let released = Rc::clone(&socket.released);
            drop(socket);
            released.wake();
            // A connection that could not be set up is closed; this accept reports it as reset.
            let stream = accepted.ok_or(NativeError::Errno(errno::CANCELED))??.ok_or(NativeError::Errno(errno::CONNECTION_RESET))?;
            Ok(TcpStreamUnshaped::new(Conn::new(&conn.io, Kind::Stream, crate::net::Socket::stream(stream))))
        }))
    }

    /// Releases the listener; pending accepts reject `Canceled`. Resolves once the port is free (the accepts were
    /// what kept the descriptor open). Idempotent.
    fn close<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        let conn = self.0.get().ok();
        let socket = conn.as_ref().and_then(|conn| conn.socket().ok());
        let open = match &conn {
            Some(conn) => conn.io.open(host_ref(scope)?),
            None => false,
        };
        self.0.close();
        match (conn, socket) {
            (Some(conn), Some(socket)) if open => crate::native::promise(scope, |_| {
                Ok(Op::new(conn.io.runtime, async move {
                    let released = Rc::clone(&socket.released);
                    released.wait_alone(socket).await;
                    Ok::<(), NativeError>(())
                }))
            }),
            _ => resolved(scope),
        }
    }

    #[getter]
    fn closed(&self, host: &HostState) -> bool {
        self.0.closed(host)
    }

    #[getter(name = "localAddr")]
    fn local_addr(&self) -> Result<SockAddr, NativeError> {
        self.0.local_addr()
    }
}

/// A listener that emits `connection` events (an unshaped stream each).
pub(crate) struct EventTcpListener(Front);

#[class(path = "net.EventTcpListener", side_effect = "any", needs = "runtime")]
impl EventTcpListener {
    /// Subscribes `handler` to `connection`, `error` or `close`; returns a `Registration`.
    fn register<'s>(
        &self,
        scope: &mut v8::PinScope<'s, '_>,
        event: String,
        handler: v8::Local<'s, v8::Function>,
    ) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        let conn = self.0.get()?;
        sub::register(scope, &conn, &event, handler)
    }

    fn pause(&self, scope: &mut v8::PinScope<'_, '_>) -> Result<(), NativeError> {
        sub::set_paused(scope, &self.0.conn()?, true)
    }

    fn resume(&self, scope: &mut v8::PinScope<'_, '_>) -> Result<(), NativeError> {
        sub::set_paused(scope, &self.0.conn()?, false)
    }

    #[getter]
    fn paused(&self) -> Result<bool, NativeError> {
        Ok(self.0.conn()?.flow.paused())
    }

    fn close<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        self.0.close();
        resolved(scope)
    }

    #[getter]
    fn closed(&self, host: &HostState) -> bool {
        self.0.closed(host)
    }

    #[getter(name = "localAddr")]
    fn local_addr(&self) -> Result<SockAddr, NativeError> {
        self.0.local_addr()
    }
}
