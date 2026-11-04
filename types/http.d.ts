import type { Mode, NativeStream, BytesLike, Registration, Lease } from './net.d.ts';
import type { Io } from './io.d.ts';
import type { DuckStream, TlsClient, TlsServer } from './tls.d.ts';

/**
 * `api.http.fields`: an ordered sequence of header fields, not a map: duplicates and order are kept. A class
 * defined natively (`new` throws; make one with {@link HeaderList.of}); fields are checked when they are put: names
 * are lowercase tokens and not connection-specific, values are strings without CR, LF or NUL (`InvalidInput`
 * otherwise), and pseudo header fields (`:method`, `:status`, ...) may only lead the list, as on the wire. A list a
 * session received is sealed: `put` on it is a `TypeError`.
 */
export declare class HeaderList implements Iterable<readonly [name: string, value: string]> {
  private constructor();
  /** A new list of `pairs`, in order (`[]` for an empty one). */
  static of(pairs: readonly (readonly [name: string, value: string])[]): HeaderList;
  /** Appends a field. */
  put(name: string, value: string): void;
  readonly length: number;
  [Symbol.iterator](): IterableIterator<readonly [name: string, value: string]>;
  /** The fields, a frozen array of frozen pairs (a new array each call). */
  entries(): readonly (readonly [name: string, value: string])[];
  /** The first value of `name` (case-insensitive), or `undefined`. */
  get(name: string): string | undefined;
  getAll(name: string): readonly string[];
  has(name: string): boolean;
}

// ---- api.http.protocols.h2: frame-level HTTP/2 ----

/** Every SETTINGS parameter (RFC 9113 section 6.5.2, RFC 8441, RFC 9218), each one explicit. */
export interface H2Settings {
  readonly headerTableSize: number;
  readonly enablePush: boolean;
  readonly maxConcurrentStreams: number;
  readonly initialWindowSize: number;
  readonly maxFrameSize: number;
  /** Also the largest header block accepted; a bigger one resets its stream with `ENHANCE_YOUR_CALM`. */
  readonly maxHeaderListSize: number;
  readonly enableConnectProtocol: boolean;
  readonly noRfc7540Priorities: boolean;
}

/** Options of `h2.client` / `h2.server`; every one required but `io`, no defaults. */
export interface H2Options {
  /** The SETTINGS frame the session starts with. */
  readonly settings: H2Settings;
  /** The connection's receive window, at least 65535. */
  readonly window: number;
  /** A header block is delivered in `headers` events of about this many bytes. */
  readonly batch: number;
  /** Bytes of padding added to every HEADERS and DATA frame (0: none); a submit may say otherwise. */
  readonly padding: number;
  /** Extension frame types (not 0 to 9, ALTSVC or ORIGIN) received as `unknown` events; other unknown types are dropped. */
  readonly extensions: readonly number[];
  /** `'parsed'`: header blocks must be valid HTTP messages (RFC 9113 section 8). `'raw'`: any block, as it comes. */
  readonly frames: 'parsed' | 'raw';
  /** The runtime of a {@link DuckStream} (required for one; a native stream runs on its own). */
  readonly io?: Io;
}

/** What `submitHeaders` / `submitData` send with. */
export interface H2SendOptions {
  readonly endStream: boolean;
  /** Bytes of padding for this frame (the session's `padding` otherwise). */
  readonly padding?: number;
}

export type H2StreamState = 'idle' | 'open' | 'reserved_local' | 'reserved_remote' | 'half_closed_local' | 'half_closed_remote' | 'closed';

