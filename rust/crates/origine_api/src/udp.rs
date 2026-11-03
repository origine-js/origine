//! UDP as Rust-defined classes: `io.udp.bind(addr)` returns a `UdpSocketUnshaped`, which `.pulling()` turns into a
//! `PullUdpSocket` (`recvFrom`) and `.evented()` into an `EventUdpSocket` (`register('datagram')`). Both send with
//! `sendTo` and may `connect` to one peer. The network ceiling applies to the bound address (`listen` rules) and to
//! every destination (`connect` rules): a datagram cannot reach what a connection could not.
//!
//! The loop has no `recvfrom`: a receive waits for a datagram with a one-byte `MSG_PEEK` on the loop, then takes it
//! with a non-blocking `recvfrom(2)` on the isolate thread.

use std::future::Future;
use std::rc::Rc;

use origine_api_core::{NativeError, errno};

use crate::conn::{Busy, Conn, Front};
use crate::decode::ArrayBufferArg;
use crate::native::{Op, host_ref};
use crate::net::{SockAddr, Use, allowed};
use crate::stream::resolved;
use crate::{HostState, IntoJs, class, native, sub};

/// The largest datagram `recvFrom` takes.
const MAX_DATAGRAM: f64 = 65535.0;

/// What `recvFrom` resolves: `{ data, addr }`.
pub(crate) struct Received(Vec<u8>, std::net::SocketAddr);

impl<'s> IntoJs<'s> for Received {
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        sub::datagram_value(scope, self.0, self.1)
    }
}

/// `sendTo(data, addr?)`: one datagram to `addr` (checked against the ceiling's `connect` rules) or, without it, to
/// the connected peer. Resolves the bytes sent.
fn send_to(
    host: &HostState,
    front: &Front,
    data: &ArrayBufferArg<'_>,
    to: Option<SockAddr>,
) -> Result<Op<'static, impl Future<Output = Result<usize, NativeError>> + use<>>, NativeError> {
    let conn = front.get()?;
    let socket = conn.socket()?;
    let lp = conn.io.lp(host)?;
    let to = to.map(|SockAddr(addr)| allowed(host, addr, Use::Connect)).transpose()?;
    if to.is_none() && conn.peer.get().is_none() {
        return Err(NativeError::Errno(errno::NOT_CONNECTED));
    }
    let bytes = data.to_vec();
    Ok(Op::new(conn.io.runtime, async move {
        let udp = socket.udp().ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
        sub::send_to(udp, &lp, &bytes, to).await
    }))
}

/// `connect(addr)`: datagrams go to `addr` by default and only its datagrams are received.
fn connect(host: &HostState, front: &Front, addr: SockAddr) -> Result<(), NativeError> {
    let conn = front.get()?;
    conn.io.lp(host)?;
    let addr = allowed(host, addr.0, Use::Connect)?;
    let socket = conn.socket()?;
    socket.udp().ok_or(NativeError::Errno(errno::BAD_HANDLE))?.connect(addr)?;
    conn.peer.set(Some(addr));
    Ok(())
}

/// A bound datagram socket that receives nothing yet.
pub(crate) struct UdpSocketUnshaped(pub(crate) Front);

#[class(path = "net.UdpSocketUnshaped", side_effect = "any", needs = "runtime")]
impl UdpSocketUnshaped {
    /// Consumes this object: a `PullUdpSocket`.
    fn pulling(&self) -> Result<PullUdpSocket, NativeError> {
        Ok(PullUdpSocket(Front::new(self.0.take(|_| Ok(()))?)))
    }

    /// Consumes this object: an `EventUdpSocket`.
    fn evented(&self) -> Result<EventUdpSocket, NativeError> {
        Ok(EventUdpSocket(Front::new(self.0.take(|_| Ok(()))?)))
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

/// A datagram socket read with promises.
pub(crate) struct PullUdpSocket(Front);

#[class(path = "net.PullUdpSocket", side_effect = "any", needs = "runtime")]
impl PullUdpSocket {
    /// The next datagram: `{ data, addr }`, `data` its first `length` bytes at most (the rest is dropped, as
    /// `recvfrom(2)` does).
    #[method(promise, name = "recvFrom")]
    fn recv_from(
        &self,
        host: &HostState,
        length: f64,
    ) -> Result<Op<'static, impl Future<Output = Result<Received, NativeError>> + use<>>, NativeError> {
        if length.fract() != 0.0 || !(1.0..=MAX_DATAGRAM).contains(&length) {
            return Err(NativeError::type_error("length must be an integer in 1..65535"));
        }
        let conn = self.0.get()?;
        let socket = conn.socket()?;
        let lp = conn.io.lp(host)?;
        let busy = Busy::new(&conn);
        Ok(Op::new(conn.io.runtime, async move {
            let _busy = busy;
            let (data, from) = sub::recv_from(&socket, &lp, length as usize).await?;
            Ok(Received(data, from))
        }))
    }

    #[method(promise, name = "sendTo")]
    fn send_to(
        &self,
        host: &HostState,
        data: ArrayBufferArg<'_>,
        addr: Option<SockAddr>,
    ) -> Result<Op<'static, impl Future<Output = Result<usize, NativeError>> + use<>>, NativeError> {
        send_to(host, &self.0, &data, addr)
    }

