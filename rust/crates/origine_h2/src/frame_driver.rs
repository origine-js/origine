//! The async side of [`FrameSession`]: a [`FrameDriver`] future that moves bytes between a [`Transport`] and the
//! session, and a [`FrameConn`] handle through which the owner reads frame events, submits frames and waits for
//! its DATA to leave. Like [`crate::Driver`], one task (`run`) does all the I/O; everything else is a short
//! synchronous call on the session followed by a wake of that task.

use crate::driver::ConnError;
use crate::error::H2Error;
use crate::event::Role;
use crate::frames::{FrameEvent, FrameOptions, FrameSession};
use origine_transport::Transport;
use std::cell::RefCell;
use std::collections::VecDeque;
use std::future::{Future, poll_fn};
use std::io;
use std::pin::Pin;
use std::rc::Rc;
use std::task::{Context, Poll, Waker};

const READ_CHUNK: usize = 16 * 1024;

#[derive(Default)]
struct Inner {
    events: VecDeque<FrameEvent>,
    reader: Option<Waker>,
    /// Who waits for DATA to leave (or a stream to close).
    writers: Vec<Waker>,
    driver: Option<Waker>,
    /// How the connection ended (`Ok` for a clean end); taken once by `next`.
    done: Option<Result<(), ConnError>>,
    /// `next` answered the end.
    finished: bool,
    /// The owner closed the connection: the driver stops.
    closed: bool,
}

struct Shared {
    session: RefCell<FrameSession>,
    inner: RefCell<Inner>,
    /// Told whenever an event is queued or the connection ends (event delivery on the owner's thread).
    notify: RefCell<Option<Box<dyn Fn()>>>,
}

impl Shared {
    fn kick(&self) {
        let waker = self.inner.borrow_mut().driver.take();
        if let Some(w) = waker {
            w.wake();
        }
    }

    fn notify(&self) {
        if let Some(notify) = self.notify.borrow().as_ref() {
            notify();
        }
    }
}

/// The two halves of a frame-level connection.
pub fn frame_connect<T: Transport + 'static>(
    role: Role,
    options: &FrameOptions,
    transport: T,
) -> Result<(FrameConn, FrameDriver<T>), H2Error> {
    let session = FrameSession::new(role, options)?;
    let shared = Rc::new(Shared { session: RefCell::new(session), inner: RefCell::default(), notify: RefCell::new(None) });
    Ok((FrameConn { shared: Rc::clone(&shared) }, FrameDriver { shared, transport: Rc::new(transport) }))
}

/// A handle on a frame-level connection; cheap to clone.
#[derive(Clone)]
pub struct FrameConn {
    shared: Rc<Shared>,
}

/// What `next` and `try_next` answer.
#[derive(Debug, PartialEq, Eq)]
pub enum Next {
    Event(FrameEvent),
    /// The connection failed (answered once, before `End`).
    Failed(ConnError),
    /// The connection is over: nothing follows.
    End,
}

impl FrameConn {
    /// Runs `f` on the session (a submit), then wakes the driver to send what it queued.
    pub fn with<R>(&self, f: impl FnOnce(&mut FrameSession) -> Result<R, H2Error>) -> Result<R, H2Error> {
        if self.is_done() {
            return Err(H2Error::InvalidState("connection closed"));
        }
        let result = f(&mut self.shared.session.borrow_mut());
        self.shared.kick();
        result
    }

    /// Reads the session (info).
    pub fn read<R>(&self, f: impl FnOnce(&FrameSession) -> R) -> R {
        f(&self.shared.session.borrow())
    }

    /// Whether the connection is over (ended, failed or closed).
    pub fn is_done(&self) -> bool {
        let inner = self.shared.inner.borrow();
        inner.done.is_some() || inner.closed || inner.finished
    }

    /// Calls `notify` whenever an event is queued or the connection ends.
    pub fn set_notify(&self, notify: Box<dyn Fn()>) {
        *self.shared.notify.borrow_mut() = Some(notify);
    }

    /// The next event without waiting; `None` when none is queued yet.
    pub fn try_next(&self) -> Option<Next> {
        let mut inner = self.shared.inner.borrow_mut();
        if let Some(event) = inner.events.pop_front() {
            return Some(Next::Event(event));
        }
        if inner.finished {
            return Some(Next::End);
        }
        match inner.done.take() {
            Some(done) => {
                inner.finished = true;
                Some(match done {
                    Err(e) => Next::Failed(e),
                    Ok(()) => Next::End,
                })
            }
            None if inner.closed => {
                inner.finished = true;
                Some(Next::End)
            }
            None => None,
        }
    }

    /// The next event; after the end, [`Next::End`] again.
    pub async fn next(&self) -> Next {
        poll_fn(|cx| {
            if let Some(next) = self.try_next() {
                return Poll::Ready(next);
            }
            self.shared.inner.borrow_mut().reader = Some(cx.waker().clone());
            Poll::Pending
        })
        .await
    }

