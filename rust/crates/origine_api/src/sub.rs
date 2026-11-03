//! The event side of a conn: `register(event, handler)`, `pause`/`resume`, the pumps that feed it and the delivery
//! of its events on the isolate thread.
//!
//! # Flow
//! * The handlers are held natively: a conn that is `register`ed gets a [`Hub`] in the Host (its handlers as
//!   `Global<Function>`s, its context and its reused `DataEvent`), keyed by an internal id that never reaches JS.
//! * The first handler of the event that makes the conn flow (`data`, `connection`, `datagram`) spawns a **pump**
//!   task: it re-arms `recv` (`accept`) after every completion and queues an [`Event`] on the host-wide queue. The
//!   task never touches V8. It stops re-arming while [`MAX_QUEUED`] events are undelivered, so a slow handler
//!   backpressures the peer through TCP.
//! * [`crate::host::poll`] drains the queue on the isolate thread ([`deliver`]): it calls the handlers inside the
//!   hub's context and runs a microtask checkpoint after each event. A handler that throws goes to the `error`
//!   handlers; with none (or when one of them throws) it becomes an unhandled rejection.
//! * A stream's pump receives straight into **slabs**: [`SLAB`]-byte V8 backing stores (allocated by the isolate's
//!   `ArrayBuffer` allocator, so inside the V8 sandbox when there is one) that no guest object wraps while the loop
//!   owns a window of it. Each receive gets the next [`CHUNK`] bytes of the current slab and keeps only the bytes
//!   that arrived. `DataEvent.buffer()` carves exactly those bytes out of the slab ([`pinned::carve`]) into a new
//!   `ArrayBuffer` (a *lease*); nothing is copied, and the slab goes back to the allocator with its last lease.
//! * `pause` parks the conn's read-side events (in order) instead of dispatching them; `resume` puts them back in
//!   front of the queue. The pump keeps its bound, so a paused conn holds at most that many chunks. The write side
//!   is not paused: `drain` is always dispatched. See [`Pause`].
//!
//! # Lifetime
//! Hubs never keep the host alive by themselves: the pump task and its in-flight `recv`/`accept` are excluded
//! from [`crate::HostState::live_items`] (the [`Idle`] counters). `io.run()` resolves once every flowing conn of
//! the runtime has delivered its `close` event. Closing the runtime drops the hubs without calling their handlers.

use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::future::poll_fn;
use std::net::{SocketAddr, TcpStream, UdpSocket};
use std::os::fd::{FromRawFd, OwnedFd};
use std::rc::Rc;
use std::task::{Context, Poll, Waker};

use origine_api_core::{NativeError, errno};
use origine_io::Loop;
use origine_io::rt::AbortHandle;

use crate::conn::{Conn, Kind};
use crate::host::Task;
use crate::io::IoCore;
use crate::native::host_mut;
use crate::net::{ADDR_CAP, PEEK, SockAddr, Socket, prepare};
use crate::{HostState, IntoJs, class, pinned};

/// Bytes offered to one receive (the most a `data` event carries).
pub(crate) const CHUNK: usize = 16 * 1024;
/// Bytes of one slab that chunks are carved from.
const SLAB: usize = 4 * CHUNK;
/// Chunks start at multiples of this inside a slab.
const ALIGN: usize = 8;
/// Undelivered data/connection/datagram events after which a pump stops re-arming.
const MAX_QUEUED: usize = 8;
/// Fresh slabs a stream keeps ready.
const SLAB_TARGET: usize = 2;
/// The largest datagram received.
const DATAGRAM: usize = 65535;

/// The events a guest registers for.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Ev {
    Data,
    End,
    Error,
    Drain,
    Close,
    Connection,
    Datagram,
}

impl Ev {
    /// `name` as an event of a conn of `kind`.
    fn of(kind: Kind, name: &str) -> Option<Ev> {
        let ev = match name {
            "data" => Ev::Data,
            "end" => Ev::End,
            "error" => Ev::Error,
            "drain" => Ev::Drain,
            "close" => Ev::Close,
            "connection" => Ev::Connection,
            "datagram" => Ev::Datagram,
            _ => return None,
        };
        let allowed = match kind {
            Kind::Stream => matches!(ev, Ev::Data | Ev::End | Ev::Error | Ev::Drain | Ev::Close),
            Kind::Listener => matches!(ev, Ev::Connection | Ev::Error | Ev::Close),
            Kind::Datagram => matches!(ev, Ev::Datagram | Ev::Error | Ev::Close),
        };
        allowed.then_some(ev)
    }

