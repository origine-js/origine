//! `native.net.*`: loopback TCP on the io loop.
//!
//! Sockets are created with `std::net` (non-blocking, `TCP_NODELAY`, no SIGPIPE) and live in the
//! Host's socket table, bound to the runtime they were created on. `accept`, `read` and `write`
//! run on that runtime's loop (`Loop::accept/recv/send`), so they never block the isolate
//! thread. `connect` uses a blocking `std` connect, which is only acceptable because the
//! destination is restricted to the loopback interface; a fully asynchronous connect needs a
//! socket-creation op in the loop. Only `127.0.0.1`, `localhost` and `::1` are allowed
//! (`AccessDenied` otherwise): there is no embedder permission for wider network access yet.
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
const SEND_FLAGS: u32 = if cfg!(target_os = "linux") { 0x4000 } else { 0 };
/// Pending-connection queue and peer-address capacity for `accept`.
const ADDR_CAP: usize = 128;

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

    fn fd(&self) -> isize {
        match &self.endpoint {
            Endpoint::Listener(l) => l.as_raw_fd() as isize,
            Endpoint::Stream(s) => s.as_raw_fd() as isize,
        }
    }

    fn is_listener(&self) -> bool {
        matches!(self.endpoint, Endpoint::Listener(_))
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
fn prepare(stream: &TcpStream) -> Result<(), NativeError> {
    stream.set_nonblocking(true)?;
    stream.set_nodelay(true)?;
    no_sigpipe(stream);
    Ok(())
}

/// The loopback address `host:port`; `AccessDenied` for any other host.
fn loopback(host: &str, port: u32) -> Result<SocketAddr, NativeError> {
    let port = u16::try_from(port).map_err(|_| NativeError::Errno(errno::INVALID_PATH))?;
    let ip = match host {
        "127.0.0.1" | "localhost" => IpAddr::V4(Ipv4Addr::LOCALHOST),
        "::1" => IpAddr::V6(Ipv6Addr::LOCALHOST),
        _ => return Err(NativeError::Errno(errno::ACCESS_DENIED)),
    };
    Ok(SocketAddr::new(ip, port))
}

/// A stream socket of the table (not a listener) with its loop; `BadHandle` otherwise.
fn stream_of(host: &HostState, key: ScopeKey, id: u32) -> Result<(Rc<Socket>, Rc<origine_io::Loop>), NativeError> {
    let (socket, lp) = host.socket(key, id)?;
    if socket.is_listener() { Err(NativeError::Errno(errno::BAD_HANDLE)) } else { Ok((socket, lp)) }
}

/// `native.net.listen(io, host, port)`: binds and listens on a loopback address (`port` 0 picks
/// one) and returns `{ id, port }` with the actual port. Throws `AccessDenied` (not loopback),
/// `BadHandle` (unknown or closed `io`), `AddressInUse`, ...
#[native(side_effect = "any", path = "net.listen", needs = "runtime")]
fn net_listen(host: &mut HostState, key: ScopeKey, io: u32, addr: String, port: u32) -> Result<Opened, NativeError> {
    host.loop_of(key, io)?;
    let listener = TcpListener::bind(loopback(&addr, port)?)?;
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

/// `native.net.connect(io, host, port)`: Promise `{ id, port }`. Loopback only (see the module docs).
#[native(side_effect = "any", path = "net.connect", needs = "runtime", promise)]
fn net_connect(
    host: &mut HostState,
    key: ScopeKey,
    io: u32,
    addr: String,
    port: u32,
) -> Result<Op<'static, impl Future<Output = Result<Opened, NativeError>> + use<>>, NativeError> {
    host.loop_of(key, io)?;
    let stream = TcpStream::connect(loopback(&addr, port)?)?;
    prepare(&stream)?;
    let port = u32::from(stream.peer_addr()?.port());
    let id = host.reserve_socket()?;
    host.insert_socket(id, Socket { owner: key, runtime: io, endpoint: Endpoint::Stream(stream) })?;
    Ok(Op::new(io, async move { Ok(Opened { id, port }) }))
}

/// `native.net.read(id, len)`: Promise `Uint8Array` of 1..=`len` bytes read once from the stream
/// (empty at end of stream). `len` is capped like `fileReadAlloc` (256 MiB, else `FileTooBig`).
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

/// `native.net.write(id, data)`: Promise of the byte count; copies `data` and sends all of it.
#[native(side_effect = "any", path = "net.write", needs = "runtime", promise)]
fn net_write(
    host: &mut HostState,
    key: ScopeKey,
    id: u32,
    data: ArrayBufferArg<'_>,
) -> Result<Op<'static, impl Future<Output = Result<usize, NativeError>> + use<>>, NativeError> {
    let (socket, lp) = stream_of(host, key, id)?;
    let runtime = socket.runtime();
    let mut data = data.to_vec();
    let total = data.len();
    Ok(Op::new(runtime, async move {
        let mut sent = 0;
        while sent < total {
            let (result, buf) = lp.send(socket.fd(), data, SEND_FLAGS).await;
            data = buf;
            let n = result?;
            if n == 0 {
                return Err(NativeError::Errno(errno::BROKEN_PIPE));
            }
            sent += n;
            data.drain(..n);
        }
        Ok(total)
    }))
}

/// `native.net.close(id)`: releases the socket now. Streams are shut down so a pending read
/// completes. `BadHandle` for an unknown, foreign or already closed id.
#[native(side_effect = "any", path = "net.close", needs = "runtime")]
fn net_close(host: &mut HostState, key: ScopeKey, id: u32) -> Result<(), NativeError> {
    host.remove_socket(key, id)?.shutdown();
    Ok(())
}
