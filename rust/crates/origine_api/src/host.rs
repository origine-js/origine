//! Rust-side state of one Host, kept in the isolate annex slot (`scope.get_slot_mut::<HostState>()`):
//! the I/O runtimes the guest created, the fs grants bound to them, and the promises of the
//! operations in flight.
//!
//! Everything here runs on the isolate thread. V8 is touched only from the C entry points
//! (`lib.rs`) and from natives; tasks hold plain data and never a `Global`: those live in
//! [`Pending`] records, which are dropped (rejected or cleared) before the isolate goes away.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::future::Future;
use std::os::fd::{AsFd, IntoRawFd, OwnedFd};
use std::pin::Pin;
use std::rc::Rc;
use std::time::{Duration, Instant};

use origine_api_core::slab::Slab;
use origine_api_core::{Backend, Ceiling, NativeError, errno};
use origine_api_fs::{Access, Grant};
use origine_io::fs::Dir;
use origine_io::rt::Runtime;
use origine_io::{Loop, Mode, Options};

use crate::native::{Hook, ScopeKey, Wrap, finish};
use crate::net::Socket;
use crate::sub::{Events, Idle, Sub};
use crate::sys::{self, WakeRx};

/// Settles a promise on the isolate thread: finished async natives queue one of these.
pub type Completion = Box<dyn for<'s, 'i> FnOnce(&mut v8::PinScope<'s, 'i, ()>)>;

/// Completions shared between `HostState` and the tasks it spawned.
pub(crate) type CompletionQueue = Rc<RefCell<Vec<Completion>>>;

/// A task as the runtime runs it.
pub(crate) type Task = Pin<Box<dyn Future<Output = ()>>>;

/// The promise of one operation in flight (or of a runtime's `close`).
pub struct Pending {
    resolver: v8::Global<v8::PromiseResolver>,
    context: v8::Global<v8::Context>,
    runtime: u32,
    hook: Option<Hook>,
    /// Maps the encoded result into the final resolution value (see [`Wrap`]).
    wrap: Option<Wrap>,
}

impl Pending {
    pub(crate) fn new(
        resolver: v8::Global<v8::PromiseResolver>,
        context: v8::Global<v8::Context>,
        runtime: u32,
        hook: Option<Hook>,
    ) -> Pending {
        Pending { resolver, context, runtime, hook, wrap: None }
    }

    /// Adds the result mapping of an [`crate::native::Op`].
    pub(crate) fn with_wrap(mut self, wrap: Option<Wrap>) -> Pending {
        self.wrap = wrap;
        self
    }

    pub(crate) fn into_parts(self) -> (v8::Global<v8::PromiseResolver>, v8::Global<v8::Context>, Option<Hook>, Option<Wrap>) {
        (self.resolver, self.context, self.hook, self.wrap)
    }
}

/// What the embedder configured (`origine_api_configure`).
pub(crate) struct FsConfig {
    pub root: Option<OwnedFd>,
    pub write: bool,
    pub asynchronous: bool,
}

struct GrantRecord {
    grant: Rc<Grant>,
    owner: ScopeKey,
    runtime: u32,
}

enum RtState {
    Open,
    /// Closing: tasks are gone; waiting for the loop to go quiet, then the grants are released
    /// (their descriptors close through detached ops) and it goes quiet again.
    Draining {
        close_op: Option<u64>,
        grants_released: bool,
    },
}

struct RuntimeEntry {
    lp: Rc<Loop>,
    rt: Option<Runtime>,
    owner: ScopeKey,
    state: RtState,
    /// Grants of a draining runtime, released after its tasks are gone.
    held: Vec<Rc<GrantRecord>>,
}

impl RuntimeEntry {
    fn is_open(&self) -> bool {
        matches!(self.state, RtState::Open)
    }
}

