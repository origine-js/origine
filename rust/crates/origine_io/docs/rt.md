# `origine_io::rt`: the runtime

Source: `src/rt.rs`. A small single-threaded async runtime on top of a [`Loop`](futures.md). std
only: it spawns no threads and never blocks except inside `Loop::run(Mode::Once)`.

## Design

* **The loop is the reactor** (like mio under tokio): it completes ops and calls their callbacks,
  which wake the op futures' `Waker`s. **`Runtime` is the executor** (like tokio's `LocalSet`): it
  owns tasks and polls the ones that were woken. Nothing in the crate is `Send`; tasks are
  polled only on the loop thread and may be `!Send` futures.
* `Runtime::new(Rc<Loop>)` binds a runtime to one loop and records the creating thread. One
  runtime per loop.
* There is no global runtime. `Handle::current()` / `rt::spawn` / `rt::sleep` work only while a
  runtime is polling a task (or inside `Runtime::block_on`) on this thread: a thread-local points
  to the current runtime (`EnterGuard`).

```
 Loop::run ──► callbacks ──► Waker::wake ──► task pushed on ready queue
                                                    │
 Runtime::tick / block_on ──► drain: poll ready tasks (budget per poll) ◄─┘
```

## Types

| Item | Role |
|---|---|
| `Runtime` | owns tasks. `spawn`, `handle`, `event_loop`, `sleep`, `timeout`, `task_count`, `has_work`, `has_ready`, `run_until_idle`, `tick`, `block_on`. Drop cancels everything. |
| `Handle` | weak, `Clone`: `spawn`, `sleep`, `timeout`, `is_closed`, `Handle::try_current()` / `current()`. Spawning on a dropped runtime returns a handle that resolves to `Cancelled`. |
| `JoinHandle<T>` | `Future<Output = Result<T, JoinError>>`. `abort()`, `abort_handle()`, `is_finished()`. **Dropping detaches** the task (it keeps running, output discarded). Polling again after `Ready` never completes. |
| `AbortHandle` | `Clone`, weak. `abort()`, `is_finished()`. |
| `JoinError` | `Cancelled` (aborted, or runtime dropped) or `Panicked(Box<dyn Any + Send>)`; `is_cancelled`, `is_panic`, `into_panic` (panics on a cancelled error). Implements `Error`. |
| `JoinSet<T>` | tasks of one output type, joined in completion order. |
| free fns | `spawn`, `sleep`, `timeout`, `yield_now`, `consume_budget`, `join`, `select`; `Either<A, B>`, `Elapsed`, `Sleep`. |

`spawn` requires `F: Future + 'static`, `F::Output: 'static`; neither needs `Send`. A new task
first runs on the next drain.

### JoinSet

```rust
let mut set = JoinSet::new();          // current runtime; unbounded
let mut set = JoinSet::bounded(16);    // at most 16 running; the rest queue (panics if n == 0)
let mut set = JoinSet::new_in(&handle);  // or bounded_in(&handle, n): outside a runtime
set.spawn(async { 1 });
while let Some(res) = set.join_next().await { /* Result<T, JoinError> */ }
let all: Result<Vec<T>, JoinError> = set.join_all().await;   // completion order
```

* `bounded(n)` queues extra futures without starting them; a slot freed by a finished task starts
  the next queued one (FIFO).
* `join_next()` returns `None` once nothing is running, queued or finished-but-unjoined.
* `join_all()` aborts the rest on the first panic/cancellation and returns that error.
* `abort_all()` aborts running tasks and discards queued ones; aborted tasks still show up as
  `Cancelled` results.
* **Dropping the set aborts its running tasks** (unlike dropping a `JoinHandle`).
* `len()` counts running + queued + finished-but-unjoined.
* `fs::Dir::remove_dir_all` uses `JoinSet::bounded(16)`, hence needs a runtime ([fs.md](fs.md)).

### Combinators and timers

* `join(a, b)`: both polled each time, returns both outputs (futures are boxed; no spawn).
* `select(a, b) -> Either<A::Output, B::Output>`: `a` is polled first (wins ties). **The loser is
  dropped before the result is returned**, which cancels its in-flight loop ops.
* `sleep(d) -> Sleep`: `Future<Output = io::Result<()>>` on the loop's `timeout` op. The deadline
  starts when the `Sleep` is *created*; the op is submitted on the first poll with the remaining
  time; dropping it cancels the op. Errors only if the loop reports one or the runtime is gone
  (`BrokenPipe`).
* `timeout(d, fut) -> Result<F::Output, Elapsed>`: `select(fut, sleep(d))`. On expiry `fut` is
  dropped (its ops cancelled).
* `yield_now()`: reschedules the task behind all other ready tasks.
* `Runtime::sleep/timeout` and `Handle::sleep/timeout` exist for use outside a task.

## Wakers and cross-thread wakes

A `Waker` must be `Send + Sync`, so the wake path is the only multi-thread part:

* each task is an `Arc<Task>` with an atomic `queued` flag and a weak pointer to `Shared`;
  `Shared` holds a `Mutex<VecDeque<Arc<Task>>>` ready queue, a `LoopHandle` and the loop thread id;
* `wake`: `queued.swap(true)`; if it was already queued return; push on the ready queue; if
  `thread::current().id()` differs from the loop thread, also call `LoopHandle::wake()` so a
  sleeping `Loop::run(Mode::Once)` returns and the new task gets polled;
