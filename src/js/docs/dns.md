# `api.dns`: address lookups

`api.dns` exists wherever `api.net` does and is built with `-Ddns` (on by default; without it the getter throws `PermissionDenied`). It resolves a name to addresses (A and AAAA) through servers you name, over UDP, TCP, TLS (DoT) or HTTPS (DoH). The wire codec is hickory-proto; the resolver logic is ours ([`origine_dns`](../../../rust/crates/origine_dns/docs/README.md)); natives in [natives.md](../../../rust/crates/origine_api/docs/natives.md#dns-needs--runtime). Design: [docs/http-design.md](../../../docs/http-design.md).

```js
import { SocketAddr } from 'origine:@std/net';

const { dns } = api;
const resolver = dns.resolver(io, {
  servers: [dns.DnsServer.udp([SocketAddr.parse('127.0.0.1:5353')])],
  dnssec: 'off', timeout: 2000, tries: 2,
});
const addresses = await resolver.lookup('example.test', { family: 'any' });   // IpAddr[], IPv6 first
console.log(addresses.map(String));
await resolver.close();
```

## Addresses

`IpAddr` and `SocketAddr` are not part of `api.dns`: they are plain value types, so they live in `origine:@std/net` ([addr.md](addr.md)) and `api.dns` neither re-exports them nor has a second spelling (one obvious way). `Resolver.lookup` returns that module's `IpAddr` instances and `DnsServer` takes them.

## Servers and resolvers

`DnsServer` says how one server is reached: `udp(servers)`, `tcp(servers)`, `tls(name, servers)` (DoT; `name` is what the server's certificate must be valid for), `https(url, servers)` (DoH) or `system()`. `servers` hold `IpAddr` (the transport's default port: 53, 853 for TLS, the URL's port for HTTPS) or `SocketAddr` values. `dns.resolver(io, { servers, roots?, dnssec, timeout, tries, cache? })` makes a `Resolver`; **every option but `roots` and `cache` is required**: `timeout` is milliseconds per attempt at one address, `tries` the rounds over all servers, `roots` (a `RootPki`) is required with `tls` and `https`, `cache` (below) is absent for no caching, and `dnssec: 'validate'` is `Unsupported` until validation exists. `Resolver` is a class defined in Rust (`new Resolver()` is a `TypeError`; frozen; its members refuse other objects): the native resolver is owned by the instance and freed when it is collected, or at once by `close()` (or `await using`); lookups in flight finish.

- **Servers are subject to the [network ceiling](../../../docs/net-grant.md).** A resolver opens sockets of its own, so each server address (an IPv4-mapped one is checked as the IPv4 address) must be allowed by a `connect` rule, or `dns.resolver` rejects with `PermissionDenied` and the address as the detail; the same check runs again before every query. By default only loopback passes, so `system()` on a machine whose `/etc/resolv.conf` names a LAN resolver needs `--net-connect=<its address>@53` (or the embedder's rule).
- **`system()`** reads `/etc/resolv.conf` (nameservers on port 53 over UDP, the search list, `ndots`) and `/etc/hosts` when the resolver is made; other servers in the list add to them. Explicit servers do not read the hosts file.
- **`lookup(name, { family })`**: `family` (`'ipv4' | 'ipv6' | 'any'`) is required. In order: an IP literal is itself; `localhost` and `*.localhost` are the loopback addresses (RFC 6761, never asked of a server); the hosts file; then the servers in order, `tries` rounds, trying search domains as `ndots` says (a trailing dot makes a name absolute). A UDP answer that does not fit (TC) is asked again over TCP at the same address. Answers must carry our id and question or they are ignored. Names must be ASCII (`InvalidInput`; no IDNA yet).
- **`https(url, servers)`** is DNS over HTTPS (RFC 8484): each query is one HTTP/2 `POST` of the DNS message (`content-type` and `accept` `application/dns-message`, query id 0) to `url`. `url` is a string `https://host[:port][/path][?query]`: a host name or IPv4 address (lowercased; it is what the certificate must be valid for and the `:authority`), no userinfo, no fragment, no brackets (`TypeError` otherwise). It reaches `servers` directly, so DoH never needs DNS to find the server; the server must negotiate `h2` (else `Unsupported`, there is no HTTP/1 fallback). **Cost:** every query opens its own TCP connection, TLS handshake and HTTP/2 connection and closes them after the answer, as DoT does; nothing stays open between lookups, so an idle resolver does not keep the program alive (a cache is the way to spare connections). A status other than 200 is `ServerFailure` (`subject`: `HTTP status 503`; redirects are not followed), a body that is not `application/dns-message` or is over 65535 bytes is `ProtocolError`. It needs a build with `-Dhttp` and `-Dtls` (`Unsupported` at `dns.resolver` otherwise). `api.http` is not involved: it uses the same `origine_h2` and `origine_tls` crates beneath.
- **`cache`** is `{ limit, ttl: { min, max }, negative: { min, max } }`: `limit` entries (at least 1), the rest in milliseconds, **all required, no defaults**. Absent means every lookup asks the servers. Shared by every lookup of one resolver, keyed by lowercased name and family. A positive answer is kept for its shortest record TTL (CNAMEs on the way count) raised to `ttl.min` and cut to `ttl.max`; a negative answer (NXDOMAIN, or no record of that type) for the smaller of the SOA's TTL and MINIMUM (RFC 2308) clamped by `negative`; one without a SOA is not kept, and `negative.max: 0` turns negative caching off. SERVFAIL and transport errors are never kept. When full, the entry nearest to expiry makes room (a copy of the answer costs memory: `limit` bounds it). Literals, `localhost` and the hosts file are never asked, so never cached. `min` and `max` must satisfy `min <= max` (`TypeError`).
- **Errors.** `NotFound` (`subject`: the name; NXDOMAIN, or no address of that family), `TimedOut`, `ServerFailure` (`subject`: `SERVFAIL`, `REFUSED`, ...), `ProtocolError` (an answer that is not about our question), `InvalidInput`, `PermissionDenied`, the transport's own (`ConnectionRefused`, ...), and for DoT the TLS errors of [tls.md](tls.md) (`CertificateRejected`, ...).
- **Not yet:** DNSSEC, DoQ, record types other than A and AAAA, EDNS, `api.net.udp`. Answers are unauthenticated input.

## Presets

`import { presets } from 'origine:@std/dns/presets'` is data in its own module, not part of `DnsServer`: `presets.cloudflare`, `cloudflareMalware`, `cloudflareFamily`, `adguard`, `google` and `quad9`, each frozen with `name`, `servers` (its `IpAddr` values, IPv4 first) and the methods `udp()`, `tcp()`, `tls()` and `https()`. A method makes a **new** `DnsServer` with the realm's public constructors (`presets.cloudflare.tls()` is `DnsServer.tls('one.one.one.one', presets.cloudflare.servers)`), so it costs and needs what they do: `roots` for `tls` and `https`, and an embedder `connect` rule for the public addresses (loopback is the only thing allowed by default; `dns.resolver` rejects with `PermissionDenied` otherwise). A transport a provider does not offer has no method (every preset has all four; none has `quic` yet). The table (addresses, TLS names, DoH URLs) is pinned by a test. Cloudflare Malware, Cloudflare Family, AdGuard and Quad9 **filter**: names they block resolve to nothing or to an address of their own. Presets are never a default: `servers` is always explicit.

| key | name | IPv4 | DoT name | DoH URL |
| --- | --- | --- | --- | --- |
| `cloudflare` | Cloudflare | 1.1.1.1, 1.0.0.1 | one.one.one.one | https://cloudflare-dns.com/dns-query |
| `cloudflareMalware` | Cloudflare Malware | 1.1.1.2, 1.0.0.2 | security.cloudflare-dns.com | https://security.cloudflare-dns.com/dns-query |
| `cloudflareFamily` | Cloudflare Family | 1.1.1.3, 1.0.0.3 | family.cloudflare-dns.com | https://family.cloudflare-dns.com/dns-query |
| `adguard` | AdGuard (default mode) | 94.140.14.14, 94.140.15.15 | dns.adguard-dns.com | https://dns.adguard-dns.com/dns-query |
| `google` | Google | 8.8.8.8, 8.8.4.4 | dns.google | https://dns.google/dns-query |
| `quad9` | Quad9 (recommended) | 9.9.9.9, 149.112.112.112 | dns.quad9.net | https://dns.quad9.net/dns-query |
