// Run: zig build run -- examples/std/net-addr/init.js   (or: zig-out/bin/origine examples/std/net-addr/init.js)
// IpAddr and SocketAddr are value types from origine:@std/net: they parse, print and classify addresses, and open
// nothing, so they need no capability. api.dns and api.net take and return these very instances.
//
// Prints (stderr):
//   v4 loopback: 127.0.0.1 ; isLoopback: true
//   IPv4-mapped IPv6 is not loopback until canonical: false, then true
//   socket address: [::1]:853 port 853
//   IpAddr.v4 from octets copies them: 10.0.0.1 private: true
//   a bad address is a TypeError: true
import { IpAddr, SocketAddr } from 'origine:@std/net';
import { eprintln } from 'origine:@std/debug';

export function main() {
  const loopback = IpAddr.v4(127, 0, 0, 1);
  eprintln(`v4 loopback: ${loopback} ; isLoopback: ${loopback.isLoopback()}`);

  const mapped = IpAddr.parse('::ffff:127.0.0.1');
  eprintln(`IPv4-mapped IPv6 is not loopback until canonical: ${mapped.isLoopback()}, then ${mapped.toCanonical().isLoopback()}`);

  const socket = SocketAddr.parse('[::1]:853');
  eprintln(`socket address: ${socket} port ${socket.port}`);

  const octets = Uint8Array.from([10, 0, 0, 1]);
  const ten = IpAddr.fromOctets(octets);
  octets[0] = 0;   // fromOctets copied the bytes
  eprintln(`IpAddr.fromOctets copies them: ${ten} private: ${ten.isPrivate()}`);

  let bad = false;
  try {
    IpAddr.parse('10.0.0.256');
  } catch (e) {
    bad = e instanceof TypeError;
  }
  eprintln('a bad address is a TypeError:', bad);
}