    /// The event whose handlers make a conn of `kind` flow.
    fn flows(kind: Kind) -> Ev {
        match kind {
            Kind::Stream => Ev::Data,
            Kind::Listener => Ev::Connection,
            Kind::Datagram => Ev::Datagram,
        }
    }
}

/// What a hub holds back.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Pause {
    None,
    /// No handler wants the data: chunks, connections and datagrams wait for one, and an `End` waits behind them;
    /// anything else has nothing to wait for and is dispatched.
    NoHandler,
    /// The guest called `pause`: everything of the read side, in order.
    Explicit,
}

impl Pause {
    /// Whether `kind` is held back, given whether events already are.
    fn parks(self, kind: &EventKind, parked: bool) -> bool {
        match kind {
            EventKind::Drain => false,
            EventKind::Data { .. } | EventKind::Accept { .. } | EventKind::Datagram { .. } => self != Pause::None,
            EventKind::End => self == Pause::Explicit || (self == Pause::NoHandler && parked),
            EventKind::Error(_) | EventKind::Closed => self == Pause::Explicit,
        }
    }
}

pub(crate) enum EventKind {
    /// `n` bytes at `offset` of `slab`.
    Data {
        slab: v8::SharedRef<v8::BackingStore>,
        offset: usize,
        n: usize,
    },
    End,
    Error(u32),
    Drain,
    Accept {
        stream: TcpStream,
    },
    Datagram {
        data: Vec<u8>,
        from: SocketAddr,
    },
    Closed,
}

pub(crate) struct Event {
    hub: u32,
    kind: EventKind,
}

/// All hubs' events, in the order they happened.
pub(crate) type Events = Rc<RefCell<VecDeque<Event>>>;

/// A one-waiter wake-up cell.
#[derive(Default)]
struct Signal(RefCell<Option<Waker>>);

impl Signal {
    fn set(&self, cx: &Context<'_>) {
        *self.0.borrow_mut() = Some(cx.waker().clone());
    }

    fn wake(&self) {
        if let Some(waker) = self.0.borrow_mut().take() {
            waker.wake();
        }
    }
}

/// Per-runtime counters: what keeps the runtime "busy" and what only listens.
#[derive(Default)]
pub(crate) struct Idle {
    /// Flowing hubs that have not delivered `close` yet (what `io.run` waits for).
    live: Cell<usize>,
    /// The pending `io.run` calls.
    waiters: RefCell<Vec<Waker>>,
    /// Live pump tasks (excluded from the host's live count).
    pub(crate) pumps: Cell<usize>,
    /// Pump ops in flight (excluded from the host's live count).
    pub(crate) recving: Cell<usize>,
}

impl Idle {
    /// Resolves once no flowing hub is left.
    pub(crate) async fn run(self: Rc<Idle>) -> Result<(), NativeError> {
        poll_fn(move |cx| {
            if self.live.get() == 0 {
                return Poll::Ready(Ok(()));
            }
            let mut waiters = self.waiters.borrow_mut();
            if !waiters.iter().any(|waker| waker.will_wake(cx.waker())) {
                waiters.push(cx.waker().clone());
            }
            Poll::Pending
        })
        .await
    }

    fn finished(&self) {
        self.live.set(self.live.get() - 1);
        for waker in self.waiters.borrow_mut().drain(..) {
            waker.wake();
        }
    }
}

/// Increments a counter for as long as it lives.
struct Count<'a>(&'a Cell<usize>);

impl<'a> Count<'a> {
    fn new(cell: &'a Cell<usize>) -> Count<'a> {
        cell.set(cell.get() + 1);
        Count(cell)
    }
}

impl Drop for Count<'_> {
    fn drop(&mut self) {
        self.0.set(self.0.get() - 1);
    }
}

/// The event side of a conn that lives with the conn (no V8 in it).
#[derive(Default)]
pub(crate) struct Flow {
    /// The hub, once something was registered.
    pub(crate) hub: Cell<Option<u32>>,
    /// The pump was started.
    pub(crate) started: Cell<bool>,
    /// The pump counts in `Idle::live` until `close` is delivered.
    counted: Cell<bool>,
    /// Handlers of the flowing event, and why the conn is paused.
    flowing: Cell<usize>,
    user_paused: Cell<bool>,
    auto_paused: Cell<bool>,
    /// Fresh slabs the pump may receive into (topped up by [`refill`]).
    slabs: RefCell<Vec<v8::SharedRef<v8::BackingStore>>>,
    /// The pump waits here for a slab.
    need: Signal,
    /// Undelivered data/connection/datagram events, and where the pump waits for room.
    queued: Cell<usize>,
    space: Signal,
    stopped: Cell<bool>,
    /// The guest closed the conn: a pause no longer holds its events back (its `close` goes through).
    pub(crate) released: Cell<bool>,
    /// The tasks of the conn (pumps, the writer), aborted when it closes.
    pub(crate) aborts: RefCell<Vec<AbortHandle>>,
}

