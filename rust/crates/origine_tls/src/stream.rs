use crate::config::{TlsClient, TlsServer};
use crate::error::TlsError;
use crate::gate::Gate;
use crate::transport::Transport;
use rustls::{ClientConnection, Connection, HandshakeKind, ServerConnection};
use rustls_pki_types::ServerName;
use std::cell::{Cell, RefCell};
use std::future::Future;
use std::io::{self, Read, Write};
use std::rc::Rc;

/// One TLS record is at most 16 KiB of payload plus up to 2 KiB of framing and padding.
const READ_CHUNK: usize = 18 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Version {
    Tls12,
    Tls13,
}

/// What the handshake settled; read it with [`TlsStream::info`].
#[derive(Clone, Debug)]
pub struct Info {
    /// The negotiated ALPN protocol, if both sides offered one.
    pub alpn: Option<String>,
    pub version: Version,
    /// The name the client asked for: the one passed to `connect`, or the SNI a server received.
    pub servername: Option<String>,
    /// The peer's certificates in DER, leaf first; empty when it sent none.
    pub peer: Vec<Vec<u8>>,
    /// The handshake resumed an earlier session instead of doing a full one.
    pub resumed: bool,
}

/// A TLS connection over a [`Transport`].
///
/// Cloning gives another handle on the same connection, so one task can read while another writes.
/// At most one `read` and one `write`/`shutdown` run at a time (a second one waits its turn). Writes
/// from several tasks are not kept apart record by record: callers serialize their writes.
///
/// Dropping a `write` or `shutdown` future half way leaves a partly sent record stream; the next
/// operation fails with [`TlsError::Poisoned`] instead of corrupting it. Dropping a `read` is safe.
pub struct TlsStream<T> {
    shared: Rc<Shared<T>>,
}

impl<T> Clone for TlsStream<T> {
    fn clone(&self) -> Self {
        TlsStream { shared: self.shared.clone() }
    }
}

struct Shared<T> {
    transport: T,
    conn: RefCell<Connection>,
    read_gate: Gate,
    write_gate: Gate,
    poisoned: Cell<bool>,
    /// `shutdown` was called: rustls would accept more plaintext and silently never send it.
    write_closed: Cell<bool>,
    /// Encrypted bytes rustls had no room for (its plaintext was full); fed again after a read.
    leftover: RefCell<Vec<u8>>,
    read_buf: RefCell<Vec<u8>>,
    servername: Option<String>,
}

struct Poison<'a> {
    flag: &'a Cell<bool>,
    armed: bool,
}

impl Drop for Poison<'_> {
    fn drop(&mut self) {
        if self.armed {
            self.flag.set(true);
        }
    }
}

impl<T: Transport> TlsStream<T> {
    /// Connects as a client and completes the handshake.
    pub async fn connect(client: &TlsClient, transport: T, servername: &str) -> Result<TlsStream<T>, TlsError> {
        let name = ServerName::try_from(servername.to_owned()).map_err(|_| TlsError::InvalidServerName(servername.to_owned()))?;
        let conn = ClientConnection::new(client.config.clone(), name)?;
        TlsStream::start(Connection::Client(conn), transport, Some(servername.to_owned())).await
    }

    /// Accepts a client and completes the handshake.
    pub async fn accept(server: &TlsServer, transport: T) -> Result<TlsStream<T>, TlsError> {
        let conn = ServerConnection::new(server.config.clone())?;
        TlsStream::start(Connection::Server(conn), transport, None).await
    }

    async fn start(conn: Connection, transport: T, servername: Option<String>) -> Result<TlsStream<T>, TlsError> {
        let stream = TlsStream {
            shared: Rc::new(Shared {
                transport,
                conn: RefCell::new(conn),
                read_gate: Gate::new(),
                write_gate: Gate::new(),
                poisoned: Cell::new(false),
                write_closed: Cell::new(false),
                leftover: RefCell::new(Vec::new()),
                read_buf: RefCell::new(Vec::new()),
                servername,
            }),
        };
        stream.handshake().await?;
        Ok(stream)
    }

