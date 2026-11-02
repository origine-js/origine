// `api.dns`: address lookups (docs/http-design.md). An ES module factory used by index.js, like net.js. A
// `DnsServer` says how one server is reached (`udp`, `tcp`, `tls`, `https`, or `system()`); `dns.resolver` makes a
// `Resolver` (a class defined in Rust) over an ordered list of them; `resolver.lookup(name, { family })` resolves a name to `IpAddr`s.
// Every server address is checked against the embedder's network ceiling (the sockets are not `api.net` sockets).
import { freeze, freezeMethods, own, failure, ioHandles, closedIo, errors, hostError } from './util.js';
import { provide } from './handles.js';
import { IpAddr, SocketAddr } from './addr.js';
const { BadHandle, Unsupported } = errors;
// Read when the module is evaluated (before guest code): a realm cannot swap it.
const { asyncDispose } = Symbol;
const DEFAULT_PORT = { udp: 53, tcp: 53, tls: 853, https: 443 };
const LABEL = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/;
// `https://host[:port][/path][?query]` only: no userinfo, no fragment, no IP-literal brackets, no whitespace.
const parseUrl = url => {
  const match = typeof url === 'string' ? /^https:\/\/([^/?#@\s[\]]+)(\/[^\s#]*|\?[^\s#]*)?$/.exec(url) : null;
  if (match === null) throw new TypeError('url must be an https:// URL with a host, an optional port, a path and a query');
  const [, hostPort, rest = '/'] = match;
  const colon = hostPort.lastIndexOf(':');
  const host = (colon < 0 ? hostPort : hostPort.slice(0, colon)).toLowerCase();
  const port = colon < 0 ? 443 : /^[1-9][0-9]{0,4}$/.test(hostPort.slice(colon + 1)) ? Number(hostPort.slice(colon + 1)) : 0;
  if (port < 1 || port > 65535 || host.length > 253 || !host.split('.').every(label => label.length <= 63 && LABEL.test(label))) {
    throw new TypeError('url must have a host name and a port from 1 to 65535');
  }
  return { host, port, authority: port === 443 ? host : `${host}:${port}`, path: rest.startsWith('/') ? rest : `/${rest}` };
};

export default native => {
  const token = {};
  const ioId = io => {
    if (io === null || typeof io !== 'object' || !ioHandles.has(io) || closedIo.has(io)) throw failure(BadHandle);
    return io.id;
  };
  // An `IpAddr` means the transport's default port; a `SocketAddr` names the port.
  const addrsOf = (kind, servers, port = DEFAULT_PORT[kind]) => {
    if (!Array.isArray(servers) || servers.length === 0) throw new TypeError('servers must be a non-empty array of IpAddr or SocketAddr');
    return Object.freeze(
      servers.map(server => {
        if (server instanceof SocketAddr) return server;
        if (server instanceof IpAddr) return SocketAddr.new(server, port);
        throw new TypeError('servers must hold IpAddr or SocketAddr values');
      }),
    );
  };

  /** How one DNS server is reached. */
  class DnsServer {
    #kind;
    #name;
    #addrs;
    #target;
    constructor(made, kind, name, addrs, target) {
      if (made !== token) throw new TypeError('use DnsServer.system, udp, tcp, tls or https');
      this.#kind = kind;
      this.#name = name;
      this.#addrs = addrs;
      this.#target = target;
      Object.freeze(this);
    }
    /** The nameservers, search list and hosts file of this machine, read when the resolver is made. */
    static system() {
      return new DnsServer(token, 'system', undefined, Object.freeze([]));
    }
    /** Datagrams on port 53 (or the `SocketAddr`'s); an answer that does not fit is asked again over TCP. */
    static udp(servers) {
      return new DnsServer(token, 'udp', undefined, addrsOf('udp', servers));
    }
    static tcp(servers) {
      return new DnsServer(token, 'tcp', undefined, addrsOf('tcp', servers));
    }
    /** DNS over TLS (port 853): `name` is what the server's certificate must be valid for. Needs `roots` in `dns.resolver`. */
    static tls(name, servers) {
      if (typeof name !== 'string' || name === '' || /\s/.test(name)) throw new TypeError('name must be a non-empty string');
      return new DnsServer(token, 'tls', name, addrsOf('tls', servers));
    }
    /** DNS over HTTPS (RFC 8484, HTTP/2 POST): `url` is `https://host[:port]/path`, the host is what the server's certificate must be valid for. An `IpAddr` means the URL's port (443 if it has none). Needs `roots` in `dns.resolver`. */
    static https(url, servers) {
      const { host, port, authority, path } = parseUrl(url);
      return new DnsServer(token, 'https', host, addrsOf('https', servers, port), `${authority} ${path}`);
    }
    static line(server) {
      if (!(server instanceof DnsServer)) throw new TypeError('servers must be DnsServer values');
      const list = server.#addrs.join(',');
      if (server.#kind === 'system') return 'system';
      if (server.#kind === 'tls') return `tls ${server.#name} ${list}`;
      return server.#kind === 'https' ? `https ${server.#target} ${list}` : `${server.#kind} ${list}`;
    }
    static needsRoots(server) {
      return server.#kind === 'tls' || server.#kind === 'https';
    }
  }

  // `Resolver` is a class defined in Rust (rust/crates/origine_api/src/dns.rs: `closed`, `close()`); these members
  // need the glue's own objects (the `api.io` handle, `IpAddr`) and are defined on its prototype by the installer.
  const ios = new WeakMap();
  const resolverMembers = {
    get io() {
      const io = ios.get(this);
      if (io === undefined) throw new TypeError('Resolver.prototype.io called on an object that is not a Resolver');
      return io;
    },
    /**
     * The addresses of `name`: an IP literal is itself, `localhost` is the loopback addresses, then the hosts file
     * (for `system()`), then the servers. `family` ('ipv4' | 'ipv6' | 'any') is required; IPv6 comes first for 'any'.
     * Rejects `NotFound` (`subject`: the name), `TimedOut`, `ServerFailure` (`subject`: the response code), ... A
     * name must be ASCII (no IDNA yet).
     */
    async lookup(name, options) {
      if (typeof name !== 'string') throw new TypeError('name must be a string');
      const family = { ipv4: 4, ipv6: 6, any: 0 }[own(options, 'family')];
      if (family === undefined) throw new TypeError("family must be 'ipv4', 'ipv6' or 'any'");
      if (this.closed) throw failure(BadHandle);
      const packed = await native.dns.lookup(this, name, family);
      const out = [];
      for (let at = 0; at < packed.length;) {
        const length = packed[at] === 4 ? 4 : 16;
        out.push(IpAddr.fromOctets(packed.subarray(at + 1, at + 1 + length)));
        at += 1 + length;
      }
      return out;
    },
    [asyncDispose]() {
      return this.close();
    },
  };

  // The presets module (`origine:@std/dns/presets`) makes servers with the public constructors of this realm.
  provide('dns/classes', { DnsServer, IpAddr });

  for (const C of [DnsServer]) {
    freezeMethods(C);
    freezeMethods(C.prototype);
    Object.freeze(C.prototype);
    Object.freeze(C);
  }

  // Called when the capability is bound (index.js `late`): the installer exists only then.
  return () => {
    const Resolver = native.dns.Resolver(hostError, resolverMembers);
    return freeze({
      IpAddr,
      SocketAddr,
      DnsServer,
      Resolver,
      /**
       * `{ servers: DnsServer[] (at least one), roots?: RootPki (required with `DnsServer.tls` and `https`), dnssec: 'off',
       * timeout: ms per attempt, tries: rounds over the servers, cache?: { limit, ttl: { min, max }, negative: { min, max } } }`;
       * every number is required, and no `cache` means no caching. `dnssec: 'validate'` is `Unsupported` until
       * validation is built.
       */
      resolver(io, options) {
        const servers = own(options, 'servers');
        if (!Array.isArray(servers) || servers.length === 0) throw new TypeError('servers must be a non-empty array of DnsServer');
        const dnssec = own(options, 'dnssec');
        if (dnssec !== 'off' && dnssec !== 'validate') throw new TypeError("dnssec must be 'off' or 'validate'");
        if (dnssec === 'validate') throw failure(Unsupported);
        const positive = name => {
          const value = own(options, name);
          if (!Number.isSafeInteger(value) || value < 1 || value > 0xffffffff) throw new TypeError(`${name} must be a positive integer`);
          return value;
        };
        const timeout = positive('timeout');
        const tries = positive('tries');
        const spec = servers.map(DnsServer.line).join('\n');
        const roots = own(options, 'roots');
        const needsRoots = servers.some(DnsServer.needsRoots);
        if (needsRoots && roots === undefined) throw new TypeError('roots is required with DnsServer.tls and DnsServer.https');
        const cache = own(options, 'cache');
        let numbers = [0, 0, 0, 0, 0];
        if (cache !== undefined) {
          const count = (object, name, least) => {
            const value = own(object, name);
            if (!Number.isSafeInteger(value) || value < least) throw new TypeError(`cache.${name} must be an integer of at least ${least}`);
            return value;
          };
          const clamp = (object, what) => {
            const min = count(object, 'min', 0);
            const max = count(object, 'max', 0);
            if (min > max) throw new TypeError(`${what}.min must not be above ${what}.max`);
            return [min, max];
          };
          numbers = [
            count(cache, 'limit', 1),
            ...clamp(own(cache, 'ttl'), 'cache.ttl'),
            ...clamp(own(cache, 'negative'), 'cache.negative'),
          ];
        }
        const resolver = native.dns.resolver(ioId(io), spec, roots, timeout, tries, ...numbers);
        ios.set(resolver, io);
        return resolver;
      },
    });
  };
};
