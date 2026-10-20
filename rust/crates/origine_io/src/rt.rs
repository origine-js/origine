//! A small single-threaded async runtime on top of the [`Loop`] (the loop is the reactor, like
//! mio under tokio). std only: no threads, no blocking.
//!
//! * [`Runtime`] is bound to one `Rc<Loop>`. [`Runtime::spawn`] accepts `!Send` futures and
//!   returns a [`JoinHandle`]. Tasks are only ever polled on the loop thread.
//! * Wakers are `Arc<Task>` based (the `Waker` contract requires `Send + Sync`): a wake marks the
//!   task ready in a mutex-guarded queue shared with the runtime and, when it happens on another
//!   thread, also calls [`LoopHandle::wake`] so a sleeping `Loop::run(Mode::Once)` returns.
//! * Dropping the [`Runtime`], or aborting a task, drops the task's future. Dropping an op future
//!   cancels the op (see the crate docs): the op memory stays alive until its callback ran.
//! * A panic inside a task is caught and surfaced as [`JoinError::Panicked`]; the runtime stays
//!   usable.
//! * Fairness: every task poll starts with a budget of cooperative operations
//!   ([`JoinHandle`], [`JoinSet::join_next`], [`consume_budget`]); when it is used up they return
//!   `Pending` and reschedule the task behind the others. [`Runtime::tick`] polls a bounded number
//!   of rounds before it lets the loop run, so busy tasks cannot starve I/O.
//!
//! # Driving
//! * [`Runtime::block_on`] for tests and simple programs.
//! * [`Runtime::tick`] for a host that owns the thread: drain ready tasks, `Loop::run(mode)`,
//!   drain again. [`Runtime::has_work`] tells whether it must keep ticking.
//! * [`Runtime::run_until_idle`] polls ready tasks until none is ready (does not run the loop).
//!
//! # Panics and detaching
//! Dropping a [`JoinHandle`] detaches the task (it keeps running, its output is dropped); use
//! [`JoinHandle::abort`] / [`AbortHandle`] to cancel.

use std::any::Any;
use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, VecDeque};
use std::fmt;
use std::future::Future;
use std::io;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::pin::Pin;
use std::rc::{Rc, Weak};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak as ArcWeak};
use std::task::{Context, Poll, Wake, Waker};
use std::thread::{self, ThreadId};
use std::time::{Duration, Instant};

use crate::{Loop, LoopHandle, Mode, OpFuture};

type Deliver<T> = Box<dyn FnOnce(Result<T, JoinError>)>;
type LocalFut = Pin<Box<dyn Future<Output = ()>>>;

/// Cooperative operations a task may complete per poll before it is rescheduled.
const COOP_BUDGET: u32 = 128;
/// Rounds of ready tasks `tick` polls before/after running the loop.
const TICK_ROUNDS: usize = 4;
const ROOT: u64 = 0;

