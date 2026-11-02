//! `native.net.*`: loopback TCP on the io loop.
//!
//! Sockets are non-blocking, `TCP_NODELAY`, no SIGPIPE, and live in the Host's socket table,
//! bound to the runtime they were created on. `accept`, `connect` and `read` run on that
//! runtime's loop (`Loop::accept/connect/recv/send`), so they never block the isolate thread:
//! `connect` creates a raw non-blocking `socket(2)` and lets the loop finish the handshake.
//! Only loopback destinations are allowed (`PermissionDenied` otherwise): there is no embedder
//! permission for wider network access yet. IP literals are used as given; `localhost` never
//! reaches the system resolver (RFC 6761): `connect` tries `127.0.0.1` then `::1`, `listen`
//! binds `127.0.0.1`.
//!
//! An operation in flight holds an `Rc<Socket>`, so `close` can never free a descriptor under a
//! running `recv`; closing a stream shuts it down so a pending read completes with 0 bytes. No
//! system call wakes an `accept` on every platform, so closing a listener wakes its pending accepts
//! directly: they cancel their op, reject `Canceled` and let go of the descriptor.

use std::cell::{Cell, RefCell};
use std::future::{Future, poll_fn};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::pin::pin;
use std::rc::Rc;
use std::task::{Poll, Waker};

use origine_api_core::{NativeError, errno, pin};

use crate::HostState;
use crate::decode::ArrayBufferArg;
use crate::fs::{AllocRead, ReadInto};
use crate::native;
use crate::native::{Op, ScopeKey, host_mut};
use crate::pinned;

/// `MSG_NOSIGNAL` on Linux; macOS has none (the socket gets `SO_NOSIGPIPE` instead).
pub(crate) const SEND_FLAGS: u32 = if cfg!(target_os = "linux") { 0x4000 } else { 0 };
/// Pending-connection queue and peer-address capacity for `accept`.
pub(crate) const ADDR_CAP: usize = 128;

enum Endpoint {
    Listener(TcpListener),
    Stream(TcpStream),
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

/// A socket of the Host table.
pub struct Socket {
    owner: ScopeKey,
    runtime: u32,
    endpoint: Endpoint,
    /// The guest closed it: what a pending `accept` looks at when `closers` wakes it.
    closed: Cell<bool>,
    /// The pending `accept`s of a listener.
    closers: RefCell<Vec<Waker>>,
}

impl Socket {
    pub(crate) fn owner(&self) -> ScopeKey {
        self.owner
    }

    pub(crate) fn runtime(&self) -> u32 {
        self.runtime
    }

    pub(crate) fn fd(&self) -> isize {
        match &self.endpoint {
            Endpoint::Listener(l) => l.as_raw_fd() as isize,
            Endpoint::Stream(s) => s.as_raw_fd() as isize,
            #[cfg(feature = "tls")]
            Endpoint::Tls(t) => t.inner.fd(),
        }
    }

    pub(crate) fn is_listener(&self) -> bool {
        matches!(self.endpoint, Endpoint::Listener(_))
    }