impl Flow {
    pub(crate) fn push(&self, io: &IoCore, hub: u32, kind: EventKind) {
        if matches!(kind, EventKind::Data { .. } | EventKind::Accept { .. } | EventKind::Datagram { .. }) {
            self.queued.set(self.queued.get() + 1);
        }
        io.events.borrow_mut().push_back(Event { hub, kind });
    }

    /// Stops the tasks (the conn closed).
    pub(crate) fn stop(&self) {
        self.stopped.set(true);
        let aborts = std::mem::take(&mut *self.aborts.borrow_mut());
        for handle in aborts {
            handle.abort();
        }
        self.space.wake();
        self.need.wake();
    }

    /// Whether the conn holds its events back: after `pause()`, or while no handler of the flowing event listens.
    pub(crate) fn paused(&self) -> bool {
        self.user_paused.get() || self.flowing.get() == 0
    }

    /// Waits while the queue is full; false once the conn stopped.
    async fn room(&self) -> bool {
        poll_fn(|cx| {
            if self.queued.get() < MAX_QUEUED || self.stopped.get() {
                Poll::Ready(())
            } else {
                self.space.set(cx);
                Poll::Pending
            }
        })
        .await;
        !self.stopped.get()
    }
}

/// The chunk being delivered.
struct Current {
    slab: v8::SharedRef<v8::BackingStore>,
    offset: usize,
    n: usize,
    /// The lease `DataEvent.buffer()` carved, the same for every call of one event.
    lease: Option<v8::Global<v8::ArrayBuffer>>,
}

struct Handler {
    ev: Ev,
    entry: u64,
    function: v8::Global<v8::Function>,
}

/// The V8 side of a conn's events: kept in the Host (`HostState::hubs`), dropped when its `close` is delivered or
/// its runtime closes.
pub(crate) struct Hub {
    conn: Rc<Conn>,
    context: v8::Global<v8::Context>,
    /// The `DataEvent` of a stream, reused for every chunk.
    data_event: Option<v8::Global<v8::Object>>,
    handlers: Vec<Handler>,
    next_entry: u64,
    /// The pause the hub applies, and the events it holds back.
    applied: Pause,
    parked: VecDeque<Event>,
    current: Option<Current>,
}

impl Hub {
    /// Puts back in front of the queue, in order, the parked events the pause no longer holds back.
    fn release(&mut self) {
        let stopped = self.conn.flow.released.get();
        let mut freed = Vec::new();
        for event in std::mem::take(&mut self.parked) {
            if !stopped && self.applied.parks(&event.kind, !self.parked.is_empty()) {
                self.parked.push_back(event);
            } else {
                freed.push(event);
            }
        }
        let mut events = self.conn.io.events.borrow_mut();
        while let Some(event) = freed.pop() {
            events.push_front(event);
        }
    }

    pub(crate) fn runtime(&self) -> u32 {
        self.conn.io.runtime
    }
}

impl HostState {
    /// The hub of `conn`, made on first use.
    fn hub_of(&mut self, scope_parts: Option<(v8::Global<v8::Context>, Option<v8::Global<v8::Object>>)>, conn: &Rc<Conn>) -> Option<u32> {
        if let Some(id) = conn.flow.hub.get() {
            return Some(id);
        }
        let (context, data_event) = scope_parts?;
        let id = self.next_hub;
        self.next_hub = self.next_hub.checked_add(1)?;
        self.hubs.insert(
            id,
            Hub {
                conn: Rc::clone(conn),
                context,
                data_event,
                handlers: Vec::new(),
                next_entry: 0,
                applied: Pause::None,
                parked: VecDeque::new(),
                current: None,
            },
        );
        conn.flow.hub.set(Some(id));
        Some(id)
    }

    fn spawn_pump(&self, conn: &Conn, task: Task) -> Result<(), NativeError> {
        let handle = self.spawn_detached(conn.io.runtime, task)?;
        conn.flow.aborts.borrow_mut().push(handle);
        Ok(())
    }
}

