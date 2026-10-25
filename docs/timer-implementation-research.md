# Bun and Deno timer implementation research

Checked 2026-10-23 against upstream `main`, pinned to Bun
[`5c6d4e24`](https://github.com/oven-sh/bun/commit/5c6d4e24cd185d5bef8d98e7f1f1e3ef10ac163f)
and Deno
[`d7205acb`](https://github.com/denoland/deno/commit/d7205acbed60f68414d1485407a5b50bc867131e).
These are source observations, not benchmark results or claims about older releases.

## Bun

- **Scheduling:** the current native implementation is Rust. `TimerHeap` wraps an
  intrusive pairing heap, with timer nodes embedded in their owners. The loop
  peeks at the earliest deadline to compute its wait timeout and pops due timers.
  Windows uses a shared libuv timer for the next deadline. Timer keepalive counts
  are separate from heap membership; crossing zero refs/unrefs the loop.
  [Heap and loop integration](https://github.com/oven-sh/bun/blob/5c6d4e24cd185d5bef8d98e7f1f1e3ef10ac163f/src/runtime/timer/mod.rs#L195-L264).
- **Ordering:** the comparator rounds JavaScript deadlines down to milliseconds
  and breaks ties with an insertion/refresh epoch, including wraparound handling.
  This deliberately stabilizes equal-deadline ordering.
  [Comparator](https://github.com/oven-sh/bun/blob/5c6d4e24cd185d5bef8d98e7f1f1e3ef10ac163f/src/event_loop/EventLoopTimer.rs#L91-L134).
- **Delay conversion:** callback timers convert to a number, truncate, and use
  1 ms for values outside `[1, 2^31 - 1]`, with warnings for selected cases.
  `Bun.sleep` follows a different path: it saturates to `[0, 2^31 - 1]`.
  [Conversion and sleep](https://github.com/oven-sh/bun/blob/5c6d4e24cd185d5bef8d98e7f1f1e3ef10ac163f/src/runtime/timer/Timer.rs#L111-L200).
- **Cancellation and ownership:** cancel drops keepalive, marks the timer
  canceled, downgrades the strong JS reference, and removes an active timeout
  from the heap before releasing its native reference. Rescheduling uses the
  monotonic timestamp plus the delay. This is resource cancellation, rather than
  merely ignoring a later callback.
  [Rescheduling](https://github.com/oven-sh/bun/blob/5c6d4e24cd185d5bef8d98e7f1f1e3ef10ac163f/src/runtime/timer/timer_object_internals.rs#L760-L822),
  [cancel](https://github.com/oven-sh/bun/blob/5c6d4e24cd185d5bef8d98e7f1f1e3ef10ac163f/src/runtime/timer/timer_object_internals.rs#L1065-L1088).
- **Promise timers:** `node:timers/promises` validates `signal` and `ref`, rejects
  immediately for an already aborted signal, clears the timer on abort, rejects
  with `AbortError`, and removes the abort listener after settlement.
  [Promise timeout](https://github.com/oven-sh/bun/blob/5c6d4e24cd185d5bef8d98e7f1f1e3ef10ac163f/src/js/node/timers.promises.ts#L38-L85).

## Deno

- **Scheduling:** current core timers are managed in JavaScript. Timers with the
  same truncated delay share a doubly linked list; a binary min-heap orders the
  lists by expiry and list ID. Only an earlier next expiry needs native
  rescheduling. Cancellation unlinks the timer, clears its callback, decrements
  the ref count, and removes leak tracking; it does not necessarily immediately
  delete the now-empty bucket or disarm the shared native wakeup. The next drain
  cleans up empty buckets. Repeating timers reinsert using that drain's `now`.
  Next-tick/microtask processing runs between callbacks and between due lists.
  Core normalizes delays outside `[1, 2^31 - 1]` to 1 ms before truncation.
  [Core timer queue](https://github.com/denoland/deno/blob/d7205acbed60f68414d1485407a5b50bc867131e/libs/core/02_timers.js#L159-L408).
- **Native wakeup:** Rust's `UserTimer` holds a single replaceable reactor timer,
  a monotonic base instant, and a separate ref flag. Replacing the deadline
  clears stale ready state. Polling registers the external waker before checking
  readiness and checks elapsed deadlines directly, covering executor stalls.
  [Native timer](https://github.com/denoland/deno/blob/d7205acbed60f68414d1485407a5b50bc867131e/libs/core/web_timeout.rs).
- **Web API layer:** numeric IDs map to internal timers. `clearTimeout` and
  `clearInterval` both cancel and delete the mapping. WebIDL signed-long
  conversion happens before core scheduling; this differs from merely validating
  a JavaScript number. The wrappers also preserve async context.
  [Web timers](https://github.com/denoland/deno/blob/d7205acbed60f68414d1485407a5b50bc867131e/ext/web/02_timers.js).
- **Promise timers:** the Node-compatible implementation validates options,
  supports `ref: false`, rejects pre-aborted signals, clears the timer on abort,
  rejects with `AbortError`, and removes its listener after settlement.
  [Promise timeout](https://github.com/denoland/deno/blob/d7205acbed60f68414d1485407a5b50bc867131e/ext/node/polyfills/timers.ts#L68-L135).
  Deno also documents timer ref/unref as control over event-loop exit.
  [Runtime API](https://docs.deno.com/api/deno/runtime/).

## Recommendations for origine

These are design judgments from the source comparison:

1. **Reuse the existing scheduler.** `src/io/timers.zig` already provides an
   indexed binary heap, monotonic deadlines, and O(log n) removal for kqueue and
   threaded backends; io_uring has native timeout ops. A second JavaScript heap
   or a per-timer thread would duplicate machinery. Bun and Deno show that both
   native heaps and JS bucketing are viable; their code alone does not establish
   which is faster for origine.
2. **Make cancellation remove native work and release promise state.** Repeated
   cancellation and cancellation after completion should be harmless. Scope and
   runtime ownership checks must prevent a stale handle from canceling a reused
   operation ID. Closing a runtime must settle pending timer promises.
3. **Specify the API's own delay rules.** A capability API may deliberately reject
   negative, nonfinite, or out-of-range delays instead of inheriting compatibility
   coercions. Document units, fractional-delay handling, limits, asynchronous
   zero-delay behavior, and when the deadline starts.
4. **Treat keepalive separately from cancellation.** Initially, pending timers
   can keep the host progressing like other pending operations. Add `ref/unref`
   only with explicit host-loop semantics; an unreferenced timer still exists.
5. **Do not promise cancellation through `Promise.race`.** A timer winning a race
   against filesystem/network work does not cancel that work. A future timeout
   API needs an operation cancellation hook or shared cancellation signal.
6. **Test lifecycle and ordering before optimizing:** cancel before first poll,
   cancel after expiry, double cancel, close with pending timers, surviving
   siblings, zero-delay promise ordering, and teardown without live operations.
   If FIFO order for identical deadlines becomes a contract, add a sequence
   tie-break rather than relying on the present heap's incidental order.
