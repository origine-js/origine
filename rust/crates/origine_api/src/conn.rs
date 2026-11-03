//! One descriptor as the guest holds it: a [`Conn`] is the state of a TCP stream, a TCP listener or a UDP socket,
//! shared by the object that fronts it ([`Front`], inside a Rust-defined class instance), the tasks that work on
//! it (reads, the write pump, the event pumps of `sub.rs`) and its event hub.
//!
//! No table holds it: the guest's object owns it in the cppgc heap. Its io runtime keeps a weak list of the
//! conns made on it ([`crate::io::IoCore`]) so that `io.close()` closes their descriptors; collecting the object
//! of a conn nothing else uses closes the descriptor too. `close()` frees the descriptor at once; the object
//! stays allocated until it is collected and answers `BadHandle` from then on.
//!
//! # Writes
//! Two lanes share one order. `direct.write` is a plain non-blocking `write(2)` on the isolate thread: no copy, no
//! buffer, it answers the bytes the kernel took and answers 0 while the outbox is busy (the queue has priority).
//! `queued.put` tries the kernel first when the outbox is idle, then copies what is left (at most the room under
//! `limit`) into the outbox, which a writer task flushes in order. `queued.send` copies its bytes when it is
//! called, waits its turn (sends are admitted in call order, each once it fits under `limit` or the queue is
//! empty) and resolves once the bytes reached the kernel.

use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::future::poll_fn;
use std::net::SocketAddr;
use std::rc::Rc;
use std::task::{Poll, Waker};

use origine_api_core::{NativeError, errno};
use origine_io::Loop;
use origine_io::rt::{AbortHandle, Handle};

use crate::host::Task;
use crate::io::IoCore;
use crate::net::Socket;
use crate::sub::{EventKind, Flow};

/// What a conn is.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Kind {
    Stream,
    Listener,
    Datagram,
}

/// The default `queued.limit`: bytes the outbox holds for a slow peer.
pub(crate) const QUEUE_LIMIT: usize = 1 << 20;

/// The write side of a stream.
#[derive(Default)]
pub(crate) struct Outbox {
    queue: VecDeque<Vec<u8>>,
    /// Bytes in `queue`.
    pub(crate) bytes: usize,
    /// A writer task owns the queue.
    writing: bool,
    /// Bytes ever accepted (kernel or queue) and bytes that reached the kernel.
    accepted: u64,
    sent: u64,
    /// `end` was called: no more writes; the FIN goes out once the queue is empty.
    ended: bool,
    /// The FIN went out.
    finished: bool,
    /// The outbox failed (write error, peer gone, socket closed): the errno pending writes get.
    failed: Option<u32>,
    /// Sends and ends that wait for their turn hold tickets; `serving` is the next one admitted.
    next_ticket: u64,
    serving: u64,
    /// Everything waiting on the outbox.
    waiters: Vec<Waker>,
}

impl Outbox {
    fn wake(&mut self) {
        for waker in self.waiters.drain(..) {
            waker.wake();
        }
    }

    /// Sends (and ends) waiting for their turn.
    pub(crate) fn waiting(&self) -> usize {
        (self.next_ticket - self.serving) as usize
    }
}

/// The state of one descriptor (see the module docs).
pub(crate) struct Conn {
    pub(crate) io: Rc<IoCore>,
    pub(crate) kind: Kind,
    socket: RefCell<Option<Rc<Socket>>>,
    pub(crate) local: Option<SocketAddr>,
    pub(crate) peer: Cell<Option<SocketAddr>>,
    closed: Cell<bool>,
    /// Pull-mode operations in flight.
    pub(crate) pending: Cell<usize>,
    /// How far each direction is finished: the peer's FIN was seen / reading was ended locally, and the local FIN
    /// was sent. A stream closes itself once both are.
    peer_ended: Cell<bool>,
    pub(crate) read_ended: Cell<bool>,
    write_ended: Cell<bool>,
    pub(crate) out: RefCell<Outbox>,
    pub(crate) limit: Cell<usize>,
    /// The event side (`sub.rs`).
    pub(crate) flow: Flow,
}

