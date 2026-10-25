# `api.io`: timers and cancellation

Timers belong to an I/O runtime and require the embedder's runtime ceiling, just like
filesystem and network operations. Timers use the existing backend timeout support
without a per-timer thread: kqueue and threaded backends share a timer heap, while
uring uses native timeout operations.

```js
export async function main(api) {
  const io = api.io.create();
  try {
    await io.sleep(10);
    const deadline = io.now() + 100;
    await io.sleepUntil(deadline);

    const timer = io.timer(60_000);
    const result = timer.promise.catch(error => error.name);
    timer.cancel();
    // await result === 'Canceled'; the underlying timeout was canceled too.
    await result;
  } finally {
    await io.close();
  }
}
```

| Method | Result |
| --- | --- |
| `io.now()` | Monotonic milliseconds since host creation, shared by its runtimes; unrelated to wall-clock timestamps. |
| `io.sleep(ms)` | `Promise<void>` that resolves after the delay. |
| `io.timer(ms)` | Frozen `{ promise, cancel }`; `promise` has the same behavior as `sleep`. |
| `io.sleepUntil(deadline)` | Sleeps until an absolute time produced from `io.now()`. Past deadlines are asynchronous zero-delay sleeps. |
| `io.timerAt(deadline)` | Cancellable version of `sleepUntil`. |

Delays accept finite numbers from `0` through `2147483647` milliseconds, including
fractions. Invalid values throw `TypeError`; values are not coerced or silently
clamped. Deadlines must be finite non-negative numbers; a deadline more than the
maximum delay into the future also throws. Timers run no earlier than their
deadline and may run later when the isolate is busy. A zero-delay timer never
settles synchronously. No relative ordering is promised for equal deadlines.

`cancel()` returns `true` when it canceled a pending timer and rejects that timer's
promise with the frozen `{ errno, name: 'Canceled' }` error used by other I/O APIs.
It removes the native task and cancels its backend timeout. Repeated cancellation,
cancellation after settlement, and cancellation after runtime close return `false`.
A retained old handle cannot cancel a newer timer. Attach a rejection handler
before canceling, as with any promise that can reject.

Pending timers supply native work while the host waits for `main`'s returned
promise; await the timer or return a promise that depends on it. `io.run()` is
unnecessary. As with other I/O, returning from `main` ends CLI execution even if
an unawaited timer remains. `io.close()` cancels every pending timer along with the
runtime's other operations. Starting a timer or reading its clock after close
throws `BadHandle`. Canceling a timer leaves sibling timers and filesystem/network
operations alone. Timers are local to their owning scope and cannot grant access
to another runtime by presenting its numeric identifier.

This API cancels timers. Racing a timer against a filesystem or socket promise does
not cancel that operation; those APIs currently support cancellation by closing the
runtime. Timer callbacks, intervals, ambient globals, and `AbortSignal` integration
are not provided by this surface.