thread_local! {
    static BUDGET: Cell<u32> = const { Cell::new(u32::MAX) };
    static CURRENT: RefCell<Weak<RtInner>> = const { RefCell::new(Weak::new()) };
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// `true` if the task may complete a cooperative operation now; otherwise it has been
/// rescheduled and must return `Pending`.
fn coop_ready(cx: &Context<'_>) -> bool {
    BUDGET.with(|b| {
        let v = b.get();
        if v == 0 {
            cx.waker().wake_by_ref();
            false
        } else {
            b.set(v - 1);
            true
        }
    })
}

/// Completes immediately, but consumes one unit of the task's cooperative budget; when it is
/// exhausted the task yields to the others first. Put it in long loops that never otherwise
/// return `Pending`.
pub fn consume_budget() -> impl Future<Output = ()> {
    std::future::poll_fn(|cx| if coop_ready(cx) { Poll::Ready(()) } else { Poll::Pending })
}

/// Reschedule the current task behind all other ready tasks.
pub fn yield_now() -> impl Future<Output = ()> {
    let mut yielded = false;
    std::future::poll_fn(move |cx| {
        if yielded {
            Poll::Ready(())
        } else {
            yielded = true;
            cx.waker().wake_by_ref();
            Poll::Pending
        }
    })
}

// ---------------------------------------------------------------------------------------------
// Wake plumbing (the only part shared across threads)

struct Shared {
    ready: Mutex<VecDeque<Arc<Task>>>,
    handle: LoopHandle,
    thread: ThreadId,
}

struct Task {
    id: u64,
    /// In the ready queue (or about to be).
    queued: AtomicBool,
    shared: ArcWeak<Shared>,
}

impl Wake for Task {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }
    fn wake_by_ref(self: &Arc<Self>) {
        let Some(shared) = self.shared.upgrade() else { return };
        if self.queued.swap(true, Ordering::AcqRel) {
            return;
        }
        lock(&shared.ready).push_back(self.clone());
        if thread::current().id() != shared.thread {
            shared.handle.wake();
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Runtime

struct Slot {
    /// `None` while the task is being polled.
    fut: Option<LocalFut>,
    /// Abort requested while the future was out being polled.
    abort: bool,
}

struct RtInner {
    lp: Rc<Loop>,
    shared: Arc<Shared>,
    tasks: RefCell<BTreeMap<u64, Slot>>,
    next_id: Cell<u64>,
    closed: Cell<bool>,
}

/// Keeps the "current runtime" thread-local pointing at one runtime while it polls tasks.
struct EnterGuard(Weak<RtInner>);

impl EnterGuard {
    fn enter(inner: &Rc<RtInner>) -> EnterGuard {
        EnterGuard(CURRENT.with(|c| c.replace(Rc::downgrade(inner))))
    }
}

impl Drop for EnterGuard {
    fn drop(&mut self) {
        CURRENT.with(|c| *c.borrow_mut() = std::mem::take(&mut self.0));
    }
}

/// Drop a value, discarding a panic raised by its destructor.
fn drop_quiet<T>(v: T) {
    let _ = catch_unwind(AssertUnwindSafe(move || drop(v)));
}

impl RtInner {
    fn spawn_raw<T: 'static>(self: &Rc<Self>, fut: impl Future<Output = T> + 'static, deliver: Deliver<T>) -> AbortHandle {
        let wrapped = TaskFuture { fut: Some(Box::pin(fut)), deliver: Some(deliver) };
        if self.closed.get() {
            drop(wrapped); // delivers `Cancelled`
            return AbortHandle { rt: Weak::new(), id: 0 };
        }
        let id = self.next_id.get() + 1;
        self.next_id.set(id);
        self.tasks.borrow_mut().insert(id, Slot { fut: Some(Box::pin(wrapped)), abort: false });
        let task = Arc::new(Task { id, queued: AtomicBool::new(false), shared: Arc::downgrade(&self.shared) });
        task.wake_by_ref();
        AbortHandle { rt: Rc::downgrade(self), id }
    }

    fn abort(&self, id: u64) {
        let fut = {
            let mut tasks = self.tasks.borrow_mut();
            match tasks.get_mut(&id) {
                None => return,
                Some(slot) if slot.fut.is_some() => {
                    let f = slot.fut.take();
                    tasks.remove(&id);
                    f
                }
                Some(slot) => {
                    slot.abort = true;
                    None
                }
            }
        };
        drop_quiet(fut); // outside the borrow: its destructor may touch the runtime
    }

    fn poll_task(&self, task: &Arc<Task>) -> bool {
        let fut = {
            let mut tasks = self.tasks.borrow_mut();
            tasks.get_mut(&task.id).and_then(|s| s.fut.take())
        };
        let Some(mut fut) = fut else { return false };
        let waker = Waker::from(task.clone());
        let mut cx = Context::from_waker(&waker);
        BUDGET.with(|b| b.set(COOP_BUDGET));
        let poll = fut.as_mut().poll(&mut cx);
        let keep = {
            let mut tasks = self.tasks.borrow_mut();
            match (poll, tasks.get_mut(&task.id)) {
                (Poll::Pending, Some(slot)) if !slot.abort => {
                    slot.fut = Some(fut);
                    None
                }
                (_, Some(_)) => {
                    tasks.remove(&task.id);
                    Some(fut)
                }
                (_, None) => Some(fut),
            }
        };
        drop_quiet(keep);
        true
    }

    /// Poll the ready tasks for up to `max_rounds` rounds (a round polls what was ready when it
    /// started; tasks woken meanwhile wait for the next round). Returns the number of polls.
    fn drain(self: &Rc<Self>, max_rounds: usize, mut root: Option<&mut bool>) -> usize {
        let _enter = EnterGuard::enter(self);
        let mut polls = 0;
        for _ in 0..max_rounds {
            let batch = std::mem::take(&mut *lock(&self.shared.ready));
            if batch.is_empty() {
                break;
            }
            for task in batch {
                task.queued.store(false, Ordering::Release);
                if task.id == ROOT {
                    if let Some(r) = root.as_deref_mut() {
                        *r = true;
                    }
                } else if self.poll_task(&task) {
                    polls += 1;
                }
            }
        }
        polls
    }

    fn has_ready(&self) -> bool {
        !lock(&self.shared.ready).is_empty()
    }
}

/// The single-threaded runtime. Owns the tasks; dropping it cancels all of them.
pub struct Runtime {
    inner: Rc<RtInner>,
}

impl Runtime {
    /// Create a runtime on the calling thread (the loop thread).
    pub fn new(lp: Rc<Loop>) -> Runtime {
        let shared = Arc::new(Shared { ready: Mutex::new(VecDeque::new()), handle: lp.handle(), thread: thread::current().id() });
        Runtime {
            inner: Rc::new(RtInner { lp, shared, tasks: RefCell::new(BTreeMap::new()), next_id: Cell::new(0), closed: Cell::new(false) }),
        }
    }

    /// A weak, cloneable handle for spawning from anywhere on this thread (tasks included).
    pub fn handle(&self) -> Handle {
        Handle { inner: Rc::downgrade(&self.inner) }
    }

    pub fn event_loop(&self) -> &Rc<Loop> {
        &self.inner.lp
    }

    /// Spawn a task. It first runs on the next drain. See [`Handle::spawn`].
    pub fn spawn<F: Future + 'static>(&self, f: F) -> JoinHandle<F::Output>
    where
        F::Output: 'static,
    {
        self.handle().spawn(f)
    }

    pub fn sleep(&self, d: Duration) -> Sleep {
        self.handle().sleep(d)
    }

    pub fn timeout<F: Future>(&self, d: Duration, fut: F) -> impl Future<Output = Result<F::Output, Elapsed>> + use<F> {
        self.handle().timeout(d, fut)
    }

    /// Number of live (not finished, not aborted) tasks.
    pub fn task_count(&self) -> usize {
        self.inner.tasks.borrow().len()
    }

    /// Tasks are alive or the loop has active ops: the host must keep ticking.
    pub fn has_work(&self) -> bool {
        self.task_count() > 0 || self.inner.lp.active() > 0
    }

    /// Some task is ready to be polled (it was woken or just spawned).
    pub fn has_ready(&self) -> bool {
        self.inner.has_ready()
    }

    /// Poll ready tasks until none is ready. Does not run the loop. Returns the number of polls.
    /// A task that keeps rescheduling itself (`yield_now` in a loop) keeps this running.
    pub fn run_until_idle(&self) -> usize {
        self.inner.drain(usize::MAX, None)
    }

    /// Host integration: drain ready tasks, `Loop::run(mode)`, drain ready tasks again. Returns
    /// the number of task polls. `Mode::Once` is downgraded to `NoWait` when tasks are still
    /// ready, so it only blocks when there is nothing to do but wait. Panics if the loop fails.
    pub fn tick(&self, mode: Mode) -> usize {
        let mut polls = self.inner.drain(TICK_ROUNDS, None);
        let mode = if mode == Mode::Once && self.inner.has_ready() { Mode::NoWait } else { mode };
        self.inner.lp.run(mode).expect("loop run failed");
        polls += self.inner.drain(TICK_ROUNDS, None);
        polls
    }

    /// Run `fut` (it need not be `'static` or `Send`) to completion, driving tasks and the loop.
    /// Blocks in `Loop::run(Once)` when nothing is ready, so it never returns if the future can
    /// no longer be woken.
    pub fn block_on<F: Future>(&self, fut: F) -> F::Output {
        let mut fut = std::pin::pin!(fut);
        let root = Arc::new(Task { id: ROOT, queued: AtomicBool::new(false), shared: Arc::downgrade(&self.inner.shared) });
        let waker = Waker::from(root);
        let mut cx = Context::from_waker(&waker);
        let _enter = EnterGuard::enter(&self.inner);
        let mut root_ready = true;
        loop {
            if root_ready {
                root_ready = false;
                BUDGET.with(|b| b.set(COOP_BUDGET));
                if let Poll::Ready(v) = fut.as_mut().poll(&mut cx) {
                    return v;
                }
            }
            self.inner.drain(TICK_ROUNDS, Some(&mut root_ready));
            let mode = if root_ready || self.inner.has_ready() { Mode::NoWait } else { Mode::Once };
            self.inner.lp.run(mode).expect("loop run failed");
        }
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        self.inner.closed.set(true);
        loop {
            let slot = self.inner.tasks.borrow_mut().pop_first();
            match slot {
                Some((_, slot)) => drop_quiet(slot),
                None => break,
            }
        }
        lock(&self.inner.shared.ready).clear();
        // Let the loop run the callbacks of the ops we just cancelled.
        let _ = self.inner.lp.run(Mode::NoWait);
    }
}

/// Cloneable weak reference to a [`Runtime`]; spawning after the runtime is dropped yields a task
/// that is immediately cancelled.
#[derive(Clone)]
pub struct Handle {
    inner: Weak<RtInner>,
}

impl Handle {
    /// The runtime currently polling a task (or inside `block_on`) on this thread.
    pub fn try_current() -> Option<Handle> {
        let inner = CURRENT.with(|c| c.borrow().clone());
        (inner.strong_count() > 0).then_some(Handle { inner })
    }

    /// # Panics
    /// If called outside a runtime.
    pub fn current() -> Handle {
        Handle::try_current().expect("not inside an origine_io::rt runtime")
    }

    pub fn is_closed(&self) -> bool {
        self.inner.upgrade().is_none_or(|rt| rt.closed.get())
    }

    pub fn spawn<F: Future + 'static>(&self, f: F) -> JoinHandle<F::Output>
    where
        F::Output: 'static,
    {
        let state = Rc::new(RefCell::new(JoinInner { result: None, waker: None }));
        let st = state.clone();
        let deliver = Box::new(move |r: Result<F::Output, JoinError>| {
            let waker = {
                let mut s = st.borrow_mut();
                s.result = Some(r);
                s.waker.take()
            };
            if let Some(w) = waker {
                w.wake();
            }
        });
        let abort = self.spawn_raw(f, deliver);
        JoinHandle { state, abort }
    }

    fn spawn_raw<T: 'static>(&self, f: impl Future<Output = T> + 'static, deliver: Deliver<T>) -> AbortHandle {
        match self.inner.upgrade() {
            Some(rt) => rt.spawn_raw(f, deliver),
            None => {
                drop(TaskFuture { fut: Some(Box::pin(f)), deliver: Some(deliver) });
                AbortHandle { rt: Weak::new(), id: 0 }
            }
        }
    }

    pub fn sleep(&self, d: Duration) -> Sleep {
        Sleep { lp: self.inner.upgrade().map(|rt| rt.lp.clone()), deadline: Instant::now() + d, op: None }
    }

    pub fn timeout<F: Future>(&self, d: Duration, fut: F) -> impl Future<Output = Result<F::Output, Elapsed>> + use<F> {
        timeout_with(self.sleep(d), fut)
    }
}

// ---------------------------------------------------------------------------------------------
// Tasks and join handles

/// The future stored in the runtime: catches panics and reports the outcome exactly once, also
/// when it is dropped before completion (`Cancelled`).
struct TaskFuture<T> {
    fut: Option<Pin<Box<dyn Future<Output = T>>>>,
    deliver: Option<Deliver<T>>,
}

impl<T> TaskFuture<T> {
    fn finish(&mut self, r: Result<T, JoinError>) {
        drop_quiet(self.fut.take());
        if let Some(d) = self.deliver.take() {
            d(r);
        }
    }
}

impl<T> Future for TaskFuture<T> {
    type Output = ();
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        let this = self.get_mut();
        let Some(fut) = this.fut.as_mut() else { return Poll::Ready(()) };
        match catch_unwind(AssertUnwindSafe(|| fut.as_mut().poll(cx))) {
            Ok(Poll::Pending) => Poll::Pending,
            Ok(Poll::Ready(v)) => {
                this.finish(Ok(v));
                Poll::Ready(())
            }
            Err(p) => {
                this.finish(Err(JoinError::Panicked(p)));
                Poll::Ready(())
            }
        }
    }
}

