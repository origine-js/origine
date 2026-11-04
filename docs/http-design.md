# TLS, HTTP/2 and DNS: design

Why `api.tls`, `api.http` and `api.dns` look the way they do, what was built, and what is still planned. The reference for each API is its doc: [tls.md](../src/js/docs/tls.md), [http.md](../src/js/docs/http.md), [dns.md](../src/js/docs/dns.md), [addr.md](../src/js/docs/addr.md) (`origine:@std/net`) and [net-grant.md](net-grant.md); this file keeps the decisions and the reasons, and does not repeat the call-by-call behaviour. Every public name follows [api-guidelines.md](api-guidelines.md); the shapes follow [`api.net`](../src/js/docs/net.md) (`mode: 'pull' | 'event'`, `queued` write lane, `end(side)`).

## Status

| Area | State |
| --- | --- |
| `api.tls` | Built: TLS 1.2/1.3 over any stream (native, TLS over TLS, or duck-typed JS), `TlsStreamUnshaped` / `PullTlsStream` / `EventTlsStream`, Rust-defined classes |
| `api.http` | Built: HTTP/2 sessions, `connect` / `serve`, pull and event mode, client pool, redirects, `fetch` |
| `api.dns` | Built: `system`, `udp`, `tcp`, DoT, DoH, resolver cache, presets (`origine:@std/dns/presets`) |
| `origine:@std/net` | Built: `IpAddr`, `SocketAddr` |
| Network ceiling | Built, see [net-grant.md](net-grant.md) |
| `io` in native | Built (stage 1 of the io/http redesign): `Io` class, `io.timer` / `io.tcp` / `io.udp`, unshaped and shaped native objects, native event hub, `Transport` bridge; see [io in native](#io-in-native) |
| QUIC, HTTP/3, DoQ | Planned: [quic-design.md](quic-design.md) (datagrams are `io.udp.bind`) |
| DNSSEC, HTTP/1.x, WebSocket, cookies, caching, decompression, `RootPki.system()`, `URL` | Not built (see [Not built](#not-built)) |

## Decisions

| Area | Decision | Why |
| --- | --- | --- |
| HTTP versions | **HTTP/2 only**: h2 over TLS by ALPN, cleartext h2c for loopback and tests. No HTTP/1.x | one framing layer to get right; h2c gives certificate-free tests. Cost: a server that only speaks HTTP/1 is unreachable (`NoApplicationProtocol`) |
| h2 core | **nghttp2** (sans-io C, built by Zig in `lib/nghttp2`), wrapped in `origine_h2` | header callbacks per field; no socket or loop of its own |
| TLS | **rustls on aws-lc-rs** (`origine_tls`); the vendored aws-lc-sys is patched to link the AWS-LC that Zig builds in `lib/aws-lc` ([aws-lc.md](aws-lc.md)) | Rust is core to the build; sans-io `read_tls` / `write_tls` |
| DNS | **hickory-proto as the wire codec only**; the resolver logic is ours (`origine_dns`) | c-ares has no DoT/DoH/DNSSEC; hickory-resolver needs tokio and `Send` futures, we have a single-threaded `oio` loop |
| Engines vs loop | every protocol engine is sans-io behind the `Transport` trait of `origine_transport` (owned buffers, `!Send` futures) | protocol bugs and loop bugs stay separable: engines are tested over in-memory pipes, then over sockets |
| uSockets / uWS | rejected | readiness-only; would need a second socket world beside `oio` and loses zero-copy receives |
| Rust-defined classes | values with native state are classes defined in Rust (`#[class]`), owned by V8's cppgc heap | see [Values](#values-and-ownership) |
| Names | the network ceiling is about **addresses**; `api.net` and `api.http.connect` take IP literals, `api.dns` turns names into addresses | a name could resolve anywhere, so a check on names proves nothing |
| Size | default release build at most 70 MB stripped (`just check-size`) | a runtime that is a single download. A local `-Doptimize=small` run on 2026-11-02 measured 43,852,304 bytes with every flag on, against 40.1 MB before the networking crates (44,092,784 bytes once AWS-LC came from `lib/aws-lc`, +41,680 bytes, [aws-lc.md](aws-lc.md)); no CI job runs it yet |

## Architecture

```
  origine:@std/net   IpAddr · SocketAddr        origine:@std/dns/presets   presets.*  (data)
  api.dns   Resolver · DnsServer                origine_dns   (hickory-proto codec + resolver logic)
  api.http  session · connect · serve · pool · fetch   origine_h2    (nghttp2 + session state machine + async driver)
  api.tls   client · server                     origine_tls   (rustls over a Transport)
  io.tcp · io.udp  (api.net: the classes)       origine_transport   (the Transport trait; sockstream.rs bridges native streams)
                       oio loop (io_uring · kqueue · threaded)
```

Each protocol is an internal Rust crate; the natives (`rust/crates/origine_api`) and the DNS resolver sit on the same crates, so a lookup over DoT or DoH never goes through JS: `origine_api` implements the resolver's `Exchange` over UDP, TCP, `origine_tls` and `origine_h2` directly, and `api.http` is not involved in DoH. `api.tls` and `api.http` take a native stream (a TCP or TLS stream, unshaped or idle shaped) and consume it: the engine reads and writes its socket in Rust (`sockstream.rs`, the `Transport` bridge) without entering JS. A TLS handshake makes a `TlsStreamUnshaped`, whose shaped classes share the members (and the Rust code) of the TCP ones; a TLS stream is itself a native stream, so TLS over TLS and h2 over TLS go through the same bridge. `api.tls` also takes a duck-typed JS stream through a slower adapter. There is no socket table: every network object is a cppgc instance (see [io in native](#io-in-native)).

### Build flags

| Flag | Default | Effect |
| --- | --- | --- |
| `-Dhttp` | `true` | `api.http`; builds and links nghttp2 (`lib/nghttp2`, a lazy dependency: a disabled flag fetches nothing) |
| `-Dtls` | `true` | `api.tls`; rustls, and AWS-LC's libcrypto built and linked by Zig (`lib/aws-lc`; [aws-lc.md](aws-lc.md)) |
| `-Ddns` | `true` | `api.dns` |
| `-Dquic` | `true`, needs `-Dtls` | reserved; gates nothing yet (see [quic-design.md](quic-design.md)) |

A flag selects a Rust feature of `origine_native` and what Zig builds. With a flag off the natives are not registered and the getter throws `PermissionDenied` (`api.http` is not `undefined`: the capability objects are fixed, so an absent feature fails when reached, never returns a weaker object). DoH needs both `-Dhttp` and `-Dtls` and is `Unsupported` at `dns.resolver` otherwise.

## Values and ownership

`RootPki`, `Identity`, `ClientAuth`, `TlsSessions`, `TlsClient`, `TlsServer` and `Resolver` hold native state. They are **classes defined in Rust** (`#[class]`, `origine_api/src/class.rs`) and **owned by the cppgc heap** (`gc.rs`):

- The JS object is the owner; there is no JS wrapper around an integer id. When it is collected the Rust value is dropped. Anything built from it takes its own `Clone` (the values are `Arc`-backed immutable data), so collecting a `RootPki` never breaks a live `TlsClient`. This replaced a `FinalizationRegistry` over numeric ids ([cppgc-research.md](cppgc-research.md) has the V8 and Deno findings behind it).
- A class is one `FunctionTemplate` per isolate, made on first use, never in a snapshot (a wrapped object reachable from a snapshot has no serializer). Hence `tls` and `dns` are built when the capability is bound, not at snapshot time (`late` in `glue/index.js`).
- Construction is by **named constructor only** (`RootPki.fromPem`): `new RootPki()` is a `TypeError`, so parsing and validation happen where the value is made and a bad certificate fails there with its own error. Classes and prototypes are frozen; a member called on anything but an instance (or an argument of the wrong class) is a `TypeError`: the brand check is the cppgc unwrap.
- `Drop` runs inside a collection, possibly while a native holds the host state, so the values are plain self-contained data and never touch V8 or a table.
- Early release is explicit and visible: `release()` on the TLS values, `close()` / `await using` on a `Resolver` (lookups in flight finish). Sockets, servers and sessions are not GC-owned: they are handles that keep the program alive and are closed explicitly.
- Not every class is Rust-defined: `HeaderList`, `DnsServer`, `IpAddr` and `SocketAddr` are plain JS values with no native state.

## io in native

The whole io layer is native and owned by the cppgc heap; the JS glue only installs the classes and adds the few
members that need JS (async iterators, `Symbol.asyncDispose`, `buffer()` making a `Lease`).

- **`Io` holds factories and loop-wide operations.** `api.io.create()` returns an `Io` (Rust class) with `run()`,
  `close()`, `backend`, `closed` and its tables as frozen properties: `io.timer` (sleeps, timers, `now`), `io.tcp`
  (`listen`, `connect`), `io.udp` (`bind`). A function lives on the object whose state it needs; no integer id
  reaches the guest (the glue reads a runtime's number for the async fs natives only).
- **Unshaped, then shaped** (replaces `mode` / `socketMode`): a factory returns an unshaped object owning the
  descriptor and flowing nothing; `.pulling()` / `.evented()` consume it into the shaped class. An accepted
  connection is unshaped again. An unshaped stream is already a stream for a native engine.
- **`close()` frees, collection drops.** `close()` (the object's or the runtime's) frees the descriptor and cancels
  what waits (`Canceled`); the object stays allocated until it is collected and answers `BadHandle`. There is no
  socket table: the runtime keeps a weak list of its conns to close them with it.
- **Handlers are held natively** (`Global<Function>` in the Host's hubs) and called from the loop, one event at a
  time, in order; a returned promise is not awaited (backpressure is the bounded read-ahead and `pause()`).
- **The `Transport` bridge** (`sockstream.rs`): an engine given a native stream (recognised by its cppgc `TypeId`)
  takes its socket and does its I/O in Rust; `api.tls` and `api.http.session` work this way.
- **Duck-typed streams** (`sockstream.rs`, `JsStream`; `api.tls` only so far): any other object with `read(length)`
  or `readInto(buffer)`, `queued.put(bytes)` / `queued.drained()`, `end(side)` and `close()` is a stream the engine
  calls from the loop: each call is a completion run on the isolate thread, its promise settles native callbacks that
  wake the engine's task. The object lives in the Host (`JsStreams`, keyed by an id that never reaches JS) and is
  dropped with its TLS stream or its runtime; tasks hold no `Global`. Having no runtime of its own, it needs the
  caller's `io` (required for such a stream, refused when it names another runtime than a native stream's).
- **No narrowing.** `api.io` is `{ create }`: the embedder's `Config.runtime` is the only limit (`api.io.narrow` was
  removed). The async fs hears that a runtime closed through one realm-wide hook (`native.io.link`).
- **Addresses** are `SocketAddr`s, crossing as octets, port and scope id; nothing is resolved, and the network
  ceiling is checked at `listen` / `bind` / `connect` and on every datagram destination.

## `api.tls`

- **Explicit trust and sessions.** `roots` is required (no default trust; `RootPki.bundled()` is the Mozilla set compiled in), resumption exists only with a `TlsSessions` the caller passes, a server needs `clientAuth` (`none()` or `require(roots)`). A server presents the first identity valid for the client's SNI name, else its first; the client then refuses it (`NotValidForName`), so a wrong name fails on the client, not silently.
- **`connect` / `accept` consume the native stream** and return a `TlsStreamUnshaped`, which takes its shape (`PullTlsStream`, `EventTlsStream`) like any stream. Consuming makes the transfer of ownership visible and rules out two readers on one stream; a stream with a read pending, bytes queued, a handler or an ended side is refused before it is touched. There is no kernel lane under TLS, so `direct.write` always takes 0 and `queued` is the way to send.
- **TLS streams are their own classes** with the TCP members plus `info()` (what the handshake settled). The class says what the bytes are, and `info()` lives on the object whose state it reads, so there is no `api.tls.info(stream)` that would have to answer for plain streams.
- **Duck-typed streams take `io`.** A stream that is not native is read through its JS methods (a turn and a copy per call) on the runtime the caller names: `io` is required then, and only then (a native stream runs on its own, and naming another `Io` is a `TypeError`). The adapter writes with `queued.put` and waits on `queued.drained()` for the rest, the contract the native `SendQueue` has too.
- **Truncation is an error.** `read` is empty only after `close_notify`; a connection cut earlier is `UnexpectedEof`, also during the handshake. `end('write')` sends `close_notify` and is a half close.
- **Errors keep one meaning each**: `CertificateRejected` (with the reason as `subject`), `TlsAlert`, `NoApplicationProtocol`, `ProtocolError`, `UnexpectedEof`, `InvalidData` (bad certificate or key), `InvalidInput` (bad server name).
- Backpressure comes from rustls' bounded buffers (16 KiB plaintext, 64 KiB output); a cancelled write that already handed a record to the transport poisons the stream.

## `api.http`

- **Sessions are the core; the rest is built on them.** `http.session(socket, { role, mode, limits })` is HTTP/2 over a socket you provide (it consumes it). `connect` and `serve` add dialing, TLS with ALPN `h2` and listening; `pool` and `fetch` add reuse and redirects. There is no `cleartext` option: a `TlsServer` makes every connection TLS and no `tls` means h2c, so a server never mixes the two.
- **Headers are a stream of fields, not a map.** `HeaderList` is one packed buffer, ordered, duplicates kept; the whole list crosses into the native once, because nghttp2's HPACK encoder wants it complete. Received blocks arrive as `headers` events in batches of about `limits.batch`, so a huge block never sits in memory as one value; `limits.headers` bounds it (a block over it resets the stream with `ENHANCE_YOUR_CALM`). Connection-specific fields are refused.
- **Flow control is the backpressure.** nghttp2 runs with automatic window updates off: received data stays unacknowledged until the caller says `consume(bytes)`, so a slow reader slows the peer. `send` waits while a stream already has `limits.window` bytes queued. `fetch` does this for you per chunk.
- **Limits have no defaults** (`streams`, `headers`, `window`, `connection`, `batch`), and so do the pool's (`limit`, `perKey`, `idle`, `queue`) and the redirect rules: a hidden default is a footgun at a trust boundary.
- **Modes are types.** `mode: 'pull'` gives `Pull*` classes (`next()`, `accept()`), `'event'` gives `Event*` classes (`register`). Events of one object are delivered one at a time, in order. A `ClientSession` serves both; the write side is shared.
- **Lifetime.** Sessions and servers keep the program alive until closed; `end()` is a graceful GOAWAY, `close()` is immediate. Dropping an exchange whose own side is complete lets it finish quietly (a response just queued is not cut off); abandoning a request is an explicit `reset(code)`. Server push is off.
- **Wait for SETTINGS.** The peer's limits are unknown until `ready()`; `connect` resolves only after them, and the pool reads the peer's `SETTINGS_MAX_CONCURRENT_STREAMS` (`native.http.peer`) before reusing a session.
- **The pool** keys sessions by `(scheme, host, port, TLS configuration object, servername)`: two `TlsClient` objects are two keys, because equal contents are not equal trust. One dial per key at a time; at `limit` the longest-idle session of any key is closed. Host resolution stays the caller's (`lookup`, or an IP literal): the pool dials what the network ceiling then checks, and no DNS hides inside.
- **Redirects are a required decision** (`redirect: { limit, strip }`, `limit: 0` follows nothing). `strip` names the fields dropped when the origin changes (put `authorization`, `cookie`, `proxy-authorization` there), because only the caller knows which fields are credentials. https to http is `PermissionDenied`; every hop is dialed through `api.net`, so the ceiling applies to each one. A redirect response is cancelled, not drained.

## `api.dns`

- **A resolver is explicit.** `servers` (never a default; presets are data, not a fallback), `timeout`, `tries` and `dnssec` are required; `cache` is absent for no caching and, when present, has all its numbers (`limit`, TTL clamps, negative clamps). `dnssec: 'validate'` is `Unsupported` until it exists: answers are unauthenticated input and the option says so.
- **Servers carry their own addresses** (`IpAddr` for the transport's default port, `SocketAddr` for another), so DoT and DoH never need DNS to find the server, and the server list is part of the network ceiling: each address is checked when the resolver is made and before every query. `system()` reads `resolv.conf` and the hosts file when the resolver is made and still passes the ceiling, so a LAN resolver needs a `connect` rule.
- **Transports:** UDP (an answer that does not fit is asked again over TCP), TCP, DoT, and DoH (RFC 8484: one HTTP/2 POST per query, id 0, `h2` required, redirects not followed). A DoT or DoH query opens its connection and closes it after the answer: no pooling yet, so an idle resolver keeps nothing alive; the cache spares connections.
- **Cache semantics** follow the RFCs: a positive answer lives for its shortest record TTL clamped by `ttl`, a negative one for the SOA's TTL and MINIMUM (RFC 2308) clamped by `negative` (no SOA, not kept); SERVFAIL and transport errors are never kept. When full, the entry nearest to expiry makes room, so `limit` bounds memory.
- **Order and literals.** An IP literal is itself, `localhost` is loopback (RFC 6761, never asked of a server), then the hosts file, then the servers; IPv6 comes first for `family: 'any'`. `family` is required. Names must be ASCII (no IDNA).
- **A response must be about our question** (id, QR bit, the single question) or the next server is tried; query ids are a hashed counter with a process-random key.
- **Presets** are data in their own module, pinned by a test, and each method calls the public `DnsServer` constructors, so a preset is nothing a program could not write by hand. The filtering providers change answers on purpose and the docs say so. The table must be re-checked against the providers' docs before a release.
- **Addresses are not part of `api.dns`.** `IpAddr` and `SocketAddr` are plain value types (parsing one opens nothing), so they are the std module `origine:@std/net`; `api.dns` takes and returns those instances and has no second spelling of them. `IpAddr` is one class for both families with Rust's names and `toCanonical()` (`::ffff:a.b.c.d` is `a.b.c.d`): permission decisions must use the canonical address, and the ceiling does.

## Permissions and errors

The **network ceiling** ([net-grant.md](net-grant.md)) is the only authority over the network: `connect` and `listen` rules over CIDR ranges and ports, loopback only by default, checked on the canonicalised address a program is about to use. It covers `api.net`, everything on it (`api.tls`, `api.http`, the pool and every redirect hop) and the servers of `api.dns` resolvers. Rules are about addresses, not names; the file also says what is not done (narrowing for a child scope or isolate, rate limits).

Errors are the realm's `IoError` / `HostError` classes, one meaning per code with the offending thing as `subject` (the denied address, the TLS alert, the DNS response code). The Rust crates use enums with `Display` and a variant per meaning (`TlsError`, `DnsError`, `H2Error`, `ConnError`), mapped to codes at the native boundary, so a new failure cannot hide in a string.

## Not built

- **QUIC, HTTP/3, DoQ and `api.net.udp`:** [quic-design.md](quic-design.md). The datagram layer on `oio` is tested (`src/io/udp_test.zig`) but not exposed to JS.
- **DNSSEC** (hickory-proto has the primitives; chain walking and denial of existence would be ours), EDNS, record types other than A and AAAA, IDNA, DoT/DoH connection reuse.
- **HTTP/1.x, WebSocket** (extended CONNECT), server push, cookies, caching, response decompression.
- **Interop testing** against external tools (`curl --http2-prior-knowledge`, `h2spec`); today the h2 engine is tested against itself over pipes and TLS, and the APIs by `src/tests/managed/{tls,http,dns,netgrant}.zig`.
- **DNS inside `connect` and `fetch`:** deliberately absent; pass an address or give the pool a `lookup`.

## Open questions

1. **System roots.** `RootPki.system()` waits on per-OS loading (Security.framework and the like); only `bundled()`, `fromPem` and `fromDer` exist.
2. **`URL`.** No URL class exists: `DnsServer.https` and `fetch` parse `https://host[:port][/path][?query]` and absolute URLs themselves (no userinfo, fragment or IPv6 brackets for DoH). Revisit when a `URL` exists.
3. **`system()` on macOS** (VPN and scoped resolvers): verify what the `resolv.conf` view misses.
4. **Size budget in CI.** `just check-size` exists; nothing runs it automatically.
