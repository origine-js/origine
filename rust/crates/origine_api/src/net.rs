//! The socket engine under `io.tcp` and `io.udp`: descriptors on the io loop, the network ceiling, and the
//! conversion of `origine:@std/net` `SocketAddr`s.
//!
//! Sockets are non-blocking, no SIGPIPE, and streams are `TCP_NODELAY`. `accept`, `connect`, `recv` and `send`
//! run on the runtime's loop (`Loop::accept/connect/recv/send`), so they never block the isolate thread:
//! `connect` creates a raw non-blocking `socket(2)` and lets the loop finish the handshake.
//!
//! A socket belongs to the [`crate::conn::Conn`] that the guest's object fronts; an operation in flight holds
//! its own `Rc<Socket>`, so closing never frees a descriptor under a running `recv`. Closing a stream shuts it
//! down so a pending read completes with 0 bytes. No system call wakes an `accept` on every platform, so closing
//! a listener wakes its pending accepts directly ([`Socket::closers`]): they cancel their op and let go.

use std::cell::{Cell, RefCell};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::rc::Rc;
use std::task::Waker;

use origine_api_core::{ArgError, NativeError, errno};

use crate::{FromJs, HostState, IntoJs, native};

/// `MSG_NOSIGNAL` on Linux; macOS has none (the socket gets `SO_NOSIGPIPE` instead).
pub(crate) const SEND_FLAGS: u32 = if cfg!(target_os = "linux") { 0x4000 } else { 0 };
/// `MSG_PEEK`: how a datagram socket waits for a datagram without taking it.
pub(crate) const PEEK: u32 = 2;
/// Peer-address capacity for `accept`.
pub(crate) const ADDR_CAP: usize = 128;

enum Endpoint {
    Listener(TcpListener),
    Stream(TcpStream),
    Datagram(UdpSocket),
    /// A TLS stream over a plain stream socket (its handshake done): reads and writes carry plaintext.
    #[cfg(feature = "tls")]
    Tls(TlsConn),
}

/// The TLS stream of a socket and the plain socket under it (kept alive for its descriptor).
#[cfg(feature = "tls")]
struct TlsConn {
    stream: origine_tls::TlsStream<crate::sockstream::SocketTransport>,
    inner: Rc<Socket>,
}

/// One descriptor (or a TLS stream over one).
pub struct Socket {
    endpoint: Endpoint,
    /// The guest closed it: what a pending `accept` looks at when `closers` wakes it.
    pub(crate) closed: Cell<bool>,
    /// The pending `accept`s of a listener.
    pub(crate) closers: RefCell<Vec<Waker>>,
    /// Told when an operation let go of its reference (what closing a listener waits for).
    pub(crate) released: Rc<Released>,
}

/// Wakes who waits for the other references of a socket to be dropped.
#[derive(Default)]
pub(crate) struct Released(RefCell<Vec<Waker>>);

impl Released {
    pub(crate) fn wake(&self) {
        for waker in self.0.borrow_mut().drain(..) {
            waker.wake();
        }
    }

    /// Resolves once `socket` is the last reference to its socket (and then drops it, closing the descriptor).
    pub(crate) async fn wait_alone(&self, socket: Rc<Socket>) {
        std::future::poll_fn(|cx| {
            if Rc::strong_count(&socket) == 1 {
                return std::task::Poll::Ready(());
            }
            self.0.borrow_mut().push(cx.waker().clone());
            std::task::Poll::Pending
        })
        .await;
    }
}

impl Socket {
    fn new(endpoint: Endpoint) -> Socket {
        Socket { endpoint, closed: Cell::new(false), closers: RefCell::default(), released: Rc::default() }
    }

    /// A connected stream socket.
    pub(crate) fn stream(stream: TcpStream) -> Socket {
        Socket::new(Endpoint::Stream(stream))
    }

    pub(crate) fn listener(listener: TcpListener) -> Socket {
        Socket::new(Endpoint::Listener(listener))
    }

    pub(crate) fn datagram(socket: UdpSocket) -> Socket {
        Socket::new(Endpoint::Datagram(socket))
    }

