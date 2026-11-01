//! The async side of [`Session`]: a [`Driver`] future that moves bytes between a [`Transport`] and the
//! session, and [`Connection`] / [`Exchange`] handles through which tasks open streams, read events and
//! write bodies. No executor is assumed: spawn `Driver::run` wherever tasks run (it is `!Send`).
//!
//! One task per connection (`run`) does all the I/O; everything else is a short synchronous call on the
//! session followed by a wake of that task, so nothing here holds a borrow across an await.

use crate::error::H2Error;
use crate::event::{Event, HeaderKind, Limits, Pseudo, Role};
use crate::fields::FieldList;
use crate::session::{Body, RequestHead, Session};
use origine_transport::Transport;
use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::future::{Future, poll_fn};
use std::io;
use std::pin::Pin;
use std::rc::Rc;
use std::task::{Context, Poll, Waker};
use std::time::{Duration, Instant};

const CANCEL: u32 = 8;
const READ_CHUNK: usize = 16 * 1024;

/// Why a connection ended. Cloneable so every stream can be told.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ConnError {
    /// The transport failed or ended while streams were open.
    Transport(io::ErrorKind, String),
    /// An HTTP/2 protocol error (ours or the peer's), after which the connection is closed.
    Protocol(H2Error),
    /// The connection was shut down (GOAWAY handled, or `close` finished) and no stream can start.
    Closed,
}

fn transport_error(e: io::Error) -> ConnError {
    ConnError::Transport(e.kind(), e.to_string())
}

/// What a stream's reader sees, in order. After `Closed` or `Aborted`, `next` returns `None`.
#[derive(Debug, PartialEq, Eq)]
pub enum StreamEvent {
    /// A batch of a header block ([`Event::Headers`]).
    Headers { kind: HeaderKind, pseudo: Pseudo, fields: FieldList, last: bool, end_stream: bool },
    /// Body bytes; give them back with [`Exchange::consume`] once used.
    Data(Vec<u8>),
    /// The peer ended its side with a DATA frame.
    End,
    /// The stream is over: `0` normally, else the HTTP/2 error code of the reset.
    Closed(u32),
    /// The connection died with the stream open.
    Aborted(ConnError),
}

impl StreamEvent {
    fn is_terminal(&self) -> bool {
        matches!(self, StreamEvent::Closed(_) | StreamEvent::Aborted(_))
    }
}

#[derive(Default)]
struct Inbox {
    events: VecDeque<StreamEvent>,
    reader: Option<Waker>,
    writer: Option<Waker>,
    /// A terminal event was queued (the stream accepts nothing more).
    ended: bool,
    /// A terminal event was handed out.
    delivered: bool,
    /// Our side of the stream is complete (head without body, or body finished).
    local_done: bool,
}

struct Ping {
    id: u64,
    sent: Instant,
    rtt: Option<Duration>,
    waker: Option<Waker>,
}

#[derive(Default)]
struct Inner {
    streams: HashMap<u32, Inbox>,
    accept: VecDeque<u32>,
    accept_wakers: Vec<Waker>,
    ready: bool,
    ready_wakers: Vec<Waker>,
    goaway: Option<(u32, u32)>,
    pings: Vec<Ping>,
    next_ping: u64,
    driver: Option<Waker>,
    /// The driver finished: `Ok` for a clean end.
    done: Option<Result<(), ConnError>>,
}

struct Shared {
    session: RefCell<Session>,
    inner: RefCell<Inner>,
    limits: Limits,
    role: Role,
}

impl Shared {
    fn kick(&self) {
        let waker = self.inner.borrow_mut().driver.take();
        if let Some(w) = waker {
            w.wake();
        }
    }

    fn refuse_if_done(&self) -> Result<(), H2Error> {
        if self.inner.borrow().done.is_some() {
            return Err(H2Error::InvalidState("connection closed"));
        }
        Ok(())
    }
}

