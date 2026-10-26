//! Event-style sockets: `native.net.subscribe/start/pause/resume/take/release`, the write lanes
//! (`directWrite`, `put`, `queued`, `flushed`, `end`) and `native.io.run`.
//!
//! A socket is *subscribed* with one JS dispatcher function. Rust never sees the guest's
//! handlers: the glue keeps the table and registers a single `dispatch(kind, a, b)` function, and
//! the host calls it once per event with small integers. No promise, resolver or `Global` is
//! created per message.
//!
//! # Flow
//! * `resume` spawns a **pump** task per stream (or listener): it re-arms `recv` (`accept`) after
//!   every completion into a recycled native buffer and queues an [`Event`] on the host-wide
//!   queue. The task never touches V8. It stops re-arming while [`MAX_QUEUED`] events are
//!   undelivered, so a slow handler backpressures the peer through TCP.
//! * [`crate::host::poll`] drains the queue on the isolate thread (`deliver`): it calls the
//!   dispatcher inside the socket's context and runs a microtask checkpoint after each event.
//! * The pump receives straight into **slabs**: [`SLAB`]-byte V8 backing stores (allocated by the
//!   isolate's `ArrayBuffer` allocator, so inside the V8 sandbox when there is one) that no guest
//!   object wraps while the loop owns a window of it. Each receive gets the next [`CHUNK`] bytes
//!   of the current slab and keeps only the bytes that arrived, so small reads pack tightly.
//!   `take` carves exactly those bytes out of the slab ([`pinned::carve`]) into a new
//!   `ArrayBuffer` (a *lease*): `byteLength` is the chunk length, no other byte of the slab is
//!   reachable through it and nothing is copied. The carved store holds a reference on its slab, so
//!   the slab goes back to the allocator when its last lease is gone. `release` detaches the
//!   `ArrayBuffer` (a retained view becomes empty) which drops that reference at once; a lease that
//!   is never released is dropped by the garbage collector. Slabs are allocated on the isolate
//!   thread ([`refill`]) because only it can allocate stores; the pump waits when none is ready.
//! * Writes have two lanes that share one order. `directWrite` is a plain non-blocking
//!   `write(2)` on the isolate thread: no copy, no buffer, it answers the bytes the kernel took and
//!   answers 0 while the outbox is busy (the queue has priority). `put` tries the kernel first when
//!   the outbox is idle, then copies what is left (at most `max` bytes) into the outbox, which a
//!   writer task flushes in order. `flushed` is a promise for "everything accepted so far reached
//!   the kernel"; the glue builds `queued.send` on it. A `Drain` event follows every time the
//!   outbox becomes empty.
//! * `pause` parks the socket's events (in order) instead of dispatching them; `resume` puts them
//!   back in front of the host queue. The pump keeps its [`MAX_QUEUED`] bound, so a paused socket
//!   holds at most that many chunks and then stops reading.
//!
//! # Lifetime
//! Subscriptions never keep the host alive by themselves: the pump task and its in-flight
//! `recv`/`accept` are excluded from [`crate::HostState::live_items`] (the [`Idle`] counters).
//! `native.io.run(io)` is a task that resolves once every resumed subscription of the runtime has
//! delivered its `Close` event, so `await io.run()` keeps the program alive. Writer tasks and
//! undelivered events count as live work. Closing the runtime drops the subscriptions without
//! calling their handlers.

use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::future::{Future, poll_fn};
use std::io::Write;
use std::net::TcpStream;
use std::os::fd::{FromRawFd, OwnedFd};
use std::rc::Rc;
use std::task::{Context, Poll, Waker};

use origine_api_core::{NativeError, errno};
use origine_io::Loop;
use origine_io::rt::AbortHandle;

use crate::HostState;
use crate::decode::ArrayBufferArg;
use crate::host::Task;
use crate::native;
use crate::native::{ScopeKey, host_mut, host_ref};
use crate::net::{ADDR_CAP, SEND_FLAGS, Socket, prepare, stream_of};
use crate::pinned;

