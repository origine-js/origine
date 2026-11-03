// `origine:@std/net`: plain value types for addresses, shared by `api.dns` (it returns and accepts them).
declare module 'origine:@std/net' {
  /**
   * An IP address, v4 (4 octets) or v6 (16), in Rust's vocabulary. Built by named constructors that validate; frozen.
   */
  export class IpAddr {
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
  export class SocketAddr {
    private constructor();
    static new(ip: IpAddr, port: number): SocketAddr;
    /** `1.2.3.4:53` or `[::1]:853`. */
    static parse(text: string): SocketAddr;
    readonly ip: IpAddr;
    readonly port: number;
    equals(other: unknown): boolean;
    toString(): string;
  }
}
