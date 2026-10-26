import type { HostError, IoError } from "./errors.d.ts";
import type { Io } from "./io.d.ts";

/**
 * How a handle is read, chosen explicitly (there is no default) and visible in its type:
 * `'pull'` asks for each read with a promise, `'event'` is pushed to `register`ed handlers.
 * Two behaviours that cannot be mixed are two types, with a consuming transfer between them.
 */
export type Mode = "event" | "pull";

/** Which side of a socket {@link SocketBase.end} ends, as in `shutdown(2)`. */
export type EndSide = "write" | "read" | "both";

/** Bytes the write side takes: an `ArrayBuffer` or any view over one. */
export type BytesLike = ArrayBuffer | ArrayBufferView;

/** What `register` returns. */
export interface Registration {
  /** Removes the handler. Returns `true` if it was registered. When the last flowing handler goes the handle pauses itself. */
  unregister(): boolean;
}

/**
 * A chunk received by a socket: a `Uint8Array` over an `ArrayBuffer` of **exactly** the received
 * bytes (`buffer.byteLength === length`, offset 0); no other byte of the socket's memory is
 * reachable through it. Give it back with {@link Lease.unref} or `using`: that detaches the
 * `ArrayBuffer` (any view you kept becomes empty). One you never release is garbage collected like
 * any buffer.
 */
export interface Lease extends Uint8Array<ArrayBuffer>, Disposable {
  /** `true` once `unref()` ran. */
  readonly released: boolean;
  /** Detaches the buffer and frees its memory. Idempotent. */
  unref(): void;
}

/** The `data` event: valid only while its handlers run. */
export interface DataEvent {
  /** Bytes received (0 once the event is over). */
  readonly length: number;
  /**
   * The chunk as a {@link Lease}: the same lease on every call within one event. Allocates
   * nothing until called (the bytes were received into a slab and are carved out without copy).
   * Throws a `TypeError` after the event is over.
   */
  buffer(): Lease;
}

/** Events of an {@link EventSocket} and the arguments their handlers get. */
export interface SocketEvents {
  /** Bytes arrived. The first handler starts the flow. */
  data: [event: DataEvent];
  /** The peer finished sending (its FIN). The socket stays open and writable: answer with `end('write')` or `close()`. */
  end: [];
  /** A failure: an {@link IoError} or {@link HostError}, or whatever a handler threw. The socket is closed by the runtime, then `close` fires. */
  error: [error: unknown];
  /** The send queue became empty (after the sends it settles). */
  drain: [];
  /** The handle closed. Fires once; handlers are dropped afterwards. */
  close: [];
}

/** Events of an {@link EventServer}. */
export interface ServerEvents<S extends Mode> {
  /** A connection arrived, as a socket of the server's `socketMode`. The first handler starts accepting; a connection nobody handles is closed. */
  connection: [socket: Socket<S>];
  /** A failure: an {@link IoError} or {@link HostError}, or whatever a handler threw. */
  error: [error: unknown];
  /** The server closed. */
  close: [];
}

/** Base of every handle: what both modes and both kinds share. */
export interface Handle extends AsyncDisposable {
  /** The runtime this handle belongs to. */
  readonly io: Io;
  /** `true` after `close()`, once the runtime is closed, or after a mode transfer consumed this handle. Every operation on a closed handle throws or rejects `BadHandle`. */
  readonly closed: boolean;
  /**
   * Releases the handle and discards what is still queued; pending reads finish with end of
   * stream and pending sends reject `Canceled`. Idempotent. Closing a server with an
   * `accept()` pending leaves that accept pending until the runtime closes.
   */
  close(): Promise<void>;
}

/**
 * `socket.queued`: the send queue. Everything that goes through it leaves the socket in call
 * order and it has priority over {@link SocketBase.direct}. "Sent" means taken by the kernel
 * (`write(2)` returned), not received by the peer. A write error rejects every pending `send`,
 * throws from `put`, and the socket emits `error` once and closes.
 */
export interface SendQueue {
  /** Bytes in the queue the kernel has not taken yet. */
  readonly bytes: number;
  /** Sends that wait for room (their bytes are not in the queue yet). */
  readonly waiting: number;
  /**
   * Bytes the queue may hold. Default 1 MiB, or the `sendQueueLimit` of `connect`/`listen`
   * (accepted sockets inherit it). A positive integer (`TypeError` otherwise). A `send` into an
   * empty queue is admitted whatever its size.
   */
  limit: number;
  /**
   * Queues as much of `data` as fits under {@link SendQueue.limit} and returns the **number of
   * bytes taken** (0 when the queue is full or sends are waiting). Copies what it queues, so the
   * buffer can be reused right after. To wait for room, wait for `drain` or `drained()`.
   */
  put(data: BytesLike): number;
  /**
   * Queues all of `data`, waiting for room, and resolves when its last byte is in the kernel. Reads
   * `data` when it is admitted (at once unless the queue is full): leave it untouched until the
   * promise settles. Rejects when the socket fails (`BrokenPipe`, ...) or closes first (`Canceled`).
   */
  send(data: BytesLike): Promise<void>;
  /** Resolves when the queue is empty and no send is waiting. */
  drained(): Promise<void>;
}

