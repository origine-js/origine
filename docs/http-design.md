# HTTP/2, TLS, DNS and QUIC: design

Status: **in progress.** Done: `origine_tls`, `origine_h2` (+ async driver), `origine_transport`, `api.net.udp`'s loop ops tested, the `api.tls` natives and JS glue (pull and event mode, `-Dtls`), and the `api.http` natives and JS glue (HTTP/2 sessions over `api.net` or `api.tls` sockets, pull and event mode, `-Dhttp`). `http.connect` / `http.serve` (no `cleartext` option: a `TlsServer` makes every connection TLS and no `tls` means h2c). `api.dns` (`IpAddr`, `SocketAddr`, `DnsServer.system/udp/tcp/tls`, `Resolver.lookup`; servers subject to the network ceiling; no cache, DNSSEC, DoH or DoQ). Not yet: `api.quic`.

Original status: **draft, first slice not implemented.** Scope: an HTTP/2 client and server (`api.http`) behind a build flag that is **on by default**, `api.tls`, `api.dns`, and interface-only declarations for `api.quic` and `api.net.udp`. Every public name is subject to [api-guidelines.md](api-guidelines.md); the shapes follow [`api.net`](../src/js/docs/net.md) (`mode: 'pull' | 'event'`, `queued` / `direct` write lanes, `end(side)`).

## Decisions

| Area | Decision | Why |
|---|---|---|
| HTTP versions | **HTTP/2 only** (h2 over TLS by ALPN; h2c prior-knowledge on loopback). HTTP/1.x is out for now | one framing layer to get right; h2c covers certificate-free loopback tests |
| h2 core | **nghttp2** (sans-io C, Zig recipe in `lt-zcurl/build/nghttp2.zig`) | header callbacks per field; no socket or loop of its own |
| TCP TLS | **rustls on aws-lc-rs** | Rust is core to the build; sans-io `read_tls` / `write_tls` |
| QUIC / h3 (later) | **ngtcp2 + nghttp3** | ngtcp2 1.22.1 backends are BoringSSL / aws-lc >= 1.39, OpenSSL, quictls, GnuTLS, wolfSSL, picotls: **no rustls**. QUIC therefore links a C aws-lc (Zig-built) beside the one inside aws-lc-rs: two copies, accepted for now (see open questions) |
| DNS | **hickory-proto** as wire codec only; our own thin resolver | c-ares 1.34.6 has no DoT/DoH/DNSSEC (its docs say the schemes exist but are "not yet implemented"); hickory-resolver needs tokio and `Send` futures |
| Loop risk | `oio` is unproven, so engines are sans-io behind a `Transport` trait and tested over in-memory pipes separately from loop tests | protocol bugs and loop bugs stay separable |
| uSockets / uWS | rejected for now | readiness-only (epoll/kqueue/libuv backends, own loop-wide recv buffer); would need an `oio` poll op, a second socket world, and loses zero-copy receives |
| Size | default release build <= 70 MB, CI-enforced | measured baseline `zig build -Doptimize=small`: **40.1 MB** (the 82 MB `zig-out` binary is a debug-app build) |

## Reference runtimes (checked against local clones)

- **Deno** (`e7b39ebd55`): `hyper` 1.x in `ext/http`; `reqwest` / `hyper-rustls` in `ext/fetch`; `rustls` on `aws-lc-rs`; `quinn` (tokio) in `ext/net/quic.rs` for the unstable QUIC API, no h3 in HTTP or fetch; `hickory-resolver` 0.25.2 with only `tokio` + `serde` features (no DoT/DoH/DNSSEC). All on tokio.
- **Bun** (`3f3a9ff8`): BoringSSL + vendored uSockets/uWS (`packages/bun-usockets`, `packages/bun-uws`, Apache-2.0); `Bun.serve` h1 plus experimental `http2` and `http3` (lsquic with 16 local patches in `patches/lsquic/`); the client in `src/http` has `H2Client.rs` (lshpack) and `H3Client.rs` (lsquic + lsqpack); picohttpparser; c-ares for DNS.
- Neither has a low-level layer (TLS socket, QUIC stream, exchange with explicit head/body). That is the gap here.

## Architecture

```
  origine:@std/net   IpAddr · SocketAddr          origine:@std/dns/presets   presets.*  (static data, own module)
  api.dns   Resolver ── DnsServer(udp | tcp | tls | https | quic)       origine_dns   (hickory-proto codec + resolver logic)
  api.http  session · connect · serve   (h2)                          origine_h2    (nghttp2 + session state machine)
  api.tls   client · server             (rustls)                      origine_tls   (rustls over a Transport trait)
  api.quic  (types only)  api.net.udp (types, then natives)           origine_quic  (later: ngtcp2 + nghttp3)
  api.net   TCP (exists)   ──────────────  oio loop (io_uring · kqueue · threaded)
```