    async fn handshake(&self) -> Result<(), TlsError> {
        let _read = self.shared.read_gate.lock().await;
        loop {
            self.flush().await?;
            if !self.shared.conn.borrow().is_handshaking() {
                break;
            }
            if !self.fill().await? {
                return Err(TlsError::UnexpectedEof);
            }
        }
        // Tickets and the like that the finished handshake queued.
        self.flush().await
    }

    /// Reads plaintext into `buf` (not empty). `Ok(0)` means the peer sent `close_notify`: a clean end
    /// of its side. The transport ending without it is [`TlsError::UnexpectedEof`], never `Ok(0)`.
    pub async fn read(&self, buf: &mut [u8]) -> Result<usize, TlsError> {
        if buf.is_empty() {
            return Err(TlsError::Io(io::Error::new(io::ErrorKind::InvalidInput, "empty read buffer")));
        }
        let _read = self.shared.read_gate.lock().await;
        let mut ended = false;
        loop {
            let got = self.shared.conn.borrow_mut().reader().read(buf);
            match got {
                Ok(n) => {
                    // A key update or an alert answer may be queued; it is small, and rare enough
                    // that waiting for it here cannot starve a busy writer.
                    if self.shared.conn.borrow().wants_write() {
                        let _ = self.flush().await;
                    }
                    return Ok(n);
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    // Records rustls took in earlier but could not decode while its plaintext was full.
                    if self.process().await? {
                        continue;
                    }
                    if ended {
                        return Err(TlsError::UnexpectedEof);
                    }
                    ended = !self.fill().await?;
                }
                Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Err(TlsError::UnexpectedEof),
                Err(e) => return Err(TlsError::Io(e)),
            }
        }
    }

    /// Encrypts and sends all of `data`; returns once every byte is in the transport.
    pub async fn write(&self, data: &[u8]) -> Result<(), TlsError> {
        let mut rest = data;
        while !rest.is_empty() {
            if self.shared.write_closed.get() {
                return Err(TlsError::Io(io::Error::from(io::ErrorKind::BrokenPipe)));
            }
            if self.shared.poisoned.get() {
                return Err(TlsError::Poisoned);
            }
            // rustls takes up to its own buffer limit (64 KiB) at a time.
            let n = self.shared.conn.borrow_mut().writer().write(rest)?;
            rest = &rest[n..];
            self.flush().await?;
        }
        Ok(())
    }

    /// Sends `close_notify` and flushes it. Reading stays possible; later writes fail with
    /// `BrokenPipe`. It does not close the transport.
    pub async fn shutdown(&self) -> Result<(), TlsError> {
        self.shared.write_closed.set(true);
        self.shared.conn.borrow_mut().send_close_notify();
        self.flush().await
    }

    /// What the handshake settled.
    pub fn info(&self) -> Info {
        let conn = self.shared.conn.borrow();
        let servername = match &*conn {
            Connection::Client(_) => self.shared.servername.clone(),
            Connection::Server(s) => s.server_name().map(str::to_owned),
        };
        Info {
            alpn: conn.alpn_protocol().and_then(|p| String::from_utf8(p.to_vec()).ok()),
            version: match conn.protocol_version() {
                Some(rustls::ProtocolVersion::TLSv1_2) => Version::Tls12,
                _ => Version::Tls13,
            },
            servername,
            peer: conn.peer_certificates().map(|c| c.iter().map(|d| d.as_ref().to_vec()).collect()).unwrap_or_default(),
            resumed: conn.handshake_kind() == Some(HandshakeKind::Resumed),
        }
    }

    /// Takes the write turn and sends everything rustls has queued, until nothing is queued.
    async fn flush(&self) -> Result<(), TlsError> {
        let _write = self.shared.write_gate.lock().await;
        loop {
            if self.shared.poisoned.get() {
                return Err(TlsError::Poisoned);
            }
            let out = {
                let mut conn = self.shared.conn.borrow_mut();
                let mut out = Vec::new();
                while conn.wants_write() {
                    conn.write_tls(&mut out)?;
                }
                out
            };
            if out.is_empty() {
                return Ok(());
            }
            let mut bomb = Poison { flag: &self.shared.poisoned, armed: true };
            let (res, _) = self.shared.transport.write_all(out).await;
            bomb.armed = false;
            res?;
        }
    }