/**
 * `socket.direct`: the unbuffered lane, a plain non-blocking write. It never overtakes the send
 * queue: while anything is queued or waiting it takes nothing.
 */
export interface DirectWriter {
  /**
   * One non-blocking `write(2)` with no copy and nothing kept: returns the **number of bytes the
   * kernel took** (0 to `data.byteLength`; 0 also when the queue is busy). A write error throws and closes the socket.
   */
  write(data: BytesLike): number;
}

/** The write side shared by both socket kinds. */
export interface SocketBase extends Handle {
  /** The peer's port. */
  readonly remotePort: number;
  /** The send queue (`put`, `send`, `drained`, `bytes`, `waiting`, `limit`): written before `direct`. */
  readonly queued: SendQueue;
  /** The unbuffered write lane (`write`). */
  readonly direct: DirectWriter;
  /**
   * Ends one side or both, like `shutdown(2)`; `side` is required (`TypeError` without it).
   *
   * - `'write'`: once everything queued and waiting is out, sends the FIN and resolves; later
   *   writes fail `BrokenPipe`.
   * - `'read'`: stops reading and discards what arrives (reads resolve empty, no more `data`/`end`).
   * - `'both'`: both, the read side after the flush.
   *
   * The runtime **never closes a socket because the peer sent its FIN**; a socket closes itself
   * once the peer finished (or you ended `'read'`) and your write side was ended. `close()`
   * releases it at any time.
   */
  end(side: EndSide): Promise<void>;
}

/** A socket read with promises (`Socket<'pull'>`): `read`, `readInto`, `readCopy`. Has no `register`. */
export interface PullSocket extends SocketBase {
  /** Reads once: a `Uint8Array` of 1 to `length` bytes (`length` an integer in 1 to 2**28), **empty at end of stream**. The result is allocated. */
  read(length: number): Promise<Uint8Array>;
  /**
   * Reads once straight into `buffer` (not empty) with **no copy**: the buffer is detached while the
   * read runs and the promise resolves `{ bytes, buffer }` with `buffer` a new `ArrayBuffer` over
   * the same memory (`bytes` 0 at end of stream). Rejects `Unsupported` for a buffer that cannot be
   * detached (shared, resizable). Best for large reads.
   */
  readInto(buffer: BytesLike): Promise<{ readonly bytes: number; readonly buffer: ArrayBuffer }>;
  /** Reads once into `buffer` **by copy** and resolves the byte count (0 at end of stream). The buffer is not detached, so one buffer serves every read. Best for small reads. */
  readCopy(buffer: BytesLike): Promise<number>;
  /**
   * Hands the connection to a **new** `EventSocket` and **consumes this handle**: it reports
   * `closed === true` and every operation on it throws or rejects `BadHandle` (the connection is
   * not closed). `queued` and `direct` carry over. Throws `WouldBlock` while a read is pending.
   */
  toEvent(): EventSocket;
}

/** A socket that pushes events (`Socket<'event'>`): `register`, `pause`, `resume`. Has no `read*`. */
export interface EventSocket extends SocketBase {
  /**
   * Subscribes `handler` to `event`; handlers of one event run in registration order. The first
   * `data` handler starts reading. A handler that throws goes to the `error` handlers (with none
   * it becomes an unhandled rejection). Registrations never keep the program alive: await
   * `io.run()`. After `close` handlers are dropped; `register` on a closed handle throws `BadHandle`.
   */
  register<E extends keyof SocketEvents>(event: E, handler: (...args: SocketEvents[E]) => void): Registration;
  /** Stops delivery: after it returns no `data`, `end` or `error` is dispatched until `resume()`. At most 8 chunks are held, then reading stops and TCP holds the peer back. Idempotent. */
  pause(): void;
  /** Undoes `pause()`; held events are dispatched first, in order. Idempotent. */
  resume(): void;
  /** `true` after `pause()`, or while no `data` handler listens. */
  readonly paused: boolean;
  /**
   * Hands the connection to a **new** `PullSocket` and **consumes this handle** (`BadHandle`
   * afterwards); registered handlers are dropped. Throws `Unsupported` once a `data` handler
   * started the flow: the chunks already read belong to the events.
   */
  toPull(): PullSocket;
}

/**
 * A socket of read mode `M`: `Socket<'pull'>` is a {@link PullSocket}, `Socket<'event'>` an
 * {@link EventSocket}. The two share only the write side.
 */
export type Socket<M extends Mode = Mode> = M extends "pull" ? PullSocket : M extends "event" ? EventSocket : never;