    /// The TLS stream and the plain socket under it, for a stream socket made by `tls.connect` / `tls.accept`.
    #[cfg(feature = "tls")]
    pub(crate) fn tls(&self) -> Option<(&origine_tls::TlsStream<crate::sockstream::SocketTransport>, &Rc<Socket>)> {
        match &self.endpoint {
            Endpoint::Tls(t) => Some((&t.stream, &t.inner)),
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

    /// A TLS socket of `owner` on `runtime` over `inner`.
    #[cfg(feature = "tls")]
    pub(crate) fn over_tls(
        owner: ScopeKey,
        runtime: u32,
        stream: origine_tls::TlsStream<crate::sockstream::SocketTransport>,
        inner: Rc<Socket>,
    ) -> Socket {
        Socket::new(owner, runtime, Endpoint::Tls(TlsConn { stream, inner }))
    }

    /// A stream socket (accepted by a subscription's pump) of `owner` on `runtime`.
    pub(crate) fn accepted(owner: ScopeKey, runtime: u32, stream: TcpStream) -> Socket {
        Socket::new(owner, runtime, Endpoint::Stream(stream))
    }

    fn new(owner: ScopeKey, runtime: u32, endpoint: Endpoint) -> Socket {
        Socket { owner, runtime, endpoint, closed: Cell::new(false), closers: RefCell::default() }
    }

    /// Wakes pending reads (they complete with 0 bytes) and accepts (they reject `Canceled`) when the
    /// guest closes the socket.
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
            Endpoint::Listener(_) => {}
        }
    }
}

/// `{ id, port }`: a new socket and its (local for a listener, remote for a stream) port.
#[derive(crate::IntoJs)]
pub struct Opened {
    id: u32,
    port: u32,
}

#[cfg(target_os = "macos")]
fn no_sigpipe(stream: &TcpStream) {
    unsafe extern "C" {
        fn setsockopt(fd: i32, level: i32, name: i32, value: *const std::ffi::c_void, len: u32) -> i32;
    }
    const SOL_SOCKET: i32 = 0xffff;
    const SO_NOSIGPIPE: i32 = 0x1022;
    let one: i32 = 1;
    // SAFETY: `fd` is a live socket owned by `stream`; `one` is a valid 4-byte option value that
    // outlives the call, and `len` is its size.
    unsafe { setsockopt(stream.as_raw_fd(), SOL_SOCKET, SO_NOSIGPIPE, std::ptr::from_ref(&one).cast(), 4) };
}

#[cfg(not(target_os = "macos"))]
fn no_sigpipe(_: &TcpStream) {}

/// Non-blocking, no-delay, no SIGPIPE.
pub(crate) fn prepare(stream: &TcpStream) -> Result<(), NativeError> {
    stream.set_nonblocking(true)?;
    stream.set_nodelay(true)?;
    no_sigpipe(stream);
    Ok(())
}

/// The addresses `host:port` names, each kept only if the network ceiling allows it (`listen`: to listen on, else to
/// connect to). An IP literal is used as given; `localhost` is 127.0.0.1 then ::1 and is never looked up (RFC 6761).
/// A name that is not a literal is refused: `api.net` does not resolve, so look it up with `api.dns` and pass the
/// address, which is what the ceiling is checked against (a name could lead anywhere). `PermissionDenied` when
/// nothing is allowed, with the address (or the name) as the detail.
pub(crate) fn allowed(host: &HostState, name: &str, port: u32, listen: bool) -> Result<Vec<SocketAddr>, NativeError> {
    let port = u16::try_from(port).map_err(|_| NativeError::Errno(errno::INVALID_INPUT))?;
    let ips = if name.eq_ignore_ascii_case("localhost") {
        vec![IpAddr::V4(Ipv4Addr::LOCALHOST), IpAddr::V6(Ipv6Addr::LOCALHOST)]
    } else {
        match name.parse::<IpAddr>() {
            Ok(ip) => vec![ip],
            Err(_) => return Err(NativeError::Errno(errno::PERMISSION_DENIED).with_subject(name.to_owned())),
        }
    };
    let candidates: Vec<SocketAddr> = ips.into_iter().map(|ip| SocketAddr::new(ip, port)).collect();
    let permitted = |addr: &SocketAddr| if listen { host.net.allows_listen(addr) } else { host.net.allows_connect(addr) };
    let kept: Vec<SocketAddr> = candidates.iter().copied().filter(permitted).collect();
    if kept.is_empty() {
        return Err(NativeError::Errno(errno::PERMISSION_DENIED).with_subject(candidates[0].to_string()));
    }
    Ok(kept)
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

/// A fresh non-blocking stream socket for `addr`'s family (no SIGPIPE, no-delay), not connected.
pub(crate) fn new_stream(addr: &SocketAddr) -> Result<TcpStream, NativeError> {
    new_socket(addr, SOCK_STREAM).map(TcpStream::from)
}

/// A fresh non-blocking datagram socket for `addr`'s family, not connected.
#[cfg(feature = "dns")]
pub(crate) fn new_datagram(addr: &SocketAddr) -> Result<OwnedFd, NativeError> {
    let fd = new_socket(addr, SOCK_DGRAM)?;
    set_nonblocking(&fd)?;
    Ok(fd)
}

#[cfg(feature = "dns")]
fn set_nonblocking(fd: &OwnedFd) -> Result<(), NativeError> {
    unsafe extern "C" {
        fn fcntl(fd: i32, cmd: i32, ...) -> i32;
    }
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    const O_NONBLOCK: i32 = if cfg!(target_os = "linux") { 0x800 } else { 0x4 };
    // SAFETY: `fd` is a live descriptor owned by the caller; F_GETFL takes no argument.
    let flags = unsafe { fcntl(fd.as_raw_fd(), F_GETFL) };
    if flags < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    // SAFETY: as above; F_SETFL takes the new flags as an int.
    if unsafe { fcntl(fd.as_raw_fd(), F_SETFL, flags | O_NONBLOCK) } < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
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
        no_sigpipe(&stream);
        return Ok(OwnedFd::from(stream));
    }
    Ok(owned)
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

/// A stream socket of the table (not a listener) with its loop; `BadHandle` otherwise.
pub(crate) fn stream_of(host: &HostState, key: ScopeKey, id: u32) -> Result<(Rc<Socket>, Rc<origine_io::Loop>), NativeError> {
    let (socket, lp) = host.socket(key, id)?;
    if socket.is_listener() { Err(NativeError::Errno(errno::BAD_HANDLE)) } else { Ok((socket, lp)) }
}

/// `native.net.listen(io, host, port)`: binds and listens on a loopback address (`port` 0 picks
/// one) and returns `{ id, port }` with the actual port. Throws `PermissionDenied` (not loopback),
/// `BadHandle` (unknown or closed `io`), `AddressInUse`, ...
#[native(side_effect = "any", path = "net.listen", needs = "runtime")]
fn net_listen(host: &mut HostState, key: ScopeKey, io: u32, addr: String, port: u32) -> Result<Opened, NativeError> {
    host.loop_of(key, io)?;
    let listener = TcpListener::bind(allowed(host, &addr, port, true)?[0])?;
    listener.set_nonblocking(true)?;
    let port = u32::from(listener.local_addr()?.port());
    let id = host.reserve_socket()?;
    host.insert_socket(id, Socket::new(key, io, Endpoint::Listener(listener)))?;
    Ok(Opened { id, port })
}

/// `native.net.accept(id)`: Promise `{ id, port }` of the next connection (`port` = the peer's).
/// Rejects `Canceled` when the listener is closed first.
#[native(side_effect = "any", path = "net.accept", needs = "runtime", promise)]
fn net_accept(
    host: &mut HostState,
    key: ScopeKey,
    id: u32,
) -> Result<Op<'static, impl Future<Output = Result<Opened, NativeError>> + use<>>, NativeError> {
    let (listener, lp) = host.socket(key, id)?;
    if !listener.is_listener() {
        return Err(NativeError::Errno(errno::BAD_HANDLE));
    }
    let runtime = listener.runtime();
    let new_id = host.reserve_socket()?;
    let slot: Rc<RefCell<Option<TcpStream>>> = Rc::default();
    let filled = Rc::clone(&slot);
    let future = async move {
        let mut accepting = pin!(lp.accept(listener.fd(), ADDR_CAP));
        let accepted = poll_fn(|cx| {
            // The op first: a connection it already accepted is not dropped here.
            if let Poll::Ready(accepted) = accepting.as_mut().poll(cx) {
                return Poll::Ready(Some(accepted));
            }
            if listener.closed.get() {
                return Poll::Ready(None);
            }
            let mut closers = listener.closers.borrow_mut();
            if !closers.iter().any(|waker| waker.will_wake(cx.waker())) {
                closers.push(cx.waker().clone());
            }
            Poll::Pending
        })
        .await;
        let (fd, _peer) = accepted.ok_or(NativeError::Errno(errno::CANCELED))??;
        // SAFETY: `fd` was just returned by `accept` and nothing else owns it.
        let stream = TcpStream::from(unsafe { OwnedFd::from_raw_fd(fd as i32) });
        prepare(&stream)?;
        let port = u32::from(stream.peer_addr()?.port());
        *filled.borrow_mut() = Some(stream);
        Ok(Opened { id: new_id, port })
    };
    let hook = Box::new(move |scope: &mut v8::PinScope<'_, '_>| {
        let stream = slot.borrow_mut().take().ok_or(NativeError::Errno(errno::CANCELED))?;
        host_mut(scope)?.insert_socket(new_id, Socket::accepted(key, runtime, stream))
    });
    Ok(Op::new(runtime, future).with_hook(hook))
}

/// `native.net.connect(io, host, port)`: Promise `{ id, port }`. Loopback only (see the module
/// docs). Nothing blocks: the socket is created here and the loop completes the handshake; for
/// `localhost` each address is tried in turn, and the last error is reported when all fail.
#[native(side_effect = "any", path = "net.connect", needs = "runtime", promise)]
fn net_connect(
    host: &mut HostState,
    key: ScopeKey,
    io: u32,
    addr: String,
    port: u32,
) -> Result<Op<'static, impl Future<Output = Result<Opened, NativeError>> + use<>>, NativeError> {
    let lp = host.loop_of(key, io)?;
    let candidates = allowed(host, &addr, port, false)?;
    let id = host.reserve_socket()?;
    let slot: Rc<RefCell<Option<TcpStream>>> = Rc::default();
    let filled = Rc::clone(&slot);
    let future = async move {
        let mut last = NativeError::Errno(errno::UNEXPECTED);
        for candidate in candidates {
            let stream = match new_stream(&candidate) {
                Ok(stream) => stream,
                Err(error) => {
                    last = error;
                    continue;
                }
            };
            if let Err(error) = lp.connect(stream.as_raw_fd() as isize, sockaddr_bytes(&candidate)).await {
                last = NativeError::Errno(errno::errno_of(&error));
                continue;
            }
            let _ = stream.set_nodelay(true);
            let port = u32::from(stream.peer_addr()?.port());
            *filled.borrow_mut() = Some(stream);
            return Ok(Opened { id, port });
        }
        Err(last)
    };
    let hook = Box::new(move |scope: &mut v8::PinScope<'_, '_>| {
        let stream = slot.borrow_mut().take().ok_or(NativeError::Errno(errno::CANCELED))?;
        host_mut(scope)?.insert_socket(id, Socket::accepted(key, io, stream))
    });
    Ok(Op::new(io, future).with_hook(hook))
}