/// Bytes offered to one receive (the most a `data` event carries).
pub(crate) const CHUNK: usize = 16 * 1024;
/// Bytes of one slab that chunks are carved from.
const SLAB: usize = 4 * CHUNK;
/// Chunks start at multiples of this inside a slab.
const ALIGN: usize = 8;
/// Undelivered data/connection events after which a pump stops re-arming.
const MAX_QUEUED: usize = 8;
/// Fresh slabs a socket keeps ready.
const SLAB_TARGET: usize = 2;

/// `dispatch(kind, a, b)` kinds; `glue/net.js` uses the same numbers.
const KIND_DATA: u32 = 0;
const KIND_END: u32 = 1;
const KIND_ERROR: u32 = 2;
const KIND_DRAIN: u32 = 3;
const KIND_CONNECTION: u32 = 4;
const KIND_CLOSE: u32 = 5;

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
        port: u32,
    },
    Closed,
}

pub(crate) struct Event {
    socket: u32,
    kind: EventKind,
}

/// All sockets' events, in the order they happened.
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
    /// Resumed subscriptions that have not delivered `Close` yet (what `io.run` waits for).
    live: Cell<usize>,
    /// Live pump tasks (excluded from the host's live count).
    pub(crate) pumps: Cell<usize>,
    /// Pump ops in flight (excluded from the host's live count).
    pub(crate) recving: Cell<usize>,
    waiter: Signal,
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

#[derive(Default)]
struct Outbox {
    queue: VecDeque<Vec<u8>>,
    /// Bytes in `queue`.
    bytes: usize,
    /// A writer task owns the queue.
    writing: bool,
    /// Bytes ever accepted (kernel or queue) and bytes that reached the kernel; `flushed` waits
    /// for `sent >= accepted`.
    accepted: u64,
    sent: u64,
    /// `end` was called: no more writes; FIN goes out once the queue is empty.
    ended: bool,
    /// The outbox failed (write error, peer gone, socket closed): the errno pending writes get.
    failed: Option<u32>,
    /// Pending `flushed` promises.
    waiters: Vec<Waker>,
}

impl Outbox {
    fn wake(&mut self) {
        for waker in self.waiters.drain(..) {
            waker.wake();
        }
    }
}

/// State shared between a subscription (host side) and its tasks.
pub(crate) struct Shared {
    socket: u32,
    events: Events,
    idle: Rc<Idle>,
    /// Fresh slabs the pump may receive into (topped up by [`refill`]).
    slabs: RefCell<Vec<v8::SharedRef<v8::BackingStore>>>,
    /// The pump waits here for a slab.
    need: Signal,
    /// Sockets whose slabs ran out; the host refills them (shared with `HostState`).
    refill: Rc<RefCell<Vec<u32>>>,
    queued: Cell<usize>,
    space: Signal,
    out: RefCell<Outbox>,
    stop: Cell<bool>,
    closed: Cell<bool>,
    aborts: RefCell<Vec<AbortHandle>>,
}

impl Shared {
    fn push(&self, kind: EventKind) {
        if matches!(kind, EventKind::Data { .. } | EventKind::Accept { .. }) {
            self.queued.set(self.queued.get() + 1);
        }
        self.events.borrow_mut().push_back(Event { socket: self.socket, kind });
    }

    /// Fails the outbox once: drops the queue and rejects every pending `flushed` with `code`.
    fn fail_out(&self, code: u32) {
        let mut out = self.out.borrow_mut();
        if out.failed.is_none() {
            out.failed = Some(code);
            out.queue.clear();
            out.bytes = 0;
            out.wake();
        }
    }

    /// Queues the final event once.
    fn push_closed(&self) {
        self.fail_out(errno::CANCELED);
        if !self.closed.replace(true) {
            self.push(EventKind::Closed);
        }
    }

    /// Stops the tasks and queues `Close` (the guest closed the socket).
    pub(crate) fn close(&self) {
        self.stop.set(true);
        let aborts = std::mem::take(&mut *self.aborts.borrow_mut());
        for handle in aborts {
            handle.abort();
        }
        self.space.wake();
        self.push_closed();
    }

    fn fail(&self, code: u32) {
        self.fail_out(code);
        self.push(EventKind::Error(code));
        self.push_closed();
    }
}

