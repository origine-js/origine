import type { SocketAddr } from 'origine:@std/net';
import type { Io } from './io.d.ts';
import type {
  BytesLike,
  Direct,
  EndSide,
  NativeStream,
  NetObject,
  Registration,
  SendQueue,
  ShapeOptions,
  StreamEvents,
  TcpStreamBase,
} from './net.d.ts';

/**
 * The authorities a peer is checked against. Built by a named constructor, which parses and validates:
 * a bad certificate fails there with `InvalidData`. Frozen; `release()` forgets the native value
 * (configurations built from it keep working). Like every `api.tls` value class it is defined natively: `new`
 * throws a `TypeError`, and a method called on another object, or an instance of another class passed where
 * this one is expected, is a `TypeError`.
 */
export declare class RootPki {
  private constructor();
  /** The Mozilla roots compiled into the binary. */
  static bundled(): RootPki;
  /** Every certificate of a PEM bundle; at least one. */
  static fromPem(pem: Uint8Array): RootPki;
  /** DER certificates; at least one. */
  static fromDer(certs: Uint8Array[]): RootPki;
  release(): void;
}

/** A certificate chain with the private key of its leaf; a key that does not belong to the certificate is `InvalidData`. */
export declare class Identity {
  private constructor();
  /** PEM chain (leaf first) and PEM private key (PKCS#8, PKCS#1 or SEC1). */
  static fromPem(cert: Uint8Array, key: Uint8Array): Identity;
  static fromDer(options: { cert: Uint8Array[]; key: Uint8Array }): Identity;
  release(): void;
}

/** Whether a server asks the client for a certificate. */
export declare class ClientAuth {
  private constructor();
  static none(): ClientAuth;
  /** Clients must present a certificate issued by one of `roots`. */
  static require(roots: RootPki): ClientAuth;
}

/** A client-side resumption cache. Passing one to {@link TlsCap.client} is what turns resumption on. */
export declare class TlsSessions {
  private constructor();
  /** Remembers at most `limit` server names. */
  static create(options: { limit: number }): TlsSessions;
  release(): void;
}

export interface TlsClientOptions {
  /** Required: there is no default trust. */
  roots: RootPki;
  /** Presented when the server asks for one. */
  identity?: Identity;
  /** ALPN protocol names in preference order. */
  alpn?: string[];
  /** Without it no session is resumed. */
  sessions?: TlsSessions;
}

export interface TlsServerOptions {
  /** At least one. The first whose certificate is valid for the client's SNI name is used, else the first. */
  identities: Identity[];
  /** Required. */
  clientAuth: ClientAuth;
  alpn?: string[];
}

/** What the handshake of a TLS stream settled ({@link TlsStreamUnshaped.info} and the shaped classes' `info()`). */
export interface TlsInfo {
  /** The negotiated ALPN protocol, or `undefined`. */
  readonly alpn: string | undefined;
  readonly version: 'tls1.2' | 'tls1.3';
  /** The name the client asked for (as given, or the SNI the server received). */
  readonly servername: string | undefined;
  /** The handshake resumed an earlier session. */
  readonly resumed: boolean;
  /** The peer's certificates in DER, leaf first; empty when it sent none. */
  readonly peer: Uint8Array[];
}

/**
 * A stream that is not native, read and written through its methods by the TLS engine (a slower path: a turn of the
 * loop and a copy per call). The engine calls `read(length)` if there is one, else `readInto(new Uint8Array(length))`;
 * `queued.put(bytes)` returns how many bytes it took (it must copy them) and `queued.drained()` is awaited before
 * putting the rest; `end('write')` follows `close_notify` and `close()` follows closing the TLS stream (their results
 * are not awaited). A rejection carrying an `errno` (an `IoError` / `HostError`) fails the TLS stream with that code,
 * any other with `Unexpected`; a value of the wrong kind is `InvalidData`. The method's name is the `subject`.
 */
export interface DuckStream {
  read?(length: number): Promise<Uint8Array>;
  readInto?(buffer: Uint8Array): Promise<{ readonly bytes: number; readonly buffer: ArrayBuffer | ArrayBufferView }>;
  readonly queued: {
    put(bytes: Uint8Array): number;
    drained(): Promise<void>;
  };
  end(side: 'write'): unknown;
  close(): unknown;
}

/**
 * What a TLS stream runs over: a native stream ({@link NativeStream}: TCP or TLS, unshaped or an idle shaped one),
 * which is consumed, or a {@link DuckStream}, which needs `io`.
 */
export type TlsTransport = NativeStream | DuckStream;

export interface TlsConnectOptions {
  /** The name the certificate must be valid for (and the SNI sent). A non-empty string. */
  servername: string;
  /**
   * The runtime the handshake and the TLS stream run on. Required for a {@link DuckStream} (`TypeError` without it);
   * a native stream runs on its own, and naming another `Io` for it is a `TypeError`.
   */
  io?: Io;
}