/// Makes the hub of `conn` (with its context and, for a stream, its `DataEvent`) if it has none.
fn ensure_hub(scope: &mut v8::PinScope<'_, '_>, conn: &Rc<Conn>) -> Result<u32, NativeError> {
    if let Some(id) = conn.flow.hub.get() {
        return Ok(id);
    }
    let current = scope.get_current_context();
    let context = v8::Global::new(scope, current);
    let data_event = if conn.kind == Kind::Stream {
        let event = class::wrap(scope, crate::stream::DataEvent(Rc::clone(conn)))?;
        let event = v8::Local::<v8::Object>::try_from(event).map_err(|_| NativeError::Errno(errno::UNEXPECTED))?;
        Some(v8::Global::new(scope, event))
    } else {
        None
    };
    host_mut(scope)?.hub_of(Some((context, data_event)), conn).ok_or(NativeError::Errno(errno::UNSUPPORTED))
}

/// `register(event, handler)` of an event-mode object: see the module docs. Returns the `Registration`.
pub(crate) fn register<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    conn: &Rc<Conn>,
    event: &str,
    handler: v8::Local<'s, v8::Function>,
) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    if !conn.io.open(crate::native::host_ref(scope)?) {
        return Err(NativeError::Errno(errno::BAD_HANDLE));
    }
    let ev = Ev::of(conn.kind, event).ok_or_else(|| NativeError::type_error(format!("unknown event: {event}")))?;
    let id = ensure_hub(scope, conn)?;
    let function = v8::Global::new(scope, handler);
    let host = host_mut(scope)?;
    let hub = host.hubs.get_mut(&id).ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
    let entry = hub.next_entry;
    hub.next_entry += 1;
    hub.handlers.push(Handler { ev, entry, function });
    let flows = ev == Ev::flows(conn.kind);
    if flows {
        conn.flow.flowing.set(conn.flow.flowing.get() + 1);
        conn.flow.auto_paused.set(false);
        start(scope, conn)?;
        sync(host_mut(scope)?, conn);
    }
    class::wrap(scope, crate::stream::Registration { conn: Rc::clone(conn), hub: id, entry, flows })
}

/// Removes a handler; `true` if it was registered. Without a flowing handler the conn pauses itself.
pub(crate) fn unregister(host: &mut HostState, conn: &Rc<Conn>, id: u32, entry: u64, flows: bool) -> bool {
    let Some(hub) = host.hubs.get_mut(&id) else { return false };
    let before = hub.handlers.len();
    hub.handlers.retain(|handler| handler.entry != entry);
    let removed = hub.handlers.len() != before;
    if removed && flows && !conn.is_closed() {
        conn.flow.flowing.set(conn.flow.flowing.get() - 1);
        if conn.flow.flowing.get() == 0 {
            conn.flow.auto_paused.set(true);
            sync(host, conn);
        }
    }
    removed
}

/// `pause()` / `resume()`.
pub(crate) fn set_paused(scope: &mut v8::PinScope<'_, '_>, conn: &Rc<Conn>, paused: bool) -> Result<(), NativeError> {
    conn.flow.user_paused.set(paused);
    if paused {
        ensure_hub(scope, conn)?;
    }
    sync(host_mut(scope)?, conn);
    Ok(())
}

/// Leaves event mode: refused once the pump started (what it read belongs to the events). Drops the hub.
pub(crate) fn unsubscribe(host: &mut HostState, conn: &Conn) -> Result<(), NativeError> {
    if conn.flow.started.get() {
        return Err(NativeError::Errno(errno::UNSUPPORTED));
    }
    if let Some(id) = conn.flow.hub.take() {
        host.hubs.remove(&id);
    }
    conn.flow.flowing.set(0);
    conn.flow.user_paused.set(false);
    conn.flow.auto_paused.set(false);
    Ok(())
}

/// Applies the pause state (explicit, or because no handler listens) to the hub.
fn sync(host: &mut HostState, conn: &Conn) {
    let flow = &conn.flow;
    let want = if flow.user_paused.get() {
        Pause::Explicit
    } else if flow.auto_paused.get() {
        Pause::NoHandler
    } else {
        Pause::None
    };
    let Some(id) = flow.hub.get() else { return };
    let Some(hub) = host.hubs.get_mut(&id) else { return };
    if want == hub.applied {
        return;
    }
    hub.applied = want;
    hub.release();
}

