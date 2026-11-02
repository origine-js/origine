import type { Io } from './io.d.ts';
import type { RootPki } from './tls.d.ts';

/**
 * An IP address, v4 (4 octets) or v6 (16), in Rust's vocabulary. Built by named constructors that validate; frozen.
 * (Lives in `api.dns` for now; it is meant to be shared with `api.net` and `api.tls`.)
 */
export declare class IpAddr {
  private constructor();
  static v4(a: number, b: number, c: number, d: number): IpAddr;
  /** Eight 16-bit segments. */
  static v6(...segments: number[]): IpAddr;
  /** 4 or 16 bytes (copied). */
  static fromOctets(octets: Uint8Array): IpAddr;
  /** `1.2.3.4` or `::1`: no port, no brackets, no zone. Throws `TypeError` otherwise. */
  static parse(text: string): IpAddr;
  readonly family: 4 | 6;
  /** A fresh copy. */
  octets(): Uint8Array;
  isV4(): boolean;
  isV6(): boolean;
  isUnspecified(): boolean;
  /** 127.0.0.0/8 or ::1. An IPv4-mapped address is not loopback until {@link IpAddr.toCanonical}. */
  isLoopback(): boolean;
  isMulticast(): boolean;
  /** RFC 1918 or the unique-local range fc00::/7. */
  isPrivate(): boolean;
  isLinkLocal(): boolean;
  isDocumentation(): boolean;
  /** `::ffff:a.b.c.d` becomes `a.b.c.d`; anything else is itself. Permission checks must use it. */
  toCanonical(): IpAddr;
  equals(other: unknown): boolean;
  toString(): string;
}

/** An address and a port. */
export declare class SocketAddr {
  private constructor();
  static new(ip: IpAddr, port: number): SocketAddr;
  /** `1.2.3.4:53` or `[::1]:853`. */
  static parse(text: string): SocketAddr;
  readonly ip: IpAddr;
  readonly port: number;
  equals(other: unknown): boolean;
  toString(): string;
}

/**
 * How one DNS server is reached. Servers are `IpAddr` (the transport's default port: 53, 853 for TLS, or the URL's
 * port, 443 by default, for HTTPS) or
 * `SocketAddr` values, and each must be allowed by a `connect` rule of the embedder's network ceiling
 * (`PermissionDenied` at `dns.resolver`, loopback only by default): a resolver opens sockets of its own.
 */
export declare class DnsServer {
  private constructor();
  /** This machine's nameservers, search list and hosts file, read when the resolver is made. */
  static system(): DnsServer;
  /** Datagrams; an answer that does not fit is asked again over TCP. */
  static udp(servers: (IpAddr | SocketAddr)[]): DnsServer;
  static tcp(servers: (IpAddr | SocketAddr)[]): DnsServer;
  /** DNS over TLS. `name` is what the server's certificate must be valid for; needs `roots` in {@link DnsCap.resolver}. */
  static tls(name: string, servers: (IpAddr | SocketAddr)[]): DnsServer;
  /**
   * DNS over HTTPS (RFC 8484): one HTTP/2 POST per query to `url`, which is `https://host[:port][/path][?query]`
   * (no userinfo, no fragment, a host name or IPv4 address). The host is what the server's certificate must be
   * valid for; a server that does not negotiate `h2` is `Unsupported`, redirects are not followed. Needs `roots`
   * in {@link DnsCap.resolver} and a build with `-Dhttp`. Throws `TypeError` for a URL it does not accept.
   */
  static https(url: string, servers: (IpAddr | SocketAddr)[]): DnsServer;
}

/**
 * What a resolver remembers between lookups. Every number is required and in milliseconds except `limit`: nothing
 * has a default.
 */
export interface ResolverCache {
  /** Most answers held at once (at least 1); when full, the one nearest to expiry makes room. */
  limit: number;
  /** A positive answer lives for its shortest record's TTL raised to `min` and cut to `max`. */
  ttl: { min: number; max: number };
  /**
   * A negative answer (NXDOMAIN, or no records of the type) lives for the smaller of its SOA's TTL and minimum
   * (RFC 2308), clamped the same way; one without a SOA is not kept. A `max` of 0 turns negative caching off.
   */
  negative: { min: number; max: number };
}

export interface ResolverOptions {
  /** At least one, tried in order. */
  servers: DnsServer[];
  /** Required with {@link DnsServer.tls} and {@link DnsServer.https}. */
  roots?: RootPki;
  /** `'validate'` is `Unsupported` until DNSSEC validation is built. */
  dnssec: 'off' | 'validate';
  /** Milliseconds per attempt at one address. */
  timeout: number;
  /** Rounds over all the servers. */
  tries: number;
  /**
   * Shared by every lookup of the resolver. Absent means no caching: every lookup asks the servers. Addresses
   * from literals, `localhost` and the hosts file are never cached (they are never asked).
   */
  cache?: ResolverCache;
}

export declare class Resolver {
  private constructor();
  readonly io: Io;
  readonly closed: boolean;
  /**
   * The addresses of `name`: an IP literal is itself, `localhost` is the loopback addresses, then the hosts file (for
   * `system()`), then the servers (search domains per `ndots`). IPv6 comes first for `'any'`. Rejects `NotFound`
   * (`subject`: the name), `TimedOut`, `ServerFailure` (`subject`: the response code), `InvalidInput` (not an ASCII
   * name), the transport's own errors, and for DoT `CertificateRejected` and friends.
   */
  lookup(name: string, options: { family: 'ipv4' | 'ipv6' | 'any' }): Promise<IpAddr[]>;
  /** Forgets the resolver; lookups in flight finish. */
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
}

/** `api.dns` (needs an `io`; built with `-Ddns`, on by default). Optional cache, no DNSSEC, A and AAAA only. */
export interface DnsCap {
  readonly IpAddr: typeof IpAddr;
  readonly SocketAddr: typeof SocketAddr;
  readonly DnsServer: typeof DnsServer;
  readonly Resolver: typeof Resolver;
  resolver(io: Io, options: ResolverOptions): Resolver;
}