/// Rust-side state of one Host.
pub struct HostState {
    ceiling: Ceiling,
    fs: FsConfig,
    runtimes: BTreeMap<u32, RuntimeEntry>,
    next_runtime: u32,
    grants: BTreeMap<u32, Rc<GrantRecord>>,
    next_grant: u32,
    sockets: BTreeMap<u32, Rc<Socket>>,
    next_socket: u32,
    pub(crate) subs: BTreeMap<u32, Sub>,
    pub(crate) events: Events,
    pub(crate) refill: Rc<RefCell<Vec<u32>>>,
    idle: BTreeMap<u32, Rc<Idle>>,
    pending: Slab<Pending>,
    timers: BTreeMap<(u32, u32), (u64, origine_io::rt::AbortHandle)>,
    clock_start: Instant,
    completions: CompletionQueue,
    wake: WakeRx,
}

impl HostState {
    /// A state that allows nothing until [`HostState::configure`].
    pub fn new(wake: WakeRx) -> HostState {
        HostState {
            ceiling: Ceiling::NONE,
            fs: FsConfig { root: None, write: false, asynchronous: false },
            runtimes: BTreeMap::new(),
            next_runtime: 1,
            grants: BTreeMap::new(),
            next_grant: 1,
            sockets: BTreeMap::new(),
            next_socket: 1,
            subs: BTreeMap::new(),
            events: Rc::default(),
            refill: Rc::default(),
            idle: BTreeMap::new(),
            pending: Slab::default(),
            timers: BTreeMap::new(),
            clock_start: Instant::now(),
            completions: Rc::default(),
            wake,
        }
    }

    pub(crate) fn configure(&mut self, ceiling: Ceiling, fs: FsConfig) {
        self.ceiling = ceiling;
        self.fs = fs;
    }

    pub(crate) fn completions(&self) -> CompletionQueue {
        Rc::clone(&self.completions)
    }

    pub(crate) fn take_pending(&mut self, id: u64) -> Option<Pending> {
        self.pending.take(id)
    }

    // ---- runtimes ----------------------------------------------------------------------

    /// Creates a runtime owned by `owner`, enforcing the embedder's ceiling.
    pub fn create_runtime(&mut self, owner: ScopeKey, backend: Backend, entries: Option<u32>) -> Result<u32, NativeError> {
        self.ceiling.check_create(self.runtimes.len(), backend).map_err(NativeError::Errno)?;
        let id = self.next_runtime;
        let next = id.checked_add(1).ok_or(NativeError::Errno(errno::PERMISSION_DENIED))?;
        let kind = match backend {
            Backend::Auto => origine_io::Backend::Auto,
            Backend::Uring => origine_io::Backend::Uring,
            Backend::Kqueue => origine_io::Backend::KqueueGcd,
            Backend::Threaded => origine_io::Backend::Threaded,
        };
        let entries = entries.unwrap_or(self.ceiling.default_entries).min(1 << 16);
        let lp = Loop::new(Options { backend: kind, entries }).map_err(|_| NativeError::Errno(errno::UNSUPPORTED))?;
        let lp = Rc::new(lp);
        let rt = Runtime::new(Rc::clone(&lp));
        self.next_runtime = next;
        self.runtimes.insert(id, RuntimeEntry { lp, rt: Some(rt), owner, state: RtState::Open, held: Vec::new() });
        Ok(id)
    }

    /// The open runtime `id` of `owner`; `BadHandle` for an unknown, foreign or closing one.
    fn open_runtime(&self, owner: ScopeKey, id: u32) -> Result<&RuntimeEntry, NativeError> {
        match self.runtimes.get(&id) {
            Some(entry) if entry.owner == owner && entry.is_open() => Ok(entry),
            _ => Err(NativeError::Errno(errno::BAD_HANDLE)),
        }
    }