Each protocol is an internal Rust crate; the JS natives and the DNS resolver sit on the same crates, so a lookup over DoT never goes through JS. Engines talk to the world only through `Transport` (read bytes, write bytes), implemented over `origine_io` op futures in production and over in-memory pipes in tests.

### Build flags

Plumbed like `-Dtypescript`. C dependencies are Zig `lazyDependency` packages, so a disabled flag fetches none of them.

| Flag | Default | Effect |
|---|---|---|
| `-Dhttp` | `true` | `api.http`, nghttp2. Implies `tls` for `https:` |
| `-Dtls` | `true` | `api.tls`, rustls + aws-lc-rs |
| `-Ddns` | `true` | `api.dns` |
| `-Dquic` | `true` while <= 70 MB holds, else `false` | `api.quic`, `api.net.udp`, ngtcp2 + nghttp3 (not in the first slice) |

With a flag off the natives are not registered and the API name is **absent** (`api.http === undefined`); nothing returns a weaker object. CI builds the default and an all-off configuration and fails above 70 MB.

## Interface (first slice)

Values are frozen classes with named constructors; parsing and validation happen in the factory, so a bad certificate or address fails there with its own error.

```ts
// origine:@std/net, Rust vocabulary in camelCase
class IpAddr {                                   // one class: v4 = [u8; 4], v6 = [u8; 16]
  static v4(a, b, c, d): IpAddr;  static v6(...segments /* 8 x u16 */): IpAddr;
  static fromOctets(octets: Uint8Array /* 4 or 16 bytes */): IpAddr;  static parse(text: string): IpAddr;
  readonly family: 4 | 6;  octets(): Uint8Array /* fresh copy */;
  isV4(); isV6(); isUnspecified(); isLoopback(); isMulticast(); isPrivate(); isLinkLocal(); isDocumentation();
  toCanonical(): IpAddr;   // ::ffff:a.b.c.d -> a.b.c.d; permission checks must use it
  equals(other): boolean;  toString(): string;
}
class SocketAddr { static new(ip: IpAddr, port: number): SocketAddr; static parse(text: string): SocketAddr; readonly ip: IpAddr; readonly port: number; toString(): string }

class RootPki    { static bundled();  static fromPem(pem: Uint8Array);  static fromDer(certs: Uint8Array[]) }
class Identity   { static fromPem(cert: Uint8Array, key: Uint8Array);  static fromDer(o: { cert: Uint8Array[]; key: Uint8Array }) }
class ClientAuth { static none();  static require(roots: RootPki) }
class TlsSessions{ static create(o: { limit: number }) }                 // resumption cache is explicit
class HeaderList { put(name, value): void; get; getAll; has; length; [Symbol.iterator] }   // ordered fields, not a map

// api.tls
tls.client({ roots: RootPki, identity?: Identity, alpn?: string[], sessions?: TlsSessions }): TlsClient
tls.server({ identities: Identity[], clientAuth: ClientAuth, alpn?: string[] }): TlsServer
TlsClient.connect(socket, { servername, mode }) / TlsServer.accept(socket, { mode })   // consume the plain socket
// connect/accept resolve a plain Socket<M> (a TLS endpoint inside the socket table); tls.info(socket) = alpn, version, peer. close_notify on end('write'); EOF without it is an error.

// api.http (HTTP/2)
http.session(socket, { role: 'client' | 'server', mode, limits })                     // core: h2 over a stream you provide
http.connect(io, { host, port, tls?, resolver, mode, limits }): Promise<ClientSession> // dial + TLS(ALPN h2), or h2c without tls
http.serve(io, { listen, tls?, mode, limits })                                        // tls present: all TLS; absent: cleartext h2c
limits: { streams, headers, window, batch }                                            // bytes, all required
```

