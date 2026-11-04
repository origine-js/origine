import type { SocketAddr } from 'origine:@std/net';
import type { EventTlsStream, PullTlsStream, TlsStreamUnshaped } from './tls.d.ts';

// The network objects. They are made by an `Io`'s tables (`io.tcp.listen`, `io.tcp.connect`, `io.udp.bind`) and
// are instances of classes defined natively: `new` throws a `TypeError`, a member called on another object is a
// `TypeError`, and no id reaches the program. A factory returns an **unshaped** object that owns the descriptor and
// flows nothing; `pulling()` or `evented()` consumes it (it answers `BadHandle` afterwards) and returns the shaped
// class. `close()` frees the descriptor at once; the object stays usable as a value and answers `BadHandle`.

/** How an HTTP/2 object of `api.http` is read: `'pull'` asks with promises, `'event'` pushes to `register`ed handlers. */
export type Mode = 'event' | 'pull';

/**
 * A native stream a protocol engine (`api.tls`, `api.http`) can take over: one nothing is using yet. The TLS stream
 * classes of `api.tls` are native streams too.
 */
export type NativeStream = TcpStreamUnshaped | PullTcpStream | EventTcpStream | TlsStreamUnshaped | PullTlsStream | EventTlsStream;

/** Which side of a stream {@link TcpStreamBase.end} ends, as in `shutdown(2)`. */
export type EndSide = 'write' | 'read' | 'both';

/** Bytes the write side takes: an `ArrayBuffer` or any view over one. */
export type BytesLike = ArrayBuffer | ArrayBufferView;

/** What `register` returns. */
export interface Registration {
  /** Removes the handler. Returns `true` if it was registered. When the last flowing handler goes the object pauses itself. */
  unregister(): boolean;
}

/** Options of `pulling()` / `evented()` of a stream. */
export interface ShapeOptions {
  /** The send queue of the stream. */
  readonly queued?: {
    /** Its initial `queued.limit`: a positive integer. Default 1 MiB. */
    readonly limit?: number;
  };
}

/**
 * Received bytes: a `Uint8Array` over an `ArrayBuffer` of **exactly** those bytes (`buffer.byteLength === length`,
 * offset 0); no other byte of the socket's memory is reachable through it. It stays valid, across awaits, until
 * {@link Lease.unref} or the end of its `using` block detaches the `ArrayBuffer` (any view you kept becomes empty).
 * One you never release is garbage collected like any buffer.
 */
export interface Lease extends Uint8Array<ArrayBuffer>, Disposable {
  /** `true` once `unref()` ran. */
  readonly released: boolean;
  /** Detaches the buffer and frees its memory. Idempotent. */
  unref(): void;
}

/** The `data` event of an {@link EventTcpStream}: valid only while its handlers run (the object is reused). */
export interface DataEvent {
  /** Bytes received (0 once the event is over). */
  readonly length: number;
  /**
   * The chunk as a {@link Lease}: the same lease on every call within one event. Copies nothing (the bytes were
   * received into a slab and are carved out). Call it while the handler runs (before an `await`): a `TypeError`
   * once the event is over. The lease itself stays valid until released.
   */
  buffer(): Lease;
}

/** The `datagram` event of an {@link EventUdpSocket}: one whole datagram. */
export interface DatagramEvent {
  /** Bytes of the datagram. */
  readonly length: number;
  /** Where it came from. */
  readonly from: SocketAddr;
  /** The datagram as a {@link Lease}, the same on every call (made once, by one copy into V8 memory). */
  buffer(): Lease;
}

/** Events of an {@link EventTcpStream} and the arguments their handlers get. */
export interface StreamEvents {
  /** Bytes arrived. The first handler starts the flow. */
  data: [event: DataEvent];
  /** The peer finished sending (its FIN). The stream stays open and writable: answer with `end('write')` or `close()`. */
  end: [];
  /** A failure (an `IoError` or `HostError`), or what a handler threw. The stream is closed, then `close` fires. */
  error: [error: unknown];
  /** The send queue became empty. */
  drain: [];
  /** The stream closed. Fires once; handlers are dropped afterwards. */
  close: [];
}

/** Events of an {@link EventTcpListener}. */
export interface ListenerEvents {
  /** A connection arrived, unshaped. The first handler starts accepting; a connection nobody handles is closed. */
  connection: [stream: TcpStreamUnshaped];
  error: [error: unknown];
  close: [];
}

/** Events of an {@link EventUdpSocket}. */
export interface DatagramEvents {
  /** A datagram arrived. The first handler starts receiving. */
  datagram: [event: DatagramEvent];
  error: [error: unknown];
  close: [];
}

// Handler rules shared by every `register`: handlers of one event run in registration order; a handler that throws
// goes to the `error` handlers (with none it becomes an unhandled rejection); a promise a handler returns is not
// awaited (its rejection is the program's to handle). Registrations never keep the program alive: await `io.run()`.
// After `close` handlers are dropped; `register` on a closed object throws `BadHandle`. `pause()` stops delivery of
// the read side (`end`, `error` and `close` included) until `resume()`; at most 8 chunks are held, then reading
// stops and the peer is held back. `paused` is true after `pause()` or while no handler of the flowing event listens.

