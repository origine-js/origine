//! The bridge from the guest's stream objects to the Rust [`Transport`] the protocol engines (`origine_tls`,
//! `origine_h2`, the DNS exchanges) run over.
//!
//! A native stream (a `TcpStreamUnshaped`, or a `PullTcpStream` / `EventTcpStream` nothing is using; plain or made
//! by `api.tls`) is recognised by its class (the cppgc `TypeId`) and **consumed**: its socket leaves the object
//! (which answers `BadHandle` afterwards) and the engine reads and writes it on the loop, without entering JS.

use std::future::Future;
use std::io;
use std::rc::Rc;

use origine_api_core::{ArgError, NativeError};
use origine_io::Loop;
use origine_transport::Transport;

use crate::FromJs;
use crate::conn::{Conn, Front};
use crate::gc;
use crate::io::IoCore;
use crate::net::Socket;
use crate::stream::{EventTcpStream, PullTcpStream, TcpStreamUnshaped};

/// The bytes under a TLS stream or an HTTP/2 session: a socket (plain or TLS), read and written through its loop.
/// Holds the socket, so closing the guest's object cannot free the descriptor under a running op.
pub(crate) struct SocketTransport {
    pub(crate) socket: Rc<Socket>,
    pub(crate) lp: Rc<Loop>,
}

impl Transport for SocketTransport {
    fn read(&self, buf: Vec<u8>) -> impl Future<Output = (io::Result<usize>, Vec<u8>)> {
        let (socket, lp) = (Rc::clone(&self.socket), Rc::clone(&self.lp));
        // Boxed: a socket may itself be a TLS stream over this transport.
        Box::pin(async move { socket.recv(&lp, buf).await })
    }

    fn write_all(&self, buf: Vec<u8>) -> impl Future<Output = (io::Result<()>, Vec<u8>)> {
        let (socket, lp) = (Rc::clone(&self.socket), Rc::clone(&self.lp));
        Box::pin(async move {
            let mut buf = buf;
            while !buf.is_empty() {
                let (result, back) = socket.send(&lp, buf).await;
                buf = back;
                match result {
                    Ok(0) => return (Err(io::Error::from(io::ErrorKind::WriteZero)), buf),
                    Ok(n) => {
                        buf.drain(..n);
                    }
                    Err(e) => return (Err(e), buf),
                }
            }
            (Ok(()), buf)
        })
    }
}

/// A native stream argument: one of the TCP stream classes (plain or TLS inside), borrowed for the call.
pub(crate) struct StreamArg<'s>(&'s Front);

impl<'s> FromJs<'s> for StreamArg<'s> {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        let isolate: &mut v8::Isolate = scope;
        if let Some(stream) = gc::unwrap_ref::<TcpStreamUnshaped>(isolate, value) {
            return Ok(StreamArg(&stream.0));
        }
        if let Some(stream) = gc::unwrap_ref::<PullTcpStream>(isolate, value) {
            return Ok(StreamArg(stream.front()));
        }
        if let Some(stream) = gc::unwrap_ref::<EventTcpStream>(isolate, value) {
            return Ok(StreamArg(stream.front()));
        }
        Err(ArgError::new(index, "a TcpStreamUnshaped, PullTcpStream or EventTcpStream"))
    }
}

impl StreamArg<'_> {
    /// The conn of the stream, if nothing is using it (no read in flight, nothing queued, no handler, neither side
    /// ended); `WouldBlock` / `Unsupported` / `BadHandle` otherwise, leaving the object usable.
    pub(crate) fn conn(&self) -> Result<Rc<Conn>, NativeError> {
        let conn = self.0.get()?;
        conn.idle()?;
        Ok(conn)
    }

    /// Takes the stream's socket out (the object is consumed), with its runtime.
    pub(crate) fn take(self) -> Result<(Rc<IoCore>, Rc<Socket>), NativeError> {
        let conn = self.0.take(Conn::idle)?;
        let socket = conn.detach()?;
        Ok((Rc::clone(&conn.io), socket))
    }
}
