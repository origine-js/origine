// `api.http` client layer: `ClientPool` (sessions reused per origin), redirect following and `fetch` on top of it
// (docs/http-design.md). Built by http.js, which hands over what only it can reach: `connect`, the exchange `watch` hook,
// the session's `peer` limits and the `HeaderList` helpers. Pull-mode `fetch` only; the pool serves both modes.
import { freeze, freezeMethods, own, failure, errors } from '../util.js';
import { constants } from '../errors.js';
const {
  BadHandle,
  WouldBlock,
  Unsupported,
  InvalidInput,
  PermissionDenied,
  QuotaExceeded,
  ProtocolError,
  UnexpectedEof,
  ConnectionReset,
  BrokenPipe,
} = errors;

export default k => {
  const { connect, watch, peer, merge, HeaderList, limitsOf, modeOf } = k;
  const token = {};
  const tlsIds = new WeakMap();
  let tlsCount = 0;
  const tlsId = tls => {
    let id = tlsIds.get(tls);
    if (id === undefined) tlsIds.set(tls, (id = ++tlsCount));
    return id;
  };
  const TOKEN = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;
  const LITERAL = /^(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9a-fA-F:.]*:[0-9a-fA-F:.]*)$/;
  const isBytes = value => value instanceof ArrayBuffer || ArrayBuffer.isView(value);
  const integer = (object, name, min, max, what) => {
    const value = own(object, name);
    if (!Number.isSafeInteger(value) || value < min || value > max)
      throw new TypeError(`${what}.${name} must be an integer in ${min}..${max}`);
    return value;
  };

  /** The origin a pool keys on: `scheme`, `host` (lowercase; a name or an IP literal), `port`, the TLS configuration and `servername`. */
  const targetOf = target => {
    if (target === null || typeof target !== 'object') throw new TypeError('target must be an object');
    const scheme = own(target, 'scheme');
    if (scheme !== 'http' && scheme !== 'https') throw new TypeError("scheme must be 'http' or 'https'");
    const host = own(target, 'host');
    if (typeof host !== 'string' || host === '') throw new TypeError('host must be a non-empty string');
    const port = own(target, 'port');
    if (!Number.isInteger(port) || port < 0 || port > 65535) throw new TypeError('port must be an integer in 0..65535');
    const tls = own(target, 'tls');
    if (scheme === 'https' && (tls === null || typeof tls !== 'object')) throw new TypeError('an https target needs tls');
    if (scheme === 'http' && tls !== undefined) throw new TypeError('an http target has no tls');
    const servername = own(target, 'servername') ?? host;
    if (typeof servername !== 'string') throw new TypeError('servername must be a string');
    return { scheme, host: host.toLowerCase(), port, tls, servername };
  };
  const keyOf = t => `${t.scheme}|${t.host}|${t.port}|${t.tls === undefined ? 0 : tlsId(t.tls)}|${t.servername}`;

  /**
   * A set of HTTP/2 client sessions, shared by the requests of one program. Sessions are keyed by origin (scheme, host,
   * port, TLS configuration, servername); a request goes to a session of its key with a free stream (the peer's
   * `SETTINGS_MAX_CONCURRENT_STREAMS`, read after each connect), else the pool dials another session of that key, else it waits.
   */
  class ClientPool {
    #io;
    #mode;
    #limits;
    #lookup;
    #policy;
    #keys = new Map();
    #total = 0;
    #waiters = [];
    #clock = 0;
    #closed = false;
    constructor(made, io, options) {
      if (made !== token || new.target !== ClientPool) throw new TypeError(constants.ILLEGAL_CONSTRUCTOR);
      this.#io = io;
      this.#mode = modeOf(options);
      limitsOf(own(options, 'limits'));
      this.#limits = own(options, 'limits');
      const lookup = own(options, 'lookup');
      if (lookup !== undefined && typeof lookup !== 'function') throw new TypeError('lookup must be a function');
      this.#lookup = lookup;
      const sessions = own(options, 'sessions');
      if (sessions === null || typeof sessions !== 'object') throw new TypeError('sessions is required');
      this.#policy = freeze({
        limit: integer(sessions, 'limit', 1, 0x7fffffff, 'sessions'),
        perKey: integer(sessions, 'perKey', 1, 0x7fffffff, 'sessions'),
        idle: integer(sessions, 'idle', 0, 2147483647, 'sessions'),
        queue: integer(sessions, 'queue', 0, 0x7fffffff, 'sessions'),
      });
    }
    /** The read mode of the sessions, so of the exchanges `open` returns. */
    get mode() {
      return this.#mode;
    }
    /** The sizes and times the pool was made with. */
    get sessions() {
      return this.#policy;
    }
    /** Sessions open or being dialed. */
    get size() {
      return this.#total;
    }
    /** Requests waiting for a stream or a session slot. */
    get waiting() {
      return this.#waiters.length;
    }
    get closed() {
      return this.#closed;
    }
    /**
     * Opens a request on a pooled session. `target` is the origin (`{ scheme, host, port, tls?, servername? }`), `head` the
     * request (`{ method, authority, path }`; the scheme is the target's), `options` as `ClientSession.open`.
     */
    async open(target, head, options) {
      const t = targetOf(target);
      const text = name => {
        const value = own(head, name);
        if (typeof value !== 'string' || value === '') throw new TypeError(`${name} must be a non-empty string`);
        return value;
      };
      const request = { method: text('method'), scheme: t.scheme, authority: text('authority'), path: text('path') };
      for (;;) {
        const slot = await this.#lease(t);
        let exchange;
        try {
          exchange = slot.session.open(request, options);
        } catch (e) {
          this.#unlease(slot);
          // A reused session that turned out dead (GOAWAY, closed by the peer): forget it and take another.
          if (e?.errno === BrokenPipe && !slot.fresh) {
            this.#drop(slot);
            continue;
          }
          if (e?.errno === BrokenPipe) this.#drop(slot);
          throw e;
        }
        slot.fresh = false;
        watch(exchange, () => this.#unlease(slot));
        return exchange;
      }
    }
    /** Closes every session now (streams in flight end) and fails the requests waiting. Idempotent. */
    async close() {
      if (this.#closed) return;
      this.#closed = true;
      const slots = [];
      for (const entry of this.#keys.values()) slots.push(...entry.slots);
      for (const slot of slots) this.#drop(slot);
      this.#keys.clear();
      for (const waiter of this.#waiters.splice(0)) waiter.reject(failure(BadHandle, 'the pool is closed'));
      await Promise.all(slots.map(slot => slot.session.close()));
    }
    [Symbol.asyncDispose]() {
      return this.close();
    }

    async #lease(t) {
      const key = keyOf(t);
      for (;;) {
        if (this.#closed) throw failure(BadHandle, 'the pool is closed');
        let entry = this.#keys.get(key);
        if (entry === undefined) this.#keys.set(key, (entry = { key, target: t, slots: [], dialing: 0 }));
        const slot = this.#room(entry);
        if (slot !== undefined) {
          this.#take(slot);
          return slot;
        }
        if (entry.dialing === 0 && entry.slots.length < this.#policy.perKey && (this.#total < this.#policy.limit || this.#evict())) {
          return this.#dial(entry);
        }
        await this.#wait();
      }
    }
    // A session of `entry` that can take one more stream; sessions found dead or going away are dropped or drained.
    #room(entry) {
      for (const slot of Array.from(entry.slots)) {
        if (slot.draining) continue;
        let streams = -1;
        try {
          if (!slot.session.closed) streams = peer(slot.session);
        } catch {
          streams = -1;
        }
        if (streams < 0) {
          if (slot.active === 0) this.#drop(slot);
          else slot.draining = true;
          continue;
        }
        if (slot.active < streams) return slot;
      }
      return undefined;
    }
    #take(slot) {
      slot.active++;
      slot.used = ++this.#clock;
      if (slot.timer !== undefined) {
        slot.timer.cancel();
        slot.timer = undefined;
      }
    }
    #unlease(slot) {
      if (slot.gone || slot.active === 0) return;
      slot.active--;
      slot.used = ++this.#clock;
      if (slot.active === 0) {
        if (slot.draining || this.#policy.idle === 0 || slot.session.closed) this.#drop(slot);
        else {
          const timer = this.#io.timer.timer(this.#policy.idle);
          slot.timer = timer;
          timer.promise.then(
            () => {
              if (slot.timer === timer && slot.active === 0) this.#drop(slot);
            },
            () => {},
          );
        }
      }
      this.#wake();
    }
    #drop(slot) {
      if (slot.gone) return;
      slot.gone = true;
      if (slot.timer !== undefined) slot.timer.cancel();
      slot.timer = undefined;
      const entry = slot.entry;
      entry.slots.splice(entry.slots.indexOf(slot), 1);
      if (entry.slots.length === 0 && entry.dialing === 0) this.#keys.delete(entry.key);
      this.#total--;
      slot.session.close().catch(() => {});
      this.#wake();
    }
    // Closes the idle session used longest ago, to make room for another origin; whether there was one.
    #evict() {
      let oldest;
      for (const entry of this.#keys.values()) {
        for (const slot of entry.slots) if (slot.active === 0 && (oldest === undefined || slot.used < oldest.used)) oldest = slot;
      }
      if (oldest === undefined) return false;
      this.#drop(oldest);
      return true;
    }
    #wait() {
      if (this.#waiters.length >= this.#policy.queue) throw failure(WouldBlock, 'the pool queue is full');
      return new Promise((resolve, reject) => this.#waiters.push({ resolve, reject }));
    }
    #wake() {
      for (const waiter of this.#waiters.splice(0)) waiter.resolve();
    }
    async #dial(entry) {
      const t = entry.target;
      entry.dialing++;
      this.#total++;
      let session;
      try {
        let host = t.host;
        if (!LITERAL.test(host)) {
          if (this.#lookup === undefined) throw failure(InvalidInput, 'the host is a name and the pool has no lookup');
          host = await this.#lookup(host);
          if (typeof host !== 'string') throw new TypeError('lookup must resolve an IP address string');
        }
        session = await connect(this.#io, {
          host,
          port: t.port,
          tls: t.tls,
          servername: t.servername,
          mode: this.#mode,
          limits: this.#limits,
        });
      } catch (e) {
        entry.dialing--;
        this.#total--;
        if (entry.slots.length === 0 && entry.dialing === 0) this.#keys.delete(entry.key);
        this.#wake();
        throw e;
      }
      entry.dialing--;
      if (this.#closed) {
        this.#total--;
        await session.close();
        throw failure(BadHandle, 'the pool is closed');
      }
      const slot = { entry, session, active: 1, used: ++this.#clock, timer: undefined, fresh: true, draining: false, gone: false };
      entry.slots.push(slot);
      this.#wake();
      return slot;
    }
  }

  // ---- URLs ----
  const parseUrl = text => {
    const m = /^(https?):\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(?:#.*)?$/i.exec(text);
    if (m === null) return undefined;
    const scheme = m[1].toLowerCase();
    let host = m[2];
    let portText;
    let bracket = false;
    const v6 = /^\[([0-9a-fA-F:.]+)\](?::(\d*))?$/.exec(host);
    if (v6 !== null) {
      host = v6[1];
      portText = v6[2];
      bracket = true;
    } else {
      const at = host.lastIndexOf(':');
      if (at >= 0) {
        portText = host.slice(at + 1);
        host = host.slice(0, at);
      }
    }
    host = host.toLowerCase();
    if (host === '' || /[\s[\]@]/.test(host)) return undefined;
    const fallback = scheme === 'https' ? 443 : 80;
    if (portText !== undefined && portText !== '' && !/^\d{1,5}$/.test(portText)) return undefined;
    const port = portText === undefined || portText === '' ? fallback : Number(portText);
    if (port > 65535) return undefined;
    const path = (m[3] === '' ? '/' : m[3]) + (m[4] ?? '');
    const authority = (bracket ? `[${host}]` : host) + (port === fallback ? '' : `:${port}`);
    return { scheme, host, port, path, authority, origin: `${scheme}://${host}:${port}`, text: `${scheme}://${authority}${path}` };
  };
  const removeDots = path => {
    const segments = path.split('/');
    const out = [];
    segments.forEach((segment, i) => {
      const last = i === segments.length - 1;
      if (segment === '.') {
        if (last) out.push('');
      } else if (segment === '..') {
        if (out.length > 1) out.pop();
        if (last) out.push('');
      } else out.push(segment);
    });
    return out.join('/');
  };
  // RFC 3986 reference resolution, for the `Location` of a redirect.
  const resolveRef = (base, ref) => {
    if (/^[a-z][a-z0-9+.-]*:/i.test(ref)) return ref;
    const root = `${base.scheme}://${base.authority}`;
    if (ref.startsWith('//')) return `${base.scheme}:${ref}`;
    if (ref.startsWith('/')) return root + ref;
    const basePath = base.path.split('?')[0];
    if (ref.startsWith('?')) return root + basePath + ref;
    if (ref.startsWith('#')) return root + base.path;
    const cut = ref.search(/[?#]/);
    const head = cut < 0 ? ref : ref.slice(0, cut);
    return root + removeDots(basePath.slice(0, basePath.lastIndexOf('/') + 1) + head) + (cut < 0 ? '' : ref.slice(cut));
  };

  // ---- fetch ----
  const REDIRECTS = new Set([301, 302, 303, 307, 308]);
  const BODY_HEADERS = new Set(['content-length', 'content-type', 'content-encoding', 'content-language', 'content-location']);
  const without = (list, names) => {
    const out = HeaderList.of([]);
    if (list !== undefined) for (const [name, value] of list) if (!names.has(name)) out.put(name, value);
    return out;
  };
  const cancel = exchange => {
    try {
      exchange.reset(8);
    } catch {
      // Already over.
    }
    exchange.release();
  };
  // Sends the request body in the background: the peer may answer before it is complete, and `send` waits for its window.
  const upload = async (exchange, body, state) => {
    try {
      if (isBytes(body)) await exchange.send(body);
      else for await (const chunk of body) await exchange.send(chunk);
      exchange.finish();
    } catch (e) {
      state.error = e;
      try {
        exchange.reset(8);
      } catch {
        // Already over.
      }
    }
  };
  const reset = (code, state) => state.error ?? failure(ConnectionReset, `the stream was reset by the peer (code ${code})`);
  // Reads up to the final response head (skipping 1xx blocks); a block may arrive in several batches.
  const readHead = async (exchange, state) => {
    let block;
    for (;;) {
      const ev = await exchange.next();
      if (ev === undefined) throw failure(UnexpectedEof, 'the stream ended before a response');
      if (ev.type === 'closed') throw ev.code === 0 ? failure(UnexpectedEof, 'the stream ended before a response') : reset(ev.code, state);
      if (ev.type === 'data') exchange.consume(ev.data.length);
      if (ev.type !== 'headers' || ev.kind !== 'response') continue;
      if (ev.status !== undefined) block = { status: ev.status, lists: [] };
      block.lists.push(ev.headers);
      if (!ev.last) continue;
      if (block.status >= 200) {
        return { status: block.status, headers: block.lists.length === 1 ? block.lists[0] : merge(block.lists), endStream: ev.endStream };
      }
      block = undefined;
    }
  };

  /** The body of a {@link FetchResponse}: read it once with `for await`. */
  class ResponseBody {
    #response;
    constructor(made, response) {
      if (made !== token) throw new TypeError(constants.ILLEGAL_CONSTRUCTOR);
      this.#response = response;
    }
    [Symbol.asyncIterator]() {
      return FetchResponse.iterate(this.#response);
    }
  }
  /**
   * What `http.fetch` resolves: the final response head and its body. The stream stays open (and holds a session slot of
   * the pool) until the body is read to its end, the iteration stops early (cancelling the stream), or `close()`.
   */
  class FetchResponse {
    #exchange;
    #state;
    #body;
    #empty;
    #taken = false;
    #over = false;
    #trailers;
    constructor(made, parts) {
      if (made !== token) throw new TypeError(constants.ILLEGAL_CONSTRUCTOR);
      this.status = parts.status;
      this.headers = parts.headers;
      this.url = parts.url;
      this.redirected = parts.redirected;
      this.#exchange = parts.exchange;
      this.#state = parts.state;
      this.#empty = parts.endStream;
      this.#body = new ResponseBody(token, this);
      if (this.#empty) this.#finish(false);
      Object.freeze(this);
    }
    /** The body, an async iterable of `Uint8Array` chunks. */
    get body() {
      return this.#body;
    }
    /** Trailing fields, once the body was read to its end; `undefined` before or when there were none. */
    get trailers() {
      return this.#trailers;
    }
    #finish(abort) {
      if (this.#over) return;
      this.#over = true;
      if (abort) cancel(this.#exchange);
      else this.#exchange.release();
    }
    static iterate(response) {
      if (response.#taken) throw new TypeError('the body can be read only once');
      response.#taken = true;
      const exchange = response.#exchange;
      let unused = 0;
      let lists = [];
      const iterator = {
        async next() {
          if (response.#over) return { done: true, value: undefined };
          // The previous chunk was used when the next one is asked for: that gives its bytes back to the peer's window.
          if (unused > 0) {
            exchange.consume(unused);
            unused = 0;
          }
          try {
            for (;;) {
              const ev = await exchange.next();
              if (ev === undefined) break;
              if (ev.type === 'data') {
                if (ev.data.length === 0) continue;
                unused = ev.data.length;
                return { done: false, value: ev.data };
              }
              if (ev.type === 'headers' && ev.kind === 'trailers') {
                lists.push(ev.headers);
                if (ev.last) {
                  response.#trailers = lists.length === 1 ? lists[0] : merge(lists);
                  lists = [];
                }
              } else if (ev.type === 'closed') {
                if (ev.code !== 0) throw reset(ev.code, response.#state);
                break;
              }
            }
            response.#finish(false);
            return { done: true, value: undefined };
          } catch (e) {
            response.#finish(true);
            throw e;
          }
        },
        async return() {
          response.#finish(true);
          return { done: true, value: undefined };
        },
        [Symbol.asyncIterator]() {
          return iterator;
        },
      };
      return iterator;
    }
    /** Cancels the stream if the body is not finished and gives its session slot back. Idempotent. */
    close() {
      this.#finish(true);
    }
    [Symbol.dispose]() {
      this.close();
    }
  }

  const redirectOf = options => {
    const redirect = own(options, 'redirect');
    if (redirect === null || typeof redirect !== 'object') throw new TypeError('redirect is required');
    const limit = integer(redirect, 'limit', 0, 0x7fffffff, 'redirect');
    const strip = own(redirect, 'strip');
    if (!Array.isArray(strip) || strip.some(name => typeof name !== 'string' || !TOKEN.test(name) || name !== name.toLowerCase()))
      throw new TypeError('redirect.strip must be an array of lowercase header names');
    return { limit, strip: new Set(strip) };
  };

  const fetch = async (pool, request) => {
    if (!(pool instanceof ClientPool)) throw new TypeError('pool must be a ClientPool');
    if (pool.mode !== 'pull') throw new TypeError("fetch needs a pool of mode 'pull'");
    if (request === null || typeof request !== 'object') throw new TypeError('request must be an object');
    let method = own(request, 'method');
    if (typeof method !== 'string' || !TOKEN.test(method)) throw new TypeError('method must be a token');
    const text = own(request, 'url');
    let url = typeof text === 'string' ? parseUrl(text) : undefined;
    if (url === undefined) throw new TypeError('url must be an absolute http or https URL without userinfo');
    let headers = own(request, 'headers');
    if (headers !== undefined && !(headers instanceof HeaderList)) throw new TypeError('headers must be a HeaderList');
    let body = own(request, 'body');
    if (body !== undefined && !isBytes(body) && typeof body?.[Symbol.asyncIterator] !== 'function')
      throw new TypeError('body must be bytes or an async iterable of bytes');
    const tls = own(request, 'tls');
    if (tls !== undefined && (tls === null || typeof tls !== 'object')) throw new TypeError('tls must be a TlsClient');
    if (url.scheme === 'https' && tls === undefined) throw new TypeError('an https URL needs tls');
    const { limit, strip } = redirectOf(request);

    for (let hops = 0; ; hops++) {
      const exchange = await pool.open(
        { scheme: url.scheme, host: url.host, port: url.port, tls: url.scheme === 'https' ? tls : undefined },
        { method, authority: url.authority, path: url.path },
        { headers, body: body === undefined ? undefined : 'stream' },
      );
      const state = { error: undefined };
      if (body !== undefined) upload(exchange, body, state);
      let head;
      try {
        head = await readHead(exchange, state);
      } catch (e) {
        cancel(exchange);
        throw e;
      }
      const location = limit > 0 && REDIRECTS.has(head.status) ? head.headers.get('location') : undefined;
      if (location === undefined) {
        return new FetchResponse(token, { ...head, url: url.text, redirected: hops > 0, exchange, state });
      }
      cancel(exchange);
      if (hops >= limit) throw failure(QuotaExceeded, `more than ${limit} redirects`);
      const next = parseUrl(resolveRef(url, location));
      if (next === undefined) throw failure(ProtocolError, 'the Location of a redirect is not an http or https URL');
      if (url.scheme === 'https' && next.scheme === 'http') throw failure(PermissionDenied, 'a redirect from https to http is refused');
      if (next.scheme === 'https' && tls === undefined) throw failure(Unsupported, 'a redirect to https needs the tls of the request');
      const rewrite =
        head.status === 303 ? method !== 'GET' && method !== 'HEAD' : head.status !== 307 && head.status !== 308 && method === 'POST';
      if (rewrite) {
        method = 'GET';
        body = undefined;
        headers = without(headers, BODY_HEADERS);
      } else if (body !== undefined && !isBytes(body)) {
        throw failure(Unsupported, 'a request body stream cannot be sent again after a redirect');
      }
      if (next.origin !== url.origin && headers !== undefined) headers = without(headers, strip);
      url = next;
    }
  };

  for (const C of [ResponseBody]) {
    freezeMethods(C);
    freezeMethods(C.prototype);
    Object.freeze(C.prototype);
    Object.freeze(C);
  }

  return {
    ClientPool,
    FetchResponse,
    pool: (io, options) => new ClientPool(token, io, options),
    fetch,
  };
};