/** Base of the servers. */
export interface ServerBase extends Handle {
  /** The port listened on (the real one when `port: 0` was asked). */
  readonly port: number;
}

/** A server whose connections are awaited (`Server<'pull', S>`). `S` is the mode of the sockets it accepts. */
export interface PullServer<S extends Mode = Mode> extends ServerBase {
  /** Resolves the next connection as a socket of the server's `socketMode`. */
  accept(): Promise<Socket<S>>;
  /** Hands the listener to a new `EventServer` and consumes this handle. Throws `WouldBlock` while an `accept()` is pending. */
  toEvent(): EventServer<S>;
}

/** A server that emits events (`Server<'event', S>`). `S` is the mode of the sockets it hands out. */
export interface EventServer<S extends Mode = Mode> extends ServerBase {
  /** Subscribes to `connection`, `error` or `close`. The first `connection` handler starts accepting. Same rules as {@link EventSocket.register}. */
  register<E extends keyof ServerEvents<S>>(event: E, handler: (...args: ServerEvents<S>[E]) => void): Registration;
  /** Stops accepting until `resume()`; connections wait in the kernel backlog. Idempotent. */
  pause(): void;
  /** Undoes `pause()`. Idempotent. */
  resume(): void;
  /** `true` after `pause()`, or while no `connection` handler listens. */
  readonly paused: boolean;
  /** Hands the listener to a new `PullServer` and consumes this handle. Throws `Unsupported` once a `connection` handler started accepting. */
  toPull(): PullServer<S>;
}

/** A server of read mode `M` handing out sockets of mode `S`. */
export type Server<M extends Mode = Mode, S extends Mode = Mode> = M extends "pull"
  ? PullServer<S>
  : M extends "event"
    ? EventServer<S>
    : never;

/** Options shared by `listen` and `connect`. Loopback only: any other host is `PermissionDenied`. */
export interface AddressOptions {
  /** `127.0.0.1`, `::1`, another loopback IP literal (used as given) or `localhost` (never resolved; `connect` tries 127.0.0.1 then ::1, `listen` binds 127.0.0.1). Default `'127.0.0.1'`. */
  readonly host?: string;
  /** Initial `queued.limit` of every socket made through this call: a positive integer. Default 1 MiB. */
  readonly sendQueueLimit?: number;
}

/** Options of {@link NetCap.listen}. */
export interface ListenOptions<M extends Mode = Mode, S extends Mode = Mode> extends AddressOptions {
  /** The read mode of the server: `'pull'` for `accept()`, `'event'` for `register('connection')`. Required. */
  readonly mode: M;
  /** The read mode of the sockets it accepts. Required. */
  readonly socketMode: S;
  /** The port to listen on, 0 to 65535; `0` (the default) asks the system for one, see `server.port`. */
  readonly port?: number;
}

/** Options of {@link NetCap.connect}. */
export interface ConnectOptions<M extends Mode = Mode> extends AddressOptions {
  /** The read mode of the socket. Required. */
  readonly mode: M;
  /** The port to connect to, 0 to 65535. Required (`TypeError` without it). */
  readonly port: number;
}

/** A frozen class value of `api.net`: handles cannot be constructed by guests (`TypeError`), but `instanceof` works. */
export interface HandleClass<T> extends Function {
  readonly prototype: T;
}

/**
 * `api.net`: loopback TCP on an {@link Io} runtime. Only loopback addresses are allowed. Every
 * socket belongs to the runtime it was created with; closing the runtime invalidates it.
 */
export interface NetCap {
  readonly Handle: HandleClass<Handle>;
  readonly Server: HandleClass<ServerBase>;
  readonly PullServer: HandleClass<PullServer>;
  readonly EventServer: HandleClass<EventServer>;
  readonly Socket: HandleClass<SocketBase>;
  readonly PullSocket: HandleClass<PullSocket>;
  readonly EventSocket: HandleClass<EventSocket>;
  /**
   * Binds and listens, **synchronously**. The class of the result follows `mode` (a literal), and
   * `socketMode` types the sockets it hands out. Throws an {@link IoError} (`AddressInUse`,
   * `PermissionDenied`) or a {@link HostError} (`BadHandle` for a closed `io`) or a `TypeError` for a missing or unknown `mode`/`socketMode`.
   */
  listen<M extends Mode, S extends Mode>(io: Io, options: ListenOptions<M, S>): Server<M, S>;
  /**
   * Connects to a loopback listener. The class of the result follows `mode`. Never blocks: the
   * socket is created non-blocking and the loop finishes the handshake. Rejects an {@link IoError}
   * (`ConnectionRefused`, ...) or a {@link HostError} (`BadHandle`, `Canceled`) or a `TypeError` for missing `port` or `mode`.
   */
  connect<M extends Mode>(io: Io, options: ConnectOptions<M>): Promise<Socket<M>>;
}