/** What every network object has. */
export interface NetObject extends AsyncDisposable {
  /** `true` once consumed by a transfer, after `close()`, or once the runtime is closed. */
  readonly closed: boolean;
  /** The local address (`BadHandle` once closed). */
  readonly localAddr: SocketAddr;
  /** Releases the descriptor now; pending reads end, pending accepts and sends reject `Canceled`. Idempotent. */
  close(): Promise<void>;
}

/** A connected stream that flows nothing yet (`io.tcp.connect`, an accepted connection). */
export declare class TcpStreamUnshaped implements NetObject {
  private constructor();
  readonly closed: boolean;
  readonly localAddr: SocketAddr;
  readonly peerAddr: SocketAddr;
  /** Consumes this object: the stream read with promises. */
  pulling(options?: ShapeOptions): PullTcpStream;
  /** Consumes this object: the stream that pushes events. */
  evented(options?: ShapeOptions): EventTcpStream;
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
}

/**
 * `stream.queued`: the send queue. Everything that goes through it leaves the stream in call order and it has
 * priority over `direct`. "Sent" means taken by the kernel, not received by the peer. A write error rejects every
 * pending `send`, throws from `put`, and the stream emits `error` once and closes.
 */
export declare class SendQueue {
  private constructor();
  /** Bytes in the queue the kernel has not taken yet. */
  readonly bytes: number;
  /** Sends (and `end`s) waiting for their turn. */
  readonly waiting: number;
  /** Bytes the queue may hold: a positive integer (`TypeError` otherwise). A send into an empty queue is admitted whatever its size. */
  limit: number;
  /** Queues as much of `data` as fits under `limit` and returns the **number of bytes taken** (0 when full or sends wait). Copies what it takes. */
  put(data: BytesLike): number;
  /** Copies all of `data` now, waits its turn and room, and resolves once its last byte is in the kernel. Rejects when the stream fails (`BrokenPipe`, ...) or closes first (`Canceled`). */
  send(data: BytesLike): Promise<void>;
  /** Resolves when no send waits and the queue is empty. */
  drained(): Promise<void>;
}

/** `stream.direct`: the unbuffered lane, a plain non-blocking write. It never overtakes the send queue. */
export declare class Direct {
  private constructor();
  /** One non-blocking `write(2)` with no copy: the **number of bytes the kernel took** (0 to `data.byteLength`; 0 while the queue is busy; always 0 under TLS). */
  write(data: BytesLike): number;
}

/** The write side shared by both stream shapes. */
export interface TcpStreamBase extends NetObject {
  readonly peerAddr: SocketAddr;
  /** The send queue: written before `direct`. Its own object, kept by a transfer's new object for the same connection. */
  readonly queued: SendQueue;
  readonly direct: Direct;
  /**
   * Ends one side or both, like `shutdown(2)`; `side` is required (rejects `TypeError` without it). `'write'`: once
   * everything queued and waiting is out, sends the FIN (under TLS `close_notify` first) and resolves; later writes
   * fail `BrokenPipe`. `'read'`: stops reading and discards what arrives. `'both'`: both. A stream closes itself
   * once the peer finished (or you ended `'read'`) and your write side was ended; never because of the peer's FIN alone.
   */
  end(side: EndSide): Promise<void>;
}

/** A stream read with promises. */
export declare class PullTcpStream implements TcpStreamBase {
  private constructor();
  readonly closed: boolean;
  readonly localAddr: SocketAddr;
  readonly peerAddr: SocketAddr;
  readonly queued: SendQueue;
  readonly direct: Direct;
  end(side: EndSide): Promise<void>;
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
  /** Reads once: a `Uint8Array` of 1 to `length` bytes (an integer in 1 to 2**28), **empty at end of stream**. Allocated. */
  read(length: number): Promise<Uint8Array>;
  /** Reads once straight into `buffer` (not empty) with **no copy**: it is detached while the read runs and comes back as a new `ArrayBuffer`. `Unsupported` for a buffer that cannot be detached. */
  readInto(buffer: BytesLike): Promise<{ readonly bytes: number; readonly buffer: ArrayBuffer }>;
  /** Reads once into `buffer` (not empty) **by copy**: the byte count, 0 at end of stream. */
  readCopy(buffer: BytesLike): Promise<number>;
  /** `for await (const chunk of stream)`: the bytes as `read(65536)` returns them, until the end of the stream. */
  [Symbol.asyncIterator](): AsyncIterableIterator<Uint8Array>;
  /** Consumes this object: an {@link EventTcpStream} over the connection. `WouldBlock` while a read is pending. */
  toEvented(): EventTcpStream;
}