impl<T> Drop for TaskFuture<T> {
    fn drop(&mut self) {
        if self.deliver.is_some() {
            self.finish(Err(JoinError::Cancelled));
        }
    }
}

/// Why a task did not produce its output.
pub enum JoinError {
    /// Aborted, or its runtime was dropped.
    Cancelled,
    /// The task panicked; the payload is what `panic!` carried.
    Panicked(Box<dyn Any + Send>),
}

impl JoinError {
    pub fn is_cancelled(&self) -> bool {
        matches!(self, JoinError::Cancelled)
    }
    pub fn is_panic(&self) -> bool {
        matches!(self, JoinError::Panicked(_))
    }
    /// The panic payload.
    ///
    /// # Panics
    /// If the error is not a panic.
    pub fn into_panic(self) -> Box<dyn Any + Send> {
        match self {
            JoinError::Panicked(p) => p,
            JoinError::Cancelled => panic!("JoinError::into_panic on a cancelled task"),
        }
    }
}

impl fmt::Debug for JoinError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            JoinError::Cancelled => f.write_str("Cancelled"),
            JoinError::Panicked(_) => f.write_str("Panicked(..)"),
        }
    }
}

impl fmt::Display for JoinError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            JoinError::Cancelled => f.write_str("task was cancelled"),
            JoinError::Panicked(_) => f.write_str("task panicked"),
        }
    }
}

