import type { Mode, PullSocket, BytesLike } from "./net.d.ts";
import type { Io } from "./io.d.ts";
import type { TlsClient, TlsServer, TlsSocket } from "./tls.d.ts";

/**
 * An ordered sequence of header fields, not a map: duplicates and order are kept. Names are lowercase tokens;
 * values are UTF-8 strings without CR, LF or NUL. One you build is packed into a single buffer and crosses
 * into the native once; one you receive is frozen.
 */
export declare class HeaderList implements Iterable<[name: string, value: string]> {
  constructor();
  /** Appends a field and returns the list. A received list throws `TypeError`; a bad name or value does too. */
  put(name: string, value: string): this;
  readonly length: number;
  [Symbol.iterator](): IterableIterator<[name: string, value: string]>;
  /** The first value of `name` (case-insensitive), or `undefined`. */
  get(name: string): string | undefined;
  getAll(name: string): string[];
  has(name: string): boolean;
}

/** Sizes in bytes (a count for `streams`); all required, no defaults. */
export interface HttpLimits {
  /** Streams the peer may have open at once. */
  streams: number;
  /** Largest header block accepted per message (name + value + 32 per field); a block over it resets the stream. */
  headers: number;
  /** Window per stream; also how much a writer may have queued and unsent before `send` waits. */
  window: number;
  /** Window for the whole connection; at least 65535. */
  connection: number;
  /** A header block is delivered in batches of about this many bytes. */
  batch: number;
}

export interface SessionOptions<R extends "client" | "server" = "client" | "server"> {
  role: R;
  /** Pull mode only for now: `'event'` is `Unsupported`. */
  mode: "pull";
  limits: HttpLimits;
}

export interface RequestHead {
  method: string;
  scheme: string;
  authority: string;
  path: string;
}

/** What `next()` yields, in order. After `closed`, `next()` resolves `undefined`. */
export type StreamEvent =
  | {
      readonly type: "headers";
      readonly kind: "request" | "response" | "trailers";
      /** Pseudo headers, present on the first batch of a block only (and only those that exist). */
      readonly method?: string;
      readonly scheme?: string;
      readonly authority?: string;
      readonly path?: string;
      readonly status?: number;
      readonly headers: HeaderList;
      /** This batch ends the block. */
      readonly last: boolean;
      /** The peer sends nothing more on the stream (only with `last`). */
      readonly endStream: boolean;
    }
  /** Body bytes; give them back with {@link Exchange.consume} once used. */
  | { readonly type: "data"; readonly data: Uint8Array }
  /** The peer ended its side with a DATA frame. */
  | { readonly type: "end" }
  /** The stream is over: `code` is 0, or the HTTP/2 error code of a reset. */
  | { readonly type: "closed"; readonly code: number };

/** One stream. */
export declare class Exchange {
  protected constructor();
  readonly id: number;
  /** The next event, `undefined` after `closed`. A connection that died with the stream open rejects (`UnexpectedEof`, `ConnectionReset`, `ProtocolError`, ...). */
  next(): Promise<StreamEvent | undefined>;
  /** Gives `bytes` of received body back to the peer's window. Call it when the data was used, not when it arrived: that is the backpressure. */
  consume(bytes: number): void;
  /** Bytes accepted by `send` that have not left yet. */
  readonly queued: number;
  /** Queues body bytes (copied now). Waits while the stream already has a window's worth queued and unsent. Rejects `BrokenPipe` once the stream is over. */
  send(data: BytesLike): Promise<void>;
  /** Ends the body, optionally with trailing fields. */
  finish(trailers?: HeaderList): void;
  /** Resets the stream with an HTTP/2 error code (8 is CANCEL). */
  reset(code?: number): void;
  /** Forgets the stream. One whose own side is still being written is cancelled; one whose side is complete ends quietly. */
  release(): void;
  [Symbol.dispose](): void;
}
export declare class ClientExchange extends Exchange {}
export declare class ServerExchange extends Exchange {
  /** Queues the response head. `body: 'stream'` follows with `send` and `finish`; without it the head ends the stream. */
  respond(options: { status: number; headers?: HeaderList; body?: "stream" }): void;
}

