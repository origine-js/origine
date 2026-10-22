//! Event-style sockets: `native.net.subscribe/resume/take/release/send` and `native.io.run`.
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
//! * The pump receives straight into a **pooled** V8 backing store (pinned like `readInto`: no
//!   guest object wraps it while the loop owns it). `take` wraps that same store in a new
//!   `ArrayBuffer` (a *lease*): no copy anywhere. `release` detaches the `ArrayBuffer` (a retained
//!   view becomes empty, never aliasing the next chunk) and returns the store to the pool. A
//!   handler that does not take the chunk gives the store back when it returns. The pool is topped
//!   up on the isolate thread ([`refill`]) because only it can allocate stores; the pump waits
//!   when the pool is empty.
//! * `send` writes synchronously (a plain non-blocking `write(2)` on the isolate thread, no loop
//!   op). What the kernel does not take goes to an outbox flushed by a writer task; `send`
//!   answers `false` above [`HIGH_WATER`] bytes queued and a `Ready` event follows when the outbox
//!   drains.
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

/// Bytes of one pooled lease store and of one native receive buffer.
pub(crate) const CHUNK: usize = 16 * 1024;
/// Undelivered data/connection events after which a pump stops re-arming.
const MAX_QUEUED: usize = 8;
/// Outbox bytes above which `send` answers `false`.
const HIGH_WATER: usize = 64 * 1024;
/// Stores a socket's pool is topped up to.
const POOL_TARGET: usize = 4;
/// Stores kept per socket for reuse.
const POOL_MAX: usize = 32;

/// `dispatch(kind, a, b)` kinds; `glue/net.js` uses the same numbers.
const KIND_DATA: u32 = 0;
const KIND_END: u32 = 1;
const KIND_ERROR: u32 = 2;
const KIND_READY: u32 = 3;
const KIND_CONNECTION: u32 = 4;
const KIND_CLOSE: u32 = 5;

pub(crate) enum EventKind {
    /// `n` bytes at the start of `store`.
    Data {
        store: v8::SharedRef<v8::BackingStore>,
        n: usize,
    },
    End,
    Error(u32),
    Ready,
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
    bytes: usize,
    /// A writer task owns the queue.
    writing: bool,
    /// A `send` answered `false`: emit `Ready` once drained.
    need_ready: bool,
}

/// State shared between a subscription (host side) and its tasks.
pub(crate) struct Shared {
    socket: u32,
    events: Events,
    idle: Rc<Idle>,
    /// Empty stores the pump may receive into (topped up by [`refill`]).
    stores: RefCell<Vec<v8::SharedRef<v8::BackingStore>>>,
    /// The pump waits here for a store.
    need: Signal,
    /// Sockets whose pool ran low; the host refills them (shared with `HostState`).
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

    /// Queues the final event once.
    fn push_closed(&self) {
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
        self.push(EventKind::Error(code));
        self.push_closed();
    }
}

