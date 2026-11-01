// `api.http`: HTTP/2 sessions over `api.net` or `api.tls` sockets (docs/http-design.md). An ES module factory used
// by index.js, like net.js and tls.js. `HeaderList` is an ordered, packed sequence of fields (not a map): `put`
// appends into one buffer and the whole list crosses into the native once. A session is made from a pull-mode
// socket, which it consumes; streams are `ClientExchange` / `ServerExchange` objects over the session's table.
// Pull mode only: `mode: 'event'` is `Unsupported` until sessions have a pump.
import { freeze, freezeMethods, own, failure, ioHandles, closedIo, errors, shared } from './util.js';
const { BadHandle, Unsupported, NoApplicationProtocol } = errors;
const HEAD = 6;
const DONE = Promise.resolve();

const encode = text => {
  const out = [];
  for (const ch of text) {
    let c = ch.codePointAt(0);
    if (c >= 0xd800 && c <= 0xdfff) c = 0xfffd;
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
  }
  return Uint8Array.from(out);
};
const decode = (bytes, from, to) => {
  let out = '';
  for (let i = from; i < to;) {
    const b = bytes[i];
    const n = b < 0x80 ? 1 : b >= 0xf0 ? 4 : b >= 0xe0 ? 3 : b >= 0xc0 ? 2 : 0;
    if (n === 0 || i + n > to) {
      out += '�';
      i += 1;
      continue;
    }
    let c = n === 1 ? b : b & (0xff >> (n + 1));
    for (let k = 1; k < n; k++) c = (c << 6) | (bytes[i + k] & 63);
    out += String.fromCodePoint(c);
    i += n;
  }
  return out;
};