/// `native.net.read(id, len)`: Promise `Uint8Array` of 1..=`len` bytes read once from the stream
/// (empty at end of stream). `len` is capped like `fileReadAlloc` (256 MiB, else `FileTooLarge`).
#[native(side_effect = "any", path = "net.read", needs = "runtime", promise)]
fn net_read(
    scope: &mut v8::PinScope<'_, '_>,
    key: ScopeKey,
    id: u32,
    len: u32,
) -> Result<Op<'static, impl Future<Output = Result<AllocRead, NativeError>> + use<>>, NativeError> {
    let len = pin::check_alloc_len(len as usize)?;
    let (socket, lp) = stream_of(host_mut(scope)?, key, id)?;
    let runtime = socket.runtime();
    let isolate: &mut v8::Isolate = scope;
    let buf = pinned::alloc_for_read(isolate, len)?;
    Ok(Op::new(runtime, async move {
        if len == 0 {
            return Ok(AllocRead::new(0, None));
        }
        let (read, buf) = socket.recv(&lp, buf).await;
        Ok(AllocRead::new(read?, buf.into_store()))
    }))
}

/// `native.net.readCopy(id, buffer)`: Promise of the byte count (0 = end of stream) read once
/// into the guest's `buffer` (an ArrayBuffer or view). The read goes to a native scratch `Vec`
/// and is copied into the buffer at completion, so nothing is detached and the guest can reuse
/// the same buffer for every read; no V8 object is created per read. `StaleHandle` if the buffer
/// was detached meanwhile.
#[native(side_effect = "any", path = "net.readCopy", needs = "runtime", promise)]
fn net_read_copy<'s>(
    host: &mut HostState,
    key: ScopeKey,
    id: u32,
    buffer: ArrayBufferArg<'s>,
) -> Result<Op<'s, impl Future<Output = Result<usize, NativeError>> + 'static + use<>>, NativeError> {
    let (socket, lp) = stream_of(host, key, id)?;
    let runtime = socket.runtime();
    let len = buffer.len();
    Ok(Op::reading(
        runtime,
        async move {
            if len == 0 {
                return Ok(Vec::new());
            }
            let (read, mut data) = socket.recv(&lp, vec![0u8; len]).await;
            data.truncate(read?);
            Ok(data)
        },
        buffer,
    ))
}

