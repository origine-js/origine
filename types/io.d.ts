import type { HostError, IoError } from "./errors.d.ts";

/**
 * The I/O backends. `'auto'` (the default) picks the first allowed one that works; the others
 * name one explicitly (`'uring'` on Linux, `'kqueue'` on macOS and BSD, `'threaded'` everywhere).
 */
export type Backend = "uring" | "kqueue" | "threaded";

/** Options of {@link IoCap.create}. */
export interface IoOptions {
  /** The backend to use. Asking for one the host excluded or the system lacks is `Unsupported`. */
  readonly backend?: Backend | "auto";
  /** Submission queue entries of the backend: a positive integer (`TypeError` otherwise). */
  readonly entries?: number;
}

/** Options of {@link IoCap.narrow}. A narrowed capability can only lower what its parent allows. */
export interface IoNarrow {
  /** The only backends `create` may use (`'auto'` then means the first of these that works). */
  readonly backends?: readonly Backend[];
  /** Most runtimes alive at once through this capability; a slot is given back once `close()` settles. */
  readonly maxRuntimes?: number;
}

/** A cancellable timer: {@link Io.timer}. */
export interface Timer {
  /** Resolves when the delay has passed; rejects with `{ errno: 14, name: 'Canceled' }` when cancelled. */
  readonly promise: Promise<void>;
  /**
   * Cancels the timer and its backend timeout. Returns `true` when it cancelled a pending timer,
   * `false` when it was already settled or the runtime is closed. Attach a rejection handler to
   * `promise` before cancelling.
   */
  cancel(): boolean;
}

/**
 * An async I/O runtime made by `api.io.create()`: the thing sockets, timers and async fs grants
 * run on. A frozen value, not transferable across scopes. Closing it cancels everything in
 * flight (`Canceled`) and invalidates the sockets made with it.
 */
export interface Io {
  readonly kind: "io";
  /** Numeric id of the runtime (not authority: every native re-checks ownership). */
  readonly id: number;
  /** The backend that was chosen. */
  readonly backend: Backend;
  /**
   * Closes the runtime, cancelling every pending operation and timer. Every call returns the
   * same promise, which settles once the runtime is really closed. Rejects a {@link HostError}
   * (`BadHandle`) for a runtime that is not this scope's.
   */
  close(): Promise<void>;
  /**
   * Resolves once every socket or server of this runtime that started flowing (an event handler
   * for `data` or `connection` was registered) has closed, immediately when there is none. Keeps
   * the program alive while pending: `await io.run()` is how event-style programs wait. Rejects
   * `BadHandle` once the runtime is closed.
   */
  run(): Promise<void>;
  /** Monotonic milliseconds since the host was created, shared by its runtimes; not a wall clock. Throws `BadHandle` once closed. */
  now(): number;
  /** A cancellable sleep of `ms` milliseconds (a finite number from 0 to 2147483647, fractions allowed; `TypeError` otherwise). */
  timer(ms: number): Timer;
  /** A cancellable sleep until `deadline`, a value derived from {@link Io.now}. A past deadline is a zero-delay sleep. */
  timerAt(deadline: number): Timer;
  /** Resolves after `ms` milliseconds; a zero delay never resolves synchronously. Rejects a {@link HostError} (`Canceled` when the runtime closes first, `BadHandle`). */
  sleep(ms: number): Promise<void>;
  /** Resolves at `deadline`, a value derived from {@link Io.now}. */
  sleepUntil(deadline: number): Promise<void>;
}

/**
 * `api.io`: async runtimes, timers and the base of sockets. Present where the embedder gave the
 * program a runtime ceiling.
 */
export interface IoCap {
  /**
   * Creates a runtime (synchronously). Throws an {@link IoError}: `Unsupported` when the backend or
   * the number of runtimes is not allowed or available, `PermissionDenied` at the runtime ceiling; or a `TypeError` for bad options.
   */
  create(options?: IoOptions): Io;
  /** A capability that can only do less than this one. There is no way to widen it again. */
  narrow(options: IoNarrow): IoCap;
}