/// The two halves of a connection: the handle tasks use, and the future that does the I/O.
pub fn connect<T: Transport + 'static>(role: Role, limits: Limits, transport: T) -> Result<(Connection, Driver<T>), H2Error> {
    let session = Session::new(role, limits)?;
    let shared = Rc::new(Shared { session: RefCell::new(session), inner: RefCell::default(), limits, role });
    Ok((Connection { shared: shared.clone() }, Driver { shared, transport: Rc::new(transport) }))
}

/// A handle on a connection; cheap to clone.
#[derive(Clone)]
pub struct Connection {
    shared: Rc<Shared>,
}

/// Runs a connection's I/O. Spawn `run()` and keep it running as long as the connection lives.
pub struct Driver<T> {
    shared: Rc<Shared>,
    transport: Rc<T>,
}

impl Connection {
    /// Waits for the peer's SETTINGS. Open streams after this, not before: until then the peer's
    /// limits are unknown (see the crate docs).
    pub async fn ready(&self) -> Result<(), ConnError> {
        poll_fn(|cx| {
            let mut inner = self.shared.inner.borrow_mut();
            if inner.ready {
                return Poll::Ready(Ok(()));
            }
            if let Some(done) = &inner.done {
                return Poll::Ready(Err(done.clone().err().unwrap_or(ConnError::Closed)));
            }
            inner.ready_wakers.push(cx.waker().clone());
            Poll::Pending
        })
        .await
    }

    /// Server side: the next request stream, or `None` once the connection is over.
    pub async fn accept(&self) -> Option<Exchange> {
        poll_fn(|cx| {
            let mut inner = self.shared.inner.borrow_mut();
            if let Some(id) = inner.accept.pop_front() {
                return Poll::Ready(Some(Exchange { shared: self.shared.clone(), id }));
            }
            if inner.done.is_some() {
                return Poll::Ready(None);
            }
            inner.accept_wakers.push(cx.waker().clone());
            Poll::Pending
        })
        .await
    }

    /// Client side: opens a request stream and queues its head. The stream is yours until the returned
    /// `Exchange` is dropped (which resets it if it is still open).
    pub fn open(&self, head: &RequestHead<'_>, fields: &FieldList, body: Body) -> Result<Exchange, H2Error> {
        self.shared.refuse_if_done()?;
        if self.shared.inner.borrow().goaway.is_some() {
            return Err(H2Error::InvalidState("the peer is closing the connection"));
        }
        let id = self.shared.session.borrow_mut().submit_request(head, fields, body)?;
        self.shared.inner.borrow_mut().streams.insert(id, Inbox { local_done: body == Body::None, ..Inbox::default() });
        self.shared.kick();
        Ok(Exchange { shared: self.shared.clone(), id })
    }

    /// Round trip of a PING.
    pub async fn ping(&self) -> Result<Duration, ConnError> {
        let id = {
            let mut inner = self.shared.inner.borrow_mut();
            inner.next_ping += 1;
            let id = inner.next_ping;
            inner.pings.push(Ping { id, sent: Instant::now(), rtt: None, waker: None });
            id
        };
        if let Err(e) = self.shared.session.borrow_mut().ping(id.to_le_bytes()) {
            self.shared.inner.borrow_mut().pings.retain(|p| p.id != id);
            return Err(ConnError::Protocol(e));
        }
        self.shared.kick();
        poll_fn(|cx| {
            let mut inner = self.shared.inner.borrow_mut();
            let done = inner.done.clone();
            let Some(i) = inner.pings.iter().position(|p| p.id == id) else { return Poll::Ready(Err(ConnError::Closed)) };
            if let Some(rtt) = inner.pings[i].rtt {
                inner.pings.remove(i);
                return Poll::Ready(Ok(rtt));
            }
            if let Some(done) = done {
                inner.pings.remove(i);
                return Poll::Ready(Err(done.err().unwrap_or(ConnError::Closed)));
            }
            inner.pings[i].waker = Some(cx.waker().clone());
            Poll::Pending
        })
        .await
    }

