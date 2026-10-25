// `api.net`: loopback TCP on an io runtime. Evaluated as an expression by src/api/glue.zig:
// `(native, util) => makeNetCap`. `makeNetCap()` returns the frozen `{ listen, connect }`.
// Handles are instances of the `Handle` classes below: the native id lives in a private field
// the guest cannot read or swap, only this file can construct them (`token`), and methods
// brand-check their receiver. Every native call still re-validates owner and runtime in Rust.
(native, { freeze, freezeMethods, own, failure, ioHandles, closedIo, errors: { BadHandle } }) => {
  const token = {};
  let idOf;
  let subscribed;
  const MAX_READ = 1 << 28;
  // `dispatch(kind, a, b)` kinds: the same numbers as rust/crates/origine_api/src/sub.rs.
  const DATA = 0;
  const END = 1;
  const ERROR = 2;
  const READY = 3;
  const CONNECTION = 4;
  const CLOSE = 5;
  const SOCKET_EVENTS = freeze(['data', 'end', 'error', 'ready', 'close']);
  const SERVER_EVENTS = freeze(['connection', 'error', 'close']);

  /**
   * A chunk of a `data` event, leased from the socket's pool: a `Uint8Array` of exactly the bytes
   * received over an ArrayBuffer that may be larger. `unref()` (or `using`) gives the store back
   * and detaches the buffer, so a view kept past that point is empty rather than aliasing the
   * next chunk. A lease that is never released is garbage collected like any buffer; the pool
   * just allocates a replacement.
   */
  class Lease extends Uint8Array {
    #id;
    #buffer;
    constructor(made, id, buffer, length) {
      if (made !== token) throw new TypeError('leases are created by data events');
      super(buffer, 0, length);
      this.#id = id;
      this.#buffer = buffer;
    }
    static get [Symbol.species]() {
      return Uint8Array;
    }
    /** True once `unref()` ran. */
    get released() {
      return this.#buffer === null;
    }
    /** Returns the buffer to the pool. Idempotent. */
    unref() {
      const buffer = this.#buffer;
      if (buffer === null) return;
      this.#buffer = null;
      native.net.release(this.#id, buffer);
    }
  }
  if (typeof Symbol.dispose === 'symbol') {
    Object.defineProperty(Lease.prototype, Symbol.dispose, {
      value: function () {
        this.unref();
      },
      writable: true,
      configurable: true,
    });
  }

  let beginData;
  let endData;
  /** The `data` event: valid only while its handlers run. */
  class DataEvent {
    #id;
    #length = 0;
    #live = false;
    #lease = null;
    constructor(made, id) {
      if (made !== token) throw new TypeError('events are created by api.net');
      this.#id = id;
    }
    static {
      beginData = (event, length) => {
        event.#length = length;
        event.#live = true;
      };
      endData = event => {
        event.#live = false;
        event.#lease = null;
      };
    }
    /** Bytes received. */
    get length() {
      return this.#live ? this.#length : 0;
    }
    /** A leased copy of the chunk (the same lease on every call of this event). */
    buffer() {
      if (!this.#live) throw new TypeError('the data event is over');
      this.#lease ??= new Lease(token, this.#id, native.net.take(this.#id), this.#length);
      return this.#lease;
    }
  }

  class Handle {
    #id;
    #io;
    #closed = false;
    #hub = null;
    constructor(made, id, io) {
      if (made !== token || new.target === Handle) throw new TypeError('handles are created by api.net');
      this.#id = id;
      this.#io = io;
    }
    static {
      idOf = handle => {
        if (handle === null || typeof handle !== 'object' || !(#id in handle)) throw new TypeError('not a handle');
        return handle.#id;
      };
      subscribed = handle => handle.#subscribe();
    }
    /** Routes this handle's native events to its handler table (once). */
    #subscribe() {
      if (this.#hub !== null) return this.#hub;
      const hub = { handlers: new Map(), event: new DataEvent(token, this.#id), started: false };
      native.net.subscribe(this.#id, (kind, a, b) => this.#dispatch(hub, kind, a, b));
      this.#hub = hub;
      return hub;
    }
    #fire(hub, name, argument) {
      const entries = hub.handlers.get(name);
      if (entries === undefined || entries.size === 0) return false;
      for (const entry of Array.from(entries)) {
        try {
          entry.fn(argument);
        } catch (e) {
          this.#fail(hub, name, e);
        }
      }
      return true;
    }
    // A throwing handler goes to the `error` handlers; with none (or when one of them throws) it
    // becomes an unhandled rejection.
    #fail(hub, name, error) {
      const entries = hub.handlers.get('error');
      if (name === 'error' || entries === undefined || entries.size === 0) {
        Promise.reject(error);
        return;
      }
      for (const entry of Array.from(entries)) {
        try {
          entry.fn(error);
        } catch (e) {
          Promise.reject(e);
        }
      }
    }
    #dispatch(hub, kind, a, b) {
      if (kind === CLOSE) {
        this.#closed = true;
        this.#fire(hub, 'close');
        hub.handlers.clear();
        return;
      }
      if (this.#closed) return;
      switch (kind) {
        case DATA:
          beginData(hub.event, a);
          try {
            this.#fire(hub, 'data', hub.event);
          } finally {
            endData(hub.event);
          }
          break;
        case END:
          this.#fire(hub, 'end');
          break;
        case ERROR:
          this.#fire(hub, 'error', failure(a));
          break;
        case READY:
          this.#fire(hub, 'ready');
          break;
        case CONNECTION: {
          const socket = new Socket(token, a, this.#io, b);
          if (!this.#fire(hub, 'connection', socket)) socket.close();
          break;
        }
      }
    }
    /**
     * Subscribes `handler` to `event` and returns `{ unregister() }`. Sockets emit `data` (an event
     * with `length` and `buffer()`), `end` (the peer finished), `error` (`{ errno, name }`), `ready`
     * (writable again after `send` answered false) and `close`; servers emit `connection` (a
     * `Socket`), `error` and `close`. The first `data` (or `connection`) handler starts the flow.
     * Handlers run in registration order. Registrations never keep the program alive: `await
     * io.run()` does, until every flowing handle has closed. After `close`, handlers are dropped.
     */
    register(event, handler) {
      const id = live(this);
      if (typeof handler !== 'function') throw new TypeError('handler must be a function');
      if (!(this instanceof Server ? SERVER_EVENTS : SOCKET_EVENTS).includes(event)) throw new TypeError(`unknown event: ${String(event)}`);
      const hub = this.#subscribe();
      let entries = hub.handlers.get(event);
      if (entries === undefined) hub.handlers.set(event, (entries = new Set()));
      const entry = { fn: handler };
      entries.add(entry);
      if ((event === 'data' || event === 'connection') && !hub.started) {
        hub.started = true;
        native.net.resume(id);
      }
      return freeze({
        unregister() {
          return entries.delete(entry);
        },
      });
    }
    /** The io runtime this handle belongs to. */
    get io() {
      return this.#io;
    }
    /** True after `close()` or once the io runtime is closed. */
    get closed() {
      return this.#closed || closedIo.has(this.#io);
    }
    /** Releases the handle; pending reads finish with end of stream. Idempotent. */
    close() {
      try {
        if (!this.closed) {
          this.#closed = true;
          native.net.close(this.#id);
        }
        return Promise.resolve();
      } catch (e) {
        return Promise.reject(e);
      }
    }
  }
  if (typeof Symbol.asyncDispose === 'symbol') {
    Object.defineProperty(Handle.prototype, Symbol.asyncDispose, {
      value: function () {
        return this.close();
      },
      writable: true,
      configurable: true,
    });
  }

  const live = handle => {
    const id = idOf(handle);
    if (handle.closed) throw failure(BadHandle);
    return id;
  };

  class Server extends Handle {
    #port;
    constructor(made, id, io, port) {
      super(made, id, io);
      this.#port = port;
    }
    /** The port listened on (the real one when `port: 0` was asked). */
    get port() {
      return this.#port;
    }
    /** Resolves the next connection as a `Socket`. */
    accept() {
      try {
        const io = this.io;
        return native.net.accept(live(this)).then(r => new Socket(token, r.id, io, r.port));
      } catch (e) {
        return Promise.reject(e);
      }
    }
  }

  class Socket extends Handle {
    #remotePort;
    constructor(made, id, io, remotePort) {
      super(made, id, io);
      this.#remotePort = remotePort;
    }
    get remotePort() {
      return this.#remotePort;
    }
    /** Reads once: a `Uint8Array` of 1 to `length` bytes, empty at end of stream. */
    read(length) {
      try {
        if (!Number.isSafeInteger(length) || length < 1 || length > MAX_READ) throw new TypeError('length must be an integer in 1..2**28');
        return native.net.read(live(this), length);
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /**
     * Reads once straight into `buffer` (an ArrayBuffer or view, at least one byte): the buffer is
     * detached while the read is in flight and resolves `{ bytes, buffer }` with `buffer` a new
     * ArrayBuffer over the same memory (`bytes` 0 at end of stream). Rejects `Unsupported` for a
     * buffer that cannot be detached (shared, resizable).
     */
    readInto(buffer) {
      try {
        if (!(buffer instanceof ArrayBuffer) && !ArrayBuffer.isView(buffer)) throw new TypeError('buffer must be an ArrayBuffer or a view');
        if (buffer.byteLength === 0) throw new TypeError('buffer must not be empty');
        return native.net.readInto(live(this), buffer);
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /**
     * Reads once into `buffer` by copy: resolves the byte count, 0 at end of stream. The buffer is
     * not detached, so one buffer can serve every read, but the bytes are copied.
     */
    readCopy(buffer) {
      try {
        if (!(buffer instanceof ArrayBuffer) && !ArrayBuffer.isView(buffer)) throw new TypeError('buffer must be an ArrayBuffer or a view');
        return native.net.readCopy(live(this), buffer);
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /**
     * Writes `data` now (a plain non-blocking write; only what the kernel did not take is copied
     * and queued). Returns whether to keep writing: `false` means the queue is above its
     * high-water mark, wait for `ready`. A failed write is reported as an `error` event.
     */
    send(data) {
      if (!(data instanceof ArrayBuffer) && !ArrayBuffer.isView(data)) throw new TypeError('data must be an ArrayBuffer or a view');
      const id = live(this);
      subscribed(this);
      return native.net.send(id, data);
    }
    /** Writes all of `data` (an ArrayBuffer or a view; it is copied). Resolves the byte count. */
    write(data) {
      try {
        if (!(data instanceof ArrayBuffer) && !ArrayBuffer.isView(data)) throw new TypeError('data must be an ArrayBuffer or a view');
        return native.net.write(live(this), data);
      } catch (e) {
        return Promise.reject(e);
      }
    }
  }

  freezeMethods(Lease);
  freezeMethods(Lease.prototype);
  freezeMethods(DataEvent);
  freezeMethods(DataEvent.prototype);
  freezeMethods(Handle);
  freezeMethods(Handle.prototype);
  freezeMethods(Server);
  freezeMethods(Server.prototype);
  freezeMethods(Socket);
  freezeMethods(Socket.prototype);

  // A live `io` handle made by this scope's `api.io`; the natives validate the id again.
  const ioId = io => {
    if (io === null || typeof io !== 'object' || !ioHandles.has(io) || closedIo.has(io)) throw failure(BadHandle);
    return io.id;
  };
  const address = options => {
    if (options !== undefined && (options === null || typeof options !== 'object')) throw new TypeError('options must be an object');
    const host = own(options, 'host') ?? '127.0.0.1';
    const port = own(options, 'port') ?? 0;
    if (typeof host !== 'string') throw new TypeError('host must be a string');
    if (!Number.isInteger(port) || port < 0 || port > 65535) throw new TypeError('port must be an integer in 0..65535');
    return [host, port];
  };

  return () =>
    freeze({
      Handle,
      Server,
      Socket,
      /** Binds and listens (loopback only). Synchronous; throws `{ errno, name }`. */
      listen(io, options) {
        const [host, port] = address(options);
        const made = native.net.listen(ioId(io), host, port);
        return new Server(token, made.id, io, made.port);
      },
      /** Connects to a loopback listener. */
      connect(io, options) {
        try {
          const [host, port] = address(options);
          return native.net.connect(ioId(io), host, port).then(r => new Socket(token, r.id, io, r.port));
        } catch (e) {
          return Promise.reject(e);
        }
      },
    });
};