    /// A TLS socket over `inner`.
    #[cfg(feature = "tls")]
    pub(crate) fn over_tls(stream: origine_tls::TlsStream<crate::sockstream::SocketTransport>, inner: Rc<Socket>) -> Socket {
        Socket::new(Endpoint::Tls(TlsConn { stream, inner }))
    }

    pub(crate) fn fd(&self) -> isize {
        match &self.endpoint {
            Endpoint::Listener(l) => l.as_raw_fd() as isize,
            Endpoint::Stream(s) => s.as_raw_fd() as isize,
            Endpoint::Datagram(d) => d.as_raw_fd() as isize,
            #[cfg(feature = "tls")]
            Endpoint::Tls(t) => t.inner.fd(),
        }
    }

    /// The TLS stream, for a stream made by `tls.connect` / `tls.accept`.
    #[cfg(feature = "tls")]
    pub(crate) fn tls(&self) -> Option<&origine_tls::TlsStream<crate::sockstream::SocketTransport>> {
        match &self.endpoint {
            Endpoint::Tls(t) => Some(&t.stream),
            _ => None,
        }
    }

    /// Whether reads and writes go through TLS (there is then no direct kernel lane).
    pub(crate) fn is_tls(&self) -> bool {
        #[cfg(feature = "tls")]
        return matches!(self.endpoint, Endpoint::Tls(_));
        #[cfg(not(feature = "tls"))]
        false
    }

    /// The datagram socket of a UDP endpoint.
    pub(crate) fn udp(&self) -> Option<&UdpSocket> {
        match &self.endpoint {
            Endpoint::Datagram(d) => Some(d),
            _ => None,
        }
    }

    /// One read into `buf`: the bytes received (0 = end of stream; for TLS, after the peer's `close_notify`).
    pub(crate) async fn recv<B: origine_io::IoBufMut>(&self, lp: &origine_io::Loop, mut buf: B) -> (std::io::Result<usize>, B) {
        match &self.endpoint {
            #[cfg(feature = "tls")]
            Endpoint::Tls(t) => {
                let total = buf.bytes_total();
                if total == 0 {
                    return (Ok(0), buf);
                }
                let ptr = buf.stable_mut_ptr();
                // SAFETY: `buf` owns `total` writable bytes at `ptr`.
                unsafe { std::ptr::write_bytes(ptr, 0, total) };
                // SAFETY: as above, now initialised; `buf` outlives the await below and nothing else touches the bytes.
                let window = unsafe { std::slice::from_raw_parts_mut(ptr, total) };
                match t.stream.read(window).await {
                    Ok(n) => {
                        // SAFETY: the first `n` bytes were just written.
                        unsafe { buf.set_init(n.min(total)) };
                        (Ok(n), buf)
                    }
                    Err(error) => (Err(error.into()), buf),
                }
            }
            _ => lp.recv(self.fd(), buf, 0).await,
        }
    }

    /// One write of (a prefix of) `buf`: the bytes taken. A TLS stream takes all of it.
    pub(crate) async fn send<B: origine_io::IoBuf>(&self, lp: &origine_io::Loop, buf: B) -> (std::io::Result<usize>, B) {
        match &self.endpoint {
            #[cfg(feature = "tls")]
            Endpoint::Tls(t) => {
                let len = buf.bytes_init();
                // SAFETY: `buf` owns `len` initialised bytes at `stable_ptr` for as long as it lives.
                let bytes = unsafe { std::slice::from_raw_parts(buf.stable_ptr(), len) };
                match t.stream.write(bytes).await {
                    Ok(()) => (Ok(len), buf),
                    Err(error) => (Err(error.into()), buf),
                }
            }
            _ => lp.send(self.fd(), buf, SEND_FLAGS).await,
        }
    }

    /// A non-blocking write: the bytes the kernel took, `Ok(0)` when it would block. A TLS stream has no direct
    /// lane and always answers `Ok(0)`.
    pub(crate) fn try_write(&self, bytes: &[u8]) -> std::io::Result<usize> {
        use std::io::Write;
        match &self.endpoint {
            Endpoint::Stream(stream) => match (&*stream).write(bytes) {
                Err(error) if matches!(error.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted) => Ok(0),
                other => other,
            },
            _ => Ok(0),
        }
    }