    /// Spawns the task `make(op id)` builds on the runtime of `pending` and registers `pending`.
    pub(crate) fn start(&mut self, pending: Pending, make: impl FnOnce(u64) -> Task) -> Result<(), NativeError> {
        let runtime = pending.runtime;
        let entry = match self.runtimes.get(&runtime) {
            Some(entry) if entry.is_open() => entry,
            _ => return Err(NativeError::Errno(errno::BAD_HANDLE)),
        };
        let handle = entry.rt.as_ref().ok_or(NativeError::Errno(errno::BAD_HANDLE))?.handle();
        let id = self.pending.insert(pending);
        drop(handle.spawn_eager(make(id))); // detached: it reports through the completion queue; first poll now, so the op is submitted in the native call
        Ok(())
    }

    /// Starts a monotonic timer belonging to the caller's runtime. Its token is never reused
    /// by the JS handle, so cancelling an expired timer cannot reach a later timer.
    pub(crate) fn start_timer(&mut self, owner: ScopeKey, token: u32, duration: Duration, pending: Pending) -> Result<(), NativeError> {
        let runtime = pending.runtime;
        let entry = self.open_runtime(owner, runtime)?;
        let lp = Rc::clone(&entry.lp);
        let handle = entry.rt.as_ref().ok_or(NativeError::Errno(errno::BAD_HANDLE))?.handle();
        if self.timers.contains_key(&(runtime, token)) {
            return Err(NativeError::Errno(errno::BAD_HANDLE));
        }
        let id = self.pending.insert(pending);
        let completions = self.completions();
        let task = handle.spawn_eager(async move {
            let result = lp.timeout(duration).await.map_err(NativeError::from);
            completions.borrow_mut().push(Box::new(move |scope| {
                let Some(host) = scope.get_slot_mut::<HostState>() else { return };
                host.timers.remove(&(runtime, token));
                if let Some(pending) = host.take_pending(id) {
                    finish(scope, pending, result);
                }
            }));
        });
        self.timers.insert((runtime, token), (id, task.abort_handle()));
        Ok(())
    }

    /// Cancels just one timer, leaving all other operations of the runtime running.
    pub(crate) fn cancel_timer(&mut self, owner: ScopeKey, runtime: u32, token: u32) -> Result<Option<Pending>, NativeError> {
        self.open_runtime(owner, runtime)?;
        let Some((id, abort)) = self.timers.remove(&(runtime, token)) else { return Ok(None) };
        abort.abort();
        Ok(self.take_pending(id))
    }

    pub(crate) fn timer_now(&self, owner: ScopeKey, runtime: u32) -> Result<f64, NativeError> {
        self.open_runtime(owner, runtime)?;
        Ok(self.clock_start.elapsed().as_secs_f64() * 1000.0)
    }

    /// Starts closing runtime `id`: its tasks are dropped (cancelling their ops), its pending
    /// promises are returned to be rejected with `Canceled`, and `close` becomes the promise that
    /// resolves once the loop is quiet and the grants are released.
    pub(crate) fn begin_close(&mut self, owner: ScopeKey, id: u32, close: Pending) -> Result<Vec<Pending>, NativeError> {
        self.open_runtime(owner, id)?;
        let canceled = self.cancel_runtime(id);
        let op = self.pending.insert(close);
        if let Some(entry) = self.runtimes.get_mut(&id) {
            entry.state = RtState::Draining { close_op: Some(op), grants_released: false };
        }
        Ok(canceled)
    }

    /// Drops the runtime's tasks, takes its grants out of reach and returns its pending promises.
    fn cancel_runtime(&mut self, id: u32) -> Vec<Pending> {
        let rt = self.runtimes.get_mut(&id).and_then(|entry| entry.rt.take());
        drop(rt); // cancels every task; the loop runs once to deliver the cancellations
        self.timers.retain(|(runtime, _), _| *runtime != id);
        let canceled = self.pending.take_where(|pending| pending.runtime == id);
        self.sockets.retain(|_, socket| socket.runtime() != id);
        self.subs.retain(|_, sub| sub.runtime != id);
        let grant_ids: Vec<u32> = self.grants.iter().filter(|(_, record)| record.runtime == id).map(|(grant, _)| *grant).collect();
        if let Some(entry) = self.runtimes.get_mut(&id) {
            entry.state = RtState::Draining { close_op: None, grants_released: false };
            for grant in grant_ids {
                if let Some(record) = self.grants.remove(&grant) {
                    entry.held.push(record);
                }
            }
        }
        canceled
    }