* a wake after the runtime was dropped finds the weak `Shared` gone and does nothing.

Op futures are woken from the loop callback on the loop thread, so they take the cheap same-thread
path. A future woken from another thread (a channel, a timer thread, `LoopHandle::post`) takes the
cross-thread path (test `wake_from_another_thread`).

## Cooperative budget

Every task poll starts with a thread-local budget of 128 units (outside a task it is unlimited).
`JoinHandle::poll` (when the result is ready), `JoinSet::join_next` (when a result is ready) and
`consume_budget()` each spend one unit. When the budget is 0 they re-queue the task
(`wake_by_ref`) and return `Pending`, so a task that joins many already-finished futures in a loop
cannot starve the others. Put `consume_budget().await` in long loops that never otherwise return
`Pending`. Op futures do not spend budget.

`tick` and `block_on` also bound the work between loop turns: `drain` polls at most 4 rounds
(a round polls the tasks that were ready when it started; tasks woken meanwhile wait for the next
round), then lets the loop run. `run_until_idle` has no round limit: a task that reschedules itself
forever (`yield_now` in a loop) keeps it running.

## Driving the runtime

* `Runtime::block_on(fut)`: for tests and simple programs. `fut` need not be `'static`/`Send`. Loops:
  poll the root future if its waker fired, drain ready tasks, `Loop::run(NoWait)` if anything is
  ready else `run(Once)`. Blocks forever if the future can no longer be woken. Panics if the loop
  fails. A panic of the root future propagates (only spawned tasks are isolated).
* `Runtime::run_until_idle() -> usize`: poll ready tasks until none is ready; does **not** run the
  loop. Returns the number of task polls.
* `Runtime::tick(mode) -> usize`: drain (up to 4 rounds), `Loop::run(mode)`, drain again; returns
  the number of polls. `Mode::Once` is downgraded to `NoWait` while tasks are still ready, so it
  only blocks when there is nothing to do but wait. Panics if the loop fails.
* `Runtime::has_work()`: `task_count() > 0 || loop.active() > 0` (the host must keep ticking).
  `has_ready()`: some task has been woken or spawned.

### How the Host embeds `tick`

The V8 Host (`origine_api`, see [`../../origine_api/docs/README.md`](../../origine_api/docs/README.md)
and [`docs/async-host-contract.md`](../../../../docs/async-host-contract.md)) owns the isolate
thread. Per `origine_api_poll` it calls `rt.tick(Mode::NoWait)` on every open runtime, advances
draining runtimes, and settles finished promises from a completion queue. When it has to wait it
does not call `Loop::run(Once)` (there may be several loops); it `poll(2)`s on each loop's
`pollable()` fd plus a wake channel, then ticks again. So `tick(NoWait)` is the unit of progress,
and the loops' pollable fds say when it is worth calling.

## Cancellation semantics

* **Abort** (`JoinHandle::abort`, `AbortHandle::abort`, `JoinSet` abort): the task's future is
  dropped *now*, outside any runtime borrow (its destructor may touch the runtime). That drops the
  op futures it was awaiting, which cancels the ops (memory kept until their callbacks, see
  [futures.md](futures.md)). The `JoinHandle` resolves to `Err(JoinError::Cancelled)` unless the
  task had already finished. A task that aborts itself is dropped right after its current poll.
* **Dropping the `Runtime`**: marks it closed, drops every task (each delivers `Cancelled`),
  clears the ready queue and runs `Loop::run(NoWait)` once so cancellation callbacks can run.
  Ops that need longer stay active; whoever owns the loop must keep running it until `active()`
  is 0 (the Host does this while draining). `Runtime::new`'s loop outlives the runtime if you hold
  another `Rc<Loop>`.
* **Select/timeout** cancel the losing branch by dropping it.
* A destructor that panics while a task is dropped is caught and discarded.

## Panics

Each spawned task is polled under `catch_unwind`; a panic ends only that task and is delivered as
`JoinError::Panicked(payload)`. This needs `panic = "unwind"` (the workspace release profile sets
it). The runtime stays usable. Poisoned internal mutexes are recovered
(`PoisonError::into_inner`).

## Examples

Concurrent reads with a bounded fan-out:

```rust
let rt = Runtime::new(lp.clone());
rt.block_on(async {
    let mut set = JoinSet::bounded(8);
    for name in names {
        let dir = dir.clone();
        set.spawn(async move { dir.read(&name).await });
    }
    let mut out = Vec::new();
    while let Some(r) = set.join_next().await {
        out.push(r.expect("task did not panic")?);
    }
    std::io::Result::Ok(out)
})
```

Deadline with cancellation of the in-flight op:

```rust
use origine_io::rt::{self, Elapsed};
match rt::timeout(Duration::from_secs(1), file.read(vec![0; 4096])).await {
    Ok((res, buf)) => { /* finished in time */ }
    Err(Elapsed) => { /* the read future was dropped, its op cancelled */ }
}
```

Host-style loop:

```rust
while rt.has_work() {
    rt.tick(Mode::NoWait);
    // wait for lp.pollable() / your own wake channel, then loop
}
```

Cancel on request:

```rust
let h = rt.spawn(async { rt::sleep(Duration::from_secs(60)).await });
h.abort();
rt.run_until_idle();
assert!(rt.block_on(h).unwrap_err().is_cancelled());
```