    /// Ends the write side: the FIN (for TLS, `close_notify` first). Reads on this side keep working.
    pub(crate) async fn finish_write(&self) {
        match &self.endpoint {
            #[cfg(feature = "tls")]
            Endpoint::Tls(t) => {
                let _ = t.stream.shutdown().await;
                t.inner.shutdown_write();
            }
            _ => self.shutdown_write(),
        }
    }

    /// Sends the FIN: the peer reads end of stream, reads on this side keep working.
    pub(crate) fn shutdown_write(&self) {
        if let Endpoint::Stream(stream) = &self.endpoint {
            let _ = stream.shutdown(Shutdown::Write);
        }
    }

    /// The local and peer addresses (the peer is `None` for a listener and an unconnected datagram socket).
    pub(crate) fn addrs(&self) -> (Option<SocketAddr>, Option<SocketAddr>) {
        match &self.endpoint {
            Endpoint::Listener(l) => (l.local_addr().ok(), None),
            Endpoint::Stream(s) => (s.local_addr().ok(), s.peer_addr().ok()),
            Endpoint::Datagram(d) => (d.local_addr().ok(), d.peer_addr().ok()),
            #[cfg(feature = "tls")]
            Endpoint::Tls(t) => t.inner.addrs(),
        }
    }

    /// Wakes pending reads (they complete with 0 bytes) and accepts (they reject `Canceled`) when the guest
    /// closes the socket.
    pub(crate) fn shutdown(&self) {
        self.closed.set(true);
        for waker in self.closers.borrow_mut().drain(..) {
            waker.wake();
        }
        match &self.endpoint {
            Endpoint::Stream(stream) => {
                let _ = stream.shutdown(Shutdown::Both);
            }
            #[cfg(feature = "tls")]
            Endpoint::Tls(t) => t.inner.shutdown(),
            Endpoint::Listener(_) | Endpoint::Datagram(_) => {}
        }
    }
}

#[cfg(target_os = "macos")]
fn no_sigpipe(fd: i32) {
    unsafe extern "C" {
        fn setsockopt(fd: i32, level: i32, name: i32, value: *const std::ffi::c_void, len: u32) -> i32;
    }
    const SOL_SOCKET: i32 = 0xffff;
    const SO_NOSIGPIPE: i32 = 0x1022;
    let one: i32 = 1;
    // SAFETY: `fd` is a live socket of the caller; `one` is a valid 4-byte option value that outlives the call,
    // and `len` is its size.
    unsafe { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, std::ptr::from_ref(&one).cast(), 4) };
}

#[cfg(not(target_os = "macos"))]
fn no_sigpipe(_: i32) {}

/// Non-blocking, no-delay, no SIGPIPE.
pub(crate) fn prepare(stream: &TcpStream) -> Result<(), NativeError> {
    stream.set_nonblocking(true)?;
    stream.set_nodelay(true)?;
    no_sigpipe(stream.as_raw_fd());
    Ok(())
}

/// What the ceiling is asked about an address.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Use {
    /// Listening on it (`io.tcp.listen`, `io.udp.bind`).
    Listen,
    /// Reaching it (`io.tcp.connect`, a datagram's destination).
    Connect,
}

/// `addr` if the embedder's network ceiling allows `what` on it, else `PermissionDenied` with the address as the
/// detail. The ceiling canonicalises (`::ffff:a.b.c.d` is `a.b.c.d`) and is about addresses, never names.
pub(crate) fn allowed(host: &HostState, addr: SocketAddr, what: Use) -> Result<SocketAddr, NativeError> {
    let permitted = match what {
        Use::Listen => host.net.allows_listen(&addr),
        Use::Connect => host.net.allows_connect(&addr),
    };
    if permitted { Ok(addr) } else { Err(NativeError::Errno(errno::PERMISSION_DENIED).with_subject(addr.to_string())) }
}

unsafe extern "C" {
    fn socket(domain: i32, kind: i32, protocol: i32) -> i32;
}

