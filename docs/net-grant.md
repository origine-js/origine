# The network ceiling

What a program may reach on the network is decided by the embedder, once, as a list of rules. Nothing is
allowed that no rule allows, and **rules are about addresses, not names**: the check runs on the address a
program is about to use, canonicalised (`::ffff:a.b.c.d` is `a.b.c.d`), so a name that resolves somewhere
forbidden, a redirect, or a DNS answer cannot get around it. The default is loopback only, both ways, which is
what `api.net` has always been.

## Rules

One per line, `#` starts a comment:

```
connect <cidr> [ports]
listen  <cidr> [ports]
```

- `<cidr>` is `10.0.0.0/8`, `2001:db8::/32`, or a bare address (one host). `0.0.0.0/0` and `::/0` are every address
  of a family. An IPv4-mapped rule (`::ffff:192.0.2.0/120`) is the IPv4 rule it stands for and needs a prefix of at
  least 96.
- `ports` is `*` (the default), a port, a range `8000-8100`, or a comma-separated list of those (`80,443,8000-8100`).
- `connect` covers `io.tcp.connect`, every datagram destination of `io.udp` (`sendTo`, `connect`), everything built on them (`api.tls`, `api.http`), and the servers of every
  `api.dns` resolver (UDP, TCP and TLS, checked when the resolver is made and again before each query).
  `listen` covers `io.tcp.listen` and `io.udp.bind` (and `api.http.serve`). Accepted connections and received datagrams need no rule of their own.
- Listening on port 0 (the system picks one) is allowed by a rule that allows every port (`*`), not by a rule that
  names ports.

The grammar and the matching are `rust/crates/origine_api_core/src/net_rules.rs`.

```
connect 127.0.0.0/8
connect ::1/128
listen  127.0.0.0/8
listen  ::1/128
connect 10.0.0.0/8 80,443
connect 2001:db8::/32
```

## What a program sees

A refused address is `PermissionDenied` with the address (`10.0.0.1:80`) as the error's `subject`. `io.tcp` and `io.udp` take `SocketAddr` values (`origine:@std/net`), never names: a name is not a `SocketAddr`. Resolve it with `api.dns` (whose servers are subject to the same ceiling) and pass the address, which is what the rules are checked against; `api.http.connect`'s `host` is such an address too (it maps `localhost` to `127.0.0.1` and refuses any other name with `PermissionDenied`).

## Giving it

- **The shell** starts with the loopback rules and adds one per flag, before the init path:
  `--net-connect=<cidr>[@ports]` and `--net-listen=<cidr>[@ports]`; `<cidr>` may be `any` (both families).
  `origine --net-connect=10.0.0.0/8@80,443 --net-listen=any app.js`. A rule that does not parse stops the shell
  (`error: network rules: line N: ...`; the lines count from the loopback defaults).
- **An embedder** sets `Config.net = .{ .rules = "..." }` (`src/api/host.zig`; default `loopback_rules`; text is
  borrowed until `destroy`). `checkNetRules` says why a text does not parse; the Host treats text that does not
  parse as granting nothing.
- Not yet: narrowing the ceiling for a child scope or isolate, rules by host name, and a rate or connection limit.