impl Conn {
    /// A conn of `io` over `socket`, registered with its runtime so that `io.close()` closes it.
    pub(crate) fn new(io: &Rc<IoCore>, kind: Kind, socket: Socket) -> Rc<Conn> {
        let (local, peer) = socket.addrs();
        let conn = Rc::new(Conn {
            io: Rc::clone(io),
            kind,
            socket: RefCell::new(Some(Rc::new(socket))),
            local,
            peer: Cell::new(peer),
            closed: Cell::new(false),
            pending: Cell::new(0),
            peer_ended: Cell::new(false),
            read_ended: Cell::new(false),
            write_ended: Cell::new(false),
            out: RefCell::default(),
            limit: Cell::new(QUEUE_LIMIT),
            flow: Flow::default(),
        });
        io.adopt(&conn);
        conn
    }

    pub(crate) fn is_closed(&self) -> bool {
        self.closed.get()
    }

    /// The socket; `BadHandle` once closed.
    pub(crate) fn socket(&self) -> Result<Rc<Socket>, NativeError> {
        self.socket.borrow().clone().ok_or(NativeError::Errno(errno::BAD_HANDLE))
    }

    /// Takes the socket out for another owner (a TLS handshake, an HTTP/2 session): the conn is closed without
    /// touching the descriptor and without events.
    pub(crate) fn detach(&self) -> Result<Rc<Socket>, NativeError> {
        let socket = self.socket.borrow_mut().take().ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
        self.closed.set(true);
        Ok(socket)
    }

    /// Whether the conn is a stream nothing is using: no read in flight, nothing queued, no event hub, neither
    /// side ended. What a handover (`tls.connect`, `http.session`) needs.
    pub(crate) fn idle(&self) -> Result<(), NativeError> {
        if self.closed.get() || self.kind != Kind::Stream {
            return Err(NativeError::Errno(errno::BAD_HANDLE));
        }
        let out = self.out.borrow();
        if self.pending.get() > 0 || out.bytes > 0 || out.writing || out.waiting() > 0 {
            return Err(NativeError::Errno(errno::WOULD_BLOCK));
        }
        if self.flow.hub.get().is_some() || self.read_ended.get() || self.write_ended.get() || out.ended {
            return Err(NativeError::Errno(errno::UNSUPPORTED));
        }
        Ok(())
    }

    /// Queues an event for the hub, if the conn has one (a pull-mode conn has none).
    pub(crate) fn push(&self, kind: EventKind) {
        if let Some(hub) = self.flow.hub.get() {
            self.flow.push(&self.io, hub, kind);
        }
    }

    /// Closes the descriptor now: pending reads end, pending accepts reject `Canceled`, what waits on the outbox
    /// rejects `Canceled`, the event pumps stop and the hub gets its `close`. Idempotent.
    pub(crate) fn close(&self) {
        if self.closed.replace(true) {
            return;
        }
        self.fail_out(errno::CANCELED);
        self.flow.stop();
        if let Some(socket) = self.socket.borrow_mut().take() {
            socket.shutdown();
        }
        self.push(EventKind::Closed);
    }

    /// Fails the outbox once: drops the queue and wakes everything waiting on it with `code`.
    fn fail_out(&self, code: u32) {
        let mut out = self.out.borrow_mut();
        if out.failed.is_none() {
            out.failed = Some(code);
            out.queue.clear();
            out.bytes = 0;
            out.wake();
        }
    }

    /// A failure of the descriptor: the hub gets `error`, then the conn closes.
    pub(crate) fn fail(&self, code: u32) {
        self.fail_out(code);
        if !self.closed.get() {
            self.push(EventKind::Error(code));
        }
        self.close();
    }

    // ---- lifecycle of a stream ----

    /// The peer's FIN was seen.
    pub(crate) fn peer_end(&self) {
        self.peer_ended.set(true);
        self.settle();
    }

    /// Reading was ended locally.
    pub(crate) fn end_read(self: &Rc<Conn>) {
        if self.read_ended.replace(true) {
            return;
        }
        // The kernel side stays open (a `shutdown(SHUT_RD)` makes some systems reset the connection when the peer
        // sends), so what arrives is read and dropped until the peer's FIN. A flowing hub's pump does that already.
        if !self.flow.started.get()
            && !self.closed.get()
            && let (Ok(socket), Some(handle)) = (self.socket(), Handle::try_current())
        {
            let conn = Rc::clone(self);
            if let Some(lp) = conn.io.lp_weak() {
                drop(handle.spawn(async move {
                    loop {
                        let (read, _) = socket.recv(&lp, vec![0u8; 1 << 16]).await;
                        match read {
                            Ok(0) => break conn.peer_end(),
                            Ok(_) => continue,
                            Err(_) => break,
                        }
                    }
                }));
            }
        }
        self.settle();
    }

