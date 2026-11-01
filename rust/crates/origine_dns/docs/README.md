# origine_dns

Address lookups over the hickory-proto wire codec, with resolver logic of our own: no hickory-resolver, no tokio, no threads. `Resolver::lookup(name, family)` turns a name into addresses: IP literals, `localhost`, the hosts file, then the servers in order with retries and the search list. One query to one server is an [`Exchange`], which the caller provides; `origine_api` implements it over UDP, TCP and TLS sockets on the io loop. Design: [docs/http-design.md](../../../../docs/http-design.md).

```
src/lib.rs       exports
src/config.rs    Config, Server, Transport, Family, parse_resolv_conf
src/hosts.rs     Hosts: /etc/hosts text to names and addresses
src/resolver.rs  Resolver, Exchange: candidates (ndots, search), rounds, truncation fallback, response checks
src/error.rs     DnsError (one meaning per variant)
src/tests.rs     the resolver against a table-driven fake network
```

- **What an answer must be.** The id and the QR bit must match and the single question must be the one asked (name compared as an absolute name); anything else is `BadResponse` and the next server is tried. NXDOMAIN to the first question settles the name (the second family is not asked); NOERROR with no record of the type is "no data", not an error, so a name with only an A record resolves for `Any` and is `NotFound` for `V6`.
- **Order.** IPv6 first for `Family::Any`; each family in the server's order. CNAME chains are not followed: A and AAAA records anywhere in the answer count (a recursive resolver sends the chain).
- **Ids** are unguessable from one another: a counter hashed with a process-random key.
- **Not here:** caching, DNSSEC, EDNS, other record types, IDNA (a name must be ASCII).
- Tests: `cargo test -p origine_dns`.