/// Starts the pump of `conn` (once): it reads (accepts, receives datagrams) and queues events from now on.
fn start(scope: &mut v8::PinScope<'_, '_>, conn: &Rc<Conn>) -> Result<(), NativeError> {
    if conn.flow.started.replace(true) {
        return Ok(());
    }
    conn.flow.counted.set(true);
    conn.io.idle.live.set(conn.io.idle.live.get() + 1);
    if conn.kind == Kind::Stream {
        let isolate: &mut v8::Isolate = scope;
        top_up(isolate, &conn.flow);
    }
    let host = host_mut(scope)?;
    let socket = conn.socket()?;
    let lp = conn.io.lp(host)?;
    let task: Task = match conn.kind {
        Kind::Stream => Box::pin(read_pump(socket, lp, Rc::clone(conn))),
        Kind::Listener => Box::pin(accept_pump(socket, lp, Rc::clone(conn))),
        Kind::Datagram => Box::pin(datagram_pump(socket, lp, Rc::clone(conn))),
    };
    host.spawn_pump(conn, task)
}

async fn read_pump(socket: Rc<Socket>, lp: Rc<Loop>, conn: Rc<Conn>) {
    let idle = Rc::clone(&conn.io.idle);
    let _alive = Count::new(&idle.pumps);
    let flow = &conn.flow;
    // The slab being filled and where its free part starts.
    let mut current: Option<(v8::SharedRef<v8::BackingStore>, usize)> = None;
    loop {
        if !flow.room().await {
            return;
        }
        if current.as_ref().is_none_or(|(slab, used)| slab.byte_length() - used < CHUNK) {
            // The old slab stays alive through the leases carved from it.
            let fresh = poll_fn(|cx| {
                if flow.stopped.get() {
                    return Poll::Ready(None);
                }
                let spare = flow.slabs.borrow_mut().pop();
                match spare {
                    Some(slab) => Poll::Ready(Some(slab)),
                    None => {
                        if let Some(hub) = flow.hub.get() {
                            conn.io.refill.borrow_mut().push(hub);
                        }
                        flow.need.set(cx);
                        Poll::Pending
                    }
                }
            })
            .await;
            let Some(slab) = fresh else { return };
            current = Some((slab, 0));
        }
        let Some((slab, used)) = current.as_mut() else { return };
        let Ok(buf) = pinned::region_over_slab(slab.clone(), *used, CHUNK) else {
            conn.fail(errno::UNEXPECTED);
            return;
        };
        let recving = Count::new(&idle.recving);
        let (read, buf) = socket.recv(&lp, buf).await;
        drop(recving);
        match read {
            Ok(0) => {
                // The peer finished: the stream stays open (writable) until it settles or the guest closes it.
                conn.push(EventKind::End);
                return;
            }
            Ok(n) => match buf.into_window() {
                Some((slab, offset)) => {
                    *used = offset + n.next_multiple_of(ALIGN);
                    conn.push(EventKind::Data { slab, offset, n });
                }
                None => {
                    conn.fail(errno::UNEXPECTED);
                    return;
                }
            },
            Err(error) => {
                conn.fail(errno::errno_of(&error));
                return;
            }
        }
    }
}

/// Accepts the next connection of `listener`: `None` once it is closed, `Err` when `accept(2)` failed, `Ok(None)`
/// for a connection that could not be set up (it is closed; the listener keeps going).
pub(crate) async fn accept_one(listener: &Socket, lp: &Loop) -> Option<Result<Option<TcpStream>, NativeError>> {
    use std::future::Future;
    let mut accepting = std::pin::pin!(lp.accept(listener.fd(), ADDR_CAP));
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
    .await?;
    Some(match accepted {
        Err(error) => Err(NativeError::Errno(errno::errno_of(&error))),
        Ok((fd, _peer)) => {
            // SAFETY: `fd` was just returned by `accept` and nothing else owns it.
            let stream = TcpStream::from(unsafe { OwnedFd::from_raw_fd(fd as i32) });
            Ok(prepare(&stream).is_ok().then_some(stream))
        }
    })
}

async fn accept_pump(listener: Rc<Socket>, lp: Rc<Loop>, conn: Rc<Conn>) {
    let idle = Rc::clone(&conn.io.idle);
    let _alive = Count::new(&idle.pumps);
    loop {
        if !conn.flow.room().await {
            return;
        }
        let recving = Count::new(&idle.recving);
        let accepted = accept_one(&listener, &lp).await;
        drop(recving);
        match accepted {
            None => return,
            Some(Ok(Some(stream))) => conn.push(EventKind::Accept { stream }),
            Some(Ok(None)) => {}
            Some(Err(error)) => {
                if !listener.closed.get() {
                    conn.fail(error.code().unwrap_or(errno::UNEXPECTED));
                }
                return;
            }
        }
    }
}