impl std::error::Error for JoinError {}

struct JoinInner<T> {
    result: Option<Result<T, JoinError>>,
    waker: Option<Waker>,
}

/// Weak handle that can cancel a task. Cloneable.
#[derive(Clone)]
pub struct AbortHandle {
    rt: Weak<RtInner>,
    id: u64,
}

impl AbortHandle {
    /// Cancel the task: its future is dropped now (or right after its current poll if it aborts
    /// itself), which cancels its in-flight ops. Its [`JoinHandle`] resolves to
    /// [`JoinError::Cancelled`] unless the task had already finished.
    pub fn abort(&self) {
        if let Some(rt) = self.rt.upgrade() {
            rt.abort(self.id);
        }
    }

    pub fn is_finished(&self) -> bool {
        self.rt.upgrade().is_none_or(|rt| !rt.tasks.borrow().contains_key(&self.id))
    }
}

/// Awaits a task's output. Dropping it **detaches** the task (it keeps running and its output is
/// discarded); call [`abort`](JoinHandle::abort) to cancel. Polling it again after it returned
/// `Ready` never completes.
pub struct JoinHandle<T> {
    state: Rc<RefCell<JoinInner<T>>>,
    abort: AbortHandle,
}

impl<T> JoinHandle<T> {
    pub fn abort(&self) {
        self.abort.abort();
    }
    pub fn abort_handle(&self) -> AbortHandle {
        self.abort.clone()
    }
    pub fn is_finished(&self) -> bool {
        self.state.borrow().result.is_some() || self.abort.is_finished()
    }
}

