// `api.tls`: TLS 1.2/1.3 over `api.net` stream sockets (docs/http-design.md). An ES module factory used by
// index.js, like net.js. The values that are parsed once and reused (`RootPki`, `Identity`, `ClientAuth`,
// `TlsSessions`, `TlsClient`, `TlsServer`) are classes defined in Rust (rust/crates/origine_api/src/tls.rs,
// `#[class]`): their named constructors parse and validate there, so a bad certificate fails with its own
// error, and each instance owns its native value until it is collected. They are made per realm when the
// capability is bound (never in a snapshot). A handshake consumes a pull-mode `api.net` socket and makes a new
// one (pull or event) whose bytes are plaintext: the whole `api.net` socket surface works on it, and
// `info(socket)` tells what the handshake settled. `connect` / `accept` are the only members written here:
// they take and make the glue's `api.net` socket objects.
import { freeze, own, failure, ioHandles, closedIo, errors, shared, hostError } from './util.js';
const { BadHandle } = errors;

// `[u32 LE length | bytes]*` in one buffer: how `tls.peer` returns a list of DER blobs.
const unpack = bytes => {
  const out = [];
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  for (let at = 0; at < bytes.length;) {
    const length = view.getUint32(at, true);
    out.push(bytes.slice(at + 4, at + 4 + length));
    at += 4 + length;
  }
  return out;
};

export default native => {
  const ioId = io => {
    if (io === null || typeof io !== 'object' || !ioHandles.has(io) || closedIo.has(io)) throw failure(BadHandle);
    return io.id;
  };

  // What each handshake settled, by the socket it made. `info(socket)` reads it.
  const infos = new WeakMap();

  // For `api.http`: what the handshake of a socket settled, or undefined.
  shared.tlsInfo = socket => infos.get(socket);

  const optionsOf = options => {
    const mode = own(options, 'mode');
    if (mode !== 'pull' && mode !== 'event') throw new TypeError("mode must be 'event' or 'pull'");
    return { mode, limit: shared.netQueueLimit(options) };
  };
  const handshake = (mode, limit, socket, begin) => {
    try {
      const taken = shared.netTake(socket);
      const done = begin(ioId(taken.io), taken.id);
      // The native took the socket: the old handle is consumed now, whatever the handshake does.
      taken.consume();
      return done.then(info => {
        const made = shared.netMake(mode, info.id, taken.io, taken.port, limit);
        infos.set(
          made,
          Object.freeze({
            id: info.id,
            alpn: info.alpn ?? undefined,
            version: info.version === 12 ? 'tls1.2' : 'tls1.3',
            servername: info.servername ?? undefined,
            resumed: info.resumed,
          }),
        );
        return made;
      });
    } catch (e) {
      return Promise.reject(e);
    }
  };

  // Defined on `TlsClient.prototype` / `TlsServer.prototype` by their installers, before they are frozen. The
  // native checks `this` (a `TypeError` for anything but an instance) before it touches the socket.
  const clientMembers = {
    /**
     * Handshakes over `socket` (a pull-mode `api.net` socket, consumed) and resolves a new `api.net` socket
     * (`mode`: 'pull' or 'event', required) whose bytes are plaintext; `servername` is required and
     * `queued: { limit }` as for `api.net`. `tls.info(socket)` tells what the handshake settled.
     */
    connect(socket, options) {
      try {
        const servername = own(options, 'servername');
        if (typeof servername !== 'string' || servername === '') throw new TypeError('servername must be a string');
        const { mode, limit } = optionsOf(options);
        return handshake(mode, limit, socket, (io, sock) => native.tls.connect(io, this, sock, servername));
      } catch (e) {
        return Promise.reject(e);
      }
    },
  };
  const serverMembers = {
    /** Handshakes over `socket` (a pull-mode `api.net` socket, consumed); `mode` is required, see `TlsClient.connect`. */
    accept(socket, options) {
      try {
        const { mode, limit } = optionsOf(options);
        return handshake(mode, limit, socket, (io, sock) => native.tls.accept(io, this, sock));
      } catch (e) {
        return Promise.reject(e);
      }
    },
  };

  // Called when the capability is bound (index.js `late`): the installers exist only then.
  return () =>
    freeze({
      RootPki: native.tls.RootPki(hostError),
      Identity: native.tls.Identity(hostError),
      ClientAuth: native.tls.ClientAuth(hostError),
      TlsSessions: native.tls.TlsSessions(hostError),
      TlsClient: native.tls.TlsClient(hostError, clientMembers),
      TlsServer: native.tls.TlsServer(hostError, serverMembers),
      /**
       * What the handshake of a socket made by `connect` / `accept` settled: `{ alpn, version, servername,
       * resumed, peer }`; `peer` is the peer's certificates in DER, leaf first (empty when it sent none).
       * `BadHandle` for any other socket.
       */
      info(socket) {
        const info = infos.get(socket);
        if (info === undefined) throw failure(BadHandle);
        return Object.freeze({
          alpn: info.alpn,
          version: info.version,
          servername: info.servername,
          resumed: info.resumed,
          get peer() {
            return unpack(native.tls.peer(shared.netId(socket)));
          },
        });
      },
      /** `{ roots: RootPki (required), identity?: Identity, alpn?: string[], sessions?: TlsSessions }`. */
      client(options) {
        return native.tls.client(options);
      },
      /** `{ identities: Identity[] (at least one), clientAuth: ClientAuth (required), alpn?: string[] }`. */
      server(options) {
        return native.tls.server(options);
      },
    });
};
