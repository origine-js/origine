import type { Mode, PullSocket } from "./net.d.ts";
import type { BytesLike } from "./net.d.ts";

/**
 * The authorities a peer is checked against. Built by a named constructor, which parses and validates:
 * a bad certificate fails there with `InvalidData`. Frozen; `release()` forgets the native value
 * (configurations built from it keep working).
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

/**
 * An established TLS connection over a consumed {@link PullSocket}. Pull mode only for now: `mode: 'event'` is
 * refused with `Unsupported`. Not yet here (absent, not stubbed): the `queued` / `direct` write lanes, `readInto`,
 * `toEvent()`.
 */
export declare class TlsSocket {
  private constructor();
  readonly io: unknown;
  readonly closed: boolean;
  /** The negotiated ALPN protocol, or `undefined`. */
  readonly alpn: string | undefined;
  readonly version: "tls1.2" | "tls1.3";
  /** The name the client asked for (as given, or the SNI the server received). */
  readonly servername: string | undefined;
  /** The handshake resumed an earlier session. */
  readonly resumed: boolean;
  /** The peer's certificates in DER, leaf first; empty when it sent none. */
  readonly peer: Uint8Array[];
  /** 1 to `length` plaintext bytes; empty only after the peer's `close_notify`. A connection cut without it rejects `UnexpectedEof`. */
  read(length: number): Promise<Uint8Array>;
  /** Reads once into `buffer` (not empty) by copy; the byte count, 0 after `close_notify`. */
  readCopy(buffer: BytesLike): Promise<number>;
  [Symbol.asyncIterator](): AsyncIterableIterator<Uint8Array>;
  /** Copies `data` now; resolves once all of it is in the transport. Sends go out in the order they were made. */
  send(data: BytesLike): Promise<void>;
  /** Sends `close_notify`; reading keeps working and later sends reject `BrokenPipe`. */
  end(side: "write"): Promise<void>;
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
}

export interface TlsConnectOptions<M extends Mode = Mode> {
  /** The name the certificate must be valid for (and the SNI sent). */
  servername: string;
  mode: M;
}

/** An immutable client configuration. Rejects `CertificateRejected` (reason in `subject`), `TlsAlert`, `NoApplicationProtocol`, `ProtocolError`, `UnexpectedEof`. */
export declare class TlsClient {
  private constructor();
  /** Handshakes over `socket`, which is consumed (a refused call leaves it usable; a failed handshake closes it). */
  connect(socket: PullSocket, options: TlsConnectOptions<"pull">): Promise<TlsSocket>;
  release(): void;
}

/** An immutable server configuration. */
export declare class TlsServer {
  private constructor();
  accept(socket: PullSocket, options: { mode: "pull" }): Promise<TlsSocket>;
  release(): void;
}

/** `api.tls` (needs an `io`; built with `-Dtls`, on by default). */
export interface TlsCap {
  readonly RootPki: typeof RootPki;
  readonly Identity: typeof Identity;
  readonly ClientAuth: typeof ClientAuth;
  readonly TlsSessions: typeof TlsSessions;
  readonly TlsClient: typeof TlsClient;
  readonly TlsServer: typeof TlsServer;
  readonly TlsSocket: typeof TlsSocket;
  client(options: TlsClientOptions): TlsClient;
  server(options: TlsServerOptions): TlsServer;
}