    /// Feeds rustls more encrypted bytes: first what it could not take before, else one transport
    /// read. `false` is the end of the transport. The caller holds the read turn.
    async fn fill(&self) -> Result<bool, TlsError> {
        let pending = std::mem::take(&mut *self.shared.leftover.borrow_mut());
        if !pending.is_empty() {
            return self.feed(&pending).await.map(|()| true);
        }
        let mut buf = std::mem::take(&mut *self.shared.read_buf.borrow_mut());
        buf.resize(READ_CHUNK, 0);
        let (res, buf) = self.shared.transport.read(buf).await;
        let n = match res {
            Ok(n) => n,
            Err(e) => {
                *self.shared.read_buf.borrow_mut() = buf;
                return Err(e.into());
            }
        };
        let fed = self.feed(&buf[..n]).await;
        *self.shared.read_buf.borrow_mut() = buf;
        fed.map(|()| n != 0)
    }

    /// Decodes what rustls already holds; true if that produced plaintext to read.
    async fn process(&self) -> Result<bool, TlsError> {
        let result = self.shared.conn.borrow_mut().process_new_packets();
        match result {
            Ok(state) => Ok(state.plaintext_bytes_to_read() > 0),
            Err(e) => {
                // rustls queued the alert for this error; send it before reporting.
                let _ = self.flush().await;
                Err(e.into())
            }
        }
    }

    async fn feed(&self, mut data: &[u8]) -> Result<(), TlsError> {
        let failed = {
            let mut conn = self.shared.conn.borrow_mut();
            // `Ok(true)`: rustls was full and the rest of `data` has to wait for the reader.
            let result = (|| -> Result<bool, TlsError> {
                if data.is_empty() {
                    // The end of the transport: rustls tells a clean close_notify from a cut.
                    conn.read_tls(&mut io::empty())?;
                    conn.process_new_packets()?;
                    return Ok(false);
                }
                while !data.is_empty() {
                    match conn.read_tls(&mut data) {
                        // After close_notify rustls reads nothing more, and what follows is to be ignored.
                        Ok(0) => return Ok(false),
                        Ok(_) => {}
                        // Full: undelivered plaintext (`Other`) or undecoded records (`InvalidData`, "message
                        // buffer full"). Not `wants_read()`: that is false exactly while plaintext is waiting.
                        Err(e)
                            if matches!(e.kind(), io::ErrorKind::Other | io::ErrorKind::InvalidData)
                                && e.to_string().contains("buffer full") =>
                        {
                            return Ok(true);
                        }
                        Err(e) => return Err(e.into()),
                    }
                    conn.process_new_packets()?;
                }
                Ok(false)
            })();
            match result {
                Ok(held) => {
                    if held {
                        self.shared.leftover.borrow_mut().extend_from_slice(data);
                    }
                    None
                }
                Err(e) => Some(e),
            }
        };
        match failed {
            None => Ok(()),
            Some(e) => {
                // rustls queued the alert for this error; send it before reporting.
                let _ = self.flush().await;
                Err(e)
            }
        }
    }
}

/// A TLS stream is a byte transport too, so a protocol can run over it: `read` ends with `0` after the
/// peer's `close_notify`; a cut connection is an `UnexpectedEof` error.
impl<T: Transport> Transport for TlsStream<T> {
    fn read(&self, mut buf: Vec<u8>) -> impl Future<Output = (io::Result<usize>, Vec<u8>)> {
        let stream = self.clone();
        async move {
            let result = TlsStream::read(&stream, &mut buf).await.map_err(io::Error::from);
            (result, buf)
        }
    }

    fn write_all(&self, buf: Vec<u8>) -> impl Future<Output = (io::Result<()>, Vec<u8>)> {
        let stream = self.clone();
        async move {
            let result = TlsStream::write(&stream, &buf).await.map_err(io::Error::from);
            (result, buf)
        }
    }
}