/** The connection. */
export declare class Session {
  protected constructor();
  readonly io: unknown;
  readonly closed: boolean;
  /** Resolves once the peer's SETTINGS arrived. Open streams after this: before it the peer's limits are unknown. */
  ready(): Promise<void>;
  /** The round trip of a PING in milliseconds. */
  ping(): Promise<number>;
  /** Starts a graceful close (GOAWAY): streams in flight finish. */
  end(): Promise<void>;
  /** Releases the session now: the transport is shut down and every stream ends. Idempotent. */
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
}
export declare class ClientSession extends Session {
  /** Opens a request and queues its head. `body: 'stream'` follows with `send` and `finish`. */
  open(head: RequestHead, options?: { headers?: HeaderList; body?: "stream" }): ClientExchange;
}
export declare class ServerSession extends Session {
  /** The next request, or `undefined` once the session is over. */
  accept(): Promise<ServerExchange | undefined>;
  [Symbol.asyncIterator](): AsyncIterableIterator<ServerExchange>;
}

export interface HttpConnectOptions {
  /** An IP address (a name is not resolved); defaults to 127.0.0.1. Subject to the network ceiling (loopback only by default). */
  host?: string;
  port: number;
  /** A client configuration whose `alpn` includes `'h2'`: the connection is TLS and must negotiate `h2` (`NoApplicationProtocol` otherwise). */
  tls?: TlsClient;
  /** The name the certificate must be valid for; defaults to `host`. */
  servername?: string;
  mode: "pull";
  limits: HttpLimits;
}

export interface HttpServeOptions {
  listen?: { host?: string; port?: number };
  /** A server configuration whose `alpn` includes `'h2'`. Without it the server speaks cleartext HTTP/2 (h2c), for loopback. */
  tls?: TlsServer;
  mode: "pull";
  limits: HttpLimits;
}

/**
 * The listener and accept loop of {@link HttpCap.serve}: the requests of every connection, in arrival order. It keeps the
 * program alive until `close()`.
 */
export declare class HttpServer {
  private constructor();
  /** The port listened on (the real one when `port: 0` was asked). */
  readonly port: number;
  readonly closed: boolean;
  /** Connections dropped before they became sessions: a failed TLS handshake, or one that did not negotiate `h2`. */
  readonly dropped: number;
  /** The next request, or `undefined` once the server is closed and none is left. */
  accept(): Promise<ServerExchange | undefined>;
  [Symbol.asyncIterator](): AsyncIterableIterator<ServerExchange>;
  /** Stops listening and closes every session now. Idempotent. */
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
}

/** `api.http` (needs an `io`; built with `-Dhttp`, on by default). */
export interface HttpCap {
  readonly HeaderList: typeof HeaderList;
  readonly ClientSession: typeof ClientSession;
  readonly ServerSession: typeof ServerSession;
  readonly HttpServer: typeof HttpServer;
  /**
   * Starts an HTTP/2 session over `socket` (a pull-mode `api.net` socket for cleartext h2c, or a {@link TlsSocket}
   * for h2), which it consumes. Synchronous. A session keeps the program alive until it is closed or its connection ends.
   */
  session(socket: PullSocket | TlsSocket, options: SessionOptions<"client">): ClientSession;
  session(socket: PullSocket | TlsSocket, options: SessionOptions<"server">): ServerSession;
  /** Dials and resolves a client session once the peer's SETTINGS arrived. */
  connect(io: Io, options: HttpConnectOptions): Promise<ClientSession>;
  /** Binds, listens and serves HTTP/2 to every client. */
  serve(io: Io, options: HttpServeOptions): HttpServer;
}
