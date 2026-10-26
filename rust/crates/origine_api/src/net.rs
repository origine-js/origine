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
//! running `recv`; closing a stream shuts it down so a pending read completes with 0 bytes. A
//! pending `accept` keeps its listener open until the runtime closes.

use std::cell::RefCell;
use std::future::Future;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::rc::Rc;

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
}

/// A socket of the Host table.
pub struct Socket {
    owner: ScopeKey,
    runtime: u32,
    endpoint: Endpoint,
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
        }
    }

    pub(crate) fn is_listener(&self) -> bool {
        matches!(self.endpoint, Endpoint::Listener(_))
    }

    /// The stream of a stream socket.
    pub(crate) fn stream(&self) -> Option<&TcpStream> {
        match &self.endpoint {
            Endpoint::Stream(stream) => Some(stream),
            Endpoint::Listener(_) => None,
        }
    }

    /// Sends the FIN: the peer reads end of stream, reads on this side keep working.
    pub(crate) fn shutdown_write(&self) {
        if let Endpoint::Stream(stream) = &self.endpoint {
            let _ = stream.shutdown(Shutdown::Write);
        }
    }

    /// A stream socket (accepted by a subscription's pump) of `owner` on `runtime`.
    pub(crate) fn accepted(owner: ScopeKey, runtime: u32, stream: TcpStream) -> Socket {
        Socket { owner, runtime, endpoint: Endpoint::Stream(stream) }
    }

    /// Wakes pending reads (they complete with 0 bytes) when the guest closes the socket.
    pub(crate) fn shutdown(&self) {
        if let Endpoint::Stream(stream) = &self.endpoint {
            let _ = stream.shutdown(Shutdown::Both);
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

/// Loopback addresses `host:port` to try, in order; `PermissionDenied` for any other host.
/// `localhost` is a name, not resolved: IPv4 first, then IPv6 (`connect` only; `listen` takes the first).
fn loopback(host: &str, port: u32) -> Result<Vec<SocketAddr>, NativeError> {
    let port = u16::try_from(port).map_err(|_| NativeError::Errno(errno::INVALID_INPUT))?;
    let ips = if host.eq_ignore_ascii_case("localhost") {
        vec![IpAddr::V4(Ipv4Addr::LOCALHOST), IpAddr::V6(Ipv6Addr::LOCALHOST)]
    } else {
        match host.parse::<IpAddr>() {
            Ok(ip) if ip.is_loopback() => vec![ip],
            _ => return Err(NativeError::Errno(errno::PERMISSION_DENIED)),
        }
    };
    Ok(ips.into_iter().map(|ip| SocketAddr::new(ip, port)).collect())
}

unsafe extern "C" {
    fn socket(domain: i32, kind: i32, protocol: i32) -> i32;
}

const AF_INET: i32 = 2;
const AF_INET6: i32 = if cfg!(target_os = "linux") { 10 } else { 30 };
const SOCK_STREAM: i32 = 1;
/// Linux creates close-on-exec sockets atomically; macOS has no such flag.
const SOCK_CLOEXEC: i32 = if cfg!(target_os = "linux") { 0x80000 } else { 0 };

/// A fresh non-blocking stream socket for `addr`'s family (no SIGPIPE, no-delay), not connected.
fn new_stream(addr: &SocketAddr) -> Result<TcpStream, NativeError> {
    let domain = if addr.is_ipv4() { AF_INET } else { AF_INET6 };
    // SAFETY: plain `socket(2)` call with constant arguments.
    let fd = unsafe { socket(domain, SOCK_STREAM | SOCK_CLOEXEC, 0) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    // SAFETY: `fd` was just returned by `socket` and nothing else owns it.
    let stream = TcpStream::from(unsafe { OwnedFd::from_raw_fd(fd) });
    // `set_nodelay` fails on an unconnected socket on some systems; the option is applied after connect.
    stream.set_nonblocking(true)?;
    no_sigpipe(&stream);
    Ok(stream)
}

/// The platform's native `sockaddr_in` / `sockaddr_in6` bytes for `addr`.
fn sockaddr_bytes(addr: &SocketAddr) -> Vec<u8> {
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
    let listener = TcpListener::bind(loopback(&addr, port)?[0])?;
    listener.set_nonblocking(true)?;
    let port = u32::from(listener.local_addr()?.port());
    let id = host.reserve_socket()?;
    host.insert_socket(id, Socket { owner: key, runtime: io, endpoint: Endpoint::Listener(listener) })?;
    Ok(Opened { id, port })
}

/// `native.net.accept(id)`: Promise `{ id, port }` of the next connection (`port` = the peer's).
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
        let (fd, _peer) = lp.accept(listener.fd(), ADDR_CAP).await?;
        // SAFETY: `fd` was just returned by `accept` and nothing else owns it.
        let stream = TcpStream::from(unsafe { OwnedFd::from_raw_fd(fd as i32) });
        prepare(&stream)?;
        let port = u32::from(stream.peer_addr()?.port());
        *filled.borrow_mut() = Some(stream);
        Ok(Opened { id: new_id, port })
    };
    let hook = Box::new(move |scope: &mut v8::PinScope<'_, '_>| {
        let stream = slot.borrow_mut().take().ok_or(NativeError::Errno(errno::CANCELED))?;
        host_mut(scope)?.insert_socket(new_id, Socket { owner: key, runtime, endpoint: Endpoint::Stream(stream) })
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
    let candidates = loopback(&addr, port)?;
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
        let (read, buf) = lp.recv(socket.fd(), buf, 0).await;
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
            let (read, mut data) = lp.recv(socket.fd(), vec![0u8; len], 0).await;
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
        let (read, buf) = lp.recv(socket.fd(), buf, 0).await;
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