/// Waits for a datagram on `socket` and takes it: its bytes (at most `len`) and its source.
pub(crate) async fn recv_from(socket: &Socket, lp: &Loop, len: usize) -> Result<(Vec<u8>, SocketAddr), NativeError> {
    let udp = socket.udp().ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
    loop {
        let mut data = vec![0u8; len.max(1)];
        match udp.recv_from(&mut data) {
            Ok((n, from)) => {
                data.truncate(n.min(len));
                return Ok((data, from));
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                // Wait for the next datagram without taking it (a peek of one byte), then take it above.
                let (waited, _) = lp.recv(socket.fd(), vec![0u8; 1], PEEK).await;
                if let Err(error) = waited
                    && error.kind() != std::io::ErrorKind::WouldBlock
                {
                    return Err(error.into());
                }
                if socket.closed.get() {
                    return Err(NativeError::Errno(errno::CANCELED));
                }
            }
            Err(error) => return Err(error.into()),
        }
    }
}

/// Sends one datagram (to `to`, or to the connected peer), waiting while the kernel has no room.
pub(crate) async fn send_to(socket: &UdpSocket, lp: &Loop, data: &[u8], to: Option<SocketAddr>) -> Result<usize, NativeError> {
    loop {
        let sent = match to {
            Some(to) => socket.send_to(data, to),
            None => socket.send(data),
        };
        match sent {
            Ok(n) => return Ok(n),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                lp.timeout(std::time::Duration::from_millis(1)).await?;
            }
            Err(error) => return Err(error.into()),
        }
    }
}

async fn datagram_pump(socket: Rc<Socket>, lp: Rc<Loop>, conn: Rc<Conn>) {
    let idle = Rc::clone(&conn.io.idle);
    let _alive = Count::new(&idle.pumps);
    loop {
        if !conn.flow.room().await {
            return;
        }
        let recving = Count::new(&idle.recving);
        let received = recv_from(&socket, &lp, DATAGRAM).await;
        drop(recving);
        match received {
            Ok((data, from)) => conn.push(EventKind::Datagram { data, from }),
            Err(error) => {
                if !socket.closed.get()
                    && let Some(code) = error.code()
                {
                    conn.fail(code);
                }
                return;
            }
        }
    }
}

/// Tops `flow` up to [`SLAB_TARGET`] fresh slabs (isolate thread only).
fn top_up(isolate: &mut v8::Isolate, flow: &Flow) {
    while flow.slabs.borrow().len() < SLAB_TARGET {
        let slab = v8::ArrayBuffer::new_backing_store(isolate, SLAB).make_shared();
        flow.slabs.borrow_mut().push(slab);
    }
}

/// Refills the slabs of the streams whose pump ran out of them, and wakes the pumps.
pub(crate) fn refill(scope: &mut v8::PinScope<'_, '_, ()>) {
    let Some(host) = scope.get_slot::<HostState>() else { return };
    let ids = std::mem::take(&mut *host.refill.borrow_mut());
    if ids.is_empty() {
        return;
    }
    let conns: Vec<Rc<Conn>> = ids.iter().filter_map(|id| host.hubs.get(id).map(|hub| Rc::clone(&hub.conn))).collect();
    let isolate: &mut v8::Isolate = scope;
    for conn in conns {
        top_up(isolate, &conn.flow);
        conn.flow.need.wake();
    }
}

/// The bytes of the chunk being delivered on `conn`, if a `data` event is being dispatched: its length.
pub(crate) fn current_length(host: &HostState, conn: &Conn) -> usize {
    conn.flow.hub.get().and_then(|id| host.hubs.get(&id)).and_then(|hub| hub.current.as_ref()).map_or(0, |current| current.n)
}

