// `api.dns`: address lookups (docs/http-design.md). An ES module factory used by index.js, like net.js. A
// `DnsServer` says how one server is reached (`udp`, `tcp`, `tls`, or `system()`); `dns.resolver` makes a
// `Resolver` (a class defined in Rust) over an ordered list of them; `resolver.lookup(name, { family })` resolves a name to `IpAddr`s.
// Servers must be loopback addresses for now (the sockets are not `api.net` sockets, and there is no embedder
// permission for the wider network yet).
import { freeze, freezeMethods, own, failure, ioHandles, closedIo, errors, hostError } from './util.js';
import { IpAddr, SocketAddr } from './addr.js';
const { BadHandle, Unsupported } = errors;
// Read when the module is evaluated (before guest code): a realm cannot swap it.
const { asyncDispose } = Symbol;
const DEFAULT_PORT = { udp: 53, tcp: 53, tls: 853 };

export default native => {
  const token = {};
  const ioId = io => {
    if (io === null || typeof io !== 'object' || !ioHandles.has(io) || closedIo.has(io)) throw failure(BadHandle);
    return io.id;
  };
  // An `IpAddr` means the transport's default port; a `SocketAddr` names the port.
  const addrsOf = (kind, servers) => {
    if (!Array.isArray(servers) || servers.length === 0) throw new TypeError('servers must be a non-empty array of IpAddr or SocketAddr');
    return Object.freeze(
      servers.map(server => {
        if (server instanceof SocketAddr) return server;
        if (server instanceof IpAddr) return SocketAddr.new(server, DEFAULT_PORT[kind]);
        throw new TypeError('servers must hold IpAddr or SocketAddr values');
      }),
    );
  };

  /** How one DNS server is reached. */
  class DnsServer {
    #kind;
    #name;
    #addrs;
    constructor(made, kind, name, addrs) {
      if (made !== token) throw new TypeError('use DnsServer.system, udp, tcp or tls');
      this.#kind = kind;
      this.#name = name;
      this.#addrs = addrs;
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
    static line(server) {
      if (!(server instanceof DnsServer)) throw new TypeError('servers must be DnsServer values');
      const list = server.#addrs.join(',');
      return server.#kind === 'system' ? 'system' : server.#kind === 'tls' ? `tls ${server.#name} ${list}` : `${server.#kind} ${list}`;
    }
    static isTls(server) {
      return server.#kind === 'tls';
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
       * `{ servers: DnsServer[] (at least one), roots?: RootPki (required with `DnsServer.tls`), dnssec: 'off',
       * timeout: ms per attempt, tries: rounds over the servers }`; every number is required. `dnssec: 'validate'` is
       * `Unsupported` until validation is built.
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
        const needsRoots = servers.some(DnsServer.isTls);
        if (needsRoots && roots === undefined) throw new TypeError('roots is required with DnsServer.tls');
        const resolver = native.dns.resolver(ioId(io), spec, roots, timeout, tries);
        ios.set(resolver, io);
        return resolver;
      },
    });
  };
};