impl<T> Future for JoinHandle<T> {
    type Output = Result<T, JoinError>;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut s = self.state.borrow_mut();
        if s.result.is_some() {
            if !coop_ready(cx) {
                return Poll::Pending;
            }
            return Poll::Ready(s.result.take().expect("checked above"));
        }
        s.waker = Some(cx.waker().clone());
        Poll::Pending
    }
}

// ---------------------------------------------------------------------------------------------
// JoinSet

struct SetState<T> {
    handle: Handle,
    limit: usize,
    running: usize,
    seq: u64,
    shutdown: bool,
    aborts: BTreeMap<u64, AbortHandle>,
    queued: VecDeque<Pin<Box<dyn Future<Output = T>>>>,
    done: VecDeque<Result<T, JoinError>>,
    waker: Option<Waker>,
}

fn start<T: 'static>(state: &Rc<RefCell<SetState<T>>>, fut: Pin<Box<dyn Future<Output = T>>>) {
    let (handle, seq) = {
        let mut s = state.borrow_mut();
        s.running += 1;
        s.seq += 1;
        (s.handle.clone(), s.seq)
    };
    let st = state.clone();
    let deliver = Box::new(move |r: Result<T, JoinError>| {
        let (waker, next) = {
            let mut s = st.borrow_mut();
            s.aborts.remove(&seq);
            s.running -= 1;
            s.done.push_back(r);
            let next = if s.shutdown || s.handle.is_closed() { None } else { s.queued.pop_front() };
            (s.waker.take(), next)
        };
        if let Some(next) = next {
            start(&st, next);
        }
        if let Some(w) = waker {
            w.wake();
        }
    });
    let abort = handle.spawn_raw(fut, deliver);
    let mut s = state.borrow_mut();
    if !abort.is_finished() {
        s.aborts.insert(seq, abort);
    }
}