    /// Advances every draining runtime; returns the close promises that are done.
    pub(crate) fn step_draining(&mut self) -> Vec<Pending> {
        let mut done = Vec::new();
        for (id, entry) in &mut self.runtimes {
            let RtState::Draining { close_op, grants_released } = &mut entry.state else { continue };
            let _ = entry.lp.run(Mode::NoWait);
            if entry.lp.active() == 0 && !*grants_released {
                entry.held.clear(); // detached closes of the descriptors
                *grants_released = true;
                let _ = entry.lp.run(Mode::NoWait);
            }
            if entry.lp.active() == 0 && *grants_released {
                done.push((*id, *close_op));
            }
        }
        let mut finished = Vec::new();
        for (id, close_op) in done {
            self.runtimes.remove(&id); // destroys the loop
            self.idle.remove(&id);
            if let Some(pending) = close_op.and_then(|op| self.pending.take(op)) {
                finished.push(pending);
            }
        }
        finished
    }

    /// Runs every open runtime's ready tasks and its loop without waiting.
    pub(crate) fn tick_all(&mut self) {
        for entry in self.runtimes.values() {
            if let Some(rt) = &entry.rt {
                rt.tick(Mode::NoWait);
            }
        }
    }

    pub(crate) fn take_completions(&mut self) -> Vec<Completion> {
        std::mem::take(&mut *self.completions.borrow_mut())
    }

    /// Tasks and active ops across runtimes, plus the close promises being waited for.
    pub fn live_items(&self) -> i64 {
        let mut live = 0usize;
        for (id, entry) in &self.runtimes {
            // Subscription pumps and their in-flight receives only listen; they never keep the host alive.
            let (pumps, recving) = self.idle.get(id).map_or((0, 0), |idle| (idle.pumps.get(), idle.recving.get()));
            live += (entry.lp.active() as usize).saturating_sub(recving);
            if let Some(rt) = &entry.rt {
                live += rt.task_count().saturating_sub(pumps);
            }
            if matches!(entry.state, RtState::Draining { .. }) {
                live += 1;
            }
        }
        live as i64 + (self.completions.borrow().len() + self.events.borrow().len()) as i64
    }

    fn any_ready(&self) -> bool {
        !self.completions.borrow().is_empty()
            || !self.events.borrow().is_empty()
            || self.runtimes.values().any(|entry| entry.rt.as_ref().is_some_and(Runtime::has_ready))
    }

    /// Blocks until a runtime's loop, the wake channel or the timeout (`None` = forever) fires.
    pub(crate) fn wait(&mut self, timeout: Option<Duration>) {
        if self.any_ready() {
            return;
        }
        let mut fds = vec![self.wake.fd()];
        let mut unpollable = false;
        for entry in self.runtimes.values() {
            match entry.lp.pollable() {
                Some(fd) => fds.push(fd as i32),
                None => unpollable = true,
            }
        }
        let mut timeout = timeout;
        if unpollable {
            timeout = Some(timeout.map_or(Duration::from_millis(1), |t| t.min(Duration::from_millis(1))));
        }
        let ms = match timeout {
            None => -1,
            Some(t) => t.as_nanos().div_ceil(1_000_000).min(i32::MAX as u128) as i32,
        };
        if let Ok(ready) = sys::wait_readable(&fds, ms)
            && ready.first().copied().unwrap_or(false)
        {
            self.wake.drain();
        }
    }

    // ---- fs grants ---------------------------------------------------------------------

    /// The grant `fs` of `owner` and the runtime it is bound to; `BadHandle` if unknown, foreign
    /// or its runtime is closing.
    pub fn grant(&self, owner: ScopeKey, fs: u32) -> Result<(Rc<Grant>, u32), NativeError> {
        match self.grants.get(&fs) {
            Some(record) if record.owner == owner && self.open_runtime(owner, record.runtime).is_ok() => {
                Ok((Rc::clone(&record.grant), record.runtime))
            }
            _ => Err(NativeError::Errno(errno::BAD_HANDLE)),
        }
    }