    /// Starts a graceful close: GOAWAY, then streams in flight finish and the driver ends.
    pub fn close(&self) {
        let _ = self.shared.session.borrow_mut().goaway(0);
        self.shared.kick();
    }

    /// How the connection ended, once it has: `None` while it runs or after a clean end.
    pub fn error(&self) -> Option<ConnError> {
        self.shared.inner.borrow().done.clone().and_then(Result::err)
    }
}

/// One request/response pair on a stream, for either side.
pub struct Exchange {
    shared: Rc<Shared>,
    id: u32,
}

impl Exchange {
    pub fn id(&self) -> u32 {
        self.id
    }

    /// The next event of the stream; `None` after its terminal event.
    pub async fn next(&self) -> Option<StreamEvent> {
        poll_fn(|cx| {
            let mut inner = self.shared.inner.borrow_mut();
            let Some(inbox) = inner.streams.get_mut(&self.id) else { return Poll::Ready(None) };
            if let Some(event) = inbox.events.pop_front() {
                if event.is_terminal() {
                    inbox.delivered = true;
                }
                return Poll::Ready(Some(event));
            }
            if inbox.delivered {
                return Poll::Ready(None);
            }
            inbox.reader = Some(cx.waker().clone());
            Poll::Pending
        })
        .await
    }

    /// Gives `bytes` of received body back to the peer's window. Call it when the data was used, not
    /// when it arrived: that is the backpressure.
    pub fn consume(&self, bytes: usize) {
        let _ = self.shared.session.borrow_mut().consume(self.id, bytes);
        self.shared.kick();
    }

    /// Server side: queues the response head.
    pub fn respond(&self, status: u16, fields: &FieldList, body: Body) -> Result<(), H2Error> {
        self.shared.session.borrow_mut().submit_response(self.id, status, fields, body)?;
        if body == Body::None {
            self.mark_local_done();
        }
        self.shared.kick();
        Ok(())
    }

    /// Queues body bytes. Waits while more than `Limits.window` bytes of this stream are already queued
    /// and unsent, so a fast writer cannot outrun the peer; an empty queue always takes the chunk.
    pub async fn send(&self, data: Vec<u8>) -> Result<(), H2Error> {
        let mut data = Some(data);
        poll_fn(|cx| {
            let mut inner = self.shared.inner.borrow_mut();
            match inner.streams.get_mut(&self.id) {
                None => return Poll::Ready(Err(H2Error::InvalidState("stream closed"))),
                Some(inbox) if inbox.ended => return Poll::Ready(Err(H2Error::InvalidState("stream closed"))),
                Some(inbox) => {
                    let queued = self.shared.session.borrow().queued(self.id);
                    if queued > 0 && queued > self.shared.limits.window as usize {
                        inbox.writer = Some(cx.waker().clone());
                        return Poll::Pending;
                    }
                }
            }
            drop(inner);
            let result = self.shared.session.borrow_mut().send_data(self.id, data.take().unwrap_or_default());
            self.shared.kick();
            Poll::Ready(result)
        })
        .await
    }

    /// Ends the body, with trailing fields if given.
    pub fn finish(&self, trailers: Option<FieldList>) -> Result<(), H2Error> {
        self.shared.session.borrow_mut().finish(self.id, trailers)?;
        self.mark_local_done();
        self.shared.kick();
        Ok(())
    }

    fn mark_local_done(&self) {
        if let Some(inbox) = self.shared.inner.borrow_mut().streams.get_mut(&self.id) {
            inbox.local_done = true;
        }
    }

    /// Bytes given to `send` that have not left yet.
    pub fn queued(&self) -> usize {
        self.shared.session.borrow().queued(self.id)
    }

    /// Resets the stream.
    pub fn reset(&self, code: u32) {
        let _ = self.shared.session.borrow_mut().reset(self.id, code);
        self.shared.kick();
    }
}

