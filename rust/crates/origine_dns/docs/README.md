# origine_dns

Address lookups over the hickory-proto wire codec, with resolver logic of our own: no hickory-resolver, no tokio, no threads. `Resolver::lookup(name, family)` turns a name into addresses: IP literals, `localhost`, the hosts file, then the servers in order with retries and the search list. One query to one server is an [`Exchange`], which the caller provides; `origine_api` implements it over UDP, TCP, TLS and HTTPS (HTTP/2, RFC 8484) on the io loop. Design: [docs/http-design.md](../../../../docs/http-design.md).

```
src/lib.rs       exports
src/config.rs    Config, Server, Transport, Family, parse_resolv_conf
src/hosts.rs     Hosts: /etc/hosts text to names and addresses
src/cache.rs     Cache, CacheConfig, Clock: TTL-bound answers, an injectable clock
src/resolver.rs  Resolver, Exchange: candidates (ndots, search), rounds, truncation fallback, response checks, cache
src/error.rs     DnsError, Failure, BadResponse, DohError (enums, one meaning per variant; no string payloads but the name asked)
src/tests.rs     the resolver against a table-driven fake network (tests/cache_tests.rs: cache and DoH)
```

- **What an answer must be.** The id and the QR bit must match and the single question must be the one asked (name compared as an absolute name); anything else is `BadResponse` and the next server is tried. NXDOMAIN to the first question settles the name (the second family is not asked); NOERROR with no record of the type is "no data", not an error, so a name with only an A record resolves for `Any` and is `NotFound` for `V6`.
- **Order.** IPv6 first for `Family::Any`; each family in the server's order. CNAME chains are not followed: A and AAAA records anywhere in the answer count (a recursive resolver sends the chain).
- **Ids** are unguessable from one another: a counter hashed with a process-random key.
- **Cache** (`Config.cache`, absent means none). One entry per question (lowercased name, A or AAAA), shared by every lookup of the resolver. A positive answer lives for its shortest record TTL (a CNAME on the way counts) raised to `min` and cut to `max`; a negative one (NXDOMAIN holds for both types; NOERROR with no record, per type) for the smaller of the SOA record's TTL and its MINIMUM from the authority section (RFC 2308), clamped by `negative_min`/`negative_max`, and **not kept** without a SOA or when the clamped life is zero. SERVFAIL and other failures are never kept. At `entries` the entry nearest to expiry goes first. The clock is injected (`Resolver::with_clock`), so expiry is tested without sleeping; no number has a default.
- **DoH.** `Transport::Https { name, authority, path }`: the query id is 0 (RFC 8484), the HTTP exchange pairs query and answer. The `Exchange` reports a non-200 status or a body that is not a DNS message as `DohError` inside the `io::Error`; the resolver turns it into `ServerFailure(Failure::Http(status))` or `BadResponse(BadResponse::Doh(..))`.
- **Not here:** DNSSEC, EDNS, other record types, IDNA (a name must be ASCII).
- Tests: `cargo test -p origine_dns`.