/** A stream that pushes events to handlers held natively. */
export declare class EventTcpStream implements TcpStreamBase {
  private constructor();
  readonly closed: boolean;
  readonly localAddr: SocketAddr;
  readonly peerAddr: SocketAddr;
  readonly queued: SendQueue;
  readonly direct: Direct;
  readonly paused: boolean;
  end(side: EndSide): Promise<void>;
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
  register<K extends keyof StreamEvents>(event: K, handler: (...args: StreamEvents[K]) => unknown): Registration;
  pause(): void;
  resume(): void;
  /** Consumes this object: a {@link PullTcpStream}. `Unsupported` once a `data` handler started the flow. */
  toPulling(): PullTcpStream;
}

/** A listening socket that accepts nothing yet (`io.tcp.listen`). */
export declare class TcpListenerUnshaped implements NetObject {
  private constructor();
  readonly closed: boolean;
  readonly localAddr: SocketAddr;
  pulling(): PullTcpListener;
  evented(): EventTcpListener;
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
}

/** A listener whose connections are awaited. */
export declare class PullTcpListener implements NetObject {
  private constructor();
  readonly closed: boolean;
  readonly localAddr: SocketAddr;
  /** The next connection, unshaped. Rejects `Canceled` when the listener closes first. */
  accept(): Promise<TcpStreamUnshaped>;
  /** `for await (const stream of listener)`: the connections until the listener is closed. */
  [Symbol.asyncIterator](): AsyncIterableIterator<TcpStreamUnshaped>;
  /** Releases the listener; pending accepts reject `Canceled`. Resolves once the port is free. */
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
}

/** A listener that emits `connection` events. */
export declare class EventTcpListener implements NetObject {
  private constructor();
  readonly closed: boolean;
  readonly localAddr: SocketAddr;
  readonly paused: boolean;
  register<K extends keyof ListenerEvents>(event: K, handler: (...args: ListenerEvents[K]) => unknown): Registration;
  pause(): void;
  resume(): void;
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
}

/** A bound datagram socket that receives nothing yet (`io.udp.bind`). */
export declare class UdpSocketUnshaped implements NetObject {
  private constructor();
  readonly closed: boolean;
  readonly localAddr: SocketAddr;
  pulling(): PullUdpSocket;
  evented(): EventUdpSocket;
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
}

/** What both datagram shapes send with. */
export interface UdpBase extends NetObject {
  /** The connected peer (`NotConnected` before `connect`). */
  readonly peerAddr: SocketAddr;
  /** One datagram to `addr` (checked against the `connect` rules), or without it to the connected peer (`NotConnected` if none). Resolves the bytes sent. */
  sendTo(data: BytesLike, addr?: SocketAddr): Promise<number>;
  /** Sends to `addr` by default and receives only its datagrams (`connect` rules). */
  connect(addr: SocketAddr): void;
}

/** A datagram socket read with promises. */
export declare class PullUdpSocket implements UdpBase {
  private constructor();
  readonly closed: boolean;
  readonly localAddr: SocketAddr;
  readonly peerAddr: SocketAddr;
  sendTo(data: BytesLike, addr?: SocketAddr): Promise<number>;
  connect(addr: SocketAddr): void;
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
  /** The next datagram: its first `length` bytes (1 to 65535; the rest is dropped) and its source. */
  recvFrom(length: number): Promise<{ readonly data: Uint8Array; readonly addr: SocketAddr }>;
}

/** A datagram socket that emits `datagram` events. */
export declare class EventUdpSocket implements UdpBase {
  private constructor();
  readonly closed: boolean;
  readonly localAddr: SocketAddr;
  readonly peerAddr: SocketAddr;
  readonly paused: boolean;
  sendTo(data: BytesLike, addr?: SocketAddr): Promise<number>;
  connect(addr: SocketAddr): void;
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
  register<K extends keyof DatagramEvents>(event: K, handler: (...args: DatagramEvents[K]) => unknown): Registration;
  pause(): void;
  resume(): void;
}

/** A frozen class value of `api.net`: for `instanceof`; constructing one is a `TypeError`. */
export interface NetClass<T> extends Function {
  readonly prototype: T;
}

/**
 * `api.net`: the classes of the network objects, for `instanceof`. Making them is `io.tcp` / `io.udp`'s job: there
 * is one implementation and this is its facade.
 */
export interface NetCap {
  readonly TcpStreamUnshaped: typeof TcpStreamUnshaped;
  readonly PullTcpStream: typeof PullTcpStream;
  readonly EventTcpStream: typeof EventTcpStream;
  readonly TcpListenerUnshaped: typeof TcpListenerUnshaped;
  readonly PullTcpListener: typeof PullTcpListener;
  readonly EventTcpListener: typeof EventTcpListener;
  readonly UdpSocketUnshaped: typeof UdpSocketUnshaped;
  readonly PullUdpSocket: typeof PullUdpSocket;
  readonly EventUdpSocket: typeof EventUdpSocket;
  readonly SendQueue: typeof SendQueue;
  readonly Direct: typeof Direct;
  readonly DataEvent: NetClass<DataEvent>;
  readonly DatagramEvent: NetClass<DatagramEvent>;
  readonly Registration: NetClass<Registration>;
  readonly Lease: NetClass<Lease>;
}