/// The lease of the chunk being delivered on `conn`: an `ArrayBuffer` of exactly its bytes, carved out of the slab
/// (no copy), the same on every call of one event. `TypeError` outside the event.
pub(crate) fn take<'s>(scope: &mut v8::PinScope<'s, '_>, conn: &Conn) -> Result<v8::Local<'s, v8::ArrayBuffer>, NativeError> {
    let over = || NativeError::type_error("the data event is over");
    let id = conn.flow.hub.get().ok_or_else(over)?;
    let host = host_mut(scope)?;
    let current = host.hubs.get_mut(&id).and_then(|hub| hub.current.as_mut()).ok_or_else(over)?;
    if let Some(lease) = current.lease.clone() {
        return Ok(v8::Local::new(scope, lease));
    }
    let store = pinned::carve(&current.slab, current.offset, current.n)?;
    let buffer = v8::ArrayBuffer::with_backing_store(scope, &store);
    let global = v8::Global::new(scope, buffer);
    if let Some(current) = host_mut(scope)?.hubs.get_mut(&id).and_then(|hub| hub.current.as_mut()) {
        current.lease = Some(global);
    }
    Ok(buffer)
}

/// Delivers every queued event (handlers may queue more); returns how many.
pub(crate) fn deliver_all(scope: &mut v8::PinScope<'_, '_, ()>) -> usize {
    let mut delivered = 0;
    while let Some(event) = scope.get_slot::<HostState>().and_then(|host| host.events.borrow_mut().pop_front()) {
        delivered += 1;
        deliver(scope, event);
    }
    delivered
}

/// What a handler is called with.
enum Arg {
    None,
    DataEvent,
    Error(u32),
    Accepted(TcpStream),
    Datagram(Vec<u8>, SocketAddr),
}

/// Delivers one event to its hub's handlers (isolate thread). Events of a hub that is gone (runtime closed) are
/// dropped.
fn deliver(scope: &mut v8::PinScope<'_, '_, ()>, event: Event) {
    let id = event.hub;
    let Some(host) = scope.get_slot_mut::<HostState>() else { return };
    let Some(hub) = host.hubs.get_mut(&id) else { return };
    let conn = Rc::clone(&hub.conn);
    let flow = &conn.flow;
    // A paused conn holds its events back, in order. A conn the guest closed does not: its `close` (and nothing
    // before it) goes through.
    if hub.applied.parks(&event.kind, !hub.parked.is_empty()) && !flow.released.get() {
        hub.parked.push_back(event);
        return;
    }
    let (ev, arg) = match event.kind {
        EventKind::Data { slab, offset, n } => {
            flow.queued.set(flow.queued.get() - 1);
            flow.space.wake();
            if conn.read_ended.get() || conn.is_closed() {
                return;
            }
            hub.current = Some(Current { slab, offset, n, lease: None });
            (Ev::Data, Arg::DataEvent)
        }
        EventKind::End => {
            let fire = !conn.read_ended.get() && !conn.is_closed();
            if !fire {
                conn.peer_end();
                return;
            }
            (Ev::End, Arg::None)
        }
        EventKind::Error(code) => (Ev::Error, Arg::Error(code)),
        EventKind::Drain => (Ev::Drain, Arg::None),
        EventKind::Accept { stream } => {
            flow.queued.set(flow.queued.get() - 1);
            flow.space.wake();
            // The guest closed the listener: nothing would take this connection. Dropping `stream` closes it.
            if flow.stopped.get() {
                return;
            }
            (Ev::Connection, Arg::Accepted(stream))
        }
        EventKind::Datagram { data, from } => {
            flow.queued.set(flow.queued.get() - 1);
            flow.space.wake();
            if flow.stopped.get() {
                return;
            }
            (Ev::Datagram, Arg::Datagram(data, from))
        }
        EventKind::Closed => (Ev::Close, Arg::None),
    };
    let context = hub.context.clone();
    let context = v8::Local::new(scope, context);
    let scope = &mut v8::ContextScope::new(scope, context);
    let value: Option<v8::Local<v8::Value>> = match arg {
        Arg::None => None,
        Arg::DataEvent => scope
            .get_slot::<HostState>()
            .and_then(|host| host.hubs.get(&id))
            .and_then(|hub| hub.data_event.clone())
            .map(|event| v8::Local::new(scope, event).into()),
        Arg::Error(code) => Some(class::guest_error(scope, NativeError::Errno(code))),
        Arg::Accepted(stream) => {
            let accepted = Conn::new(&conn.io, Kind::Stream, Socket::stream(stream));
            let value = class::wrap(scope, crate::stream::TcpStreamUnshaped::new(Rc::clone(&accepted)));
            match value {
                Ok(value) => {
                    // A connection nobody handles is closed.
                    if !fire(scope, id, ev, Some(value)) {
                        accepted.close();
                    }
                    scope.perform_microtask_checkpoint();
                    return;
                }
                Err(_) => {
                    accepted.close();
                    return;
                }
            }
        }
        Arg::Datagram(data, from) => class::wrap(scope, crate::udp::DatagramEvent::new(data, from)).ok(),
    };
    fire(scope, id, ev, value);
    scope.perform_microtask_checkpoint();

    let Some(host) = scope.get_slot_mut::<HostState>() else { return };
    match ev {
        Ev::Data => {
            // A chunk the handlers did not take is dropped here, and its slab reference with it.
            if let Some(hub) = host.hubs.get_mut(&id) {
                hub.current = None;
            }
        }
        Ev::End => conn.peer_end(),
        Ev::Close => {
            host.hubs.remove(&id);
            conn.flow.hub.set(None);
            if conn.flow.counted.replace(false) {
                conn.io.idle.finished();
            }
        }
        _ => {}
    }
}