    fn connect(&self, host: &HostState, addr: SockAddr) -> Result<(), NativeError> {
        connect(host, &self.0, addr)
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

    #[getter(name = "peerAddr")]
    fn peer_addr(&self) -> Result<SockAddr, NativeError> {
        self.0.peer_addr()
    }
}

/// A datagram socket that emits `datagram` events (`{ data, addr }`).
pub(crate) struct EventUdpSocket(Front);

#[class(path = "net.EventUdpSocket", side_effect = "any", needs = "runtime")]
impl EventUdpSocket {
    /// Subscribes `handler` to `datagram`, `error` or `close`; returns a `Registration`.
    fn register<'s>(
        &self,
        scope: &mut v8::PinScope<'s, '_>,
        event: String,
        handler: v8::Local<'s, v8::Function>,
    ) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        let conn: Rc<Conn> = self.0.get()?;
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

    #[method(promise, name = "sendTo")]
    fn send_to(
        &self,
        host: &HostState,
        data: ArrayBufferArg<'_>,
        addr: Option<SockAddr>,
    ) -> Result<Op<'static, impl Future<Output = Result<usize, NativeError>> + use<>>, NativeError> {
        send_to(host, &self.0, &data, addr)
    }

    fn connect(&self, scope: &mut v8::PinScope<'_, '_>, addr: SockAddr) -> Result<(), NativeError> {
        connect(host_ref(scope)?, &self.0, addr)
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

    #[getter(name = "peerAddr")]
    fn peer_addr(&self) -> Result<SockAddr, NativeError> {
        self.0.peer_addr()
    }
}

/// The `datagram` event of an `EventUdpSocket`: one whole datagram. `length` and `from` are its size and source;
/// the glue's `buffer()` hands its bytes out once as a `Lease` (`native.net.takeDatagram`), which stays valid
/// across awaits until it is released.
pub(crate) struct DatagramEvent {
    data: std::cell::RefCell<Option<Vec<u8>>>,
    length: usize,
    from: std::net::SocketAddr,
}

impl DatagramEvent {
    pub(crate) fn new(data: Vec<u8>, from: std::net::SocketAddr) -> DatagramEvent {
        DatagramEvent { length: data.len(), data: std::cell::RefCell::new(Some(data)), from }
    }
}

#[class(path = "net.DatagramEvent", side_effect = "any", needs = "runtime")]
impl DatagramEvent {
    /// Bytes of the datagram.
    #[getter]
    fn length(&self) -> usize {
        self.length
    }

    /// Where it came from.
    #[getter]
    fn from(&self) -> SockAddr {
        SockAddr(self.from)
    }
}

/// `native.net.takeDatagram(event)`: the bytes of a `DatagramEvent` as a new `ArrayBuffer` of exactly their length
/// (the one copy, out of the receive buffer into V8 memory). Once per event: `StaleHandle` afterwards (the glue
/// keeps the lease it made).
#[native(side_effect = "any", path = "net.takeDatagram", needs = "runtime")]
fn net_take_datagram<'s>(scope: &mut v8::PinScope<'s, '_>, event: &DatagramEvent) -> Result<v8::Local<'s, v8::ArrayBuffer>, NativeError> {
    let data = event.data.borrow_mut().take().ok_or(NativeError::Errno(errno::STALE_HANDLE))?;
    let buffer = v8::ArrayBuffer::new(scope, data.len());
    if let Some(target) = buffer.data().filter(|_| !data.is_empty()) {
        // SAFETY: `target` is the fresh buffer's `data.len()` writable bytes; `data` is Rust memory.
        unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), target.as_ptr().cast::<u8>(), data.len()) };
    }
    Ok(buffer)
}
