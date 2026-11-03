//! The bytes under a protocol: a socket, a pipe, another protocol's stream. Buffers are owned and
//! handed back, the way `origine_io` ops take them, so a transport can keep a buffer in flight.

use std::future::Future;
use std::io;

#[cfg(feature = "testing")]
pub mod pipe;

/// Single-threaded: no `Send` bound. `read` and `write_all` may be in flight at the same time (a
/// full-duplex stream); a user never has two reads or two writes in flight at once.
pub trait Transport {
    /// Reads into `buf[..buf.len()]` and returns the byte count with the buffer. `0` is the end of
    /// the stream (the peer closed its side); whether that end was clean is the caller's to decide.
    /// Dropping the future abandons the read; a transport must not lose bytes it did not hand back
    /// (for a socket: the read is canceled, or its bytes stay for the next read).
    fn read(&self, buf: Vec<u8>) -> impl Future<Output = (io::Result<usize>, Vec<u8>)>;

    /// Writes all of `buf`, or fails. Bytes leave in the order the futures complete.
    fn write_all(&self, buf: Vec<u8>) -> impl Future<Output = (io::Result<()>, Vec<u8>)>;
}

impl<T: Transport + ?Sized> Transport for std::rc::Rc<T> {
    fn read(&self, buf: Vec<u8>) -> impl Future<Output = (io::Result<usize>, Vec<u8>)> {
        (**self).read(buf)
    }

    fn write_all(&self, buf: Vec<u8>) -> impl Future<Output = (io::Result<()>, Vec<u8>)> {
        (**self).write_all(buf)
    }
}
