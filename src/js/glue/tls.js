// `api.tls`: TLS 1.2/1.3 over `api.net` stream sockets (docs/http-design.md). An ES module factory used by
// index.js, like net.js. Values that are parsed once and reused (`RootPki`, `Identity`, `ClientAuth`,
// `TlsSessions`, `TlsClient`, `TlsServer`) are frozen classes built by named constructors; the native
// parses and validates there, so a bad certificate fails with its own error. A `TlsSocket` is made from a
// pull-mode `api.net` socket, which the handshake consumes. Pull mode only: `mode: 'event'` is `Unsupported`
// until TLS sockets have a pump.
import { freeze, freezeMethods, own, failure, ioHandles, closedIo, errors, shared } from './util.js';
const { BadHandle, Unsupported } = errors;
const MAX_READ = 1 << 28;
const DONE = Promise.resolve();

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

  /** A native value (an id in the Host's TLS table). `release()` forgets it; what was built from it keeps working. */
  class Value {
    #id;
    constructor(made, id) {
      if (made !== token || new.target === Value) throw new TypeError('TLS values are made by their named constructors');
      this.#id = id;
    }
    static idOf(value, Class, name) {
      if (!(value instanceof Class)) throw new TypeError(`${name} must be a ${Class.name}`);
      return value.#id;
    }
    release() {
      native.tls.release(this.#id);
    }
  }
  const idOf = Value.idOf;

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
      return auth.#roots === undefined ? 0 : idOf(auth.#roots, RootPki, 'roots');
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

  /** What a handshake settled, and the peer's certificates. */
  class TlsSocket {
    #id;
    #io;
    #info;
    #tail = DONE;
    #closed = false;
    constructor(made, id, io, info) {
      if (made !== token) throw new TypeError('TLS sockets are made by TlsClient.connect and TlsServer.accept');
      this.#id = id;
      this.#io = io;
      this.#info = info;
      Object.freeze(this.#info);
    }
    get io() {
      return this.#io;
    }
    get closed() {
      return this.#closed || closedIo.has(this.#io);
    }
    /** The negotiated ALPN protocol, or undefined. */
    get alpn() {
      return this.#info.alpn ?? undefined;
    }
    /** 'tls1.2' or 'tls1.3'. */
    get version() {
      return this.#info.version === 12 ? 'tls1.2' : 'tls1.3';
    }
    /** The name the client asked for (as given, or the SNI the server received), or undefined. */
    get servername() {
      return this.#info.servername ?? undefined;
    }
    /** Whether the handshake resumed an earlier session. */
    get resumed() {
      return this.#info.resumed;
    }
    /** The peer's certificates in DER, leaf first (empty when it sent none). */
    get peer() {
      return unpack(native.tls.peer(this.#id));
    }
    /** Reads once: a `Uint8Array` of 1 to `length` plaintext bytes, empty after the peer's `close_notify`. A connection cut without it rejects `UnexpectedEof`. */
    read(length) {
      try {
        if (!Number.isSafeInteger(length) || length < 1 || length > MAX_READ) throw new TypeError('length must be an integer in 1..2**28');
        return native.tls.read(this.#id, length);
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /** Reads once into `buffer` (at least one byte) by copy; resolves the byte count, 0 after `close_notify`. */
    readCopy(buffer) {
      try {
        if (!(buffer instanceof ArrayBuffer) && !ArrayBuffer.isView(buffer)) throw new TypeError('buffer must be an ArrayBuffer or a view');
        if (buffer.byteLength === 0) throw new TypeError('buffer must not be empty');
        return native.tls.readCopy(this.#id, buffer);
      } catch (e) {
        return Promise.reject(e);
      }
    }
    async *[Symbol.asyncIterator]() {
      for (;;) {
        const chunk = await this.read(65536);
        if (chunk.length === 0) return;
        yield chunk;
      }
    }
    /** Sends `data` (copied now); resolves once all of it is in the transport. Sends go out in the order they were made. */
    send(data) {
      try {
        if (!(data instanceof ArrayBuffer) && !ArrayBuffer.isView(data)) throw new TypeError('data must be an ArrayBuffer or a view');
        const sent = this.#tail.then(() => native.tls.write(this.#id, data));
        this.#tail = sent.catch(() => {});
        return sent;
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /**
     * Ends your side: sends `close_notify` once everything sent is out. Reading keeps working; later
     * `send` rejects `BrokenPipe`. `side` is required and only 'write' exists here.
     */
    end(side) {
      try {
        if (side !== 'write') throw new TypeError("side must be 'write'");
        const done = this.#tail.then(() => native.tls.shutdown(this.#id));
        this.#tail = done.catch(() => {});
        return done;
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /** Releases the socket and its transport; pending operations end. Idempotent. */
    close() {
      try {
        if (!this.#closed) {
          this.#closed = true;
          native.tls.close(this.#id);
        }
        return DONE;
      } catch (e) {
        return Promise.reject(e);
      }
    }
    [Symbol.asyncDispose]() {
      return this.close();
    }
    static {
      // For `api.http`: the native id of a TLS socket, or undefined for any other value.
      shared.tlsTake = socket => {
        if (socket === null || typeof socket !== 'object' || !(#id in socket)) return undefined;
        if (socket.#closed || closedIo.has(socket.#io)) throw failure(BadHandle);
        return {
          kind: 1,
          id: socket.#id,
          io: socket.#io,
          consume: () => {
            socket.#closed = true;
          },
        };
      };
    }
  }

  const modeOf = options => {
    const mode = own(options, 'mode');
    if (mode !== 'pull' && mode !== 'event') throw new TypeError("mode must be 'event' or 'pull'");
    if (mode === 'event') throw failure(Unsupported);
  };
  const handshake = (config, socket, begin) => {
    try {
      const taken = shared.netTake(socket);
      const done = begin(ioId(taken.io), taken.id);
      // The native took the socket: the old handle is consumed now, whatever the handshake does.
      taken.consume();
      return done.then(info => new TlsSocket(token, info.id, taken.io, info));
    } catch (e) {
      return Promise.reject(e);
    }
  };

  /** An immutable client configuration; connections are made from it. */
  class TlsClient extends Value {
    /** Handshakes over `socket` (a pull-mode `api.net` socket, consumed); `servername` and `mode` are required. */
    connect(socket, options) {
      try {
        const servername = own(options, 'servername');
        if (typeof servername !== 'string' || servername === '') throw new TypeError('servername must be a string');
        modeOf(options);
        const id = idOf(this, TlsClient, 'this');
        return handshake(this, socket, (io, sock) => native.tls.connect(io, id, sock, servername));
      } catch (e) {
        return Promise.reject(e);
      }
    }
  }

  /** An immutable server configuration; connections are accepted from it. */
  class TlsServer extends Value {
    /** Handshakes over `socket` (a pull-mode `api.net` socket, consumed); `mode` is required. */
    accept(socket, options) {
      try {
        modeOf(options);
        const id = idOf(this, TlsServer, 'this');
        return handshake(this, socket, (io, sock) => native.tls.accept(io, id, sock));
      } catch (e) {
        return Promise.reject(e);
      }
    }
  }

  // For `api.dns`: the native id of a `RootPki`.
  shared.tlsRootsId = roots => idOf(roots, RootPki, 'roots');

  for (const C of [Value, RootPki, Identity, ClientAuth, TlsSessions, TlsSocket, TlsClient, TlsServer]) {
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
      TlsSocket,
      /** `{ roots: RootPki (required), identity?: Identity, alpn?: string[], sessions?: TlsSessions }`. */
      client(options) {
        const roots = idOf(own(options, 'roots'), RootPki, 'roots');
        const identity = own(options, 'identity');
        const sessions = own(options, 'sessions');
        return new TlsClient(
          token,
          native.tls.client(
            roots,
            identity === undefined ? 0 : idOf(identity, Identity, 'identity'),
            alpnOf(options),
            sessions === undefined ? 0 : idOf(sessions, TlsSessions, 'sessions'),
          ),
        );
      },
      /** `{ identities: Identity[] (at least one), clientAuth: ClientAuth (required), alpn?: string[] }`. */
      server(options) {
        const identities = own(options, 'identities');
        if (!Array.isArray(identities) || identities.length === 0) throw new TypeError('identities must be a non-empty array of Identity');
        const ids = new Uint32Array(identities.map(identity => idOf(identity, Identity, 'identity')));
        return new TlsServer(token, native.tls.server(ids, ClientAuth.rootsOf(own(options, 'clientAuth')), alpnOf(options)));
      },
    });
};
