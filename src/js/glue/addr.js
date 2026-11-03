// `IpAddr` and `SocketAddr`, in Rust's vocabulary (camelCase): one class for both families, v4 = 4 octets and
// v6 = 16, plus the address and port. Plain value types, not a capability: guests import them from
// `origine:@std/net` (src/js/std/net.js, which takes them from the provision below), and the glue (`api.dns`)
// makes and checks the same instances. Frozen instances, made by named constructors that validate.
import { seal } from './util.js';
import { provide } from './handles.js';

const token = {};

const v4Text = o => `${o[0]}.${o[1]}.${o[2]}.${o[3]}`;

// RFC 5952: lowercase hex, the longest run of two or more zero groups becomes `::` (the first on a tie),
// an IPv4-mapped address keeps its dotted tail like Rust prints it.
const v6Text = o => {
  const g = Array.from({ length: 8 }, (_, i) => (o[2 * i] << 8) | o[2 * i + 1]);
  if (g.slice(0, 5).every(x => x === 0) && g[5] === 0xffff) return `::ffff:${v4Text(o.subarray(12))}`;
  let best = -1;
  let bestLen = 1;
  for (let i = 0; i < 8;) {
    if (g[i] !== 0) {
      i++;
      continue;
    }
    let j = i;
    while (j < 8 && g[j] === 0) j++;
    if (j - i > bestLen) {
      best = i;
      bestLen = j - i;
    }
    i = j;
  }
  const hex = x => x.toString(16);
  if (best < 0) return g.map(hex).join(':');
  return `${g.slice(0, best).map(hex).join(':')}::${g
    .slice(best + bestLen)
    .map(hex)
    .join(':')}`;
};

// The parsers are natives (src/api/addr.zig) that fill `scratch`: octets at 0..16 and, for a socket address, the port as a
// u16 at 16..18. A parse is synchronous and never calls back into JS, so one scratch per realm is enough; the instance
// copies out the octets it keeps. The natives are bound at install, after this module is evaluated, so `native.addr` is
// read at call time.
let native;
export const link = value => {
  native = value;
};
const scratch = new Uint8Array(18);
const scratchPort = new Uint16Array(scratch.buffer, 16, 1);
const familyOctets = family => scratch.slice(0, family === 4 ? 4 : 16);