/** A received frame (or a stream's end), a frozen object; `type` names it. */
export type H2Frame =
  | {
      readonly type: 'settings';
      readonly ack: boolean;
      readonly entries: readonly (readonly [name: keyof H2Settings | number, value: number])[];
    }
  | {
      readonly type: 'headers';
      readonly streamId: number;
      readonly category: 'request' | 'response' | 'push_response' | 'headers' | 'push_promise';
      /** This batch of the block (sealed), pseudo header fields first. */
      readonly headers: HeaderList;
      /** The block's last batch; `endStream`, `padding` and `priority` are its. */
      readonly last: boolean;
      readonly endStream: boolean;
      readonly padding: number;
      readonly priority?: { readonly dependsOn: number; readonly weight: number; readonly exclusive: boolean };
    }
  /** One DATA frame. Give its bytes back with `consume` once used, or the peer stops sending. */
  | { readonly type: 'data'; readonly streamId: number; readonly data: Lease; readonly endStream: boolean; readonly padding: number }
  | {
      readonly type: 'priority';
      readonly streamId: number;
      readonly dependsOn: number;
      readonly weight: number;
      readonly exclusive: boolean;
    }
  | { readonly type: 'priority_update'; readonly streamId: number; readonly value: string }
  | { readonly type: 'rst_stream'; readonly streamId: number; readonly code: number }
  | { readonly type: 'push_promise'; readonly streamId: number; readonly promisedStreamId: number }
  | { readonly type: 'ping'; readonly data: Uint8Array; readonly ack: boolean }
  | { readonly type: 'goaway'; readonly lastStreamId: number; readonly code: number; readonly debug: Uint8Array }
  | { readonly type: 'window_update'; readonly streamId: number; readonly increment: number }
  | { readonly type: 'altsvc'; readonly streamId: number; readonly origin: string; readonly value: string }
  | { readonly type: 'origin'; readonly origins: readonly string[] }
  | {
      readonly type: 'unknown';
      readonly frameType: number;
      readonly flags: number;
      readonly streamId: number;
      readonly payload: Uint8Array;
    }
  /** A frame nghttp2 refused (and answered as RFC 9113 says); `reason` is its text. */
  | { readonly type: 'invalid'; readonly frameType: number; readonly streamId: number; readonly reason: string }
  /** The stream is over: `code` 0, or the error code of its reset. */
  | { readonly type: 'closed'; readonly streamId: number; readonly code: number };

/** The submits and the info both session shapes have. Submits throw `BadHandle` once the session is closed. */
export interface H2SessionBase extends AsyncDisposable {
  /** Queues a header block on `streamId`, or on a new stream (`0`, a client); returns the stream id. A block that does not end the stream opens its DATA; one on a stream whose DATA is still queued is sent after it, as trailers, and must end the stream. */
  submitHeaders(streamId: number, headers: HeaderList, options: H2SendOptions): number;
  /** Queues DATA (copied now) and resolves once it was packed into frames, inside the peer's windows; rejects when the stream or the session ends first. */
  submitData(streamId: number, data: BytesLike, options: H2SendOptions): Promise<void>;
  /** A client's RFC 9218 PRIORITY_UPDATE (`value` a Priority field value, `u=3, i`); `InvalidInput` until the peer set `noRfc7540Priorities`. nghttp2 sends no RFC 7540 PRIORITY frames. */
  submitPriority(streamId: number, value: string): void;
  submitRst(streamId: number, code: number): void;
  /** A SETTINGS frame with some parameters, any time. */
  submitSettings(settings: Partial<H2Settings>): void;
  /** A PING of exactly 8 bytes; with `ack`, the answer to one (PINGs are not answered for you). */
  submitPing(data: BytesLike, options: { readonly ack: boolean }): void;
  submitGoaway(lastStreamId: number, code: number, debug: BytesLike): void;
  /** A WINDOW_UPDATE of 1 to 2**31-1 for `streamId` (0: the connection). */
  submitWindowUpdate(streamId: number, increment: number): void;
  /** A server's PUSH_PROMISE on `streamId` (the client must have set `enablePush`); returns the promised stream id. */
  submitPush(streamId: number, headers: HeaderList): number;
  submitAltsvc(streamId: number, origin: string, value: string): void;
  submitOrigin(origins: readonly string[]): void;
  /** A frame of an extension type. */
  submitExtension(frameType: number, flags: number, streamId: number, payload: BytesLike): void;
  /** Gives `bytes` of received DATA back to the stream's and the connection's windows. */
  consume(streamId: number, bytes: number): void;
  /** Our settings as the peer acknowledged them. */
  readonly localSettings: H2Settings;
  /** The peer's, as last received. */
  readonly remoteSettings: H2Settings;
  streamState(streamId: number): H2StreamState;
  /** Bytes we may send and bytes the peer may send us on `streamId` (0: the connection). */
  windows(streamId: number): { readonly send: number; readonly receive: number };
  readonly nextStreamId: number;
  readonly closed: boolean;
  /** Ends the session now (no GOAWAY: submit one first for a graceful end). Idempotent. */
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
}

