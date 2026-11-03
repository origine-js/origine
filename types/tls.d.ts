import type { NativeStream, TcpStreamUnshaped } from './net.d.ts';

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

/** What the handshake of a stream made by {@link TlsClient.connect} / {@link TlsServer.accept} settled. */
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

export interface TlsConnectOptions {
  /** The name the certificate must be valid for (and the SNI sent). A non-empty string. */
  servername: string;
}

/** An immutable client configuration. Rejects `CertificateRejected` (reason in `subject`), `TlsAlert`, `NoApplicationProtocol`, `ProtocolError`, `UnexpectedEof`. */
export declare class TlsClient {
  private constructor();
  /**
   * Handshakes over `stream`, a native stream nothing is using (no read pending, nothing queued, no handler, no
   * side ended; `WouldBlock` / `Unsupported` otherwise), which is consumed (a refused call leaves it usable; a failed
   * handshake closes it). The handshake runs natively, without entering JS, and resolves a new
   * {@link TcpStreamUnshaped} whose bytes are plaintext: shape it with `pulling()` or `evented()`. Reads that hit a
   * connection cut without `close_notify` fail `UnexpectedEof`; `end('write')` sends `close_notify` then the FIN.
   * `queued.send` is the write path (`direct.write` always takes 0 bytes: there is no kernel lane under TLS).
   */
  connect(stream: NativeStream, options: TlsConnectOptions): Promise<TcpStreamUnshaped>;
  release(): void;
}

/** An immutable server configuration. */
export declare class TlsServer {
  private constructor();
  /** Handshakes over `stream` (consumed) as the server; see {@link TlsClient.connect}. */
  accept(stream: NativeStream): Promise<TcpStreamUnshaped>;
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
  /** What the handshake of `stream` settled (any shape of a stream made by `connect` / `accept`); `BadHandle` for a plain or closed one. */
  info(stream: NativeStream): TlsInfo;
  client(options: TlsClientOptions): TlsClient;
  server(options: TlsServerOptions): TlsServer;
}