const AF_INET: i32 = 2;
const AF_INET6: i32 = if cfg!(target_os = "linux") { 10 } else { 30 };
const SOCK_STREAM: i32 = 1;
const SOCK_DGRAM: i32 = 2;
/// Linux creates close-on-exec sockets atomically; macOS has no such flag.
const SOCK_CLOEXEC: i32 = if cfg!(target_os = "linux") { 0x80000 } else { 0 };

/// A fresh non-blocking stream socket for `addr`'s family (no SIGPIPE), not connected.
pub(crate) fn new_stream(addr: &SocketAddr) -> Result<TcpStream, NativeError> {
    new_socket(addr, SOCK_STREAM).map(TcpStream::from)
}

/// A fresh non-blocking datagram socket for `addr`'s family, not connected.
#[cfg(feature = "dns")]
pub(crate) fn new_datagram(addr: &SocketAddr) -> Result<OwnedFd, NativeError> {
    let fd = new_socket(addr, SOCK_DGRAM)?;
    UdpSocket::from(fd.try_clone()?).set_nonblocking(true)?;
    Ok(fd)
}

fn new_socket(addr: &SocketAddr, kind: i32) -> Result<OwnedFd, NativeError> {
    let domain = if addr.is_ipv4() { AF_INET } else { AF_INET6 };
    // SAFETY: plain `socket(2)` call with constant arguments.
    let fd = unsafe { socket(domain, kind | SOCK_CLOEXEC, 0) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    // SAFETY: `fd` was just returned by `socket` and nothing else owns it.
    let owned = unsafe { OwnedFd::from_raw_fd(fd) };
    if kind == SOCK_STREAM {
        // `set_nodelay` fails on an unconnected socket on some systems; the option is applied after connect.
        let stream = TcpStream::from(owned);
        stream.set_nonblocking(true)?;
        no_sigpipe(stream.as_raw_fd());
        return Ok(OwnedFd::from(stream));
    }
    Ok(owned)
}

/// A bound, non-blocking datagram socket on `addr`.
pub(crate) fn bind_datagram(addr: SocketAddr) -> Result<UdpSocket, NativeError> {
    let socket = UdpSocket::bind(addr)?;
    socket.set_nonblocking(true)?;
    no_sigpipe(socket.as_raw_fd());
    Ok(socket)
}

/// The platform's native `sockaddr_in` / `sockaddr_in6` bytes for `addr`.
pub(crate) fn sockaddr_bytes(addr: &SocketAddr) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(28);
    let family = |bytes: &mut Vec<u8>, len: u8, family: i32| {
        if cfg!(target_os = "linux") {
            bytes.extend_from_slice(&(family as u16).to_ne_bytes());
        } else {
            bytes.extend_from_slice(&[len, family as u8]);
        }
    };
    match addr {
        SocketAddr::V4(v4) => {
            family(&mut bytes, 16, AF_INET);
            bytes.extend_from_slice(&v4.port().to_be_bytes());
            bytes.extend_from_slice(&v4.ip().octets());
            bytes.extend_from_slice(&[0; 8]);
        }
        SocketAddr::V6(v6) => {
            family(&mut bytes, 28, AF_INET6);
            bytes.extend_from_slice(&v6.port().to_be_bytes());
            bytes.extend_from_slice(&v6.flowinfo().to_ne_bytes());
            bytes.extend_from_slice(&v6.ip().octets());
            bytes.extend_from_slice(&v6.scope_id().to_ne_bytes());
        }
    }
    bytes
}

/// Connects a fresh stream socket to `addr` on `lp` (the loop finishes the handshake).
pub(crate) async fn connect_stream(lp: &origine_io::Loop, addr: SocketAddr) -> Result<TcpStream, NativeError> {
    let stream = new_stream(&addr)?;
    lp.connect(stream.as_raw_fd() as isize, sockaddr_bytes(&addr)).await.map_err(|error| NativeError::Errno(errno::errno_of(&error)))?;
    let _ = stream.set_nodelay(true);
    Ok(stream)
}

// ---- `origine:@std/net` addresses ----
//
// `SocketAddr` is a sealed JS class of the glue (`glue/addr.js`), whose state is private. The glue registers two
// converters per realm (`net.link`): one gives `[octets, port, scopeId]` of a genuine `SocketAddr` (anything else:
// `undefined`), the other makes a `SocketAddr` from them. No text crosses.

