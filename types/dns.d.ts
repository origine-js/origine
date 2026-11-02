import type { Io } from "./io.d.ts";
import type { RootPki } from "./tls.d.ts";

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
 * How one DNS server is reached. Servers are `IpAddr` (the transport's default port: 53, or 853 for TLS) or
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
}

export interface ResolverOptions {
  /** At least one, tried in order. */
  servers: DnsServer[];
  /** Required with {@link DnsServer.tls}. */
  roots?: RootPki;
  /** `'validate'` is `Unsupported` until DNSSEC validation is built. */
  dnssec: "off" | "validate";
  /** Milliseconds per attempt at one address. */
  timeout: number;
  /** Rounds over all the servers. */
  tries: number;
}

/** Made by {@link DnsCap.resolver}; defined natively (`new` throws a `TypeError`), frozen. */
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
  lookup(name: string, options: { family: "ipv4" | "ipv6" | "any" }): Promise<IpAddr[]>;
  /** Forgets the resolver; lookups in flight finish. */
  close(): Promise<void>;
  [Symbol.asyncDispose](): Promise<void>;
}

/** `api.dns` (needs an `io`; built with `-Ddns`, on by default). No cache, no DNSSEC, A and AAAA only. */
export interface DnsCap {
  readonly IpAddr: typeof IpAddr;
  readonly SocketAddr: typeof SocketAddr;
  readonly DnsServer: typeof DnsServer;
  readonly Resolver: typeof Resolver;
  resolver(io: Io, options: ResolverOptions): Resolver;
}