/** A session that flows nothing yet; its SETTINGS are queued. */
export declare class H2SessionUnshaped implements AsyncDisposable {
  private constructor();
  readonly closed: boolean;
  /** Consumes this object: the session read with promises. */
  pulling(): PullH2Session;
  /** Consumes this object: the session that calls handlers. */
  evented(): EventH2Session;
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
}

/** A session read with `next()`. */
export declare class PullH2Session implements H2SessionBase, AsyncIterable<H2Frame> {
  private constructor();
  /** The next frame event; `undefined` once the session is over; rejects once with the failure of a session that failed. */
  next(): Promise<H2Frame | undefined>;
  [Symbol.asyncIterator](): AsyncIterableIterator<H2Frame>;
  submitHeaders(streamId: number, headers: HeaderList, options: H2SendOptions): number;
  submitData(streamId: number, data: BytesLike, options: H2SendOptions): Promise<void>;
  submitPriority(streamId: number, value: string): void;
  submitRst(streamId: number, code: number): void;
  submitSettings(settings: Partial<H2Settings>): void;
  submitPing(data: BytesLike, options: { readonly ack: boolean }): void;
  submitGoaway(lastStreamId: number, code: number, debug: BytesLike): void;
  submitWindowUpdate(streamId: number, increment: number): void;
  submitPush(streamId: number, headers: HeaderList): number;
  submitAltsvc(streamId: number, origin: string, value: string): void;
  submitOrigin(origins: readonly string[]): void;
  submitExtension(frameType: number, flags: number, streamId: number, payload: BytesLike): void;
  consume(streamId: number, bytes: number): void;
  readonly localSettings: H2Settings;
  readonly remoteSettings: H2Settings;
  streamState(streamId: number): H2StreamState;
  windows(streamId: number): { readonly send: number; readonly receive: number };
  readonly nextStreamId: number;
  readonly closed: boolean;
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
}

/** The events of an {@link EventH2Session}: every frame type, `error` (the session failed) and `close` (it is over). */
export type H2Events = { [T in H2Frame['type']]: [frame: Extract<H2Frame, { type: T }>] } & { error: [error: unknown]; close: [] };

/** What `EventH2Session.register` returns. */
export interface H2Registration {
  /** Removes the handler; `true` if it was registered. */
  unregister(): boolean;
}

/**
 * A session that calls handlers held natively, from the loop, one event at a time, in order; events wait while it is
 * paused or no handler is registered. Handler rules as in `api.net` (a returned promise is not awaited).
 */
export declare class EventH2Session implements H2SessionBase {
  private constructor();
  register<K extends keyof H2Events>(event: K, handler: (...args: H2Events[K]) => unknown): H2Registration;
  pause(): void;
  resume(): void;
  /** `true` after `pause()` or while no handler is registered. */
  readonly paused: boolean;
  submitHeaders(streamId: number, headers: HeaderList, options: H2SendOptions): number;
  submitData(streamId: number, data: BytesLike, options: H2SendOptions): Promise<void>;
  submitPriority(streamId: number, value: string): void;
  submitRst(streamId: number, code: number): void;
  submitSettings(settings: Partial<H2Settings>): void;
  submitPing(data: BytesLike, options: { readonly ack: boolean }): void;
  submitGoaway(lastStreamId: number, code: number, debug: BytesLike): void;
  submitWindowUpdate(streamId: number, increment: number): void;
  submitPush(streamId: number, headers: HeaderList): number;
  submitAltsvc(streamId: number, origin: string, value: string): void;
  submitOrigin(origins: readonly string[]): void;
  submitExtension(frameType: number, flags: number, streamId: number, payload: BytesLike): void;
  consume(streamId: number, bytes: number): void;
  readonly localSettings: H2Settings;
  readonly remoteSettings: H2Settings;
  streamState(streamId: number): H2StreamState;
  windows(streamId: number): { readonly send: number; readonly receive: number };
  readonly nextStreamId: number;
  readonly closed: boolean;
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
}