    /// Prepares a grant over `root` (relative to the configured fs root) bound to runtime `io`.
    /// Returns the runtime, the grant id and the future that opens the root; the grant is
    /// registered by [`HostState::register_grant`] when the promise settles.
    pub fn prepare_grant(
        &mut self,
        owner: ScopeKey,
        io: u32,
        root: &str,
        access: u32,
    ) -> Result<(u32, u32, Access, Dir, String), NativeError> {
        let lp = Rc::clone(&self.open_runtime(owner, io)?.lp);
        let denied = || NativeError::Errno(errno::PERMISSION_DENIED);
        let access = Access::from_bits(access).ok_or(NativeError::Errno(errno::INVALID_INPUT))?;
        if !self.fs.asynchronous {
            return Err(denied());
        }
        let base = self.fs.root.as_ref().ok_or_else(denied)?;
        // The embedder's write ceiling: a request above it is rejected, never downgraded.
        if access.write && !self.fs.write {
            return Err(denied());
        }
        origine_api_fs::check_root(root)?;
        let base = base.as_fd().try_clone_to_owned()?;
        let id = self.next_grant;
        self.next_grant = id.checked_add(1).ok_or_else(denied)?;
        let dir = Dir::from_fd(&lp, base.into_raw_fd() as isize);
        Ok((io, id, access, dir, if root.is_empty() { ".".to_owned() } else { root.to_owned() }))
    }

    /// Makes a freshly opened grant addressable. Fails with `Canceled` if its runtime went away.
    pub(crate) fn register_grant(&mut self, owner: ScopeKey, runtime: u32, grant: Rc<Grant>) -> Result<(), NativeError> {
        self.open_runtime(owner, runtime).map_err(|_| NativeError::Errno(errno::CANCELED))?;
        self.grants.insert(grant.id(), Rc::new(GrantRecord { grant, owner, runtime }));
        Ok(())
    }

    // ---- sockets ------------------------------------------------------------------------

    /// The loop of the open runtime `io` of `owner`; `BadHandle` for an unknown, foreign or closing one.
    pub(crate) fn loop_of(&self, owner: ScopeKey, io: u32) -> Result<Rc<Loop>, NativeError> {
        Ok(Rc::clone(&self.open_runtime(owner, io)?.lp))
    }

    /// The socket `id` of `owner`, its loop and its runtime; `BadHandle` if unknown, foreign or
    /// its runtime is closing.
    pub(crate) fn socket(&self, owner: ScopeKey, id: u32) -> Result<(Rc<Socket>, Rc<Loop>), NativeError> {
        let socket = self.sockets.get(&id).filter(|socket| socket.owner() == owner).ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
        let lp = self.loop_of(owner, socket.runtime())?;
        Ok((Rc::clone(socket), lp))
    }

    /// A fresh socket id (not yet addressable until [`HostState::insert_socket`]).
    pub(crate) fn reserve_socket(&mut self) -> Result<u32, NativeError> {
        let id = self.next_socket;
        self.next_socket = id.checked_add(1).ok_or(NativeError::Errno(errno::PERMISSION_DENIED))?;
        Ok(id)
    }

    /// Makes `socket` addressable as `id`. `Canceled` if its runtime went away meanwhile.
    pub(crate) fn insert_socket(&mut self, id: u32, socket: Socket) -> Result<(), NativeError> {
        self.open_runtime(socket.owner(), socket.runtime()).map_err(|_| NativeError::Errno(errno::CANCELED))?;
        self.sockets.insert(id, Rc::new(socket));
        Ok(())
    }

    /// Takes socket `id` out of the table; operations in flight keep the descriptor alive.
    /// Drops socket `id` from the table without an owner check (a subscription ending).
    pub(crate) fn sockets_remove(&mut self, id: u32) -> Option<Rc<Socket>> {
        self.sockets.remove(&id)
    }