/// The chunk being delivered.
struct Current {
    slab: v8::SharedRef<v8::BackingStore>,
    offset: usize,
    n: usize,
    /// `take` carved the chunk into a lease.
    taken: bool,
}

/// A subscribed socket.
pub(crate) struct Sub {
    dispatch: v8::Global<v8::Function>,
    context: v8::Global<v8::Context>,
    shared: Rc<Shared>,
    pub(crate) runtime: u32,
    owner: ScopeKey,
    /// Counted in `Idle::live`.
    counted: bool,
    started: bool,
    current: Option<Current>,
    /// `pause` parks events instead of dispatching them.
    paused: bool,
    parked: VecDeque<Event>,
}

impl HostState {
    /// Marks the subscription of `id` (if any) closed by the guest.
    pub(crate) fn sub_closed(&mut self, id: u32) {
        if let Some(sub) = self.subs.get(&id) {
            sub.shared.close();
        }
    }
}

async fn read_pump(socket: Rc<Socket>, lp: Rc<Loop>, shared: Rc<Shared>) {
    let idle = Rc::clone(&shared.idle);
    let _alive = Count::new(&idle.pumps);
    // The slab being filled and where its free part starts.
    let mut current: Option<(v8::SharedRef<v8::BackingStore>, usize)> = None;
    loop {
        poll_fn(|cx| {
            if shared.queued.get() < MAX_QUEUED || shared.stop.get() {
                Poll::Ready(())
            } else {
                shared.space.set(cx);
                Poll::Pending
            }
        })
        .await;
        if shared.stop.get() {
            return;
        }
        if current.as_ref().is_none_or(|(slab, used)| slab.byte_length() - used < CHUNK) {
            // The old slab stays alive through the leases carved from it.
            current = Some((
                poll_fn(|cx| {
                    let spare = shared.slabs.borrow_mut().pop();
                    match spare {
                        Some(slab) => Poll::Ready(slab),
                        None => {
                            shared.refill.borrow_mut().push(shared.socket);
                            shared.need.set(cx);
                            Poll::Pending
                        }
                    }
                })
                .await,
                0,
            ));
            if shared.stop.get() {
                return;
            }
        }
        let Some((slab, used)) = current.as_mut() else { return };
        let Ok(buf) = pinned::region_over_slab(slab.clone(), *used, CHUNK) else {
            shared.fail(errno::UNEXPECTED);
            return;
        };
        let recving = Count::new(&idle.recving);
        let (read, buf) = lp.recv(socket.fd(), buf, 0).await;
        drop(recving);
        match read {
            Ok(0) => {
                // The peer finished: the socket stays open (writable) until the guest closes it;
                // the glue does that once the local write side has ended too.
                shared.push(EventKind::End);
                return;
            }
            Ok(n) => match buf.into_window() {
                Some((slab, offset)) => {
                    *used = offset + n.next_multiple_of(ALIGN);
                    shared.push(EventKind::Data { slab, offset, n });
                }
                None => {
                    shared.fail(errno::UNEXPECTED);
                    return;
                }
            },
            Err(error) => {
                shared.fail(errno::errno_of(&error));
                return;
            }
        }
    }
}

async fn accept_pump(listener: Rc<Socket>, lp: Rc<Loop>, shared: Rc<Shared>) {
    let idle = Rc::clone(&shared.idle);
    let _alive = Count::new(&idle.pumps);
    loop {
        poll_fn(|cx| {
            if shared.queued.get() < MAX_QUEUED || shared.stop.get() {
                Poll::Ready(())
            } else {
                shared.space.set(cx);
                Poll::Pending
            }
        })
        .await;
        if shared.stop.get() {
            return;
        }
        let recving = Count::new(&idle.recving);
        let accepted = lp.accept(listener.fd(), ADDR_CAP).await;
        drop(recving);
        let fd = match accepted {
            Ok((fd, _peer)) => fd,
            Err(error) => {
                shared.fail(errno::errno_of(&error));
                return;
            }
        };
        // SAFETY: `fd` was just returned by `accept` and nothing else owns it.
        let stream = TcpStream::from(unsafe { OwnedFd::from_raw_fd(fd as i32) });
        let prepared = prepare(&stream).and_then(|()| stream.peer_addr().map_err(NativeError::from));
        // A connection that cannot be set up is dropped (closed); the listener keeps going.
        if let Ok(peer) = prepared {
            shared.push(EventKind::Accept { stream, port: u32::from(peer.port()) });
        }
    }
}

