# Event loop diagrams

Mermaid diagrams of the loop (`src/io/loop.zig`), its backends and how the Rust runtime and the guest API sit on top.
Reference text: [ops](ops.md), [backends](backends.md), [C API](c-api.md); Rust side: [`origine_io` runtime](../../../rust/crates/origine_io/docs/rt.md).

## 1. Layers

```mermaid
flowchart TD
    JS["Guest JS<br/>api.io.create / api.fs.requestAsync / fs.async.*"]
    NAT["Rust natives (origine_api, #[native])<br/>create promise, spawn task"]
    RT["origine_io::rt::Runtime<br/>single-threaded executor, wakers"]
    FUT["origine_io op futures / fs::Dir, File<br/>owned buffers, cancel on drop"]
    CAPI["C ABI oio_* (src/io/c_api.zig)"]
    LOOP["io.Loop (src/io/loop.zig)<br/>active count, dispatch, posts"]
    BE{{"Backend vtable"}}
    URING["io_uring (Linux)"]
    KQ["kqueue + GCD (macOS)"]
    THR["threaded pool (portable)"]
    IOCP["IOCP (Windows, reserved)"]

    JS --> NAT --> RT --> FUT --> CAPI --> LOOP --> BE
    BE --> URING
    BE --> KQ
    BE --> THR
    BE -.-> IOCP
```

Zig embedders use `io.Loop` directly; C and Rust callers go through the C ABI. Only the loop thread touches V8 and the runtime.

## 2. One turn of `Loop.run`

```mermaid
flowchart TD
    A["run(mode)"] --> M{mode}
    M -->|nowait| S0["step(block = false)"]
    M -->|once| S1["step(block = true)"]
    M -->|until_idle| U{"active > 0 ?"}
    U -->|yes| S1
    U -->|no| R["return active"]
    S0 --> R
    S1 --> R

    subgraph STEP["step(block)"]
        P["backend.poll(block, &drained)<br/>sleeps in the kernel when block and nothing is ready"]
        D["drained.done: for each op<br/>active -= 1, then op.cb(op, op.result)"]
        Q["drained.posts: for each node<br/>free node, then func(ud)"]
        P --> D --> Q
    end
    S0 -.-> P
    S1 -.-> P
```

`poll` never runs callbacks. Callbacks and posted functions run only here, on the thread that called `run`, so a callback may submit more ops.

## 3. Op lifecycle

```mermaid
stateDiagram-v2
    [*] --> Filled: caller fills Op (caller-owned memory)
    Filled --> Submitted: loop.submit(op), active += 1
    Submitted --> InFlight: kernel (io_uring) or worker thread executes
    Submitted --> Done: nop / immediate failure / timer fires
    InFlight --> Done: result stored in op.result
    Submitted --> Cancelling: loop.cancel(op)
    InFlight --> Cancelling: loop.cancel(op)
    Cancelling --> Done: result = -ECANCELED (running ops may keep their real result)
    Done --> Reported: backend.poll moves it into Drained
    Reported --> [*]: callback runs exactly once, op memory free to reuse
```

An op must stay alive and unmoved from `submit` until its callback has run. `Loop.destroy` cancels everything outstanding and runs those callbacks before freeing.

## 4. Threads

```mermaid
flowchart LR
    subgraph LT["Loop thread (isolate thread)"]
        SUB["submit / cancel"]
        RUN["run: poll + dispatch callbacks"]
        V8["V8 + Rust tasks"]
        SUB --> RUN --> V8
    end
    subgraph KER["Kernel / workers"]
        RING["io_uring ring"]
        POOL["worker pool<br/>(readdir on uring, GCD queue on macOS, threaded backend)"]
    end
    OTHER["Any other thread"]

    SUB -- "SQE / enqueue" --> RING
    SUB -- "enqueue" --> POOL
    RING -- "CQE" --> RUN
    POOL -- "done list (mutex) + wake" --> RUN
    OTHER -- "wake() / post(fn)" --> RUN
```

Only `wake` and `post` may be called from other threads. A worker never calls back into the loop or V8: it writes `op.result`, pushes the op on the done list and wakes the loop (eventfd, `EVFILT_USER`, or condvar plus self-pipe on the threaded backend; uring kernel work completes through the CQ instead).

## 5. An async read from JS (sequence)

```mermaid
sequenceDiagram
    participant JS as Guest JS
    participant N as Rust native
    participant T as rt task (File::read_at)
    participant L as io.Loop
    participant B as Backend (kernel/worker)
    JS->>N: fileRead(fs, id, buf, ...)
    N->>N: create PromiseResolver (Global)
    N->>T: spawn async task
    N-->>JS: Promise (pending)
    T->>L: oio_read(op, fd, buf, off, cb)
    L->>B: submit(op)
    Note over T: task returns Pending
    B-->>L: completion (CQE / worker + wake)
    L->>L: run: poll, dispatch cb(op, result)
    L->>T: cb stores result, wakes the task
    T->>T: rt.tick polls the task, future Ready
    T->>N: settle promise (enter saved context)
    N-->>JS: resolve(count)
    Note over JS: microtasks run (Runtime.pump)
```

## 6. Host `settle` (Zig side)

```mermaid
flowchart TD
    S["Host.settle(promise)"] --> PP["pumpPlatform (V8 tasks + microtasks)"]
    PP --> ST{"promise settled?"}
    ST -->|yes| DONE["return"]
    ST -->|no| W{"native work or platform work?"}
    W -->|none| STALL["error.Stalled"]
    W -->|some| POLL["origine_api_poll(block)<br/>poll(2) over every runtime's pollable fd + wake fd<br/>tick ready runtimes, settle promises"]
    POLL --> PUMP["Runtime.pump (microtasks)"]
    PUMP --> PP
```

Several runtimes (one `Loop` + `rt::Runtime` each, created with `api.io.create`) share the isolate thread; the host waits on all of them at once through their `pollable()` fds. V8 platform tasks wake the wait through `origine_api_wake`.