    /// Both directions finished: the stream releases itself (its `close` event follows).
    fn settle(&self) {
        if self.closed.get() || !self.write_ended.get() || !(self.peer_ended.get() || self.read_ended.get()) {
            return;
        }
        self.close();
    }

    // ---- writes ----

    /// The error a write gets now, if any: the conn's failure, `BrokenPipe` after `end`, `BadHandle` once closed.
    fn refuse(&self, out: &Outbox) -> Result<(), NativeError> {
        if let Some(code) = out.failed {
            return Err(NativeError::Errno(if self.closed.get() && code == errno::CANCELED { errno::BAD_HANDLE } else { code }));
        }
        if self.closed.get() {
            return Err(NativeError::Errno(errno::BAD_HANDLE));
        }
        if out.ended {
            return Err(NativeError::Errno(errno::BROKEN_PIPE));
        }
        Ok(())
    }

    /// The direct lane: one non-blocking write, 0 while the outbox is busy or sends wait.
    pub(crate) fn direct_write(&self, bytes: &[u8]) -> Result<usize, NativeError> {
        let socket = self.socket()?;
        {
            let out = self.out.borrow();
            self.refuse(&out)?;
            if out.writing || out.waiting() > 0 {
                return Ok(0);
            }
        }
        match socket.try_write(bytes) {
            Ok(n) => Ok(n),
            Err(error) => {
                let code = errno::errno_of(&error);
                self.fail(code);
                Err(NativeError::Errno(code))
            }
        }
    }

    /// The queued lane: the bytes accepted (kernel plus queue), at most `max` of them queued. `spawn` starts the
    /// writer task when the outbox was idle and something is left.
    fn accept_bytes(
        self: &Rc<Conn>,
        lp: &Rc<Loop>,
        bytes: &[u8],
        max: usize,
        spawn: &dyn Fn(Task) -> Result<AbortHandle, NativeError>,
    ) -> Result<usize, NativeError> {
        let socket = self.socket()?;
        let mut out = self.out.borrow_mut();
        self.refuse(&out)?;
        if out.writing {
            let take = bytes.len().min(max);
            if take > 0 {
                out.queue.push_back(bytes[..take].to_vec());
                out.bytes += take;
                out.accepted += take as u64;
            }
            return Ok(take);
        }
        let kernel = match socket.try_write(bytes) {
            Ok(n) => n,
            Err(error) => {
                drop(out);
                let code = errno::errno_of(&error);
                self.fail(code);
                return Err(NativeError::Errno(code));
            }
        };
        out.accepted += kernel as u64;
        out.sent += kernel as u64;
        let rest = &bytes[kernel..bytes.len().min(kernel.saturating_add(max))];
        if rest.is_empty() {
            return Ok(kernel);
        }
        let queued = rest.len();
        out.bytes += queued;
        out.accepted += queued as u64;
        out.queue.push_back(rest.to_vec());
        out.writing = true;
        drop(out); // the writer polls once at spawn and takes the same borrow
        match spawn(Box::pin(write_pump(socket, Rc::clone(lp), Rc::clone(self)))) {
            Ok(handle) => {
                self.flow.aborts.borrow_mut().push(handle);
                Ok(kernel + queued)
            }
            Err(error) => {
                // No writer will ever drain the outbox: undo the queueing.
                let mut out = self.out.borrow_mut();
                out.queue.clear();
                out.bytes = 0;
                out.accepted -= queued as u64;
                out.writing = false;
                Err(error)
            }
        }
    }

    /// `queued.put`: as much as fits under `limit`; 0 while sends wait.
    pub(crate) fn put(
        self: &Rc<Conn>,
        lp: &Rc<Loop>,
        bytes: &[u8],
        spawn: &dyn Fn(Task) -> Result<AbortHandle, NativeError>,
    ) -> Result<usize, NativeError> {
        let room = {
            let out = self.out.borrow();
            self.refuse(&out)?;
            if out.waiting() > 0 {
                return Ok(0);
            }
            self.limit.get().saturating_sub(out.bytes)
        };
        self.accept_bytes(lp, bytes, room, spawn)
    }

