//! A plain stream socket of the Host table as a [`Transport`], shared by `native.tls.*` and `native.http.*`.

use std::future::Future;
use std::io;
use std::rc::Rc;

use origine_api_core::{NativeError, errno};
use origine_io::Loop;
use origine_transport::Transport;

use crate::HostState;
use crate::native::ScopeKey;
use crate::net::{SEND_FLAGS, Socket};

/// The bytes under a TLS stream or an HTTP/2 session: a stream socket of the table, read and written through its loop.
/// Holds the socket, so closing the guest's id cannot free the descriptor under a running op.
pub(crate) struct SocketTransport {
    pub(crate) socket: Rc<Socket>,
    pub(crate) lp: Rc<Loop>,
}

impl Transport for SocketTransport {
    fn read(&self, buf: Vec<u8>) -> impl Future<Output = (io::Result<usize>, Vec<u8>)> {
        let (socket, lp) = (Rc::clone(&self.socket), Rc::clone(&self.lp));
        async move { lp.recv(socket.fd(), buf, 0).await }
    }

    fn write_all(&self, buf: Vec<u8>) -> impl Future<Output = (io::Result<()>, Vec<u8>)> {
        let (socket, lp) = (Rc::clone(&self.socket), Rc::clone(&self.lp));
        async move {
            let mut buf = buf;
            let mut sent = 0;
            while sent < buf.len() {
                let rest = if sent == 0 { std::mem::take(&mut buf) } else { buf.split_off(sent) };
                let rest_len = rest.len();
                let (result, back) = lp.send(socket.fd(), rest, SEND_FLAGS).await;
                match result {
                    Ok(n) if n < rest_len => {
                        // The kernel took part of it: keep going with the rest.
                        buf = back;
                        buf.drain(..n);
                        sent = 0;
                        if buf.is_empty() {
                            break;
                        }
                    }
                    Ok(_) => return (Ok(()), Vec::new()),
                    Err(e) => return (Err(e), back),
                }
            }
            (Ok(()), Vec::new())
        }
    }
}

/// Takes the plain stream socket `socket` out of the table for a handshake on runtime `io`.
pub(crate) fn take_socket(host: &mut HostState, key: ScopeKey, io: u32, socket: u32) -> Result<(Rc<Socket>, Rc<Loop>), NativeError> {
    let (found, lp) = crate::net::stream_of(host, key, socket)?;
    if found.runtime() != io || host.subs.contains_key(&socket) {
        // A socket of another runtime, or one with a subscription, cannot be handed over.
        return Err(NativeError::Errno(errno::BAD_HANDLE));
    }
    host.remove_socket(key, socket)?;
    Ok((found, lp))
}