/// Dropping an exchange whose own side is still being written cancels the stream (RST_STREAM
/// `CANCEL`). Dropping one whose side is complete lets the stream finish quietly, so the response a
/// server just queued is not cut off, and later data is discarded; to abandon a request, call `reset`.
impl Drop for Exchange {
    fn drop(&mut self) {
        let removed = self.shared.inner.borrow_mut().streams.remove(&self.id);
        if let Some(inbox) = removed
            && !inbox.ended
            && !inbox.local_done
        {
            let _ = self.shared.session.borrow_mut().reset(self.id, CANCEL);
            self.shared.kick();
        }
    }
}

// ---- the driver ----

type ReadFuture = Pin<Box<dyn Future<Output = (io::Result<usize>, Vec<u8>)>>>;
type WriteFuture = Pin<Box<dyn Future<Output = (io::Result<()>, Vec<u8>)>>>;

impl<T: Transport + 'static> Driver<T> {
    /// Moves bytes until the connection ends. `Ok` is a clean end (everything finished, or the peer
    /// closed an idle connection); streams still open at an error get [`StreamEvent::Aborted`].
    pub async fn run(self) -> Result<(), ConnError> {
        let result = self.pump().await;
        self.finish(result.clone());
        result
    }

    fn finish(&self, result: Result<(), ConnError>) {
        let mut wake = Vec::new();
        {
            let mut inner = self.shared.inner.borrow_mut();
            let abort = result.clone().err().unwrap_or(ConnError::Closed);
            for inbox in inner.streams.values_mut() {
                if !inbox.ended {
                    inbox.ended = true;
                    inbox.events.push_back(StreamEvent::Aborted(abort.clone()));
                }
                wake.extend(inbox.reader.take());
                wake.extend(inbox.writer.take());
            }
            inner.done = Some(result);
            wake.append(&mut inner.accept_wakers);
            wake.append(&mut inner.ready_wakers);
            wake.extend(inner.pings.iter_mut().filter_map(|p| p.waker.take()));
        }
        for w in wake {
            w.wake();
        }
    }

    async fn pump(&self) -> Result<(), ConnError> {
        let shared = &self.shared;
        let mut read: Option<ReadFuture> = None;
        let mut write: Option<WriteFuture> = None;
        let mut spare: Vec<u8> = Vec::new();
        let mut eof = false;
        let mut fatal: Option<ConnError> = None;
        poll_fn(|cx: &mut Context<'_>| {
            loop {
                let mut progress = false;

                if let Some(w) = write.as_mut()
                    && let Poll::Ready((result, _)) = w.as_mut().poll(cx)
                {
                    write = None;
                    progress = true;
                    if let Err(e) = result {
                        return Poll::Ready(Err(transport_error(e)));
                    }
                    wake_writers(shared);
                }
                if write.is_none() {
                    let mut out = Vec::new();
                    if let Err(e) = shared.session.borrow_mut().send(&mut out) {
                        fatal.get_or_insert(ConnError::Protocol(e));
                    }
                    if !out.is_empty() {
                        let transport = self.transport.clone();
                        write = Some(Box::pin(async move { transport.write_all(out).await }));
                        progress = true;
                    }
                }

                if read.is_none() && !eof && fatal.is_none() && shared.session.borrow().wants_read() {
                    let mut buf = std::mem::take(&mut spare);
                    buf.resize(READ_CHUNK, 0);
                    let transport = self.transport.clone();
                    read = Some(Box::pin(async move { transport.read(buf).await }));
                }
                if let Some(r) = read.as_mut()
                    && let Poll::Ready((result, buf)) = r.as_mut().poll(cx)
                {
                    read = None;
                    progress = true;
                    match result {
                        Err(e) => return Poll::Ready(Err(transport_error(e))),
                        Ok(0) => eof = true,
                        Ok(n) => {
                            if let Err(e) = shared.session.borrow_mut().recv(&buf[..n]) {
                                fatal.get_or_insert(ConnError::Protocol(e));
                            }
                        }
                    }
                    spare = buf;
                }

                if route_events(shared) {
                    progress = true;
                }
                if !progress {
                    break;
                }
            }

            if write.is_none() {
                if let Some(e) = fatal.clone() {
                    return Poll::Ready(Err(e));
                }
                let streams_open = shared.inner.borrow().streams.values().any(|i| !i.ended);
                if eof {
                    return Poll::Ready(if streams_open {
                        Err(ConnError::Transport(io::ErrorKind::UnexpectedEof, "connection closed with streams open".into()))
                    } else {
                        Ok(())
                    });
                }
                let session = shared.session.borrow();
                if !session.wants_read() && !session.wants_write() {
                    return Poll::Ready(Ok(()));
                }
            }
            shared.inner.borrow_mut().driver = Some(cx.waker().clone());
            Poll::Pending
        })
        .await
    }
}

