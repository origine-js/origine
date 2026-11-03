// `api.net`: the classes of the network objects, all defined in Rust (rust/crates/origine_api/src/{stream,udp}.rs)
// and made by an `Io`'s tables: `io.tcp.listen(addr)`, `io.tcp.connect(addr)`, `io.udp.bind(addr)` (`addr` a
// `SocketAddr` of `origine:@std/net`). A factory returns an unshaped object; `.pulling()` or `.evented()` consumes it
// and returns the shaped class. The state of every socket (its descriptor, send queue, event handlers) is native:
// this module only installs the classes with the few members that need JS (async iterators, `Symbol.asyncDispose`,
// and `buffer()`, which wraps a received chunk in a `Lease`) and publishes them. `api.net` is the facade over the
// one implementation: it has the classes, for `instanceof`, and nothing that makes a socket.
import { freeze, hostError, shared } from './util.js';
import { constants } from './errors.js';
import { IpAddr, SocketAddr } from './addr.js';

// Read when the module is evaluated (before guest code): a realm cannot swap them.
const { asyncDispose, asyncIterator, dispose } = Symbol;
const READ_CHUNK = 65536;

export default native => () => {
  const token = {};
  /**
   * A received chunk: a `Uint8Array` over an ArrayBuffer of exactly the bytes received (`buffer.byteLength ===
   * length`; no other byte of the socket's memory is reachable through it). It stays valid (across awaits) until
   * `unref()` or the end of its `using` block detaches the buffer, so a view kept past that point is empty. A lease
   * that is never released is garbage collected like any buffer.
   */
  class Lease extends Uint8Array {
    #buffer;
    constructor(made, buffer) {
      if (made !== token) throw new TypeError(constants.ILLEGAL_CONSTRUCTOR);
      super(buffer, 0, buffer.byteLength);
      this.#buffer = buffer;
    }
    static get [Symbol.species]() {
      return Uint8Array;
    }
    /** True once `unref()` ran. */
    get released() {
      return this.#buffer === null;
    }
    /** Detaches the buffer and frees its memory. Idempotent. */
    unref() {
      const buffer = this.#buffer;
      if (buffer === null) return;
      this.#buffer = null;
      native.net.release(buffer);
    }
    [dispose]() {
      this.unref();
    }
  }
  for (const target of [Lease, Lease.prototype]) {
    for (const key of Reflect.ownKeys(target)) {
      const descriptor = Object.getOwnPropertyDescriptor(target, key);
      if (typeof descriptor.value === 'function') freeze(descriptor.value);
      if (descriptor.get !== undefined) freeze(descriptor.get);
    }
    freeze(target);
  }
  // One lease per chunk: a `DataEvent` is reused, so its lease is found by the ArrayBuffer the native hands out
  // (the same one for every call of one event); a `DatagramEvent` is one datagram.
  const leases = new WeakMap();
  const leaseOf = (key, take) => {
    let lease = leases.get(key);
    if (lease === undefined) leases.set(key, (lease = new Lease(token, take())));
    return lease;
  };

  // `SocketAddr` in and out of the natives as `[octets (4 or 16 bytes), port, scopeId]`, through its public getters
  // and constructors: only a genuine `SocketAddr` crosses (a forged one fails its private-field access).
  native.net.link(
    addr => {
      if (!(addr instanceof SocketAddr)) return undefined;
      try {
        return [addr.ip.octets(), addr.port, addr.scopeId];
      } catch {
        return undefined;
      }
    },
    (octets, port, scopeId) => SocketAddr.new(IpAddr.fromOctets(octets), port, scopeId),
  );

  const closing = {
    [asyncDispose]() {
      return this.close();
    },
  };
  const classes = freeze({
    TcpStreamUnshaped: native.net.TcpStreamUnshaped(hostError, closing),
    PullTcpStream: native.net.PullTcpStream(hostError, {
      ...closing,
      /** `for await (const chunk of stream)`: the bytes as `read(65536)` returns them, until the end of the stream. */
      async *[asyncIterator]() {
        for (;;) {
          const chunk = await this.read(READ_CHUNK);
          if (chunk.length === 0) return;
          yield chunk;
        }
      },
    }),
    EventTcpStream: native.net.EventTcpStream(hostError, closing),
    TcpListenerUnshaped: native.net.TcpListenerUnshaped(hostError, closing),
    PullTcpListener: native.net.PullTcpListener(hostError, {
      ...closing,
      /** `for await (const stream of listener)`: the connections (unshaped) until the listener is closed. */
      async *[asyncIterator]() {
        for (;;) {
          let stream;
          try {
            stream = await this.accept();
          } catch (e) {
            if (this.closed) return;
            throw e;
          }
          yield stream;
        }
      },
    }),
    EventTcpListener: native.net.EventTcpListener(hostError, closing),
    UdpSocketUnshaped: native.net.UdpSocketUnshaped(hostError, closing),
    PullUdpSocket: native.net.PullUdpSocket(hostError, closing),
    EventUdpSocket: native.net.EventUdpSocket(hostError, closing),
    SendQueue: native.net.SendQueue(hostError),
    Direct: native.net.Direct(hostError),
    DataEvent: native.net.DataEvent(hostError, {
      /** The chunk as a `Lease` (the same lease on every call of one event); a `TypeError` once the event is over. */
      buffer() {
        const buffer = native.net.take(this);
        return leaseOf(buffer, () => buffer);
      },
    }),
    DatagramEvent: native.net.DatagramEvent(hostError, {
      /** The datagram as a `Lease` (the same lease on every call). */
      buffer() {
        return leaseOf(this, () => native.net.takeDatagram(this));
      },
    }),
    Registration: native.net.Registration(hostError),
    Lease,
  });
  shared.net = classes;
  return classes;
};