/// A set of tasks of one output type, joined in completion order. Dropping the set aborts the
/// tasks still running. [`JoinSet::bounded`] runs at most `n` tasks at a time and queues the
/// rest (not started until a slot frees up).
pub struct JoinSet<T> {
    state: Rc<RefCell<SetState<T>>>,
}

impl<T: 'static> JoinSet<T> {
    /// Unbounded set on the current runtime.
    ///
    /// # Panics
    /// If called outside a runtime (use [`JoinSet::new_in`]).
    pub fn new() -> Self {
        Self::new_in(&Handle::current())
    }

    /// Set running at most `n` tasks at a time, on the current runtime.
    ///
    /// # Panics
    /// If `n == 0` or outside a runtime.
    pub fn bounded(n: usize) -> Self {
        Self::bounded_in(&Handle::current(), n)
    }

    pub fn new_in(handle: &Handle) -> Self {
        Self::bounded_in(handle, usize::MAX)
    }

    pub fn bounded_in(handle: &Handle, n: usize) -> Self {
        assert!(n > 0, "JoinSet bound must be positive");
        JoinSet {
            state: Rc::new(RefCell::new(SetState {
                handle: handle.clone(),
                limit: n,
                running: 0,
                seq: 0,
                shutdown: false,
                aborts: BTreeMap::new(),
                queued: VecDeque::new(),
                done: VecDeque::new(),
                waker: None,
            })),
        }
    }

    /// Add a task. With a bound, it waits in a queue while `n` tasks are running.
    pub fn spawn<F: Future<Output = T> + 'static>(&mut self, fut: F) {
        let fut: Pin<Box<dyn Future<Output = T>>> = Box::pin(fut);
        {
            let mut s = self.state.borrow_mut();
            if s.running >= s.limit {
                s.queued.push_back(fut);
                return;
            }
        }
        start(&self.state, fut);
    }

    /// Tasks not yet joined (running, queued and finished-but-unjoined).
    pub fn len(&self) -> usize {
        let s = self.state.borrow();
        s.running + s.queued.len() + s.done.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Wait for the next task to finish; `None` when the set is empty.
    pub fn join_next(&mut self) -> impl Future<Output = Option<Result<T, JoinError>>> + '_ {
        let state = &self.state;
        std::future::poll_fn(move |cx| {
            let mut s = state.borrow_mut();
            if !s.done.is_empty() {
                if !coop_ready(cx) {
                    return Poll::Pending;
                }
                return Poll::Ready(s.done.pop_front());
            }
            if s.running == 0 && s.queued.is_empty() {
                return Poll::Ready(None);
            }
            s.waker = Some(cx.waker().clone());
            Poll::Pending
        })
    }

    /// Wait for every task and return the outputs in completion order. On the first panic or
    /// cancellation the remaining tasks are aborted and that error is returned.
    pub async fn join_all(&mut self) -> Result<Vec<T>, JoinError> {
        let mut out = Vec::new();
        while let Some(r) = self.join_next().await {
            match r {
                Ok(v) => out.push(v),
                Err(e) => {
                    self.abort_all();
                    return Err(e);
                }
            }
        }
        Ok(out)
    }

    /// Abort running tasks and discard queued ones; their results are `Cancelled` joins.
    pub fn abort_all(&mut self) {
        let (aborts, queued) = {
            let mut s = self.state.borrow_mut();
            (std::mem::take(&mut s.aborts), std::mem::take(&mut s.queued))
        };
        drop(queued);
        for a in aborts.values() {
            a.abort();
        }
    }
}