/// `native.net.readInto(id, buffer)`: reads once straight into the guest's `buffer` (an
/// ArrayBuffer or view): the buffer is detached for the duration (the loop owns its bytes, no
/// copy) and the promise resolves `{ bytes, buffer }` with `buffer` a new ArrayBuffer over the
/// same memory; `bytes` is 0 at end of stream. A buffer that cannot be detached (shared,
/// resizable, WebAssembly memory) is refused with `Unsupported` before anything is touched.
/// After a failed read the buffer stays detached (see `pinned`).
#[native(side_effect = "any", path = "net.readInto", needs = "runtime", promise)]
fn net_read_into<'s>(
    host: &mut HostState,
    key: ScopeKey,
    id: u32,
    buffer: ArrayBufferArg<'s>,
) -> Result<Op<'s, impl Future<Output = Result<ReadInto, NativeError>> + 'static + use<>>, NativeError> {
    let (socket, lp) = stream_of(host, key, id)?;
    let runtime = socket.runtime();
    let (buf, copied) = pinned::pin_for_read(&buffer)?;
    if copied {
        return Err(NativeError::Errno(errno::UNSUPPORTED));
    }
    Ok(Op::new(runtime, async move {
        let (read, buf) = socket.recv(&lp, buf).await;
        let bytes = read?;
        let store = buf.into_store().ok_or(NativeError::Errno(errno::UNEXPECTED))?;
        Ok(ReadInto::Pinned { bytes, store })
    }))
}

/// `native.net.close(id)`: releases the socket now. Streams are shut down so a pending read
/// completes. `BadHandle` for an unknown, foreign or already closed id.
#[native(side_effect = "any", path = "net.close", needs = "runtime")]
fn net_close(host: &mut HostState, key: ScopeKey, id: u32) -> Result<(), NativeError> {
    host.remove_socket(key, id)?.shutdown();
    host.sub_closed(id);
    Ok(())
}