const TO_NATIVE: &str = "origine:net.addrParts";
const FROM_NATIVE: &str = "origine:net.addrMake";

fn private<'s>(scope: &mut v8::PinScope<'s, '_>, name: &str) -> Option<v8::Local<'s, v8::Private>> {
    let name = v8::String::new(scope, name)?;
    Some(v8::Private::for_api(scope, Some(name)))
}

fn converter<'s>(scope: &mut v8::PinScope<'s, '_>, name: &str) -> Option<v8::Local<'s, v8::Function>> {
    let key = private(scope, name)?;
    let global = scope.get_current_context().global(scope);
    global.get_private(scope, key).and_then(|f| v8::Local::<v8::Function>::try_from(f).ok())
}

/// `native.net.link(toParts, fromParts)`: the realm's `SocketAddr` converters (see above). Called once per realm.
#[native(side_effect = "any", path = "net.link", needs = "runtime")]
fn net_link<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    to_parts: v8::Local<'s, v8::Function>,
    from_parts: v8::Local<'s, v8::Function>,
) -> Result<(), NativeError> {
    let global = scope.get_current_context().global(scope);
    for (name, function) in [(TO_NATIVE, to_parts), (FROM_NATIVE, from_parts)] {
        let key = private(scope, name).ok_or(NativeError::Errno(errno::UNEXPECTED))?;
        global.set_private(scope, key, function.into());
    }
    Ok(())
}

/// An `origine:@std/net` `SocketAddr` argument or result.
#[derive(Clone, Copy, Debug)]
pub(crate) struct SockAddr(pub(crate) SocketAddr);

/// `[octets, port, scopeId]` as an address.
fn from_parts<'s>(scope: &mut v8::PinScope<'s, '_>, parts: v8::Local<'s, v8::Value>) -> Option<SocketAddr> {
    let parts = v8::Local::<v8::Array>::try_from(parts).ok()?;
    let octets = parts.get_index(scope, 0)?;
    let octets = v8::Local::<v8::Uint8Array>::try_from(octets).ok()?;
    let mut bytes = [0u8; 16];
    let len = octets.byte_length();
    if len != 4 && len != 16 {
        return None;
    }
    octets.copy_contents(&mut bytes[..len]);
    let number = |scope: &mut v8::PinScope<'s, '_>, at: u32| parts.get_index(scope, at).and_then(|v| v.uint32_value(scope));
    let port = u16::try_from(number(scope, 1)?).ok()?;
    let scope_id = number(scope, 2)?;
    Some(if len == 4 {
        SocketAddr::from((std::net::Ipv4Addr::new(bytes[0], bytes[1], bytes[2], bytes[3]), port))
    } else {
        SocketAddr::V6(std::net::SocketAddrV6::new(std::net::Ipv6Addr::from(bytes), port, 0, scope_id))
    })
}

impl<'s> FromJs<'s> for SockAddr {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        let expected = || ArgError::new(index, "a SocketAddr");
        let to_parts = converter(scope, TO_NATIVE).ok_or_else(expected)?;
        v8::tc_scope!(let tc, scope);
        let undefined = v8::undefined(tc).into();
        let parts = to_parts.call(tc, undefined, &[value]).ok_or_else(expected)?;
        from_parts(tc, parts).map(SockAddr).ok_or_else(expected)
    }
}

impl<'s> IntoJs<'s> for SockAddr {
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        let make = converter(scope, FROM_NATIVE).ok_or(NativeError::Errno(errno::UNEXPECTED))?;
        let (octets, scope_id) = match self.0 {
            SocketAddr::V4(v4) => (v4.ip().octets().to_vec(), 0),
            SocketAddr::V6(v6) => (v6.ip().octets().to_vec(), v6.scope_id()),
        };
        let octets = octets.into_js(scope)?;
        let port = v8::Integer::new_from_unsigned(scope, u32::from(self.0.port())).into();
        let scope_id = v8::Integer::new_from_unsigned(scope, scope_id).into();
        let undefined = v8::undefined(scope).into();
        make.call(scope, undefined, &[octets, port, scope_id]).ok_or(NativeError::Errno(errno::UNEXPECTED))
    }
}