export default native => {
  const token = {};
  const ioId = io => {
    if (io === null || typeof io !== 'object' || !ioHandles.has(io) || closedIo.has(io)) throw failure(BadHandle);
    return io.id;
  };
  const NAME = /^[!#$%&'*+\-.^_`|~0-9a-z]+$/;
  let received;
  let ids;

  /**
   * An ordered sequence of header fields, packed into one buffer (`name_len u16 | value_len u32 | name | value`
   * records). Names are lowercase tokens; values are UTF-8 strings without CR, LF or NUL. Duplicates and order are
   * kept. Lists you receive are frozen; one you build is sent whole, in one native call.
   */
  class HeaderList {
    #bytes = new Uint8Array(256);
    #size = 0;
    #count = 0;
    #sealed = false;
    static {
      received = bytes => {
        const list = new HeaderList();
        list.#bytes = bytes;
        list.#size = bytes.length;
        for (let at = 0; at < bytes.length; list.#count++) {
          const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
          at += HEAD + view.getUint16(at, true) + view.getUint32(at + 2, true);
        }
        list.#sealed = true;
        return list;
      };
    }
    /** Appends a field. `name` must be lowercase (`InvalidInput` otherwise, also for a connection-specific one). */
    put(name, value) {
      if (this.#sealed) throw new TypeError('a received HeaderList cannot be changed');
      if (typeof name !== 'string' || !NAME.test(name)) throw new TypeError('header name must be a lowercase token');
      if (typeof value !== 'string' || /[\0\r\n]/.test(value)) throw new TypeError('header value must be a string without CR, LF or NUL');
      const n = encode(name);
      const v = encode(value);
      const need = this.#size + HEAD + n.length + v.length;
      if (need > this.#bytes.length) {
        const grown = new Uint8Array(Math.max(need, this.#bytes.length * 2));
        grown.set(this.#bytes.subarray(0, this.#size));
        this.#bytes = grown;
      }
      const view = new DataView(this.#bytes.buffer);
      view.setUint16(this.#size, n.length, true);
      view.setUint32(this.#size + 2, v.length, true);
      this.#bytes.set(n, this.#size + HEAD);
      this.#bytes.set(v, this.#size + HEAD + n.length);
      this.#size = need;
      this.#count++;
      return this;
    }
    get length() {
      return this.#count;
    }
    *[Symbol.iterator]() {
      const view = new DataView(this.#bytes.buffer, this.#bytes.byteOffset, this.#bytes.byteLength);
      for (let at = 0; at < this.#size;) {
        const n = view.getUint16(at, true);
        const v = view.getUint32(at + 2, true);
        yield [decode(this.#bytes, at + HEAD, at + HEAD + n), decode(this.#bytes, at + HEAD + n, at + HEAD + n + v)];
        at += HEAD + n + v;
      }
    }
    /** The first value of `name`, or undefined. */
    get(name) {
      const wanted = String(name).toLowerCase();
      for (const [n, v] of this) if (n === wanted) return v;
      return undefined;
    }
    getAll(name) {
      const wanted = String(name).toLowerCase();
      const out = [];
      for (const [n, v] of this) if (n === wanted) out.push(v);
      return out;
    }
    has(name) {
      return this.get(name) !== undefined;
    }
    static packed(list) {
      if (!(list instanceof HeaderList)) throw new TypeError('headers must be a HeaderList');
      return list.#bytes.subarray(0, list.#size);
    }
  }
  const EMPTY = new Uint8Array(0);
  const packed = list => (list === undefined ? EMPTY : HeaderList.packed(list));

  const bodyOf = options => {
    const body = own(options, 'body');
    if (body !== undefined && body !== 'stream') throw new TypeError("body must be 'stream' or omitted");
    return body === 'stream' ? 1 : 0;
  };

  /** The event of `next()` made from the native's record. */
  const eventOf = ev => {
    switch (ev.kind) {
      case 0: {
        const event = {
          type: 'headers',
          kind: ['request', 'response', 'trailers'][ev.head],
          headers: received(ev.fields),
          last: ev.last,
          endStream: ev.endStream,
        };
        if (ev.method !== undefined) event.method = ev.method;
        if (ev.scheme !== undefined) event.scheme = ev.scheme;
        if (ev.authority !== undefined) event.authority = ev.authority;
        if (ev.path !== undefined) event.path = ev.path;
        if (ev.status !== 0) event.status = ev.status;
        return freeze(event);
      }
      case 1:
        return freeze({ type: 'data', data: ev.data });
      case 2:
        return freeze({ type: 'end' });
      default:
        return freeze({ type: 'closed', code: ev.code });
    }
  };

  /** One stream of a session. */
  class Exchange {
    #sid;
    #id;
    #done = false;
    constructor(made, sid, id) {
      if (made !== token || new.target === Exchange) throw new TypeError('exchanges are made by their session');
      this.#sid = sid;
      this.#id = id;
    }
    static {
      ids = exchange => [exchange.#sid, exchange.#id];
    }
    get id() {
      return this.#id;
    }
    /** The next event: `{ type: 'headers' | 'data' | 'end' | 'closed' }`, `undefined` after `closed`. A dead connection rejects. */
    async next() {
      const ev = await native.http.next(this.#sid, this.#id);
      if (ev === undefined) return undefined;
      return eventOf(ev);
    }
    /** Gives `bytes` of received body back to the peer's window: call it when the data was used. */
    consume(bytes) {
      if (!Number.isSafeInteger(bytes) || bytes < 0 || bytes > 0xffffffff) throw new TypeError('bytes must be a non-negative integer');
      native.http.consume(this.#sid, this.#id, bytes);
    }
    /** Bytes accepted by `send` that have not left yet. */
    get queued() {
      return native.http.queued(this.#sid, this.#id);
    }
    /** Queues body bytes (copied now); resolves once accepted, waiting while the stream has a window's worth queued. */
    send(data) {
      try {
        if (!(data instanceof ArrayBuffer) && !ArrayBuffer.isView(data)) throw new TypeError('data must be an ArrayBuffer or a view');
        return native.http.send(this.#sid, this.#id, data);
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /** Ends the body, optionally with trailing fields. */
    finish(trailers) {
      native.http.finish(this.#sid, this.#id, packed(trailers));
    }
    /** Resets the stream with an HTTP/2 error code (8 is CANCEL). */
    reset(code = 8) {
      if (!Number.isSafeInteger(code) || code < 0 || code > 0xffffffff) throw new TypeError('code must be a 32-bit unsigned integer');
      native.http.reset(this.#sid, this.#id, code);
    }
    /** Forgets the stream. One whose own side is still being written is cancelled; a finished one ends quietly. */
    release() {
      if (!this.#done) {
        this.#done = true;
        native.http.release(this.#sid, this.#id);
      }
    }
    [Symbol.dispose]() {
      this.release();
    }
  }
  class ClientExchange extends Exchange {}
  class ServerExchange extends Exchange {
    /** Queues the response head: `{ status, headers?: HeaderList, body?: 'stream' }`. */
    respond(options) {
      const status = own(options, 'status');
      if (!Number.isInteger(status) || status < 100 || status > 599) throw new TypeError('status must be an integer in 100..599');
      const [sid, id] = ids(this);
      native.http.respond(sid, id, status, packed(own(options, 'headers')), bodyOf(options));
    }
  }

  /** The connection: what both roles share. */
  class Session {
    #id;
    #io;
    #closed = false;
    constructor(made, id, io) {
      if (made !== token || new.target === Session) throw new TypeError('sessions are made by http.session');
      this.#id = id;
      this.#io = io;
    }
    static idOf(session) {
      if (!(session instanceof Session)) throw new TypeError('not a session');
      if (session.#closed || closedIo.has(session.#io)) throw failure(BadHandle);
      return session.#id;
    }
    get io() {
      return this.#io;
    }
    get closed() {
      return this.#closed || closedIo.has(this.#io);
    }
    /** Resolves once the peer's SETTINGS arrived; open streams after this. */
    ready() {
      try {
        return native.http.ready(Session.idOf(this));
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /** The round trip of a PING in milliseconds. */
    ping() {
      try {
        return native.http.ping(Session.idOf(this));
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /** Starts a graceful close (GOAWAY): streams in flight finish. */
    end() {
      native.http.goaway(Session.idOf(this));
      return DONE;
    }
    /** Releases the session now: the transport is shut down and every stream ends. Idempotent. */
    close() {
      try {
        if (!this.#closed) {
          this.#closed = true;
          native.http.destroy(this.#id);
        }
        return DONE;
      } catch (e) {
        return Promise.reject(e);
      }
    }
    [Symbol.asyncDispose]() {
      return this.close();
    }
  }
  class ClientSession extends Session {
    /** Opens a request: `head` is `{ method, scheme, authority, path }`; options `{ headers?: HeaderList, body?: 'stream' }`. */
    open(head, options) {
      const field = name => {
        const value = own(head, name);
        if (typeof value !== 'string' || value === '') throw new TypeError(`${name} must be a non-empty string`);
        return value;
      };
      const id = native.http.open(
        Session.idOf(this),
        field('method'),
        field('scheme'),
        field('authority'),
        field('path'),
        packed(own(options, 'headers')),
        bodyOf(options),
      );
      return new ClientExchange(token, Session.idOf(this), id);
    }
  }
  class ServerSession extends Session {
    /** The next request stream, or undefined once the session is over. */
    async accept() {
      const id = await native.http.accept(Session.idOf(this));
      return id === undefined ? undefined : new ServerExchange(token, Session.idOf(this), id);
    }
    async *[Symbol.asyncIterator]() {
      for (;;) {
        const exchange = await this.accept();
        if (exchange === undefined) return;
        yield exchange;
      }
    }
  }

  const limitsOf = limits => {
    if (limits === null || typeof limits !== 'object') throw new TypeError('limits is required');
    const read = (name, min) => {
      const value = own(limits, name);
      if (!Number.isInteger(value) || value < min || value > 0x7fffffff)
        throw new TypeError(`limits.${name} must be an integer in ${min}..2**31-1`);
      return value;
    };
    return [read('streams', 1), read('headers', 1), read('window', 1), read('connection', 65535), read('batch', 1)];
  };
  const modeOf = options => {
    const mode = own(options, 'mode');
    if (mode !== 'pull' && mode !== 'event') throw new TypeError("mode must be 'event' or 'pull'");
    if (mode === 'event') throw failure(Unsupported);
  };

  const makeSession = (socket, role, limits) => {
    const taken = shared.tlsTake?.(socket) ?? shared.netTake(socket);
    const id = native.http.session(ioId(taken.io), taken.kind, taken.id, role === 'client' ? 0 : 1, ...limits);
    taken.consume();
    return new (role === 'client' ? ClientSession : ServerSession)(token, id, taken.io);
  };
  // Runs a TLS handshake that must end in 'h2'; a connection that negotiated anything else is closed.
  const secured = async handshake => {
    const socket = await handshake();
    if (socket.alpn !== 'h2') {
      await socket.close();
      throw failure(NoApplicationProtocol);
    }
    return socket;
  };

  /** The listener and accept loop of `http.serve`: every client's requests, from any connection, in arrival order. */
  class HttpServer {
    #listener;
    #sessions = new Set();
    #queue = [];
    #waiting = [];
    #closed = false;
    #dropped = 0;
    constructor(made, listener, tls, limits) {
      if (made !== token) throw new TypeError('servers are made by http.serve');
      this.#listener = listener;
      const wake = () => {
        for (const resolve of this.#waiting.splice(0)) resolve();
      };
      const connection = async plain => {
        let session;
        try {
          const socket = tls === undefined ? plain : await secured(() => tls.accept(plain, { mode: 'pull' }));
          session = makeSession(socket, 'server', limits);
          this.#sessions.add(session);
        } catch {
          // A client that fails its handshake, or does not speak h2, is dropped; `dropped` counts them.
          this.#dropped++;
          await plain.close().catch(() => {});
          return;
        }
        try {
          for await (const exchange of session) {
            this.#queue.push(exchange);
            wake();
          }
        } catch {
          // The connection died; streams already handed out see it through their own `next()`.
        } finally {
          this.#sessions.delete(session);
        }
      };
      (async () => {
        try {
          for (;;) connection(await listener.accept());
        } catch {
          // The listener was closed (`Canceled`) or failed: the server is over.
        }
        this.#closed = true;
        wake();
      })();
    }
    /** The port listened on (the real one when `port: 0` was asked). */
    get port() {
      return this.#listener.port;
    }
    get closed() {
      return this.#closed;
    }
    /** Connections dropped before they became sessions (failed TLS handshake, no 'h2'). */
    get dropped() {
      return this.#dropped;
    }
    /** The next request from any connection, or undefined once the server is closed and none is left. */
    async accept() {
      for (;;) {
        if (this.#queue.length > 0) return this.#queue.shift();
        if (this.#closed) return undefined;
        await new Promise(resolve => this.#waiting.push(resolve));
      }
    }
    async *[Symbol.asyncIterator]() {
      for (;;) {
        const exchange = await this.accept();
        if (exchange === undefined) return;
        yield exchange;
      }
    }
    /** Stops listening and closes every session now. Idempotent. */
    async close() {
      this.#closed = true;
      await this.#listener.close();
      await Promise.all(Array.from(this.#sessions, session => session.close()));
      for (const resolve of this.#waiting.splice(0)) resolve();
    }
    [Symbol.asyncDispose]() {
      return this.close();
    }
  }

  for (const C of [HeaderList, Exchange, ClientExchange, ServerExchange, Session, ClientSession, ServerSession, HttpServer]) {
    freezeMethods(C);
    freezeMethods(C.prototype);
    Object.freeze(C.prototype);
    Object.freeze(C);
  }

  return () =>
    freeze({
      HeaderList,
      ClientSession,
      ServerSession,
      HttpServer,
      /**
       * Starts an HTTP/2 session over `socket` (a pull-mode `api.net` socket or a `TlsSocket`), which it consumes.
       * Options: `role` ('client' | 'server'), `mode` ('pull'), `limits` ({ streams, headers, window, connection,
       * batch }, all required; `connection` at least 65535). Synchronous: `await session.ready()` before opening streams.
       */
      session(socket, options) {
        const role = own(options, 'role');
        if (role !== 'client' && role !== 'server') throw new TypeError("role must be 'client' or 'server'");
        modeOf(options);
        return makeSession(socket, role, limitsOf(own(options, 'limits')));
      },
      /**
       * Dials `{ host, port }` (loopback only for now; `host` defaults to 127.0.0.1) and resolves a `ClientSession`
       * once the peer's SETTINGS arrived. With `tls` (a `TlsClient` that offers 'h2' in its `alpn`) the connection is
       * TLS and `servername` (default: `host`) is checked; the peer must negotiate 'h2' (`NoApplicationProtocol`
       * otherwise). Required: `port`, `mode` ('pull'), `limits`.
       */
      async connect(io, options) {
        const host = own(options, 'host') ?? '127.0.0.1';
        const port = own(options, 'port');
        if (typeof host !== 'string') throw new TypeError('host must be a string');
        if (!Number.isInteger(port) || port < 0 || port > 65535) throw new TypeError('port must be an integer in 0..65535');
        modeOf(options);
        const limits = limitsOf(own(options, 'limits'));
        const tls = own(options, 'tls');
        const servername = own(options, 'servername') ?? host;
        if (typeof servername !== 'string') throw new TypeError('servername must be a string');
        let socket = await shared.net.connect(io, { host, port, mode: 'pull' });
        if (tls !== undefined) socket = await secured(() => tls.connect(socket, { servername, mode: 'pull' }));
        const session = makeSession(socket, 'client', limits);
        try {
          await session.ready();
        } catch (e) {
          await session.close();
          throw e;
        }
        return session;
      },
      /**
       * Listens on `listen` (`{ host?, port? }`, loopback only for now) and serves HTTP/2 to every client. With `tls` (a
       * `TlsServer` whose `alpn` includes 'h2') connections are TLS and must negotiate 'h2'; without it the server
       * speaks cleartext HTTP/2 (h2c), for loopback. Required: `mode` ('pull'), `limits`. The returned server keeps
       * the program alive until `close()`.
       */
      serve(io, options) {
        const listen = own(options, 'listen');
        if (listen !== undefined && (listen === null || typeof listen !== 'object')) throw new TypeError('listen must be an object');
        modeOf(options);
        const limits = limitsOf(own(options, 'limits'));
        const tls = own(options, 'tls');
        const listener = shared.net.listen(io, {
          host: own(listen, 'host') ?? '127.0.0.1',
          port: own(listen, 'port') ?? 0,
          mode: 'pull',
          socketMode: 'pull',
        });
        return new HttpServer(token, listener, tls, limits);
      },
    });
};