    /// Takes a ticket and waits until it is served and `fits` says the outbox has room; the outbox's error when it
    /// fails first. The caller must call [`Conn::served`] once it acted.
    async fn turn(&self, fits: impl Fn(&Outbox) -> bool) -> Result<(), NativeError> {
        let ticket = {
            let mut out = self.out.borrow_mut();
            self.refuse(&out)?;
            out.next_ticket += 1;
            out.next_ticket - 1
        };
        let admitted = poll_fn(|cx| {
            let mut out = self.out.borrow_mut();
            if let Some(code) = out.failed {
                return Poll::Ready(Err(NativeError::Errno(code)));
            }
            if out.serving == ticket && fits(&out) {
                return Poll::Ready(Ok(()));
            }
            out.waiters.push(cx.waker().clone());
            Poll::Pending
        })
        .await;
        if admitted.is_err() {
            // A failed outbox serves nobody again; keep the count of waiting sends honest.
            let mut out = self.out.borrow_mut();
            out.serving = out.serving.max(ticket + 1);
        }
        admitted
    }

    /// The ticket being served acted: the next one may go.
    fn served(&self) {
        let mut out = self.out.borrow_mut();
        out.serving += 1;
        out.wake();
    }

    /// Resolves once every byte accepted so far reached the kernel.
    async fn flushed(&self) -> Result<(), NativeError> {
        let target = self.out.borrow().accepted;
        poll_fn(|cx| {
            let mut out = self.out.borrow_mut();
            if out.sent >= target {
                Poll::Ready(Ok(()))
            } else if let Some(code) = out.failed {
                Poll::Ready(Err(NativeError::Errno(code)))
            } else {
                out.waiters.push(cx.waker().clone());
                Poll::Pending
            }
        })
        .await
    }

    /// `queued.send`: all of `data` (copied by the caller), in turn, once it fits; resolves when it reached the kernel.
    pub(crate) async fn send(self: Rc<Conn>, lp: Rc<Loop>, data: Vec<u8>) -> Result<(), NativeError> {
        let len = data.len();
        let limit = &self.limit;
        self.turn(|out| out.bytes == 0 || out.bytes + len <= limit.get()).await?;
        let accepted = self.accept_bytes(&lp, &data, usize::MAX, &spawn_here);
        self.served();
        accepted?;
        self.flushed().await
    }

    /// `queued.drained()`: resolves once no send waits and everything accepted reached the kernel.
    pub(crate) async fn drained(self: Rc<Conn>) -> Result<(), NativeError> {
        if self.closed.get() {
            return Err(NativeError::Errno(errno::BAD_HANDLE));
        }
        poll_fn(|cx| {
            let mut out = self.out.borrow_mut();
            if let Some(code) = out.failed {
                Poll::Ready(Err(NativeError::Errno(code)))
            } else if out.waiting() == 0 && out.bytes == 0 && out.sent >= out.accepted {
                Poll::Ready(Ok(()))
            } else {
                out.waiters.push(cx.waker().clone());
                Poll::Pending
            }
        })
        .await
    }

    /// `end('write')`: after what waits, no more writes; resolves once the FIN is out.
    pub(crate) async fn end_write(self: Rc<Conn>, lp: Rc<Loop>) -> Result<(), NativeError> {
        self.turn(|_| true).await?;
        let started = {
            let mut out = self.out.borrow_mut();
            let first = !std::mem::replace(&mut out.ended, true);
            first && !out.writing && out.failed.is_none()
        };
        self.served();
        if started {
            let socket = self.socket()?;
            if socket.is_tls() {
                // `close_notify` then the FIN take the loop.
                self.out.borrow_mut().writing = true;
                let task: Task = Box::pin(write_pump(socket, lp, Rc::clone(&self)));
                let handle = spawn_here(task)?;
                self.flow.aborts.borrow_mut().push(handle);
            } else {
                socket.shutdown_write();
                self.out.borrow_mut().finished = true;
            }
        }
        poll_fn(|cx| {
            let mut out = self.out.borrow_mut();
            if out.finished {
                Poll::Ready(Ok(()))
            } else if let Some(code) = out.failed {
                Poll::Ready(Err(NativeError::Errno(code)))
            } else {
                out.waiters.push(cx.waker().clone());
                Poll::Pending
            }
        })
        .await?;
        self.write_ended.set(true);
        self.settle();
        Ok(())
    }
}

/// Spawns on the runtime polling the current task (an op's future runs on its conn's runtime).
fn spawn_here(task: Task) -> Result<AbortHandle, NativeError> {
    let handle = Handle::try_current().ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
    Ok(handle.spawn_eager(task).abort_handle())
}