/// Flushes the outbox of a socket whose kernel buffer was full, in order, then sends the FIN of a
/// pending `end`.
async fn write_pump(socket: Rc<Socket>, lp: Rc<Loop>, shared: Rc<Shared>) {
    loop {
        let next = shared.out.borrow_mut().queue.pop_front();
        let Some(mut chunk) = next else {
            let mut out = shared.out.borrow_mut();
            out.writing = false;
            let fin = out.ended && out.failed.is_none();
            out.wake();
            drop(out);
            if fin {
                socket.shutdown_write();
            }
            shared.push(EventKind::Drain);
            return;
        };
        while !chunk.is_empty() {
            let (result, buf) = lp.send(socket.fd(), chunk, SEND_FLAGS).await;
            chunk = buf;
            let sent = match result {
                Ok(0) => Err(errno::BROKEN_PIPE),
                Ok(n) => Ok(n),
                Err(error) => Err(errno::errno_of(&error)),
            };
            match sent {
                Ok(n) => {
                    chunk.drain(..n);
                    let mut out = shared.out.borrow_mut();
                    out.bytes -= n;
                    out.sent += n as u64;
                    out.wake();
                }
                Err(code) => {
                    shared.out.borrow_mut().writing = false;
                    shared.fail(code);
                    return;
                }
            }
        }
    }
}

impl HostState {
    fn spawn_pump(&self, runtime: u32, shared: &Shared, task: Task) -> Result<(), NativeError> {
        let handle = self.spawn_detached(runtime, task)?;
        shared.aborts.borrow_mut().push(handle);
        Ok(())
    }
}

/// `native.net.subscribe(id, dispatch)`: routes the socket's events to `dispatch(kind, a, b)`
/// (see the module docs). `BadHandle` for an unknown, foreign or already subscribed socket.
/// Nothing is read until `resume`.
#[native(side_effect = "any", path = "net.subscribe", needs = "runtime")]
fn net_subscribe<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    key: ScopeKey,
    id: u32,
    dispatch: v8::Local<'s, v8::Value>,
) -> Result<(), NativeError> {
    let function = v8::Local::<v8::Function>::try_from(dispatch).map_err(|_| NativeError::type_error("dispatch must be a function"))?;
    let runtime = host_ref(scope)?.socket(key, id)?.0.runtime();
    let dispatch = v8::Global::new(scope, function);
    let current = scope.get_current_context();
    let context = v8::Global::new(scope, current);
    let host = host_mut(scope)?;
    if host.subs.contains_key(&id) {
        return Err(NativeError::Errno(errno::BAD_HANDLE));
    }
    let idle = host.idle_of(runtime);
    let shared = Rc::new(Shared {
        socket: id,
        events: Rc::clone(&host.events),
        idle,
        slabs: RefCell::default(),
        need: Signal::default(),
        refill: Rc::clone(&host.refill),
        queued: Cell::new(0),
        space: Signal::default(),
        out: RefCell::default(),
        stop: Cell::new(false),
        closed: Cell::new(false),
        aborts: RefCell::default(),
    });
    host.subs.insert(
        id,
        Sub {
            dispatch,
            context,
            shared,
            runtime,
            owner: key,
            counted: false,
            started: false,
            current: None,
            paused: false,
            parked: VecDeque::new(),
        },
    );
    Ok(())
}

/// Tops `shared` up to [`SLAB_TARGET`] fresh slabs (isolate thread only).
fn top_up(isolate: &mut v8::Isolate, shared: &Shared) {
    while shared.slabs.borrow().len() < SLAB_TARGET {
        let slab = v8::ArrayBuffer::new_backing_store(isolate, SLAB).make_shared();
        shared.slabs.borrow_mut().push(slab);
    }
}