/**
 * `api.http.protocols.h2`: HTTP/2 over a stream, frame by frame. The caller negotiates (TLS ALPN with `api.tls`,
 * `stream.info().alpn`) and picks the table; nothing is negotiated here.
 */
export interface H2Protocol {
  readonly H2SessionUnshaped: typeof H2SessionUnshaped;
  readonly PullH2Session: typeof PullH2Session;
  readonly EventH2Session: typeof EventH2Session;
  /** A client session over `stream`: a native stream (consumed; one nothing is using) or a {@link DuckStream} with `options.io`. */
  client(stream: NativeStream | DuckStream, options: H2Options): H2SessionUnshaped;
  server(stream: NativeStream | DuckStream, options: H2Options): H2SessionUnshaped;
}

/** `api.http.protocols.h3`: the same shape over a QUIC connection; every call throws `Unsupported` until QUIC exists. */
export interface H3Protocol {
  client(connection: unknown, options: unknown): never;
  server(connection: unknown, options: unknown): never;
}

/** `api.http.protocols`, keyed by ALPN id. */
export interface HttpProtocols {
  readonly h2: H2Protocol;
  readonly h3: H3Protocol;
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

export interface SessionOptions<R extends 'client' | 'server' = 'client' | 'server', M extends Mode = Mode> {
  role: R;
  /** The read mode of the session and of the exchanges it makes: `'pull'` (`next()`, `accept()`) or `'event'` (`register()`). */
  mode: M;
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
      readonly type: 'headers';
      readonly kind: 'request' | 'response' | 'trailers';
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
  | { readonly type: 'data'; readonly data: Uint8Array }
  /** The peer ended its side with a DATA frame. */
  | { readonly type: 'end' }
  /** The stream is over: `code` is 0, or the HTTP/2 error code of a reset. */
  | { readonly type: 'closed'; readonly code: number };

/** What an {@link EventClientExchange} / {@link EventServerExchange} delivers, by event name. */
export interface ExchangeEvents {
  /** A header block (or a batch of it; `last` marks the end of the block). */
  headers: Extract<StreamEvent, { type: 'headers' }>;
  /** Body bytes: give them back with `consume` once used. */
  data: Extract<StreamEvent, { type: 'data' }>;
  /** The peer ended its side. */
  end: undefined;
  /** The stream is over: `code` is 0, or the HTTP/2 error code of a reset. */
  close: Extract<StreamEvent, { type: 'closed' }>;
  /** A connection that died with the stream open (`UnexpectedEof`, `ConnectionReset`, `ProtocolError`, ...), or a handler that threw. */
  error: Error;
}

/** One stream: the write side, shared by both read modes. */
export declare class Exchange {
  protected constructor();
  readonly id: number;
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
  respond(options: { status: number; headers?: HeaderList; body?: 'stream' }): void;
}
interface PullReading {
  /** The next event, `undefined` after `closed`. A connection that died with the stream open rejects (`UnexpectedEof`, `ConnectionReset`, `ProtocolError`, ...). */
  next(): Promise<StreamEvent | undefined>;
}
interface EventReading {
  /**
   * Subscribes `handler` to an event and returns `{ unregister() }`. Events are delivered one at a time, in order, starting
   * the turn after the first `register`, so register everything you need at once. A handler that throws goes to the `error`
   * handlers; with none it is an unhandled rejection.
   */
  register<E extends keyof ExchangeEvents>(event: E, handler: (event: ExchangeEvents[E]) => void): Registration;
}
export declare class PullClientExchange extends ClientExchange implements PullReading {
  next(): Promise<StreamEvent | undefined>;
}
export declare class PullServerExchange extends ServerExchange implements PullReading {
  next(): Promise<StreamEvent | undefined>;
}
export declare class EventClientExchange extends ClientExchange implements EventReading {
  register<E extends keyof ExchangeEvents>(event: E, handler: (event: ExchangeEvents[E]) => void): Registration;
}
export declare class EventServerExchange extends ServerExchange implements EventReading {
  register<E extends keyof ExchangeEvents>(event: E, handler: (event: ExchangeEvents[E]) => void): Registration;
}
/** The exchange class of read mode `M` for a client. */
export type ClientExchangeOf<M extends Mode> = M extends 'pull' ? PullClientExchange : M extends 'event' ? EventClientExchange : never;
/** The exchange class of read mode `M` for a server. */
export type ServerExchangeOf<M extends Mode> = M extends 'pull' ? PullServerExchange : M extends 'event' ? EventServerExchange : never;

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
export declare class ClientSession<M extends Mode = Mode> extends Session {
  /** Opens a request and queues its head. `body: 'stream'` follows with `send` and `finish`. The exchange has the session's read mode. */
  open(head: RequestHead, options?: { headers?: HeaderList; body?: 'stream' }): ClientExchangeOf<M>;
}
export declare class ServerSession extends Session {}
export declare class PullServerSession extends ServerSession {
  /** The next request, or `undefined` once the session is over. */
  accept(): Promise<PullServerExchange | undefined>;
  [Symbol.asyncIterator](): AsyncIterableIterator<PullServerExchange>;
}
/** What an {@link EventServerSession} and an {@link EventHttpServer} deliver, by event name. */
export interface ServerEvents {
  /** A new request stream. One nobody listens for is refused (`REFUSED_STREAM`). */
  request: EventServerExchange;
  /** The session (or the server) is over. */
  close: undefined;
  error: Error;
}
export declare class EventServerSession extends ServerSession {
  register<E extends keyof ServerEvents>(event: E, handler: (event: ServerEvents[E]) => void): Registration;
}
/** The server session class of read mode `M`. */
export type ServerSessionOf<M extends Mode> = M extends 'pull' ? PullServerSession : M extends 'event' ? EventServerSession : never;

export interface HttpConnectOptions<M extends Mode = Mode> {
  /** An IP address (a name is not resolved); defaults to 127.0.0.1. Subject to the network ceiling (loopback only by default). */
  host?: string;
  port: number;
  /** A client configuration whose `alpn` includes `'h2'`: the connection is TLS and must negotiate `h2` (`NoApplicationProtocol` otherwise). */
  tls?: TlsClient;
  /** The name the certificate must be valid for; defaults to `host`. */
  servername?: string;
  mode: M;
  limits: HttpLimits;
}

export interface HttpServeOptions<M extends Mode = Mode> {
  listen?: { host?: string; port?: number };
  /** A server configuration whose `alpn` includes `'h2'`. Without it the server speaks cleartext HTTP/2 (h2c), for loopback. */
  tls?: TlsServer;
  mode: M;
  limits: HttpLimits;
}

/**
 * The listener and accept loop of {@link HttpCap.serve}: the requests of every connection, in arrival order. It keeps the
 * program alive until `close()`.
 */
export declare class HttpServer {
  protected constructor();
  /** The port listened on (the real one when `port: 0` was asked). */
  readonly port: number;
  readonly closed: boolean;
  /** Connections dropped before they became sessions: a failed TLS handshake, or one that did not negotiate `h2`. */
  readonly dropped: number;
  /** Stops listening and closes every session now. Idempotent. */
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
}
export declare class PullHttpServer extends HttpServer {
  /** The next request, or `undefined` once the server is closed and none is left. */
  accept(): Promise<PullServerExchange | undefined>;
  [Symbol.asyncIterator](): AsyncIterableIterator<PullServerExchange>;
}
export declare class EventHttpServer extends HttpServer {
  register<E extends keyof ServerEvents>(event: E, handler: (event: ServerEvents[E]) => void): Registration;
}
/** The server class of read mode `M`. */
export type HttpServerOf<M extends Mode> = M extends 'pull' ? PullHttpServer : M extends 'event' ? EventHttpServer : never;

/** The origin a pool request goes to; the pool keys its sessions on all of it. */
export interface PoolTarget {
  scheme: 'http' | 'https';
  /** A name or an IP literal (lowercased for the key). A name needs the pool's `lookup`; `InvalidInput` otherwise. */
  host: string;
  port: number;
  /** Required for `https`, forbidden for `http`. Sessions made with different configuration objects are never shared. */
  tls?: TlsClient;
  /** The name the certificate must be valid for; defaults to `host`. */
  servername?: string;
}

/** The request head of {@link ClientPool.open}; the scheme is the target's. */
export interface PoolRequestHead {
  method: string;
  authority: string;
  path: string;
}

/** Sizes and times of a pool; all required, no defaults. */
export interface PoolSessions {
  /** Most sessions open (or being dialed) at once, over all origins. At the limit an idle session of another origin is closed to make room. */
  limit: number;
  /** Most sessions per origin. */
  perKey: number;
  /** Milliseconds a session with no stream open is kept. `0` closes it as soon as its last stream ends. */
  idle: number;
  /** Most requests waiting for a stream or session; one more rejects `WouldBlock`. */
  queue: number;
}

export interface PoolOptions<M extends Mode = Mode> {
  mode: M;
  /** Limits of every session the pool dials. */
  limits: HttpLimits;
  sessions: PoolSessions;
  /** Resolves a host name to an IP address (`api.dns` is the caller's job). Without it only IP literals are accepted. */
  lookup?: (host: string) => string | Promise<string>;
}

/**
 * HTTP/2 client sessions shared by the requests of a program. A request uses a session of its origin whose open streams are
 * below the peer's `SETTINGS_MAX_CONCURRENT_STREAMS`; else the pool dials another session (one dial per origin at a time) if
 * `sessions.perKey` and `sessions.limit` allow, else it waits. A session the peer closed or sent GOAWAY on is dropped (streams
 * in flight finish) and not used again. Sessions keep the program alive until closed: `idle` or `close()`.
 */
export declare class ClientPool<M extends Mode = Mode> {
  private constructor();
  readonly mode: M;
  /** The policy the pool was made with. */
  readonly sessions: Readonly<PoolSessions>;
  /** Sessions open or being dialed. */
  readonly size: number;
  /** Requests waiting. */
  readonly waiting: number;
  readonly closed: boolean;
  /**
   * Opens a request on a pooled session. The exchange holds a stream slot until its `closed` event is read (pull) or
   * delivered (event), the connection dies, or `release()`: read it to the end or release it. Rejects `WouldBlock` when
   * `sessions.queue` is full, `BadHandle` once the pool is closed, `InvalidInput` for a name without `lookup`.
   */
  open(target: PoolTarget, head: PoolRequestHead, options?: { headers?: HeaderList; body?: 'stream' }): Promise<ClientExchangeOf<M>>;
  /** Closes every session now (streams in flight end) and rejects the requests waiting. Idempotent. */
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
}

/** Redirect rules; both fields required. */
export interface RedirectRules {
  /** Redirects followed before `QuotaExceeded`. `0` follows none: the 3xx response is returned. */
  limit: number;
  /** Lowercase header names dropped when a redirect changes the origin (scheme, host or port), e.g. `['authorization', 'cookie']`. */
  strip: string[];
}

export interface FetchRequest {
  method: string;
  /** Absolute `http:` or `https:` URL without userinfo. The host is resolved by the pool's `lookup`. */
  url: string;
  headers?: HeaderList;
  /**
   * Bytes (sent again after a 307 or 308) or an async iterable of bytes (consumed once: a 307 or 308 then rejects
   * `Unsupported`). Sent while the response is read; an error in the iterable resets the stream.
   */
  body?: BytesLike | AsyncIterable<BytesLike>;
  /** The configuration of every `https` hop; an `https` URL without it is a `TypeError`. */
  tls?: TlsClient;
  redirect: RedirectRules;
}

/** The body of a {@link FetchResponse}: iterate it once with `for await`. */
export declare class ResponseBody implements AsyncIterable<Uint8Array> {
  private constructor();
  /**
   * Yields chunks. A chunk counts as used, and its bytes go back to the peer's window, when the next one is asked for:
   * a slow reader slows the peer. Stopping early cancels the stream. A reset stream rejects.
   */
  [Symbol.asyncIterator](): AsyncIterableIterator<Uint8Array>;
}

/** The final response of {@link HttpCap.fetch}. */
export declare class FetchResponse {
  private constructor();
  readonly status: number;
  readonly headers: HeaderList;
  /** The URL of the last hop. */
  readonly url: string;
  readonly redirected: boolean;
  readonly body: ResponseBody;
  /** Trailing fields, once the body was read to its end. */
  readonly trailers: HeaderList | undefined;
  /** Cancels the stream if the body is not finished and gives its slot back. Idempotent. */
  close(): void;
  [Symbol.dispose](): void;
}

/** `api.http` (needs an `io`; built with `-Dhttp`, on by default). */
export interface HttpCap {
  /** The header field list class. */
  readonly fields: typeof HeaderList;
  /** The protocol tables, keyed by ALPN id. */
  readonly protocols: HttpProtocols;
  readonly ClientExchange: typeof ClientExchange;
  readonly ServerExchange: typeof ServerExchange;
  readonly PullClientExchange: typeof PullClientExchange;
  readonly PullServerExchange: typeof PullServerExchange;
  readonly EventClientExchange: typeof EventClientExchange;
  readonly EventServerExchange: typeof EventServerExchange;
  readonly ClientSession: typeof ClientSession;
  readonly ServerSession: typeof ServerSession;
  readonly PullServerSession: typeof PullServerSession;
  readonly EventServerSession: typeof EventServerSession;
  readonly HttpServer: typeof HttpServer;
  readonly PullHttpServer: typeof PullHttpServer;
  readonly EventHttpServer: typeof EventHttpServer;
  readonly ClientPool: typeof ClientPool;
  readonly FetchResponse: typeof FetchResponse;
  /**
   * Starts an HTTP/2 session over `socket` (a native stream nothing is using: plain for cleartext h2c, or one made by `api.tls` for h2), which it consumes. Synchronous. A session keeps the program alive until it is closed or its connection ends.
   */
  session<M extends Mode>(socket: NativeStream, options: SessionOptions<'client', M>): ClientSession<M>;
  session<M extends Mode>(socket: NativeStream, options: SessionOptions<'server', M>): ServerSessionOf<M>;
  /** Dials and resolves a client session once the peer's SETTINGS arrived. */
  connect<M extends Mode>(io: Io, options: HttpConnectOptions<M>): Promise<ClientSession<M>>;
  /** Binds, listens and serves HTTP/2 to every client. */
  serve<M extends Mode>(io: Io, options: HttpServeOptions<M>): HttpServerOf<M>;
  /** A pool of client sessions (see {@link ClientPool}). */
  pool<M extends Mode>(io: Io, options: PoolOptions<M>): ClientPool<M>;
  /**
   * Sends `request` through `pool` and resolves once the final response head arrived (1xx blocks are skipped). Redirects
   * follow `request.redirect`: 301 and 302 turn POST into GET, 303 turns every method but GET and HEAD into GET (the body and
   * its content headers are dropped), 307 and 308 keep method and body. A redirect from https to http rejects
   * `PermissionDenied`, one past `limit` `QuotaExceeded`, an unusable `Location` `ProtocolError`. The pool must be in pull mode.
   * The response holds a stream slot until its body ends, its iteration stops or `close()`.
   */
  fetch(pool: ClientPool<'pull'>, request: FetchRequest): Promise<FetchResponse>;
}
