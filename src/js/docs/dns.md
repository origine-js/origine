# `api.dns`: address lookups

`api.dns` exists wherever `api.net` does and is built with `-Ddns` (on by default; without it the getter throws `PermissionDenied`). It resolves a name to addresses (A and AAAA) through servers you name, over UDP, TCP or TLS (DoT). The wire codec is hickory-proto; the resolver logic is ours ([`origine_dns`](../../../rust/crates/origine_dns/docs/README.md)); natives in [natives.md](../../../rust/crates/origine_api/docs/natives.md#dns-needs--runtime). Design: [docs/http-design.md](../../../docs/http-design.md).

```js
const { dns } = api;
const resolver = dns.resolver(io, {
  servers: [dns.DnsServer.udp([dns.SocketAddr.parse('127.0.0.1:5353')])],
  dnssec: 'off', timeout: 2000, tries: 2,
});
const addresses = await resolver.lookup('example.test', { family: 'any' });   // IpAddr[], IPv6 first
console.log(addresses.map(String));
await resolver.close();
```

## Addresses

`IpAddr` is one class for both families (v4 = 4 octets, v6 = 16), in Rust's vocabulary: `IpAddr.v4(a,b,c,d)`, `v6(...8 segments)`, `fromOctets`, `parse`, `family`, `octets()`, `isV4`, `isV6`, `isUnspecified`, `isLoopback`, `isMulticast`, `isPrivate`, `isLinkLocal`, `isDocumentation`, `toCanonical()` (`::ffff:a.b.c.d` becomes `a.b.c.d`; **permission checks must use it**, an IPv4-mapped address is not loopback until then), `equals`, `toString` (RFC 5952 for v6). `parse` takes `1.2.3.4` or `::1` only (no port, brackets, zone, leading zeros). `SocketAddr` is an `IpAddr` and a port: `new`, `parse` (`1.2.3.4:53`, `[::1]:853`), `ip`, `port`. Both are frozen and made by named constructors (`TypeError` for bad input). For now they live on `api.dns`; they are meant to be shared with `api.net` and `api.tls`.

## Servers and resolvers

`DnsServer` says how one server is reached: `udp(servers)`, `tcp(servers)`, `tls(name, servers)` (DoT; `name` is what the server's certificate must be valid for), or `system()`. `servers` hold `IpAddr` (the transport's default port: 53, or 853 for TLS) or `SocketAddr` values. `dns.resolver(io, { servers, roots?, dnssec, timeout, tries })` makes a `Resolver`; **every option but `roots` is required**: `timeout` is milliseconds per attempt at one address, `tries` the rounds over all servers, `roots` (a `RootPki`) is required with `tls`, and `dnssec: 'validate'` is `Unsupported` until validation exists.

- **Servers must be loopback for now.** A resolver opens sockets of its own, which are not `api.net` sockets, and there is no embedder permission for the wider network yet, so a non-loopback server (an IPv4-mapped one included) is `PermissionDenied` at `dns.resolver`, with the address as the detail. That includes `system()` on a machine whose `/etc/resolv.conf` names a LAN resolver. The net grant lifts this.
- **`system()`** reads `/etc/resolv.conf` (nameservers on port 53 over UDP, the search list, `ndots`) and `/etc/hosts` when the resolver is made; other servers in the list add to them. Explicit servers do not read the hosts file.
- **`lookup(name, { family })`**: `family` (`'ipv4' | 'ipv6' | 'any'`) is required. In order: an IP literal is itself; `localhost` and `*.localhost` are the loopback addresses (RFC 6761, never asked of a server); the hosts file; then the servers in order, `tries` rounds, trying search domains as `ndots` says (a trailing dot makes a name absolute). A UDP answer that does not fit (TC) is asked again over TCP at the same address. Answers must carry our id and question or they are ignored. Names must be ASCII (`InvalidInput`; no IDNA yet).
- **Errors.** `NotFound` (`subject`: the name; NXDOMAIN, or no address of that family), `TimedOut`, `ServerFailure` (`subject`: `SERVFAIL`, `REFUSED`, ...), `ProtocolError` (an answer that is not about our question), `InvalidInput`, `PermissionDenied`, the transport's own (`ConnectionRefused`, ...), and for DoT the TLS errors of [tls.md](tls.md) (`CertificateRejected`, ...).
- **Not yet:** a cache, DNSSEC, DoH and DoQ, record types other than A and AAAA, EDNS, `api.net.udp`. Answers are unauthenticated input.