/// Refills the slabs of the sockets whose pump ran out of them, and wakes the pumps.
pub(crate) fn refill(scope: &mut v8::PinScope<'_, '_, ()>) {
    let Some(host) = scope.get_slot::<HostState>() else { return };
    let ids = std::mem::take(&mut *host.refill.borrow_mut());
    if ids.is_empty() {
        return;
    }
    let pools: Vec<Rc<Shared>> = ids.iter().filter_map(|id| host.subs.get(id).map(|sub| Rc::clone(&sub.shared))).collect();
    let isolate: &mut v8::Isolate = scope;
    for shared in pools {
        top_up(isolate, &shared);
        shared.need.wake();
    }
}

/// `native.net.start(id)`: starts reading a stream (`data`, `end`, `error`) or accepting on a
/// listener (`connection`). A peer's FIN only delivers `end`; the stream stays open until the
/// guest closes it. Idempotent.
#[native(side_effect = "any", path = "net.start", needs = "runtime")]
fn net_start(scope: &mut v8::PinScope<'_, '_>, key: ScopeKey, id: u32) -> Result<(), NativeError> {
    let host = host_mut(scope)?;
    let (socket, lp) = host.socket(key, id)?;
    let sub = host.subs.get_mut(&id).ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
    if sub.started {
        return Ok(());
    }
    sub.started = true;
    sub.counted = true;
    let shared = Rc::clone(&sub.shared);
    let runtime = sub.runtime;
    shared.idle.live.set(shared.idle.live.get() + 1);
    if !socket.is_listener() {
        let isolate: &mut v8::Isolate = scope;
        top_up(isolate, &shared);
    }
    let task: Task = if socket.is_listener() {
        Box::pin(accept_pump(socket, lp, Rc::clone(&shared)))
    } else {
        Box::pin(read_pump(socket, lp, Rc::clone(&shared)))
    };
    host_mut(scope)?.spawn_pump(runtime, &shared, task)
}

/// `native.net.pause(id)`: parks the socket's events from now on (see the module docs).
/// Idempotent; `BadHandle` for an unknown, foreign or unsubscribed socket.
#[native(side_effect = "any", path = "net.pause", needs = "runtime")]
fn net_pause(host: &mut HostState, key: ScopeKey, id: u32) -> Result<(), NativeError> {
    let sub = host.subs.get_mut(&id).filter(|sub| sub.owner == key).ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
    sub.paused = true;
    Ok(())
}

/// `native.net.resume(id)`: dispatches the parked events again, in order, ahead of everything
/// else queued. Idempotent.
#[native(side_effect = "any", path = "net.resume", needs = "runtime")]
fn net_resume(host: &mut HostState, key: ScopeKey, id: u32) -> Result<(), NativeError> {
    let sub = host.subs.get_mut(&id).filter(|sub| sub.owner == key).ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
    sub.paused = false;
    let mut events = host.events.borrow_mut();
    while let Some(event) = sub.parked.pop_back() {
        events.push_front(event);
    }
    Ok(())
}

/// `native.net.take(id)`: an `ArrayBuffer` of exactly the bytes of the chunk, carved out of the
/// slab it was received into (no copy; `byteLength` is the `data` dispatch's length and no other
/// byte of the slab is reachable). Only valid inside the `data` dispatch, once per event
/// (`StaleHandle` otherwise). Give it back with `release`.
#[native(side_effect = "any", path = "net.take", needs = "runtime")]
fn net_take<'s>(scope: &mut v8::PinScope<'s, '_>, key: ScopeKey, id: u32) -> Result<v8::Local<'s, v8::ArrayBuffer>, NativeError> {
    let host = host_mut(scope)?;
    let sub = host.subs.get_mut(&id).filter(|sub| sub.owner == key).ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
    let current = sub.current.as_mut().filter(|current| !current.taken).ok_or(NativeError::Errno(errno::STALE_HANDLE))?;
    let store = pinned::carve(&current.slab, current.offset, current.n)?;
    current.taken = true;
    Ok(v8::ArrayBuffer::with_backing_store(scope, &store))
}