    /// The idle counters of runtime `runtime`.
    pub(crate) fn idle_of(&mut self, runtime: u32) -> Rc<Idle> {
        Rc::clone(self.idle.entry(runtime).or_default())
    }

    /// Spawns `task` on the open runtime `runtime`, detached; the handle aborts it.
    pub(crate) fn spawn_detached(&self, runtime: u32, task: Task) -> Result<origine_io::rt::AbortHandle, NativeError> {
        let entry = match self.runtimes.get(&runtime) {
            Some(entry) if entry.is_open() => entry,
            _ => return Err(NativeError::Errno(errno::BAD_HANDLE)),
        };
        let handle = entry.rt.as_ref().ok_or(NativeError::Errno(errno::BAD_HANDLE))?.handle();
        Ok(handle.spawn_eager(task).abort_handle())
    }

    pub(crate) fn remove_socket(&mut self, owner: ScopeKey, id: u32) -> Result<Rc<Socket>, NativeError> {
        match self.sockets.get(&id) {
            Some(socket) if socket.owner() == owner => Ok(self.sockets.remove(&id).expect("just found")),
            _ => Err(NativeError::Errno(errno::BAD_HANDLE)),
        }
    }

    // ---- teardown ----------------------------------------------------------------------

    /// Drops every pending promise and queued completion (they own V8 `Global`s, which must be
    /// released while the isolate is alive), cancels every runtime and runs the loops until quiet
    /// (bounded). Idempotent. The detach function calls it before `Runtime.destroy`.
    pub fn drop_all(&mut self) {
        self.subs.clear();
        self.events.borrow_mut().clear();
        self.pending.clear();
        self.completions.borrow_mut().clear();
        let ids: Vec<u32> = self.runtimes.keys().copied().collect();
        for id in ids {
            drop(self.cancel_runtime(id));
        }
        for _ in 0..2000 {
            drop(self.step_draining());
            if self.runtimes.is_empty() {
                break;
            }
            self.wait(Some(Duration::from_millis(5)));
        }
        // Whatever is still not quiet is destroyed with its loop (which fires the callbacks).
        self.runtimes.clear();
        self.grants.clear();
        self.sockets.clear();
        self.subs.clear();
        self.idle.clear();
        self.pending.clear();
    }
}

impl Drop for HostState {
    fn drop(&mut self) {
        self.drop_all();
    }
}

/// One turn of the async machinery on the isolate thread (the body of `origine_api_poll`).
/// Runs tasks and loops, advances closing runtimes and settles finished promises; with `block`
/// it waits (`timeout` `None` = forever) when that made no progress. Returns the live items.
pub fn poll(scope: &mut v8::PinScope<'_, '_, ()>, block: bool, timeout: Option<Duration>) -> i64 {
    let mut settled = turn(scope);
    if block && settled == 0 {
        let Some(host) = scope.get_slot_mut::<HostState>() else { return 0 };
        host.wait(timeout);
        settled += turn(scope);
    }
    let _ = settled;
    scope.get_slot::<HostState>().map_or(0, HostState::live_items)
}

/// Ticks everything once and settles what finished; returns how many promises settled.
fn turn(scope: &mut v8::PinScope<'_, '_, ()>) -> usize {
    let Some(host) = scope.get_slot_mut::<HostState>() else { return 0 };
    host.tick_all();
    let closed = host.step_draining();
    let completions = host.take_completions();
    let mut settled = closed.len() + completions.len();
    crate::sub::refill(scope);
    settled += crate::sub::deliver_all(scope);
    for pending in closed {
        finish(scope, pending, Ok(()));
    }
    for completion in completions {
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| completion(scope)));
    }
    // Settling may have queued nothing new, but a hook can register grants whose runtime closed.
    if let Some(host) = scope.get_slot::<HostState>() {
        settled += usize::from(!host.completions.borrow().is_empty());
    }
    settled
}