/// The chunk being delivered.
struct Current {
    store: v8::SharedRef<v8::BackingStore>,
    /// `take` moved the store into a lease.
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
        let store = poll_fn(|cx| {
            let spare = shared.stores.borrow_mut().pop();
            match spare {
                Some(store) => Poll::Ready(store),
                None => {
                    shared.refill.borrow_mut().push(shared.socket);
                    shared.need.set(cx);
                    Poll::Pending
                }
            }
        })
        .await;
        if shared.stop.get() {
            return;
        }
        let Ok(buf) = pinned::region_over_store(store, CHUNK) else {
            shared.fail(errno::UNEXPECTED);
            return;
        };
        let recving = Count::new(&idle.recving);
        let (read, buf) = lp.recv(socket.fd(), buf, 0).await;
        drop(recving);
        match read {
            Ok(0) => {
                shared.push(EventKind::End);
                shared.push_closed();
                return;
            }
            Ok(n) => match buf.into_store() {
                Some(store) => shared.push(EventKind::Data { store, n }),
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

/// Flushes the outbox of a socket whose kernel buffer was full.
async fn write_pump(socket: Rc<Socket>, lp: Rc<Loop>, shared: Rc<Shared>) {
    loop {
        let next = shared.out.borrow_mut().queue.pop_front();
        let Some(mut chunk) = next else {
            let mut out = shared.out.borrow_mut();
            out.writing = false;
            if std::mem::take(&mut out.need_ready) {
                drop(out);
                shared.push(EventKind::Ready);
            }
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
                }
                Err(code) => {
                    let mut out = shared.out.borrow_mut();
                    out.queue.clear();
                    out.bytes = 0;
                    out.writing = false;
                    drop(out);
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
        stores: RefCell::default(),
        need: Signal::default(),
        refill: Rc::clone(&host.refill),
        queued: Cell::new(0),
        space: Signal::default(),
        out: RefCell::default(),
        stop: Cell::new(false),
        closed: Cell::new(false),
        aborts: RefCell::default(),
    });
    host.subs.insert(id, Sub { dispatch, context, shared, runtime, owner: key, counted: false, started: false, current: None });
    Ok(())
}

/// Tops `shared`'s pool up to [`POOL_TARGET`] fresh stores (isolate thread only).
fn top_up(isolate: &mut v8::Isolate, shared: &Shared) {
    while shared.stores.borrow().len() < POOL_TARGET {
        let store = v8::ArrayBuffer::new_backing_store(isolate, CHUNK).make_shared();
        shared.stores.borrow_mut().push(store);
    }
}

/// Refills the pools of the sockets whose pump found its pool empty, and wakes the pumps.
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

/// `native.net.resume(id)`: starts reading a stream (`data`, `end`, `error`) or accepting on a
/// listener (`connection`). Idempotent.
#[native(side_effect = "any", path = "net.resume", needs = "runtime")]
fn net_resume(scope: &mut v8::PinScope<'_, '_>, key: ScopeKey, id: u32) -> Result<(), NativeError> {
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

/// `native.net.take(id)`: an `ArrayBuffer` over the very store the chunk was received into (no
/// copy; the chunk is at its start, `length` bytes as the `data` dispatch said). Only valid inside
/// the `data` dispatch, once per event (`StaleHandle` otherwise). Give it back with `release`.
#[native(side_effect = "any", path = "net.take", needs = "runtime")]
fn net_take<'s>(scope: &mut v8::PinScope<'s, '_>, key: ScopeKey, id: u32) -> Result<v8::Local<'s, v8::ArrayBuffer>, NativeError> {
    let host = host_mut(scope)?;
    let sub = host.subs.get_mut(&id).filter(|sub| sub.owner == key).ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
    let current = sub.current.as_mut().filter(|current| !current.taken).ok_or(NativeError::Errno(errno::STALE_HANDLE))?;
    current.taken = true;
    let store = current.store.clone();
    Ok(v8::ArrayBuffer::with_backing_store(scope, &store))
}

/// `native.net.release(id, buffer)`: detaches a lease from `take` and returns its store to the
/// pool. Idempotent for a detached buffer. Nothing is remembered per lease (an unreleased lease
/// that is garbage collected leaves no trace): any plain `CHUNK`-sized `ArrayBuffer` that detaches
/// is a sound pool member, because a detached, unshared store has no guest alias left, so the
/// pump may fill it. `Unsupported` for a buffer that is shared, undetachable or not a chunk-sized
/// store; for a socket that is gone or not the caller's the buffer is only detached.
#[native(side_effect = "any", path = "net.release", needs = "runtime")]
fn net_release<'s>(scope: &mut v8::PinScope<'s, '_>, key: ScopeKey, id: u32, buffer: v8::Local<'s, v8::Value>) -> Result<(), NativeError> {
    let buffer = v8::Local::<v8::ArrayBuffer>::try_from(buffer).map_err(|_| NativeError::type_error("buffer must be an ArrayBuffer"))?;
    if buffer.was_detached() {
        return Ok(());
    }
    let store = buffer.get_backing_store();
    if store.is_shared() || store.is_resizable_by_user_javascript() || !buffer.is_detachable() || store.byte_length() != CHUNK {
        return Err(NativeError::Errno(errno::UNSUPPORTED));
    }
    let shared = host_ref(scope)?.subs.get(&id).filter(|sub| sub.owner == key).map(|sub| Rc::clone(&sub.shared));
    if buffer.detach(None) != Some(true) || !buffer.was_detached() {
        return Err(NativeError::Errno(errno::UNEXPECTED));
    }
    // The socket may be gone: the lease then only had to stop aliasing anything.
    if let Some(shared) = shared
        && shared.stores.borrow().len() < POOL_MAX
    {
        shared.stores.borrow_mut().push(store);
        shared.need.wake();
    }
    Ok(())
}

/// `native.net.send(id, data)`: writes now and answers whether the caller may keep writing
/// (`false`: the outbox is above the high-water mark; wait for `ready`). `data` is copied only for
/// what the kernel did not take. A write error becomes an `error` event, not an exception.
#[native(side_effect = "any", path = "net.send", needs = "runtime")]
fn net_send(host: &mut HostState, key: ScopeKey, id: u32, data: ArrayBufferArg<'_>) -> Result<bool, NativeError> {
    let (socket, lp) = stream_of(host, key, id)?;
    let sub = host.subs.get(&id).ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
    let (shared, runtime) = (Rc::clone(&sub.shared), sub.runtime);
    if shared.closed.get() {
        return Err(NativeError::Errno(errno::BAD_HANDLE));
    }
    let stream = socket.stream().ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
    let mut out = shared.out.borrow_mut();
    if out.writing {
        out.bytes += data.len();
        out.queue.push_back(data.to_vec());
        let ok = out.bytes < HIGH_WATER;
        out.need_ready |= !ok;
        return Ok(ok);
    }
    let (result, rest) = data.with_bytes(|bytes| {
        let result = (&*stream).write(bytes);
        let rest = match &result {
            Ok(n) if *n < bytes.len() => Some(bytes[*n..].to_vec()),
            Err(error) if matches!(error.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::Interrupted) => Some(bytes.to_vec()),
            _ => None,
        };
        (result, rest)
    });
    if let Err(error) = &result
        && rest.is_none()
    {
        drop(out);
        shared.fail(errno::errno_of(error));
        return Ok(false);
    }
    let Some(rest) = rest else { return Ok(true) };
    out.bytes += rest.len();
    out.queue.push_back(rest);
    out.writing = true;
    out.need_ready = true;
    drop(out); // the writer polls once at spawn and takes the same borrow
    host.spawn_pump(runtime, &shared, Box::pin(write_pump(socket, lp, Rc::clone(&shared))))?;
    Ok(false)
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
    let (kind, a, b) = match event.kind {
        EventKind::Data { store, n } => {
            shared.queued.set(shared.queued.get() - 1);
            shared.space.wake();
            if let Some(sub) = host.subs.get_mut(&id) {
                sub.current = Some(Current { store, taken: false });
            }
            (KIND_DATA, n as u32, 0)
        }
        EventKind::End => (KIND_END, 0, 0),
        EventKind::Error(code) => (KIND_ERROR, code, 0),
        EventKind::Ready => (KIND_READY, 0, 0),
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
        // A chunk the handler did not take goes straight back to the pump.
        if let Some(current) = host.subs.get_mut(&id).and_then(|sub| sub.current.take())
            && !current.taken
        {
            shared.stores.borrow_mut().push(current.store);
            shared.need.wake();
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
