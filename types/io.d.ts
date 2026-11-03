import type { SocketAddr } from 'origine:@std/net';
import type { TcpListenerUnshaped, TcpStreamUnshaped, UdpSocketUnshaped } from './net.d.ts';

/**
 * An I/O backend that runs (`'uring'` on Linux, `'kqueue'` on macOS and BSD, `'threaded'` everywhere). It is what
 * {@link Io.backend} reports, never `'auto'`; see {@link BackendChoice} for what `create` accepts.
 */
export type Backend = 'uring' | 'kqueue' | 'threaded';

/**
 * The backend {@link IoCap.create} is asked for: `'auto'` (the default) picks the first allowed one that works,
 * and the resolved {@link Backend} is what the runtime reports.
 */
export type BackendChoice = Backend | 'auto';

/** Options of {@link IoCap.create}. */
export interface IoOptions {
  /** The backend to use. Asking for one the host excluded or the system lacks is `Unsupported`. */
  readonly backend?: BackendChoice;
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

/** A cancellable timer: {@link IoTimer.timer}. A frozen instance of a native class. */
export interface Timer {
  /** Resolves when the delay has passed; rejects with a HostError whose errno is Canceled when cancelled. */
  readonly promise: Promise<void>;
  /**
   * Cancels the timer and its backend timeout. Returns `true` when it cancelled a pending timer,
   * `false` when it was already settled or the runtime is closed. Attach a rejection handler to
   * `promise` before cancelling.
   */
  cancel(): boolean;
}

/** `io.timer`: sleeps and cancellable timers on the runtime's monotonic clock. Every method throws `BadHandle` once the runtime is closed. */
export interface IoTimer {
  /** Monotonic milliseconds since the host was created, shared by its runtimes; not a wall clock. */
  now(): number;
  /** A cancellable sleep of `ms` milliseconds (a finite number from 0 to 2147483647, fractions allowed; `TypeError` otherwise). */
  timer(ms: number): Timer;
  /** A cancellable sleep until `deadline`, a value derived from {@link IoTimer.now}. A past deadline is a zero-delay sleep. */
  timerAt(deadline: number): Timer;
  /** Resolves after `ms` milliseconds; a zero delay never resolves synchronously. Rejects `Canceled` when the runtime closes first. */
  sleep(ms: number): Promise<void>;
  /** Resolves at `deadline`, a value derived from {@link IoTimer.now}. */
  sleepUntil(deadline: number): Promise<void>;
}

/**
 * `io.tcp`: TCP. Addresses are `SocketAddr`s of `origine:@std/net` (IP literals; nothing is resolved) and must be
 * allowed by the embedder's network ceiling (`PermissionDenied` with the address as `subject` otherwise).
 */
export interface IoTcp {
  /** Binds and listens, synchronously (`listen` rules; port 0 asks the system for one, see `localAddr`). Throws `AddressInUse`, `PermissionDenied`, `BadHandle`. */
  listen(addr: SocketAddr): TcpListenerUnshaped;
  /** Connects to one address (`connect` rules). Never blocks: the loop finishes the handshake. Rejects `ConnectionRefused`, `PermissionDenied`, `BadHandle`, `Canceled`. */
  connect(addr: SocketAddr): Promise<TcpStreamUnshaped>;
}

/** `io.udp`: datagram sockets. */
export interface IoUdp {
  /** Binds a datagram socket, synchronously (`listen` rules; port 0 picks one). */
  bind(addr: SocketAddr): UdpSocketUnshaped;
}

/**
 * An async I/O runtime made by `api.io.create()`: what sockets, timers and async fs grants run on. A frozen
 * instance of a class defined natively (`new` throws, members are brand-checked); no id reaches the program.
 * Closing it cancels everything in flight (`Canceled`) and closes the sockets made with it; the objects stay and
 * answer `BadHandle` (or `closed === true`).
 */
export interface Io extends AsyncDisposable {
  /** The backend that runs: what `'auto'` resolved to, never `'auto'`. */
  readonly backend: Backend;
  /** `true` once `close()` was called. */
  readonly closed: boolean;
  readonly timer: IoTimer;
  readonly tcp: IoTcp;
  readonly udp: IoUdp;
  /**
   * Closes the runtime, cancelling every pending operation and timer and closing every socket made on it. Every
   * call returns the same promise, which settles once the runtime is really closed.
   */
  close(): Promise<void>;
  /** The same as `close()`: `await using io = api.io.create()` closes the runtime at scope exit. */
  [Symbol.asyncDispose](): Promise<void>;
  /**
   * Resolves once every object of this runtime that started flowing (an event handler for `data`,
   * `connection` or `datagram` was registered) has closed, immediately when there is none. Keeps
   * the program alive while pending: `await io.run()` is how event-style programs wait. Rejects
   * `BadHandle` once the runtime is closed.
   */
  run(): Promise<void>;
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