/// `native.net.release(id, buffer)`: detaches a lease from `take`, which drops its hold on the slab
/// at once (the slab is freed with its last lease). Idempotent for a detached buffer. Nothing is
/// remembered per lease (an unreleased lease that is garbage collected has the same effect, later).
/// `Unsupported` for a buffer that is shared or undetachable; the socket is not consulted.
#[native(side_effect = "any", path = "net.release", needs = "runtime")]
fn net_release<'s>(_scope:&mut v8::PinScope<'s, '_>, key: ScopeKey, id: u32, buffer: v8::Local<'s, v8::Value>) -> Result<(), NativeError> {
    let _ = (key, id);
    let buffer = v8::Local::<v8::ArrayBuffer>::try_from(buffer).map_err(|_| NativeError::type_error("buffer must be an ArrayBuffer"))?;
    if buffer.was_detached() {
        return Ok(());
    }
    let store = buffer.get_backing_store();
    if store.is_shared() || store.is_resizable_by_user_javascript() || !buffer.is_detachable() {
        return Err(NativeError::Errno(errno::UNSUPPORTED));
    }
    if buffer.detach(None) != Some(true) || !buffer.was_detached() {
        return Err(NativeError::Errno(errno::UNEXPECTED));
    }
    Ok(())
}

/// A subscribed stream with what its write lanes need.
struct Writer {
    socket: Rc<Socket>,
    lp: Rc<Loop>,
    shared: Rc<Shared>,
    runtime: u32,
}

/// The subscribed stream `id` with its writer plumbing; `BadHandle` for a closed one.
fn writer_of(host: &HostState, key: ScopeKey, id: u32) -> Result<Writer, NativeError> {
    let (socket, lp) = stream_of(host, key, id)?;
    let sub = host.subs.get(&id).ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
    if sub.shared.closed.get() {
        return Err(NativeError::Errno(errno::BAD_HANDLE));
    }
    Ok(Writer { socket, lp, shared: Rc::clone(&sub.shared), runtime: sub.runtime })
}

/// A write on `stream`: the bytes the kernel took, `Ok(0)` when it would block.
fn kernel_write(stream: &TcpStream, bytes: &[u8]) -> Result<usize, std::io::Error> {
    match (&*stream).write(bytes) {
        Err(error) if matches!(error.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted) => Ok(0),
        other => other,
    }
}

/// `native.net.directWrite(id, data)`: the direct lane. A plain non-blocking write; answers the
/// bytes the kernel took, 0 when it would block or while the outbox is busy (queued bytes go
/// first). A write error throws its errno and the socket emits `error` and closes; `BrokenPipe`
/// after `end`.
#[native(side_effect = "any", path = "net.directWrite", needs = "runtime")]
fn net_direct_write(host: &mut HostState, key: ScopeKey, id: u32, data: ArrayBufferArg<'_>) -> Result<usize, NativeError> {
    let Writer { socket, shared, .. } = writer_of(host, key, id)?;
    let out = shared.out.borrow();
    if out.ended {
        return Err(NativeError::Errno(errno::BROKEN_PIPE));
    }
    if let Some(code) = out.failed {
        return Err(NativeError::Errno(code));
    }
    if out.writing {
        return Ok(0);
    }
    drop(out);
    let stream = socket.stream().ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
    match data.with_bytes(|bytes| kernel_write(stream, bytes)) {
        Ok(n) => Ok(n),
        Err(error) => {
            let code = errno::errno_of(&error);
            shared.fail(code);
            Err(NativeError::Errno(code))
        }
    }
}