fn wake_writers(shared: &Shared) {
    let wake: Vec<Waker> = shared.inner.borrow_mut().streams.values_mut().filter_map(|i| i.writer.take()).collect();
    for w in wake {
        w.wake();
    }
}

/// Moves the session's events into stream inboxes and wakes whoever waits. True if there were any.
fn route_events(shared: &Shared) -> bool {
    let events: Vec<Event> = {
        let mut session = shared.session.borrow_mut();
        std::iter::from_fn(|| session.next_event()).collect()
    };
    if events.is_empty() {
        return false;
    }
    let mut wake: Vec<Waker> = Vec::new();
    let mut give_back: Vec<(u32, usize)> = Vec::new();
    {
        let mut inner = shared.inner.borrow_mut();
        for event in events {
            match event {
                Event::Settings => {
                    inner.ready = true;
                    wake.append(&mut inner.ready_wakers);
                }
                Event::Headers { stream, kind, pseudo, fields, last, end_stream } => {
                    if kind == HeaderKind::Request && shared.role == Role::Server && !inner.streams.contains_key(&stream) {
                        inner.streams.insert(stream, Inbox::default());
                        inner.accept.push_back(stream);
                        wake.append(&mut inner.accept_wakers);
                    }
                    push(&mut inner, stream, StreamEvent::Headers { kind, pseudo, fields, last, end_stream }, &mut wake);
                }
                Event::Data { stream, data } => {
                    let len = data.len();
                    if !push(&mut inner, stream, StreamEvent::Data(data), &mut wake) {
                        give_back.push((stream, len));
                    }
                }
                Event::End { stream } => {
                    push(&mut inner, stream, StreamEvent::End, &mut wake);
                }
                Event::Closed { stream, code } => {
                    if let Some(inbox) = inner.streams.get_mut(&stream)
                        && !inbox.ended
                    {
                        inbox.ended = true;
                        inbox.events.push_back(StreamEvent::Closed(code));
                        wake.extend(inbox.reader.take());
                        wake.extend(inbox.writer.take());
                    }
                }
                Event::GoAway { last_stream, code, .. } => {
                    inner.goaway = Some((last_stream, code));
                }
                Event::PingAck { data } => {
                    let id = u64::from_le_bytes(data);
                    if let Some(p) = inner.pings.iter_mut().find(|p| p.id == id) {
                        p.rtt = Some(p.sent.elapsed());
                        wake.extend(p.waker.take());
                    }
                }
            }
        }
    }
    for (stream, len) in give_back {
        let _ = shared.session.borrow_mut().consume(stream, len);
    }
    for w in wake {
        w.wake();
    }
    true
}

/// Queues an event on a stream's inbox; false when nobody holds the stream any more.
fn push(inner: &mut Inner, stream: u32, event: StreamEvent, wake: &mut Vec<Waker>) -> bool {
    let Some(inbox) = inner.streams.get_mut(&stream) else { return false };
    inbox.events.push_back(event);
    wake.extend(inbox.reader.take());
    true
}
