// `api.tls`: TLS 1.2/1.3 over `api.net` stream sockets (docs/http-design.md). An ES module factory used by
// index.js, like net.js. Values that are parsed once and reused (`RootPki`, `Identity`, `ClientAuth`,
// `TlsSessions`, `TlsClient`, `TlsServer`) are frozen classes built by named constructors; the native
// parses and validates there, so a bad certificate fails with its own error. A handshake consumes a pull-mode
// `api.net` socket and makes a new one (pull or event) whose bytes are plaintext: the whole `api.net` socket
// surface works on it, and `info(socket)` tells what the handshake settled.
import { freeze, freezeMethods, own, failure, ioHandles, closedIo, errors, shared } from './util.js';
const { BadHandle } = errors;

// `[u32 LE length | bytes]*` in one buffer: how a list of DER blobs crosses into a native.
const pack = blobs => {
  const parts = Array.from(blobs, blob => {
    if (!(blob instanceof Uint8Array)) throw new TypeError('each certificate must be a Uint8Array');
    return blob;
  });
  const out = new Uint8Array(parts.reduce((n, p) => n + 4 + p.length, 0));
  const view = new DataView(out.buffer);
  let at = 0;
  for (const part of parts) {
    view.setUint32(at, part.length, true);
    out.set(part, at + 4);
    at += 4 + part.length;
  }
  return out;
};
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
const bytesArg = (value, name) => {
  if (!(value instanceof Uint8Array)) throw new TypeError(`${name} must be a Uint8Array`);
  return value;
};

export default native => {
  const token = {};
  const ioId = io => {
    if (io === null || typeof io !== 'object' || !ioHandles.has(io) || closedIo.has(io)) throw failure(BadHandle);
    return io.id;
  };
  const alpnOf = options => {
    const alpn = own(options, 'alpn') ?? [];
    if (!Array.isArray(alpn) || alpn.some(name => typeof name !== 'string' || name === '' || name.includes('\n')))
      throw new TypeError('alpn must be an array of protocol names');
    return alpn.join('\n');
  };

  /**
   * A native value: the object a native returned, which owns it. Nothing else holds the value, so it is freed when this
   * object (and with it the native object) is garbage collected; `release()` lets go of it now. What was built from
   * it holds its own copy, so neither ever breaks a live `TlsClient`.
   */
  class Value {
    #handle;
    constructor(made, handle) {
      if (made !== token || new.target === Value) throw new TypeError('TLS values are made by their named constructors');
      this.#handle = handle;
    }
    static handleOf(value, Class, name) {
      if (!(value instanceof Class)) throw new TypeError(`${name} must be a ${Class.name}`);
      if (value.#handle === null) throw failure(BadHandle);
      return value.#handle;
    }
    release() {
      this.#handle = null;
    }
  }
  const handleOf = Value.handleOf;

  /** The authorities a peer is checked against. */
  class RootPki extends Value {
    /** The Mozilla roots compiled into the binary. */
    static bundled() {
      return new RootPki(token, native.tls.rootsBundled());
    }
    /** Every certificate of a PEM bundle (`Uint8Array`); at least one. */
    static fromPem(pem) {
      return new RootPki(token, native.tls.rootsPem(bytesArg(pem, 'pem')));
    }
    /** An array of DER certificates (`Uint8Array`); at least one. */
    static fromDer(certs) {
      return new RootPki(token, native.tls.rootsDer(pack(certs)));
    }
  }

  /** A certificate chain with the private key of its leaf, checked against each other. */
  class Identity extends Value {
    /** PEM chain (leaf first) and PEM private key. */
    static fromPem(cert, key) {
      return new Identity(token, native.tls.identityPem(bytesArg(cert, 'cert'), bytesArg(key, 'key')));
    }
    /** `{ cert: Uint8Array[] (DER, leaf first), key: Uint8Array (DER) }`. */
    static fromDer(options) {
      return new Identity(token, native.tls.identityDer(pack(own(options, 'cert') ?? []), bytesArg(own(options, 'key'), 'key')));
    }
  }

  /** Whether a server asks the client for a certificate. */
  class ClientAuth {
    #roots;
    constructor(made, roots) {
      if (made !== token) throw new TypeError('use ClientAuth.none() or ClientAuth.require(roots)');
      this.#roots = roots;
    }
    static none() {
      return new ClientAuth(token, undefined);
    }
    static require(roots) {
      if (!(roots instanceof RootPki)) throw new TypeError('roots must be a RootPki');
      return new ClientAuth(token, roots);
    }
    static rootsOf(auth) {
      if (!(auth instanceof ClientAuth)) throw new TypeError('clientAuth must be a ClientAuth');
      return auth.#roots === undefined ? undefined : handleOf(auth.#roots, RootPki, 'roots');
    }
  }

  /** A client-side resumption cache. Passing one to `client()` is what turns resumption on. */
  class TlsSessions extends Value {
    static create(options) {
      const limit = own(options, 'limit');
      if (!Number.isSafeInteger(limit) || limit < 1) throw new TypeError('limit must be a positive integer');
      return new TlsSessions(token, native.tls.sessions(limit));
    }
  }

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

  /** An immutable client configuration; connections are made from it. */
  class TlsClient extends Value {
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
        const id = handleOf(this, TlsClient, 'this');
        return handshake(mode, limit, socket, (io, sock) => native.tls.connect(io, id, sock, servername));
      } catch (e) {
        return Promise.reject(e);
      }
    }
  }

  /** An immutable server configuration; connections are accepted from it. */
  class TlsServer extends Value {
    /** Handshakes over `socket` (a pull-mode `api.net` socket, consumed); `mode` is required, see `TlsClient.connect`. */
    accept(socket, options) {
      try {
        const { mode, limit } = optionsOf(options);
        const id = handleOf(this, TlsServer, 'this');
        return handshake(mode, limit, socket, (io, sock) => native.tls.accept(io, id, sock));
      } catch (e) {
        return Promise.reject(e);
      }
    }
  }

  // For `api.dns`: the native id of a `RootPki`.
  shared.tlsRootsHandle = roots => handleOf(roots, RootPki, 'roots');

  for (const C of [Value, RootPki, Identity, ClientAuth, TlsSessions, TlsClient, TlsServer]) {
    freezeMethods(C);
    freezeMethods(C.prototype);
    Object.freeze(C.prototype);
    Object.freeze(C);
  }

  return () =>
    freeze({
      RootPki,
      Identity,
      ClientAuth,
      TlsSessions,
      TlsClient,
      TlsServer,
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
        const roots = handleOf(own(options, 'roots'), RootPki, 'roots');
        const identity = own(options, 'identity');
        const sessions = own(options, 'sessions');
        return new TlsClient(
          token,
          native.tls.client(
            roots,
            identity === undefined ? undefined : handleOf(identity, Identity, 'identity'),
            alpnOf(options),
            sessions === undefined ? undefined : handleOf(sessions, TlsSessions, 'sessions'),
          ),
        );
      },
      /** `{ identities: Identity[] (at least one), clientAuth: ClientAuth (required), alpn?: string[] }`. */
      server(options) {
        const identities = own(options, 'identities');
        if (!Array.isArray(identities) || identities.length === 0) throw new TypeError('identities must be a non-empty array of Identity');
        const handles = identities.map(identity => handleOf(identity, Identity, 'identity'));
        return new TlsServer(token, native.tls.server(handles, ClientAuth.rootsOf(own(options, 'clientAuth')), alpnOf(options)));
      },
    });
};