/// `{ data: Uint8Array, addr: SocketAddr }`, frozen.
pub(crate) fn datagram_value<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    data: Vec<u8>,
    from: SocketAddr,
) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let object = crate::encode::new_object(scope);
    crate::encode::set(scope, object, "data", data)?;
    let addr = SockAddr(from).into_js(scope)?;
    crate::encode::set(scope, object, "addr", addr)?;
    crate::encode::freeze(scope, object)
}

/// Calls the handlers of `ev` of hub `id` with `arg`; false when there is none. A handler that throws goes to the
/// `error` handlers; with none (or from one of them) it becomes an unhandled rejection. A promise a handler returns
/// is not awaited (its rejection is the guest's to handle): backpressure is the bounded number of chunks a pump keeps
/// undelivered, and `pause()`.
fn fire(scope: &mut v8::PinScope<'_, '_>, id: u32, ev: Ev, arg: Option<v8::Local<'_, v8::Value>>) -> bool {
    let functions = handlers(scope, id, ev);
    if functions.is_empty() {
        return false;
    }
    for function in functions {
        if let Err(exception) = call(scope, &function, arg) {
            fail(scope, id, ev, exception);
        }
    }
    true
}

fn handlers(scope: &mut v8::PinScope<'_, '_>, id: u32, ev: Ev) -> Vec<v8::Global<v8::Function>> {
    scope
        .get_slot::<HostState>()
        .and_then(|host| host.hubs.get(&id))
        .map(|hub| hub.handlers.iter().filter(|handler| handler.ev == ev).map(|handler| handler.function.clone()).collect())
        .unwrap_or_default()
}

/// Calls `function(arg)`; the exception it threw, if any.
fn call(
    scope: &mut v8::PinScope<'_, '_>,
    function: &v8::Global<v8::Function>,
    arg: Option<v8::Local<'_, v8::Value>>,
) -> Result<(), v8::Global<v8::Value>> {
    v8::tc_scope!(let tc, scope);
    let function = v8::Local::new(tc, function);
    let receiver: v8::Local<v8::Value> = v8::undefined(tc).into();
    let args: Vec<v8::Local<v8::Value>> = arg.map(|arg| v8::Local::new(tc, arg)).into_iter().collect();
    match function.call(tc, receiver, &args) {
        Some(_) => Ok(()),
        None => {
            let exception = tc.exception().unwrap_or_else(|| v8::undefined(tc).into());
            Err(v8::Global::new(tc, exception))
        }
    }
}

fn fail(scope: &mut v8::PinScope<'_, '_>, id: u32, ev: Ev, exception: v8::Global<v8::Value>) {
    let errors = if ev == Ev::Error { Vec::new() } else { handlers(scope, id, Ev::Error) };
    if errors.is_empty() {
        unhandled(scope, &exception);
        return;
    }
    let value = v8::Local::new(scope, &exception);
    for function in errors {
        if let Err(thrown) = call(scope, &function, Some(value)) {
            unhandled(scope, &thrown);
        }
    }
}

/// Reports `exception` the way an unhandled promise rejection is reported.
fn unhandled(scope: &mut v8::PinScope<'_, '_>, exception: &v8::Global<v8::Value>) {
    let value = v8::Local::new(scope, exception);
    if let Some(resolver) = v8::PromiseResolver::new(scope) {
        resolver.reject(scope, value);
    }
}

/// Drops every hub of `runtime` without calling its handlers (the runtime is closing).
pub(crate) fn drop_hubs(host: &mut HostState, runtime: u32) {
    host.hubs.retain(|_, hub| {
        let keep = hub.runtime() != runtime;
        if !keep {
            hub.conn.flow.hub.set(None);
        }
        keep
    });
}
