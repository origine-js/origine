// `api.http`: HTTP/2 sessions over `api.net` or `api.tls` sockets (docs/http-design.md). An ES module factory used
// by index.js, like net.js and tls.js. `HeaderList` is an ordered, packed sequence of fields (not a map): `put`
// appends into one buffer and the whole list crosses into the native once. A session is made from a pull-mode
// socket, which it consumes; streams are `ClientExchange` / `ServerExchange` objects over the session's table.
// A session, a server and their exchanges have one of two read modes, fixed when they are made and visible in their
// class: `Pull*` (`next()`, `accept()`) or `Event*` (`register(event, handler)`); the write side is shared. Event mode
// is a dispatcher over the same natives, one event at a time, so handlers see events in order.
import { freeze, freezeMethods, own, failure, errors, shared } from './util.js';
import { IpAddr, SocketAddr } from './addr.js';
import client from './http/client.js';
import { constants, fromDetail } from './errors.js';
const { BadHandle, NoApplicationProtocol, PermissionDenied } = errors;
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
  // `host` (an IP literal, or `localhost` for 127.0.0.1: never resolved) and `port` as a `SocketAddr`. A name is
  // refused like the network ceiling refuses it: resolve it with `api.dns` and pass the address.
  const addrOf = (host, port) => {
    let ip;
    try {
      ip = IpAddr.parse(host.toLowerCase() === 'localhost' ? '127.0.0.1' : host);
    } catch {
      throw fromDetail(PermissionDenied, { subject: host });
    }
    return SocketAddr.new(ip, port);
  };
  const liveIo = io => {
    if (!(io instanceof shared.Io) || io.closed) throw failure(BadHandle);
    return io;
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
    #watch;
    constructor(made, sid, id) {
      if (made !== token || new.target === Exchange) throw new TypeError(constants.ILLEGAL_CONSTRUCTOR);
      this.#sid = sid;
      this.#id = id;
    }
    static {
      ids = exchange => [exchange.#sid, exchange.#id];
    }
    get id() {
      return this.#id;
    }
    static next(exchange) {
      return native.http.next(exchange.#sid, exchange.#id).then(
        ev => {
          if (ev === undefined || ev.kind === 3) exchange.#over();
          return ev === undefined ? undefined : eventOf(ev);
        },
        e => {
          exchange.#over();
          throw e;
        },
      );
    }
    // The pool's hook: `fn` runs once when the stream is over (its `closed` event was read, the connection died, or `release`).
    static watch(exchange, fn) {
      exchange.#watch = fn;
    }
    #over() {
      const fn = this.#watch;
      this.#watch = undefined;
      if (fn !== undefined) fn();
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
      this.#over();
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

  const rethrow = e => {
    Promise.reject(e);
  };
  /**
   * The handler table of an event-mode object. The first `register` starts `begin(hub)` (one microtask later, so
   * handlers registered in the same turn all see the first event). A handler that throws goes to the `error`
   * handlers; with none, or when one of those throws, it is an unhandled rejection.
   */
  const makeHub = (names, begin) => {
    const handlers = new Map();
    let started = false;
    const hub = {
      register(event, handler) {
        if (!names.includes(event)) throw new TypeError(`event must be one of ${names.join(', ')}`);
        if (typeof handler !== 'function') throw new TypeError('handler must be a function');
        let entries = handlers.get(event);
        if (entries === undefined) handlers.set(event, (entries = new Set()));
        const entry = { fn: handler };
        entries.add(entry);
        if (!started) {
          started = true;
          DONE.then(() => begin(hub));
        }
        return freeze({
          unregister() {
            return entries.delete(entry);
          },
        });
      },
      /** Calls the handlers of `event`; whether there were any. */
      emit(event, arg) {
        const entries = handlers.get(event);
        if (entries === undefined || entries.size === 0) return false;
        for (const entry of Array.from(entries)) {
          try {
            entry.fn(arg);
          } catch (e) {
            if (event === 'error') rethrow(e);
            else hub.fail(e);
          }
        }
        return true;
      },
      fail(e) {
        if (!hub.emit('error', e)) rethrow(e);
      },
    };
    return hub;
  };

  class PullClientExchange extends ClientExchange {
    /** The next event: `{ type: 'headers' | 'data' | 'end' | 'closed' }`, `undefined` after `closed`. A dead connection rejects. */
    next() {
      return Exchange.next(this);
    }
  }
  class PullServerExchange extends ServerExchange {
    /** As {@link PullClientExchange.next}. */
    next() {
      return Exchange.next(this);
    }
  }
  const hubs = new WeakMap();
  const pumpExchange = async (exchange, hub) => {
    try {
      for (;;) {
        const ev = await Exchange.next(exchange);
        if (ev === undefined) return;
        if (ev.type === 'closed') hub.emit('close', ev);
        else hub.emit(ev.type, ev);
      }
    } catch (e) {
      hub.fail(e);
    }
  };
  const registerOn = (exchange, event, handler) => {
    let hub = hubs.get(exchange);
    if (hub === undefined)
      hubs.set(exchange, (hub = makeHub(['headers', 'data', 'end', 'close', 'error'], hub => pumpExchange(exchange, hub))));
    return hub.register(event, handler);
  };
  class EventClientExchange extends ClientExchange {
    /**
     * Subscribes `handler` to `headers` (the head, `last` marks the end of a block), `data` (`{ data }`; give the bytes
     * back with `consume`), `end`, `close` (`{ code }`) or `error` and returns `{ unregister() }`. Events are delivered
     * one at a time, in order, from the first `register` on.
     */
    register(event, handler) {
      return registerOn(this, event, handler);
    }
  }
  class EventServerExchange extends ServerExchange {
    /** As {@link EventClientExchange.register}. */
    register(event, handler) {
      return registerOn(this, event, handler);
    }
  }

  /** The connection: what both roles share. */
  class Session {
    #id;
    #io;
    #closed = false;
    constructor(made, id, io) {
      if (made !== token || new.target === Session) throw new TypeError(constants.ILLEGAL_CONSTRUCTOR);
      this.#id = id;
      this.#io = io;
    }
    static idOf(session) {
      if (!(session instanceof Session)) throw new TypeError('not a session');
      if (session.#closed || session.#io?.closed) throw failure(BadHandle);
      return session.#id;
    }
    get io() {
      return this.#io;
    }
    get closed() {
      return this.#closed || (this.#io?.closed ?? false);
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
    #event;
    constructor(made, id, io, event) {
      super(made, id, io);
      this.#event = event;
    }
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
      return new (this.#event ? EventClientExchange : PullClientExchange)(token, Session.idOf(this), id);
    }
  }
  class ServerSession extends Session {
    /** The next request stream of `session`, or undefined once it is over. */
    static async take(session) {
      const sid = Session.idOf(session);
      const id = await native.http.accept(sid);
      return id === undefined
        ? undefined
        : new (session instanceof EventServerSession ? EventServerExchange : PullServerExchange)(token, sid, id);
    }
  }
  class PullServerSession extends ServerSession {
    /** The next request stream, or undefined once the session is over. */
    accept() {
      return ServerSession.take(this);
    }
    async *[Symbol.asyncIterator]() {
      for (;;) {
        const exchange = await this.accept();
        if (exchange === undefined) return;
        yield exchange;
      }
    }
  }
  /** A request nobody listens for is refused (REFUSED_STREAM). */
  const deliver = (hub, exchange) => {
    if (hub.emit('request', exchange)) return;
    exchange.reset(7);
    exchange.release();
  };
  const sessionHubs = new WeakMap();
  const closeSent = new WeakSet();
  // `close` goes out once, whether the session ended or was closed here.
  const sendClose = session => {
    const hub = sessionHubs.get(session);
    if (hub === undefined || closeSent.has(session)) return;
    closeSent.add(session);
    hub.emit('close');
  };
  const pumpRequests = async (session, hub) => {
    try {
      for (;;) {
        const exchange = await ServerSession.take(session);
        if (exchange === undefined) break;
        deliver(hub, exchange);
      }
    } catch (e) {
      if (!session.closed) hub.fail(e);
    }
    sendClose(session);
  };
  class EventServerSession extends ServerSession {
    /**
     * Subscribes `handler` to `request` (a new `EventServerExchange`; one nobody listens for is refused), `close` (the session
     * is over) or `error` and returns `{ unregister() }`. Requests arrive in order from the first `register` on.
     */
    register(event, handler) {
      let hub = sessionHubs.get(this);
      if (hub === undefined) sessionHubs.set(this, (hub = makeHub(['request', 'close', 'error'], hub => pumpRequests(this, hub))));
      return hub.register(event, handler);
    }
    close() {
      const done = super.close();
      sendClose(this);
      return done;
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
    return mode;
  };

  // `stream`: a native stream (plain or TLS) nothing is using, consumed by the native. `io` is what `session.io`
  // reports (undefined for `http.session`, whose stream does not say).
  const makeSession = (stream, role, limits, mode, io) => {
    const id = native.http.session(stream, role === 'client' ? 0 : 1, ...limits);
    const event = mode === 'event';
    if (role === 'client') return new ClientSession(token, id, io, event);
    return new (event ? EventServerSession : PullServerSession)(token, id, io);
  };
  // Runs a TLS handshake that must end in 'h2'; a connection that negotiated anything else is closed.
  const secured = async handshake => {
    const socket = await handshake();
    if (shared.tlsInfo?.(socket)?.alpn !== 'h2') {
      await socket.close();
      throw failure(NoApplicationProtocol);
    }
    return socket;
  };

  /** The listener and accept loop of `http.serve`: every client's requests, from any connection, in arrival order. */
  class HttpServer {
    #listener;
    #port;
    #sessions = new Set();
    #queue = [];
    #waiting = [];
    #closed = false;
    #dropped = 0;
    #hub = makeHub(['request', 'close', 'error'], () => {});
    constructor(made, listener, tls, limits, mode, io) {
      if (made !== token || new.target === HttpServer) throw new TypeError(constants.ILLEGAL_CONSTRUCTOR);
      this.#listener = listener;
      this.#port = listener.localAddr.port;
      const event = mode === 'event';
      const wake = () => {
        for (const resolve of this.#waiting.splice(0)) resolve();
      };
      const connection = async plain => {
        let session;
        try {
          const socket = tls === undefined ? plain : await secured(() => tls.accept(plain));
          session = makeSession(socket, 'server', limits, mode, io);
          this.#sessions.add(session);
        } catch {
          // A client that fails its handshake, or does not speak h2, is dropped; `dropped` counts them.
          this.#dropped++;
          await plain.close().catch(() => {});
          return;
        }
        if (event) {
          session.register('request', exchange => deliver(this.#hub, exchange));
          session.register('error', () => {
            // The connection died; streams already handed out see it through their own events.
          });
          session.register('close', () => this.#sessions.delete(session));
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
        this.#hub.emit('close');
      })();
    }
    static next(server) {
      return (async () => {
        for (;;) {
          if (server.#queue.length > 0) return server.#queue.shift();
          if (server.#closed) return undefined;
          await new Promise(resolve => server.#waiting.push(resolve));
        }
      })();
    }
    static on(server, event, handler) {
      return server.#hub.register(event, handler);
    }
    /** The port listened on (the real one when `port: 0` was asked). */
    get port() {
      return this.#port;
    }
    get closed() {
      return this.#closed;
    }
    /** Connections dropped before they became sessions (failed TLS handshake, no 'h2'). */
    get dropped() {
      return this.#dropped;
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
  class PullHttpServer extends HttpServer {
    /** The next request from any connection, or undefined once the server is closed and none is left. */
    accept() {
      return HttpServer.next(this);
    }
    async *[Symbol.asyncIterator]() {
      for (;;) {
        const exchange = await this.accept();
        if (exchange === undefined) return;
        yield exchange;
      }
    }
  }
  class EventHttpServer extends HttpServer {
    /**
     * Subscribes `handler` to `request` (a new `EventServerExchange` from any connection; one nobody listens for is
     * refused), `close` (the server is over) or `error`, and returns `{ unregister() }`.
     */
    register(event, handler) {
      return HttpServer.on(this, event, handler);
    }
  }

  const connect = async (io, options) => {
    const host = own(options, 'host') ?? '127.0.0.1';
    const port = own(options, 'port');
    if (typeof host !== 'string') throw new TypeError('host must be a string');
    if (!Number.isInteger(port) || port < 0 || port > 65535) throw new TypeError('port must be an integer in 0..65535');
    const mode = modeOf(options);
    const limits = limitsOf(own(options, 'limits'));
    const tls = own(options, 'tls');
    const servername = own(options, 'servername') ?? host;
    if (typeof servername !== 'string') throw new TypeError('servername must be a string');
    let socket = await liveIo(io).tcp.connect(addrOf(host, port));
    if (tls !== undefined) socket = await secured(() => tls.connect(socket, { servername }));
    const session = makeSession(socket, 'client', limits, mode, io);
    try {
      await session.ready();
    } catch (e) {
      await session.close();
      throw e;
    }
    return session;
  };

  const { ClientPool, FetchResponse, pool, fetch } = client({
    connect,
    watch: Exchange.watch,
    peer: session => native.http.peer(Session.idOf(session)), // the peer's stream limit, or -1 once no stream can be opened
    merge: lists => {
      const parts = lists.map(list => HeaderList.packed(list));
      const out = new Uint8Array(parts.reduce((n, part) => n + part.length, 0));
      let at = 0;
      for (const part of parts) {
        out.set(part, at);
        at += part.length;
      }
      return received(out);
    },
    HeaderList,
    limitsOf,
    modeOf,
  });

  for (const C of [
    HeaderList,
    Exchange,
    ClientExchange,
    ServerExchange,
    PullClientExchange,
    PullServerExchange,
    EventClientExchange,
    EventServerExchange,
    Session,
    ClientSession,
    ServerSession,
    PullServerSession,
    EventServerSession,
    HttpServer,
    PullHttpServer,
    EventHttpServer,
    ClientPool,
    FetchResponse,
  ]) {
    freezeMethods(C);
    freezeMethods(C.prototype);
    Object.freeze(C.prototype);
    Object.freeze(C);
  }

  return () =>
    freeze({
      HeaderList,
      ClientExchange,
      ServerExchange,
      PullClientExchange,
      PullServerExchange,
      EventClientExchange,
      EventServerExchange,
      ClientSession,
      ServerSession,
      PullServerSession,
      EventServerSession,
      HttpServer,
      PullHttpServer,
      EventHttpServer,
      ClientPool,
      FetchResponse,
      pool,
      fetch,
      /**
       * Starts an HTTP/2 session over `socket` (a native stream nothing is using, plain or made by `api.tls`), which it consumes.
       * Options: `role` ('client' | 'server'), `mode` ('pull' or 'event'), `limits` ({ streams, headers, window, connection,
       * batch }, all required; `connection` at least 65535). Synchronous: `await session.ready()` before opening streams.
       */
      session(socket, options) {
        const role = own(options, 'role');
        if (role !== 'client' && role !== 'server') throw new TypeError("role must be 'client' or 'server'");
        const mode = modeOf(options);
        return makeSession(socket, role, limitsOf(own(options, 'limits')), mode, undefined);
      },
      /**
       * Dials `{ host, port }` (loopback only for now; `host` defaults to 127.0.0.1) and resolves a `ClientSession`
       * once the peer's SETTINGS arrived. With `tls` (a `TlsClient` that offers 'h2' in its `alpn`) the connection is
       * TLS and `servername` (default: `host`) is checked; the peer must negotiate 'h2' (`NoApplicationProtocol`
       * otherwise). Required: `port`, `mode` ('pull' or 'event'), `limits`.
       */
      connect,
      /**
       * Listens on `listen` (`{ host?, port? }`, loopback only for now) and serves HTTP/2 to every client. With `tls` (a
       * `TlsServer` whose `alpn` includes 'h2') connections are TLS and must negotiate 'h2'; without it the server
       * speaks cleartext HTTP/2 (h2c), for loopback. Required: `mode` ('pull' or 'event'), `limits`. The returned server keeps
       * the program alive until `close()`.
       */
      serve(io, options) {
        const listen = own(options, 'listen');
        if (listen !== undefined && (listen === null || typeof listen !== 'object')) throw new TypeError('listen must be an object');
        const mode = modeOf(options);
        const limits = limitsOf(own(options, 'limits'));
        const tls = own(options, 'tls');
        const host = own(listen, 'host') ?? '127.0.0.1';
        const port = own(listen, 'port') ?? 0;
        if (typeof host !== 'string') throw new TypeError('host must be a string');
        if (!Number.isInteger(port) || port < 0 || port > 65535) throw new TypeError('port must be an integer in 0..65535');
        const listener = liveIo(io).tcp.listen(addrOf(host, port)).pulling();
        return new (mode === 'event' ? EventHttpServer : PullHttpServer)(token, listener, tls, limits, mode, io);
      },
    });
};