**Headers are a stream of fields, not a map.** Sending: `put` packs into one JS buffer and the whole list crosses once at `open` / `start` / `respond` (nghttp2's HPACK encoder wants the full list, so on the wire it is one HEADERS block; the stream is the API shape). Receiving: nghttp2 calls back per decoded field into a packed buffer, delivered as `HeaderList` batches when the block ends or `limits.batch` bytes accumulate: `await ex.headers.read()` gives the next batch (`undefined` at the end), `ex.headers.collect()` waits and returns one list bounded by `limits.headers`. `headers: 'whole'` on `serve` delivers the exchange with the full list (one crossing per request); `'stream'` delivers it at the first batch. Pseudo-headers are separate fields on the exchange. Flow control is the backpressure: reading a body returns window credit.

Exchanges: `ClientSession.open` / `request`, `ClientExchange` (`status`, `headers`, `body` as PullSocket-like, `upload` for streamed request bodies, `trailers`, `reset(code)`), `ServerExchange` (`respond` = whole response in one write, `start` = streamed, `reset(code)`). The exact surface is written in `src/js/docs/http.md` with the implementation.

### DNS

```ts
class DnsServer {        // one transport each; Resolver takes an ordered list
  static system();
  // servers: (IpAddr | SocketAddr)[]: an IpAddr means the transport's default port (udp/tcp 53, tls 853, https 443, quic 853)
  static udp(servers);  static tcp(servers);
  static tls(name: string, servers);        // first slice
  static https(url: URL, servers);          // with api.http
  static quic(name: string, servers);       // with api.quic
}
dns.resolver(io, { servers: DnsServer[], roots?: RootPki, dnssec: 'off' | 'validate', timeout, tries })   // 'validate' is Unsupported until built
Resolver.lookup(name, { family: 'ipv4' | 'ipv6' | 'any' }): Promise<IpAddr[]>
```

Servers carry their own IPs, so DoH and DoQ never need DNS to find the server. DNS answers are unauthenticated input unless `dnssec: 'validate'` (hickory-proto gives verification primitives; chain walking and denial of existence are ours to write, later). The resolver opens its own sockets, so the server list is part of the embedder's permission ceiling.

**Presets** are data in their own module, not part of `DnsServer`: `import { presets } from 'origine:@std/dns/presets'` gives `presets.cloudflare`, `cloudflareMalware`, `cloudflareFamily`, `adguard`, `google`, `quad9`, each with `.name`, `.servers` and one method per transport it offers (`presets.cloudflare.tls()`); a method for a transport a preset lacks is absent (`presets.google.quic === undefined`). Each method calls the public `DnsServer` constructors. The address and name table is pinned in a test and must be verified against each provider's published docs when written; the filtering ones change answers and the docs say so. Presets are never a default: `servers` is always explicit.

## Permission model

Built: the embedder's **network ceiling** ([net-grant.md](net-grant.md)): `connect` and `listen` rules over CIDR ranges and ports, checked on the canonicalised address a program is about to use, loopback only by default. It covers `api.net`, everything built on it (`api.tls`, `api.http`) and the servers of `api.dns` resolvers (at creation and per query). Decisions that differ from the first sketch: rules are about **addresses, not names** (a name could resolve anywhere, so `api.net` takes literals and `api.dns` results), and there is no per-request narrowing yet (that would be `api.net.narrow` for a child scope or isolate). `localhost` stays unresolved (RFC 6761). Still to do: redirects re-checking each hop (there are none yet) and a connection or rate limit.

## Phasing

| Phase | Deliverable | Exit test |
|---|---|---|
| 0 | aws-lc + rustls cross-compile for every `build.zig` target with size delta; nghttp2 Zig build; `oio` UDP `sendmsg` / `recvmsg` smoke test | builds everywhere; default release <= 70 MB |
| 1 | `origine:@std/net` addresses; `origine_tls`, `api.tls`; `origine_h2`, `api.http` on loopback (h2c and TLS) | `curl --http2-prior-knowledge`, `h2spec`, self-test client <-> server |
| 2 | `origine_dns`, `api.dns` (system, udp, tcp, tls), presets, `api.net.udp` | lookups against local fixture servers; presets table test |
| 3 | net grant (done), pool, redirects, DoH | SSRF suite |
| 4 | `api.quic` (ngtcp2 + nghttp3), DoQ, DNSSEC validation | `quic-interop-runner` subset, `curl --http3` |

## Open questions

1. **Unify aws-lc.** QUIC needs a C aws-lc (ngtcp2 helper); rustls brings its own. Options after Phase 0: accept two copies; use the C libssl for TCP TLS too; or write ngtcp2 crypto callbacks over rustls. Check whether `aws-lc-sys` can expose libssl.
2. **`URL`.** No URL class exists in origine; `DnsServer.https` needs a minimal https-only parser or takes `{ host, port, path }`.
3. **System roots.** `RootPki.system()` waits on per-OS loading (Security.framework etc.); `bundled()` first.
4. **UDP on `oio`.** Tested in `src/io/udp_test.zig` (macOS: kqueue and threaded backends; IPv4 and IPv6 loopback): datagram boundaries, sender address, truncation flag, cancel and in-order delivery all hold. Findings the UDP layer must respect: an empty datagram completes with 0 (not an end of stream), and concurrent sends on one socket are unordered on the threaded backend and on blocking descriptors, so `api.net.udp` keeps one send in flight per socket. Still untested: the io_uring path (needs a Linux run of `zig build test-io`).
5. **`system()` on macOS** (VPN / scoped resolvers): verify what the resolv.conf view misses.