    /// Queues DATA (see [`FrameSession::data`]); the future resolves once it was packed into frames, and fails
    /// if the stream or the connection ends first.
    pub fn data(
        &self,
        stream: u32,
        data: Vec<u8>,
        end_stream: bool,
        padding: Option<usize>,
    ) -> Result<impl Future<Output = Result<(), H2Error>> + use<>, H2Error> {
        let target = self.with(|session| session.data(stream, data, end_stream, padding))?;
        let shared = Rc::clone(&self.shared);
        Ok(poll_fn(move |cx| {
            let (sent, closed) = shared.session.borrow().sent(stream);
            if sent >= target {
                return Poll::Ready(Ok(()));
            }
            let mut inner = shared.inner.borrow_mut();
            if closed || inner.done.is_some() || inner.closed || inner.finished {
                return Poll::Ready(Err(H2Error::InvalidState("stream closed")));
            }
            inner.writers.push(cx.waker().clone());
            Poll::Pending
        }))
    }

    /// Ends the connection now (no GOAWAY: submit one first for a graceful end). Waiters are woken.
    pub fn close(&self) {
        let wake = {
            let mut inner = self.shared.inner.borrow_mut();
            inner.closed = true;
            let mut wake: Vec<Waker> = std::mem::take(&mut inner.writers);
            wake.extend(inner.reader.take());
            wake.extend(inner.driver.take());
            wake
        };
        for w in wake {
            w.wake();
        }
        self.shared.notify();
    }
}

/// Runs a frame-level connection's I/O.
pub struct FrameDriver<T> {
    shared: Rc<Shared>,
    transport: Rc<T>,
}

type ReadFuture = Pin<Box<dyn Future<Output = (io::Result<usize>, Vec<u8>)>>>;
type WriteFuture = Pin<Box<dyn Future<Output = (io::Result<()>, Vec<u8>)>>>;

impl<T: Transport + 'static> FrameDriver<T> {
    /// Moves bytes until the connection ends: `Ok` when both sides are done (GOAWAY) or the peer closed the
    /// transport, or the owner closed it.
    pub async fn run(self) -> Result<(), ConnError> {
        let result = self.pump().await;
        let wake = {
            let mut inner = self.shared.inner.borrow_mut();
            if !inner.closed {
                inner.done = Some(result.clone());
            }
            let mut wake: Vec<Waker> = std::mem::take(&mut inner.writers);
            wake.extend(inner.reader.take());
            wake
        };
        for w in wake {
            w.wake();
        }
        self.shared.notify();
        result
    }

    async fn pump(&self) -> Result<(), ConnError> {
        let shared = &self.shared;
        let mut read: Option<ReadFuture> = None;
        let mut write: Option<WriteFuture> = None;
        let mut spare: Vec<u8> = Vec::new();
        let mut eof = false;
        let mut fatal: Option<ConnError> = None;
        poll_fn(|cx: &mut Context<'_>| {
            if shared.inner.borrow().closed {
                return Poll::Ready(Ok(()));
            }
            loop {
                let mut progress = false;
                if let Some(w) = write.as_mut()
                    && let Poll::Ready((result, _)) = w.as_mut().poll(cx)
                {
                    write = None;
                    progress = true;
                    if let Err(e) = result {
                        return Poll::Ready(Err(ConnError::Transport(e.kind(), e.to_string())));
                    }
                }
                if write.is_none() {
                    let mut out = Vec::new();
                    if let Err(e) = shared.session.borrow_mut().send(&mut out) {
                        fatal.get_or_insert(ConnError::Protocol(e));
                    }
                    // Packing DATA moved the stream's counters: who waits may go on.
                    let writers: Vec<Waker> = std::mem::take(&mut shared.inner.borrow_mut().writers);
                    for w in writers {
                        w.wake();
                    }
                    if !out.is_empty() {
                        let transport = Rc::clone(&self.transport);
                        write = Some(Box::pin(async move { transport.write_all(out).await }));
                        progress = true;
                    }
                }
                if read.is_none() && !eof && fatal.is_none() && shared.session.borrow().wants_read() {
                    let mut buf = std::mem::take(&mut spare);
                    buf.resize(READ_CHUNK, 0);
                    let transport = Rc::clone(&self.transport);
                    read = Some(Box::pin(async move { transport.read(buf).await }));
                }
                if let Some(r) = read.as_mut()
                    && let Poll::Ready((result, buf)) = r.as_mut().poll(cx)
                {
                    read = None;
                    progress = true;
                    match result {
                        Err(e) => return Poll::Ready(Err(ConnError::Transport(e.kind(), e.to_string()))),
                        Ok(0) => eof = true,
                        Ok(n) => {
                            if let Err(e) = shared.session.borrow_mut().recv(&buf[..n]) {
                                fatal.get_or_insert(ConnError::Protocol(e));
                            }
                        }
                    }
                    spare = buf;
                }
                if route(shared) {
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
                if eof {
                    return Poll::Ready(Ok(()));
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

/// Moves the session's events to the owner's queue; true if there were any.
fn route(shared: &Shared) -> bool {
    let mut moved = false;
    loop {
        let event = shared.session.borrow_mut().next_event();
        let Some(event) = event else { break };
        moved = true;
        shared.inner.borrow_mut().events.push_back(event);
    }
    if moved {
        let reader = shared.inner.borrow_mut().reader.take();
        if let Some(w) = reader {
            w.wake();
        }
        shared.notify();
    }
    moved
}