/// `native.net.put(id, data, max)`: the queued lane. When the outbox is idle the kernel is tried
/// first; what it does not take is copied into the outbox, at most `max` bytes of it (the caller's
/// room). Answers the bytes accepted (kernel plus queue). A write error throws its errno and the
/// socket emits `error` and closes; `BrokenPipe` after `end`.
#[native(side_effect = "any", path = "net.put", needs = "runtime")]
fn net_put(host: &mut HostState, key: ScopeKey, id: u32, data: ArrayBufferArg<'_>, max: u64) -> Result<usize, NativeError> {
    let Writer { socket, lp, shared, runtime } = writer_of(host, key, id)?;
    let max = usize::try_from(max).unwrap_or(usize::MAX);
    let mut out = shared.out.borrow_mut();
    if out.ended {
        return Err(NativeError::Errno(errno::BROKEN_PIPE));
    }
    if let Some(code) = out.failed {
        return Err(NativeError::Errno(code));
    }
    let len = data.len();
    if out.writing {
        let take = len.min(max);
        if take > 0 {
            out.queue.push_back(data.with_bytes(|bytes| bytes[..take].to_vec()));
            out.bytes += take;
            out.accepted += take as u64;
        }
        return Ok(take);
    }
    let stream = socket.stream().ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
    let (kernel, rest) = match data
        .with_bytes(|bytes| kernel_write(stream, bytes).map(|n| (n, bytes[n..bytes.len().min(n.saturating_add(max))].to_vec())))
    {
        Ok(pair) => pair,
        Err(error) => {
            drop(out);
            let code = errno::errno_of(&error);
            shared.fail(code);
            return Err(NativeError::Errno(code));
        }
    };
    out.accepted += kernel as u64;
    out.sent += kernel as u64;
    if rest.is_empty() {
        return Ok(kernel);
    }
    let queued = rest.len();
    out.bytes += queued;
    out.accepted += queued as u64;
    out.queue.push_back(rest);
    out.writing = true;
    drop(out); // the writer polls once at spawn and takes the same borrow
    if let Err(error) = host.spawn_pump(runtime, &shared, Box::pin(write_pump(socket, lp, Rc::clone(&shared)))) {
        // No writer will ever drain the outbox: undo the queueing, or every later write would
        // only append to it and `writing` would stay set forever.
        let mut out = shared.out.borrow_mut();
        out.queue.clear();
        out.bytes = 0;
        out.accepted -= queued as u64;
        out.writing = false;
        return Err(error);
    }
    Ok(kernel + queued)
}

/// `native.net.queued(id)`: bytes waiting in the outbox.
#[native(side_effect = "none", path = "net.queued", needs = "runtime")]
fn net_queued(host: &mut HostState, key: ScopeKey, id: u32) -> Result<usize, NativeError> {
    let sub = host.subs.get(&id).filter(|sub| sub.owner == key).ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
    Ok(sub.shared.out.borrow().bytes)
}

/// `native.net.flushed(id)`: Promise<void> that resolves once every byte accepted so far reached
/// the kernel; rejects with the outbox's errno (a write error, `Canceled` when the socket closed
/// first).
#[native(side_effect = "any", path = "net.flushed", needs = "runtime", promise)]
fn net_flushed(
    host: &mut HostState,
    key: ScopeKey,
    id: u32,
) -> Result<native::Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    let sub = host.subs.get(&id).filter(|sub| sub.owner == key).ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
    let (shared, runtime) = (Rc::clone(&sub.shared), sub.runtime);
    let target = shared.out.borrow().accepted;
    Ok(native::Op::new(
        runtime,
        poll_fn(move |cx| {
            let mut out = shared.out.borrow_mut();
            if out.sent >= target {
                Poll::Ready(Ok(()))
            } else if let Some(code) = out.failed {
                Poll::Ready(Err(NativeError::Errno(code)))
            } else {
                out.waiters.push(cx.waker().clone());
                Poll::Pending
            }
        }),
    ))
}

/// `native.net.end(id)`: no more writes; the FIN goes out once the outbox is empty (now when it
/// already is). Idempotent.
#[native(side_effect = "any", path = "net.end", needs = "runtime")]
fn net_end(host: &mut HostState, key: ScopeKey, id: u32) -> Result<(), NativeError> {
    let Writer { socket, shared, .. } = writer_of(host, key, id)?;
    let mut out = shared.out.borrow_mut();
    if !std::mem::replace(&mut out.ended, true) && !out.writing && out.failed.is_none() {
        socket.shutdown_write();
    }
    Ok(())
}