/// Flushes the outbox of a stream whose kernel buffer was full, in order, then sends the FIN of a pending `end`.
async fn write_pump(socket: Rc<Socket>, lp: Rc<Loop>, conn: Rc<Conn>) {
    loop {
        let next = conn.out.borrow_mut().queue.pop_front();
        let Some(mut chunk) = next else {
            let fin = {
                let mut out = conn.out.borrow_mut();
                let fin = out.ended && out.failed.is_none() && !out.finished;
                if !fin {
                    out.writing = false;
                    out.wake();
                }
                fin
            };
            if fin {
                socket.finish_write().await;
                let mut out = conn.out.borrow_mut();
                out.finished = true;
                out.writing = false;
                out.wake();
            }
            conn.push(EventKind::Drain);
            return;
        };
        while !chunk.is_empty() {
            let (result, buf) = socket.send(&lp, chunk).await;
            chunk = buf;
            let sent = match result {
                Ok(0) => Err(errno::BROKEN_PIPE),
                Ok(n) => Ok(n),
                Err(error) => Err(errno::errno_of(&error)),
            };
            match sent {
                Ok(n) => {
                    chunk.drain(..n);
                    let mut out = conn.out.borrow_mut();
                    out.bytes -= n;
                    out.sent += n as u64;
                    out.wake();
                }
                Err(code) => {
                    conn.out.borrow_mut().writing = false;
                    conn.fail(code);
                    return;
                }
            }
        }
    }
}

/// Counts a pull-mode operation for as long as it lives.
pub(crate) struct Busy(Rc<Conn>);

impl Busy {
    pub(crate) fn new(conn: &Rc<Conn>) -> Busy {
        conn.pending.set(conn.pending.get() + 1);
        Busy(Rc::clone(conn))
    }
}

impl Drop for Busy {
    fn drop(&mut self) {
        self.0.pending.set(self.0.pending.get() - 1);
    }
}

/// The conn behind one guest object. A transfer (`pulling()`, `toEvented()`, a TLS handshake) takes it out, and the
/// object answers `BadHandle` from then on; so does `close()`.
pub(crate) struct Front(RefCell<Option<Rc<Conn>>>);

impl Front {
    pub(crate) fn new(conn: Rc<Conn>) -> Front {
        Front(RefCell::new(Some(conn)))
    }

    /// The live conn; `BadHandle` once consumed or closed.
    pub(crate) fn get(&self) -> Result<Rc<Conn>, NativeError> {
        self.0.borrow().clone().filter(|conn| !conn.is_closed()).ok_or(NativeError::Errno(errno::BAD_HANDLE))
    }

    /// The conn, closed or not; `BadHandle` once consumed. What `pause`/`resume` need: a conn that failed while paused
    /// still holds its `error` and `close` events back until `resume`.
    pub(crate) fn conn(&self) -> Result<Rc<Conn>, NativeError> {
        self.0.borrow().clone().ok_or(NativeError::Errno(errno::BAD_HANDLE))
    }

    /// Takes the live conn out after `check` accepted it.
    pub(crate) fn take(&self, check: impl FnOnce(&Conn) -> Result<(), NativeError>) -> Result<Rc<Conn>, NativeError> {
        let conn = self.get()?;
        check(&conn)?;
        self.0.borrow_mut().take();
        Ok(conn)
    }

    /// Closes the conn (if it is still this object's) and lets go of it.
    pub(crate) fn close(&self) {
        let taken = self.0.borrow_mut().take();
        if let Some(conn) = taken {
            conn.flow.released.set(true);
            conn.close();
        }
    }

    /// Whether the object no longer fronts an open conn of an open runtime.
    pub(crate) fn closed(&self, host: &crate::HostState) -> bool {
        self.get().map_or(true, |conn| !conn.io.open(host))
    }

    pub(crate) fn local_addr(&self) -> Result<crate::net::SockAddr, NativeError> {
        self.get()?.local.map(crate::net::SockAddr).ok_or(NativeError::Errno(errno::NOT_CONNECTED))
    }

    pub(crate) fn peer_addr(&self) -> Result<crate::net::SockAddr, NativeError> {
        self.get()?.peer.get().map(crate::net::SockAddr).ok_or(NativeError::Errno(errno::NOT_CONNECTED))
    }
}