export interface TlsAcceptOptions {
  /** As {@link TlsConnectOptions.io}. */
  io?: Io;
}

/** An immutable client configuration. Rejects `CertificateRejected` (reason in `subject`), `TlsAlert`, `NoApplicationProtocol`, `ProtocolError`, `UnexpectedEof`. */
export declare class TlsClient {
  private constructor();
  /**
   * Handshakes over `stream` and resolves a {@link TlsStreamUnshaped} whose bytes are plaintext: shape it with
   * `pulling()` or `evented()`. A native stream must be one nothing is using (no read pending, nothing queued, no
   * handler, no side ended; `WouldBlock` / `Unsupported` otherwise); it is consumed (a refused call leaves it usable;
   * a failed handshake closes it) and the handshake runs natively, without entering JS. A TLS stream is a native
   * stream: TLS over TLS is a `connect` over one. Any other object is a {@link DuckStream} and needs `options.io`.
   * Reads that hit a connection cut without `close_notify` fail `UnexpectedEof`; `end('write')` sends `close_notify`
   * then ends what is underneath. `queued` is the write path (`direct.write` always takes 0 bytes: there is no kernel
   * lane under TLS).
   */
  connect(stream: TlsTransport, options: TlsConnectOptions): Promise<TlsStreamUnshaped>;
  release(): void;
}

/** An immutable server configuration. */
export declare class TlsServer {
  private constructor();
  /** Handshakes over `stream` as the server; see {@link TlsClient.connect}. */
  accept(stream: TlsTransport, options?: TlsAcceptOptions): Promise<TlsStreamUnshaped>;
  release(): void;
}

/**
 * A TLS stream that flows nothing yet (what `connect` / `accept` resolve). `localAddr` / `peerAddr` are those of the
 * socket underneath (`NotConnected` over a {@link DuckStream}).
 */
export declare class TlsStreamUnshaped implements NetObject {
  private constructor();
  readonly closed: boolean;
  readonly localAddr: SocketAddr;
  readonly peerAddr: SocketAddr;
  /** Consumes this object: the stream read with promises. */
  pulling(options?: ShapeOptions): PullTlsStream;
  /** Consumes this object: the stream that pushes events. */
  evented(options?: ShapeOptions): EventTlsStream;
  /** What the handshake settled (a new frozen object each call); `BadHandle` once closed or consumed. */
  info(): TlsInfo;
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
}

/** A TLS stream read with promises: the members of `PullTcpStream`, plus `info()`. */
export declare class PullTlsStream implements TcpStreamBase {
  private constructor();
  readonly closed: boolean;
  readonly localAddr: SocketAddr;
  readonly peerAddr: SocketAddr;
  readonly queued: SendQueue;
  /** Always takes 0 bytes: there is no kernel lane under TLS. */
  readonly direct: Direct;
  /** `'write'` sends `close_notify`, then ends what is underneath (a half close). */
  end(side: EndSide): Promise<void>;
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
  /** Reads once: 1 to `length` bytes, **empty only after the peer's `close_notify`** (a cut connection is `UnexpectedEof`). */
  read(length: number): Promise<Uint8Array>;
  readInto(buffer: BytesLike): Promise<{ readonly bytes: number; readonly buffer: ArrayBuffer }>;
  readCopy(buffer: BytesLike): Promise<number>;
  [Symbol.asyncIterator](): AsyncIterableIterator<Uint8Array>;
  /** Consumes this object: an {@link EventTlsStream}. `WouldBlock` while a read is pending. */
  toEvented(): EventTlsStream;
  info(): TlsInfo;
}

/** A TLS stream that pushes events to handlers held natively: the members of `EventTcpStream`, plus `info()`. */
export declare class EventTlsStream implements TcpStreamBase {
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
  /** Consumes this object: a {@link PullTlsStream}. `Unsupported` once a `data` handler started the flow. */
  toPulling(): PullTlsStream;
  info(): TlsInfo;
}

/** `api.tls` (needs an `io`; built with `-Dtls`, on by default). */
export interface TlsCap {
  readonly RootPki: typeof RootPki;
  readonly Identity: typeof Identity;
  readonly ClientAuth: typeof ClientAuth;
  readonly TlsSessions: typeof TlsSessions;
  readonly TlsClient: typeof TlsClient;
  readonly TlsServer: typeof TlsServer;
  readonly TlsStreamUnshaped: typeof TlsStreamUnshaped;
  readonly PullTlsStream: typeof PullTlsStream;
  readonly EventTlsStream: typeof EventTlsStream;
  client(options: TlsClientOptions): TlsClient;
  server(options: TlsServerOptions): TlsServer;
}
