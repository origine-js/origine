# `origine:@std/net`: `IpAddr` and `SocketAddr`

Plain value types for network addresses, in Rust's vocabulary (camelCase). They hold no authority: parsing, printing and classifying an address opens nothing, so they are a std module and not a capability. `api.dns` takes and returns these very instances (`DnsServer` servers, `Resolver.lookup`); it does not re-export them. Source: [glue/addr.js](../glue/addr.js) (the classes), [std/net.js](../std/net.js) (the module).

```js
import { IpAddr, SocketAddr } from 'origine:@std/net';

const ip = IpAddr.parse('::ffff:127.0.0.1');
ip.isLoopback();                 // false: an IPv4-mapped address is not loopback until...
ip.toCanonical().isLoopback();   // true
SocketAddr.parse('[::1]:853').port;   // 853
```

## `IpAddr`

One class for both families (v4 = 4 octets, v6 = 16). Made by named constructors, which throw `TypeError` for bad input; `new IpAddr()` is a `TypeError` too. Instances and the classes are frozen.

| Name | What it does |
| --- | --- |
| `IpAddr.v4(a, b, c, d)` | four integers in 0..255 |
| `IpAddr.v6(...segments)` | eight integers in 0..65535 |
| `IpAddr.fromOctets(octets)` | a `Uint8Array` of 4 or 16 bytes; the bytes are **copied** |
| `IpAddr.parse(text)` | `1.2.3.4` or `::1` only: no port, brackets, zone or leading zeros (they are ambiguous with octal) |
| `family` | `4` or `6` |
| `octets()` | a **fresh copy**: 4 or 16 bytes |
| `isV4()`, `isV6()` | the family as a question |
| `isUnspecified()`, `isLoopback()`, `isMulticast()`, `isPrivate()`, `isLinkLocal()`, `isDocumentation()` | Rust's classification (`isPrivate`: RFC 1918 or `fc00::/7`) |
| `toCanonical()` | `::ffff:a.b.c.d` becomes the v4 address `a.b.c.d`; anything else is itself. **Permission checks must use it.** |
| `equals(other)` | same family and octets; a non-`IpAddr` is `false` |
| `toString()` | dotted quad, or RFC 5952 for v6 (an IPv4-mapped address keeps its dotted tail) |

## `SocketAddr`

An `IpAddr` and a port. `SocketAddr.new(ip, port)` (port an integer in 0..65535, `ip` an `IpAddr`), `SocketAddr.parse('1.2.3.4:53' | '[::1]:853')`, `ip`, `port`, `equals`, `toString`. A bracketed host must be IPv6.