/// `native.io.run(io)`: Promise<void> that resolves once every resumed subscription of the
/// runtime has delivered its `close` event (immediately when there is none). While it is pending
/// the program stays alive.
#[native(side_effect = "any", path = "io.run", needs = "runtime", promise)]
fn io_run(
    host: &mut HostState,
    key: ScopeKey,
    io: u32,
) -> Result<native::Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    host.loop_of(key, io)?;
    let idle = host.idle_of(io);
    Ok(native::Op::new(
        io,
        poll_fn(move |cx| {
            if idle.live.get() == 0 {
                Poll::Ready(Ok(()))
            } else {
                idle.waiter.set(cx);
                Poll::Pending
            }
        }),
    ))
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

/// Delivers one event to its socket's dispatcher (isolate thread). Events for a socket that is
/// gone (runtime closed) are dropped.
fn deliver(scope: &mut v8::PinScope<'_, '_, ()>, event: Event) {
    let id = event.socket;
    let Some(host) = scope.get_slot_mut::<HostState>() else { return };
    let Some(sub) = host.subs.get(&id) else { return };
    let (shared, owner, runtime) = (Rc::clone(&sub.shared), sub.owner, sub.runtime);
    // A paused socket holds its events back, in order. A socket the guest closed does not: its
    // `Close` (and nothing before it) goes through.
    if sub.paused && !shared.stop.get() {
        if let Some(sub) = host.subs.get_mut(&id) {
            sub.parked.push_back(event);
        }
        return;
    }
    let (kind, a, b) = match event.kind {
        EventKind::Data { slab, offset, n } => {
            shared.queued.set(shared.queued.get() - 1);
            shared.space.wake();
            if let Some(sub) = host.subs.get_mut(&id) {
                sub.current = Some(Current { slab, offset, n, taken: false });
            }
            (KIND_DATA, n as u32, 0)
        }
        EventKind::End => (KIND_END, 0, 0),
        EventKind::Error(code) => (KIND_ERROR, code, 0),
        EventKind::Drain => (KIND_DRAIN, 0, 0),
        EventKind::Accept { stream, port } => {
            shared.queued.set(shared.queued.get() - 1);
            shared.space.wake();
            let accepted =
                host.reserve_socket().and_then(|new| host.insert_socket(new, Socket::accepted(owner, runtime, stream)).map(|()| new));
            match accepted {
                Ok(new) => (KIND_CONNECTION, new, port),
                Err(_) => return, // table full or runtime closing: the connection is closed with `stream`
            }
        }
        EventKind::Closed => {
            if let Some(socket) = host.sockets_remove(id) {
                socket.shutdown();
            }
            (KIND_CLOSE, 0, 0)
        }
    };
    let Some(sub) = host.subs.get(&id) else { return };
    let (dispatch, context) = (sub.dispatch.clone(), sub.context.clone());
    call(scope, &dispatch, &context, [kind, a, b]);

    let Some(host) = scope.get_slot_mut::<HostState>() else { return };
    if kind == KIND_DATA {
        // A chunk the handler did not take is dropped here, and its slab reference with it.
        if let Some(sub) = host.subs.get_mut(&id) {
            sub.current = None;
        }
    } else if kind == KIND_CLOSE
        && let Some(sub) = host.subs.remove(&id)
        && sub.counted
    {
        let idle = &sub.shared.idle;
        idle.live.set(idle.live.get() - 1);
        idle.waiter.wake();
    }
}

/// Calls `dispatch(...args)` in `context`, then runs the microtasks it queued. A throw that
/// escapes the glue's own handling is dropped.
fn call(scope: &mut v8::PinScope<'_, '_, ()>, dispatch: &v8::Global<v8::Function>, context: &v8::Global<v8::Context>, args: [u32; 3]) {
    let context = v8::Local::new(scope, context);
    let scope = &mut v8::ContextScope::new(scope, context);
    v8::tc_scope!(let tc, scope);
    let function = v8::Local::new(tc, dispatch);
    let receiver: v8::Local<v8::Value> = v8::undefined(tc).into();
    let args: Vec<v8::Local<v8::Value>> = args.iter().map(|value| v8::Integer::new_from_unsigned(tc, *value).into()).collect();
    let _ = function.call(tc, receiver, &args);
    tc.perform_microtask_checkpoint();
}