export class IpAddr {
  #octets;
  constructor(made, octets) {
    if (made !== token) throw new TypeError('use IpAddr.v4, v6, fromOctets or parse');
    this.#octets = octets;
    seal(this);
  }
  static v4(a, b, c, d) {
    const parts = [a, b, c, d];
    if (parts.some(x => !Number.isInteger(x) || x < 0 || x > 255)) throw new TypeError('each octet must be an integer in 0..255');
    return new IpAddr(token, Uint8Array.from(parts));
  }
  /** Eight 16-bit segments. */
  static v6(...segments) {
    if (segments.length !== 8 || segments.some(x => !Number.isInteger(x) || x < 0 || x > 0xffff))
      throw new TypeError('v6 takes eight integers in 0..65535');
    const out = new Uint8Array(16);
    segments.forEach((s, i) => {
      out[2 * i] = s >> 8;
      out[2 * i + 1] = s & 255;
    });
    return new IpAddr(token, out);
  }
  /** 4 octets for v4, 16 for v6; the bytes are copied. */
  static fromOctets(octets) {
    if (!(octets instanceof Uint8Array) || (octets.length !== 4 && octets.length !== 16))
      throw new TypeError('octets must be a Uint8Array of 4 or 16 bytes');
    return new IpAddr(token, Uint8Array.from(octets));
  }
  /** `1.2.3.4` or `::1`: no port, no brackets, no zone. Throws `TypeError` otherwise. */
  static parse(text) {
    if (typeof text !== 'string') throw new TypeError('text must be a string');
    const family = native.addr.parseIp(text, scratch);
    if (!family) throw new TypeError(`invalid IP address: ${JSON.stringify(text)}`);
    return new IpAddr(token, familyOctets(family));
  }
  get family() {
    return this.#octets.length === 4 ? 4 : 6;
  }
  /** A fresh copy: 4 or 16 bytes. */
  octets() {
    return Uint8Array.from(this.#octets);
  }
  isV4() {
    return this.#octets.length === 4;
  }
  isV6() {
    return this.#octets.length === 16;
  }
  isUnspecified() {
    return this.#octets.every(b => b === 0);
  }
  /** 127.0.0.0/8 or ::1. An IPv4-mapped address is not loopback until `toCanonical()`. */
  isLoopback() {
    const o = this.#octets;
    return o.length === 4 ? o[0] === 127 : o.slice(0, 15).every(b => b === 0) && o[15] === 1;
  }
  isMulticast() {
    const o = this.#octets;
    return o.length === 4 ? (o[0] & 0xf0) === 0xe0 : o[0] === 0xff;
  }
  /** RFC 1918 (10/8, 172.16/12, 192.168/16) or the unique-local range fc00::/7. */
  isPrivate() {
    const o = this.#octets;
    return o.length === 4
      ? o[0] === 10 || (o[0] === 172 && (o[1] & 0xf0) === 16) || (o[0] === 192 && o[1] === 168)
      : (o[0] & 0xfe) === 0xfc;
  }
  /** 169.254.0.0/16 or fe80::/10. */
  isLinkLocal() {
    const o = this.#octets;
    return o.length === 4 ? o[0] === 169 && o[1] === 254 : o[0] === 0xfe && (o[1] & 0xc0) === 0x80;
  }
  /** The documentation ranges: 192.0.2/24, 198.51.100/24, 203.0.113/24 and 2001:db8::/32. */
  isDocumentation() {
    const o = this.#octets;
    if (o.length === 4)
      return (
        (o[0] === 192 && o[1] === 0 && o[2] === 2) ||
        (o[0] === 198 && o[1] === 51 && o[2] === 100) ||
        (o[0] === 203 && o[1] === 0 && o[2] === 113)
      );
    return o[0] === 0x20 && o[1] === 0x01 && o[2] === 0x0d && o[3] === 0xb8;
  }
  /** `::ffff:a.b.c.d` becomes the v4 address `a.b.c.d`; anything else is itself. Permission checks must use it. */
  toCanonical() {
    const o = this.#octets;
    if (o.length === 16 && o.slice(0, 10).every(b => b === 0) && o[10] === 0xff && o[11] === 0xff) return new IpAddr(token, o.slice(12));
    return this;
  }
  equals(other) {
    if (!(other instanceof IpAddr)) return false;
    const a = this.#octets;
    const b = other.#octets;
    return a.length === b.length && a.every((x, i) => x === b[i]);
  }
  toString() {
    return this.#octets.length === 4 ? v4Text(this.#octets) : v6Text(this.#octets);
  }
}

export class SocketAddr {
  #ip;
  #port;
  constructor(made, ip, port) {
    if (made !== token) throw new TypeError('use SocketAddr.new or parse');
    this.#ip = ip;
    this.#port = port;
    seal(this);
  }
  static new(ip, port) {
    if (!(ip instanceof IpAddr)) throw new TypeError('ip must be an IpAddr');
    if (!Number.isInteger(port) || port < 0 || port > 65535) throw new TypeError('port must be an integer in 0..65535');
    return new SocketAddr(token, ip, port);
  }
  /** `1.2.3.4:53` or `[::1]:853`, as Rust's `SocketAddr::from_str`: v6 needs brackets, v4 must not have them. */
  static parse(text) {
    const family = native.addr.parseSocket(text, scratch);
    if (!family) throw new TypeError(`invalid socket address: ${JSON.stringify(text)}`);
    return new SocketAddr(token, new IpAddr(token, familyOctets(family)), scratchPort[0]);
  }
  get ip() {
    return this.#ip;
  }
  get port() {
    return this.#port;
  }
  equals(other) {
    return other instanceof SocketAddr && this.#port === other.#port && this.#ip.equals(other.#ip);
  }
  toString() {
    return this.#ip.isV6() ? `[${this.#ip}]:${this.#port}` : `${this.#ip}:${this.#port}`;
  }
}

seal(IpAddr, SocketAddr);
provide('net/addr', { IpAddr, SocketAddr });