impl<T: 'static> Default for JoinSet<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> Drop for JoinSet<T> {
    fn drop(&mut self) {
        let (aborts, queued, done) = {
            let mut s = self.state.borrow_mut();
            s.shutdown = true;
            (std::mem::take(&mut s.aborts), std::mem::take(&mut s.queued), std::mem::take(&mut s.done))
        };
        drop(queued);
        for a in aborts.values() {
            a.abort();
        }
        drop(done);
    }
}

// ---------------------------------------------------------------------------------------------
// Combinators and timers

/// Output of [`select`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Either<A, B> {
    Left(A),
    Right(B),
}

/// Poll two futures concurrently and return both outputs.
pub fn join<A: Future, B: Future>(a: A, b: B) -> impl Future<Output = (A::Output, B::Output)> {
    let mut a = Box::pin(a);
    let mut b = Box::pin(b);
    let (mut ra, mut rb) = (None, None);
    std::future::poll_fn(move |cx| {
        if ra.is_none()
            && let Poll::Ready(v) = a.as_mut().poll(cx)
        {
            ra = Some(v);
        }
        if rb.is_none()
            && let Poll::Ready(v) = b.as_mut().poll(cx)
        {
            rb = Some(v);
        }
        if ra.is_some() && rb.is_some() { Poll::Ready((ra.take().expect("some"), rb.take().expect("some"))) } else { Poll::Pending }
    })
}

/// Resolve with whichever future finishes first (`a` is polled first, so it wins ties). The
/// loser is dropped before the result is returned, which cancels its in-flight ops.
pub fn select<A: Future, B: Future>(a: A, b: B) -> impl Future<Output = Either<A::Output, B::Output>> {
    let mut a = Some(Box::pin(a));
    let mut b = Some(Box::pin(b));
    std::future::poll_fn(move |cx| {
        if let Some(f) = a.as_mut()
            && let Poll::Ready(v) = f.as_mut().poll(cx)
        {
            a = None;
            b = None;
            return Poll::Ready(Either::Left(v));
        }
        if let Some(f) = b.as_mut()
            && let Poll::Ready(v) = f.as_mut().poll(cx)
        {
            a = None;
            b = None;
            return Poll::Ready(Either::Right(v));
        }
        Poll::Pending
    })
}

/// The deadline of [`timeout`] passed first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Elapsed;

impl fmt::Display for Elapsed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("deadline has elapsed")
    }
}

impl std::error::Error for Elapsed {}

async fn timeout_with<F: Future>(sleep: Sleep, fut: F) -> Result<F::Output, Elapsed> {
    match select(fut, sleep).await {
        Either::Left(v) => Ok(v),
        Either::Right(_) => Err(Elapsed),
    }
}

/// Resolve `fut`, or `Err(Elapsed)` (dropping it, which cancels its ops) after `d`. Uses the
/// current runtime's loop.
pub async fn timeout<F: Future>(d: Duration, fut: F) -> Result<F::Output, Elapsed> {
    timeout_with(sleep(d), fut).await
}

/// Timer on the current runtime's loop; see [`Handle::sleep`].
///
/// # Panics
/// If called outside a runtime.
pub fn sleep(d: Duration) -> Sleep {
    Handle::current().sleep(d)
}

/// Spawn on the current runtime.
///
/// # Panics
/// If called outside a runtime.
pub fn spawn<F: Future + 'static>(f: F) -> JoinHandle<F::Output>
where
    F::Output: 'static,
{
    Handle::current().spawn(f)
}

/// Sleeps on the loop's `timeout` op. The deadline starts when the value is created; the op is
/// submitted on the first poll and cancelled on drop. Resolves with an error only if the loop
/// reports one (e.g. cancelled by loop destruction) or the runtime is gone (`BrokenPipe`).
pub struct Sleep {
    lp: Option<Rc<Loop>>,
    deadline: Instant,
    op: Option<OpFuture<io::Result<()>>>,
}

impl Future for Sleep {
    type Output = io::Result<()>;
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let this = &mut *self;
        if this.op.is_none() {
            let Some(lp) = &this.lp else { return Poll::Ready(Err(io::ErrorKind::BrokenPipe.into())) };
            this.op = Some(lp.timeout(this.deadline.saturating_duration_since(Instant::now())));
        }
        let op = this.op.as_mut().expect("just set");
        Pin::new(op).poll(cx)
    }
}
