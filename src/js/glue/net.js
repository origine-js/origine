// `api.net`: loopback TCP on an io runtime. Evaluated as an expression by src/api/glue.zig:
// `(native, util) => makeNetCap`. `makeNetCap()` returns the frozen `{ listen, connect, ... }`.
// Handles are instances of the classes below: the native id lives in a `Core` that only this file
// can reach (a private field of the handle holds it), only this file can construct handles
// (`token`), and methods brand-check their receiver. Every native call still re-validates owner
// and runtime in Rust.
//
// A handle has one of two read modes, fixed when it is made and visible in its class:
// `PullSocket`/`PullServer` (promise reads, `accept()`) and `EventSocket`/`EventServer`
// (`register`, `pause`, `resume`). The write side (`direct`, `queued`, `end`, `close`) is shared
// by both. `toEvent()`/`toPull()` move the native handle into a new instance of the other class
// and consume the old one.
(native, { freeze, freezeMethods, own, failure, ioHandles, closedIo, errors: { BadHandle, Canceled, Unsupported, WouldBlock } }) => {
  const token = {};
  let coreOf;
  let revoke;
  let waitingOf;
  let endQueue;
  let beginData;
  let endData;
  const MAX_READ = 1 << 28;
  // Bytes per read while draining a socket whose reading was ended.
  const DRAIN_READ = 1 << 16;
  // Default `queued.limit`: bytes the outbox holds for a slow peer.
  const QUEUE_LIMIT = 1 << 20;
  const DONE = Promise.resolve();
  // `dispatch(kind, a, b)` kinds: the same numbers as rust/crates/origine_api/src/sub.rs.
  const DATA = 0;
  const END = 1;
  const ERROR = 2;
  const DRAIN = 3;
  const CONNECTION = 4;
  const CLOSE = 5;
  const SOCKET_EVENTS = freeze(['data', 'end', 'error', 'drain', 'close']);
  const SERVER_EVENTS = freeze(['connection', 'error', 'close']);

  /**
   * A chunk of a `data` event: a `Uint8Array` over an ArrayBuffer of exactly the bytes received
   * (`buffer.byteLength === length`; no other byte of the socket's memory is reachable through
   * it). `unref()` (or `using`) detaches the buffer, so a view kept past that point is empty. A
   * lease that is never released is garbage collected like any buffer.
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
    /** Detaches the buffer and frees its memory. Idempotent. */
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

  const isBytes = data => data instanceof ArrayBuffer || ArrayBuffer.isView(data);

  /**
   * The state of one native handle, shared by whichever handle object currently fronts it (a
   * mode transfer moves the core to a new object). Never exposed to the guest.
   */
  class Core {
    constructor(id, io, port, limit, server, socketMode) {
      this.id = id;
      this.io = io;
      this.port = port;
      this.limit = limit;
      this.server = server;
      this.socketMode = socketMode;
      this.closed = false;
      this.hub = null;
      // Handlers of the event that makes the handle flow (`data`, `connection`), and why it is paused.
      this.flowing = 0;
      this.userPaused = false;
      this.autoPaused = false;
      this.applied = false;
      // Pull-mode operations in flight.
      this.pending = 0;
      // How far each direction is finished: the peer's FIN was seen / reading was ended locally, and
      // the local FIN was sent. A socket closes itself once both are true.
      this.peerEnded = false;
      this.readEnded = false;
      this.writeEnded = false;
      this.queued = server ? null : new SendQueue(token, this, limit);
      this.direct = server ? null : new Direct(token, this, this.queued);
    }
    get shut() {
      return this.closed || closedIo.has(this.io);
    }
    /** Routes this handle's native events to its handler table (once). */
    subscribe() {
      if (this.hub !== null) return this.hub;
      const hub = { handlers: new Map(), event: new DataEvent(token, this.id), started: false, drain: null, shut: null };
      native.net.subscribe(this.id, (kind, a, b) => this.dispatch(hub, kind, a, b));
      this.hub = hub;
      return hub;
    }
    fire(hub, name, argument) {
      const entries = hub.handlers.get(name);
      if (entries === undefined || entries.size === 0) return false;
      for (const entry of Array.from(entries)) {
        try {
          entry.fn(argument);
        } catch (e) {
          this.fail(hub, name, e);
        }
      }
      return true;
    }
    // A throwing handler goes to the `error` handlers; with none (or when one of them throws) it
    // becomes an unhandled rejection.
    fail(hub, name, error) {
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
    dispatch(hub, kind, a, b) {
      if (kind === CLOSE) {
        this.closed = true;
        hub.shut?.();
        this.fire(hub, 'close');
        hub.handlers.clear();
        return;
      }
      if (this.closed) return;
      switch (kind) {
        case DATA:
          if (this.readEnded) break;
          beginData(hub.event, a);
          try {
            this.fire(hub, 'data', hub.event);
          } finally {
            endData(hub.event);
          }
          break;
        case END:
          if (!this.readEnded) this.fire(hub, 'end');
          this.peerEnd();
          break;
        case ERROR:
          this.fire(hub, 'error', failure(a));
          break;
        case DRAIN:
          hub.drain?.();
          this.fire(hub, 'drain');
          break;
        case CONNECTION: {
          const socket = makeSocket(this.socketMode, a, this.io, b, this.limit);
          if (!this.fire(hub, 'connection', socket)) socket.close();
          break;
        }
      }
    }
    register(event, handler) {
      if (typeof handler !== 'function') throw new TypeError('handler must be a function');
      if (!(this.server ? SERVER_EVENTS : SOCKET_EVENTS).includes(event)) throw new TypeError(`unknown event: ${String(event)}`);
      const hub = this.subscribe();
      let entries = hub.handlers.get(event);
      if (entries === undefined) hub.handlers.set(event, (entries = new Set()));
      const entry = { fn: handler };
      entries.add(entry);
      const flows = event === (this.server ? 'connection' : 'data');
      if (flows) {
        this.flowing++;
        this.autoPaused = false;
      }
      if (flows && !hub.started) {
        hub.started = true;
        native.net.start(this.id);
      }
      if (flows) this.sync();
      return freeze({
        unregister: () => {
          const removed = entries.delete(entry);
          // Without a flow handler the handle pauses itself: nothing is read to be dropped.
          if (removed && flows && !this.closed && --this.flowing === 0) {
            this.autoPaused = true;
            this.sync();
          }
          return removed;
        },
      });
    }
    /** Applies the pause state (explicit or because no handler listens) to the host. */
    sync() {
      const want = this.userPaused || this.autoPaused;
      if (this.hub === null || this.closed || want === this.applied) return;
      this.applied = want;
      if (want) native.net.pause(this.id);
      else native.net.resume(this.id);
    }
    pause() {
      this.userPaused = true;
      this.subscribe();
      this.sync();
    }
    resume() {
      this.userPaused = false;
      this.sync();
    }
    get paused() {
      return this.userPaused || this.autoPaused;
    }
    /** Leaves event mode: refused once reading started (what the pump read is held for handlers). */
    toPull() {
      if (this.hub?.started) throw failure(Unsupported);
      if (this.hub !== null) {
        this.hub.handlers.clear();
        this.userPaused = false;
        this.autoPaused = false;
        this.flowing = 0;
        this.sync();
      }
    }
    /** Leaves pull mode: refused while a read or accept is in flight. */
    toEvent() {
      if (this.pending > 0) throw failure(WouldBlock);
    }
    /** Counts a pull-mode operation until it settles; `eof(result)` says the result is end of stream. */
    track(promise, eof) {
      this.pending++;
      return promise.then(
        value => {
          this.pending--;
          if (eof(value)) this.peerEnd();
          return value;
        },
        error => {
          this.pending--;
          throw error;
        },
      );
    }
    /** The peer's FIN was seen. */
    peerEnd() {
      this.peerEnded = true;
      this.settle();
    }
    /**
     * Stops reading: what arrives is discarded and reads started afterwards resolve empty. The
     * kernel side stays open (a `shutdown(SHUT_RD)` makes some systems reset the connection when the
     * peer sends), so the runtime keeps draining the socket until the peer's FIN.
     */
    endRead() {
      if (this.readEnded) return;
      this.readEnded = true;
      if (!this.shut) {
        const drain = () =>
          native.net.read(this.id, DRAIN_READ).then(
            bytes => (bytes.length === 0 ? this.peerEnd() : drain()),
            () => {},
          );
        drain();
      }
      this.settle();
    }
    /** The local FIN was sent. */
    writeDone() {
      this.writeEnded = true;
      this.settle();
    }
    // Both directions finished: release the socket (its `close` event follows).
    settle() {
      if (this.shut || !this.writeEnded || !(this.peerEnded || this.readEnded)) return;
      this.closed = true;
      try {
        native.net.close(this.id);
      } catch {
        // already gone
      }
    }
  }

  // The core of a live handle (`BadHandle` once consumed, closed or its runtime closed).
  const live = handle => {
    const core = coreOf(handle);
    if (core === null || core.shut) throw failure(BadHandle);
    return core;
  };

  /** Base of every handle: what both modes and both kinds share. */
  class Handle {
    #core;
    #io;
    constructor(made, core) {
      if (made !== token || new.target === Handle) throw new TypeError('handles are created by api.net');
      this.#core = core;
      this.#io = core.io;
    }
    static {
      coreOf = handle => {
        if (handle === null || typeof handle !== 'object' || !(#core in handle)) throw new TypeError('not a handle');
        return handle.#core;
      };
      // Takes the core out of a live handle (which is consumed) after `check` accepted it.
      revoke = (handle, check) => {
        const core = live(handle);
        check(core);
        handle.#core = null;
        return core;
      };
    }
    /** The io runtime this handle belongs to. */
    get io() {
      return this.#io;
    }
    /** True after `close()`, once the io runtime is closed, or after a mode transfer consumed it. */
    get closed() {
      const core = coreOf(this);
      return core === null || core.shut;
    }
    /** Releases the handle; pending reads finish with end of stream. Idempotent. */
    close() {
      try {
        const core = coreOf(this);
        if (core !== null && !core.shut) {
          core.closed = true;
          native.net.close(core.id);
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

  /** Base of the servers: the listening port. */
  class Server extends Handle {
    #port;
    constructor(made, core) {
      super(made, core);
      if (new.target === Server) throw new TypeError('servers are created by api.net');
      this.#port = core.port;
    }
    /** The port listened on (the real one when `port: 0` was asked). */
    get port() {
      return this.#port;
    }
  }

  /** A server whose connections are awaited: `accept()` resolves the next one. */
  class PullServer extends Server {
    /** Resolves the next connection as a socket of the server's `socketMode`. */
    accept() {
      try {
        const core = live(this);
        return core.track(
          native.net.accept(core.id).then(r => makeSocket(core.socketMode, r.id, core.io, r.port, core.limit)),
          () => false,
        );
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /**
     * Returns an `EventServer` over the same listener and consumes this handle (it throws
     * `BadHandle` afterwards). Throws `WouldBlock` while an `accept()` is pending.
     */
    toEvent() {
      return new EventServer(token, revoke(this, core => core.toEvent()));
    }
  }

  /** A server that emits events: `register('connection', socket => ...)`. */
  class EventServer extends Server {
    /**
     * Subscribes `handler` to `connection` (a socket of the server's `socketMode`), `error`
     * (`{ errno, name }`) or `close` and returns `{ unregister() }`. The first `connection` handler
     * starts accepting. Handlers run in registration order. Registrations never keep the program
     * alive: `await io.run()` does, until every flowing handle has closed. After `close`,
     * handlers are dropped. A connection nobody handles is closed.
     */
    register(event, handler) {
      return live(this).register(event, handler);
    }
    /** Stops accepting until `resume()`; connections wait in the backlog. */
    pause() {
      live(this).pause();
    }
    /** Undoes `pause()`. Idempotent. */
    resume() {
      live(this).resume();
    }
    /** True after `pause()`, or while no `connection` handler listens. */
    get paused() {
      return live(this).paused;
    }
    /**
     * Returns a `PullServer` over the same listener and consumes this handle. Throws
     * `Unsupported` once a `connection` handler started accepting.
     */
    toPull() {
      return new PullServer(token, revoke(this, core => core.toPull()));
    }
  }

  /**
   * `socket.queued`: the send queue. Whatever goes through it leaves the socket in call order, and
   * it has priority over `socket.direct`. `put` takes what fits, `send` takes all of it (waiting for
   * room) and resolves once the bytes are in the kernel (not once the peer has them).
   */
  class SendQueue {
    #core;
    #limit;
    #attached = false;
    // Sends (and `end`s) waiting for room, in order, and `drained()` callers waiting for them.
    #waiting = [];
    #idle = [];
    constructor(made, core, limit) {
      if (made !== token) throw new TypeError('queues are created by sockets');
      this.#core = core;
      this.#limit = limit;
    }
    static {
      waitingOf = queue => queue.#waiting.length;
      endQueue = queue => queue.#end();
    }
    #attach() {
      if (this.#core.shut) throw failure(BadHandle);
      if (!this.#attached) {
        const hub = this.#core.subscribe();
        hub.drain = () => this.#admit();
        hub.shut = () => this.#cancel();
        this.#attached = true;
      }
      return this.#core.id;
    }
    /** Bytes in the queue that the kernel has not taken yet. */
    get bytes() {
      if (!this.#attached || this.#core.shut) return 0;
      try {
        return native.net.queued(this.#core.id);
      } catch {
        return 0;
      }
    }
    /** Sends waiting for room (their bytes are not in the queue yet). */
    get waiting() {
      return this.#waiting.length;
    }
    /** Bytes the queue may hold. A send into an empty queue is accepted whatever its size. */
    get limit() {
      return this.#limit;
    }
    set limit(value) {
      if (!Number.isSafeInteger(value) || value < 1) throw new TypeError('limit must be a positive integer');
      this.#limit = value;
    }
    /**
     * Queues as much of `data` as fits under `limit` and returns the number of bytes taken (0 when
     * the queue is full or sends are waiting). The bytes are copied. Wait for `drain` (or
     * `drained()`) before putting the rest. A write error throws and closes the socket.
     */
    put(data) {
      if (!isBytes(data)) throw new TypeError('data must be an ArrayBuffer or a view');
      const id = this.#attach();
      if (this.#waiting.length > 0) return 0;
      return native.net.put(id, data, Math.max(0, this.#limit - native.net.queued(id)));
    }
    /**
     * Sends all of `data`: resolves once its last byte is in the kernel. When the queue has no room
     * the send waits its turn; leave `data` untouched until the promise settles (it is read when
     * the send is admitted). Rejects when the socket fails or closes first.
     */
    send(data) {
      try {
        if (!isBytes(data)) throw new TypeError('data must be an ArrayBuffer or a view');
        const id = this.#attach();
        if (this.#waiting.length === 0 && this.#fits(id, data.byteLength)) return this.#submit(id, data);
        return new Promise((resolve, reject) => this.#waiting.push({ data, resolve, reject }));
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /** Resolves once the queue is empty and no send is waiting. */
    drained() {
      try {
        const id = this.#attach();
        if (this.#waiting.length > 0) return new Promise((resolve, reject) => this.#idle.push({ resolve, reject }));
        return this.#settled(id);
      } catch (e) {
        return Promise.reject(e);
      }
    }
    #end() {
      const id = this.#attach();
      if (this.#waiting.length === 0) return this.#finish(id);
      return new Promise((resolve, reject) => this.#waiting.push({ data: null, resolve, reject }));
    }
    #fits(id, length) {
      const bytes = native.net.queued(id);
      return bytes === 0 || bytes + length <= this.#limit;
    }
    #settled(id) {
      return native.net.queued(id) === 0 ? DONE : native.net.flushed(id);
    }
    #submit(id, data) {
      native.net.put(id, data, data.byteLength);
      return this.#settled(id);
    }
    #finish(id) {
      native.net.end(id);
      return this.#settled(id);
    }
    // The queue emptied: let the waiting sends in, in order, while they fit.
    #admit() {
      if (this.#core.shut) return;
      const id = this.#core.id;
      while (this.#waiting.length > 0) {
        const next = this.#waiting[0];
        if (next.data !== null && !this.#fits(id, next.data.byteLength)) return;
        this.#waiting.shift();
        try {
          next.resolve(next.data === null ? this.#finish(id) : this.#submit(id, next.data));
        } catch (e) {
          next.reject(e);
        }
      }
      for (const waiter of this.#idle.splice(0)) waiter.resolve(this.#settled(id));
    }
    // The socket closed: nothing waiting will ever be sent.
    #cancel() {
      const pending = this.#waiting.splice(0);
      const idle = this.#idle.splice(0);
      for (const waiter of [...pending, ...idle]) waiter.reject(failure(Canceled));
    }
  }

  /**
   * `socket.direct`: the unbuffered lane. A plain non-blocking write that takes no copy and keeps
   * nothing: it returns the bytes the kernel took, possibly none. It never overtakes the send
   * queue: while anything is queued (or waiting) it takes nothing and returns 0.
   */
  class Direct {
    #core;
    #queue;
    constructor(made, core, queue) {
      if (made !== token) throw new TypeError('direct writers are created by sockets');
      this.#core = core;
      this.#queue = queue;
    }
    /** Returns the number of bytes written (0 to `data.byteLength`). A write error throws and closes the socket. */
    write(data) {
      if (!isBytes(data)) throw new TypeError('data must be an ArrayBuffer or a view');
      if (this.#core.shut) throw failure(BadHandle);
      this.#core.subscribe();
      if (waitingOf(this.#queue) > 0) return 0;
      return native.net.directWrite(this.#core.id, data);
    }
  }

  /** Base of the sockets: the write side. */
  class Socket extends Handle {
    #remotePort;
    constructor(made, core) {
      super(made, core);
      if (new.target === Socket) throw new TypeError('sockets are created by api.net');
      this.#remotePort = core.port;
    }
    get remotePort() {
      return this.#remotePort;
    }
    /** The send queue (`put`, `send`, `drained`, `bytes`, `limit`); it goes before `direct`. */
    get queued() {
      const core = coreOf(this);
      if (core === null) throw failure(BadHandle);
      return core.queued;
    }
    /** The unbuffered write lane (`write`). */
    get direct() {
      const core = coreOf(this);
      if (core === null) throw failure(BadHandle);
      return core.direct;
    }
    /**
     * Ends one or both directions (`shutdown(2)`); `side` is required: 'write' sends the FIN once
     * everything queued (and waiting) is out, resolving when it is sent (later writes fail with
     * `BrokenPipe`); 'read' stops reading and discards what arrives (reads resolve empty); 'both'
     * does both, the read side after the flush. A peer's FIN only fires `end`; the socket closes
     * itself once the peer finished (or reading was ended) and the write side was ended, and
     * `close()` releases it at any time.
     */
    end(side) {
      if (side !== 'write' && side !== 'read' && side !== 'both') throw new TypeError("side must be 'write', 'read' or 'both'");
      try {
        const core = live(this);
        if (side === 'read') {
          core.endRead();
          return DONE;
        }
        return endQueue(core.queued).then(() => {
          if (side === 'both') core.endRead();
          core.writeDone();
        });
      } catch (e) {
        return Promise.reject(e);
      }
    }
  }

  /** A socket read with promises: `read`, `readInto`, `readCopy`. */
  class PullSocket extends Socket {
    /** Reads once: a `Uint8Array` of 1 to `length` bytes, empty at end of stream. */
    read(length) {
      try {
        if (!Number.isSafeInteger(length) || length < 1 || length > MAX_READ) throw new TypeError('length must be an integer in 1..2**28');
        const core = live(this);
        return core.track(core.readEnded ? Promise.resolve(new Uint8Array(0)) : native.net.read(core.id, length), r => r.length === 0);
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
        const core = live(this);
        return core.track(
          core.readEnded ? Promise.resolve({ bytes: 0, buffer: buffer instanceof ArrayBuffer ? buffer : buffer.buffer }) : native.net.readInto(core.id, buffer),
          r => r.bytes === 0,
        );
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
        const core = live(this);
        return core.track(core.readEnded ? Promise.resolve(0) : native.net.readCopy(core.id, buffer), n => n === 0);
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /**
     * Returns an `EventSocket` over the same connection and consumes this handle (it throws
     * `BadHandle` afterwards; its `queued`/`direct` writers carry over). Throws `WouldBlock` while a
     * read is pending.
     */
    toEvent() {
      return new EventSocket(token, revoke(this, core => core.toEvent()));
    }
  }

  /** A socket that emits events: `register('data', event => ...)`, `pause()`, `resume()`. */
  class EventSocket extends Socket {
    /**
     * Subscribes `handler` to `event` and returns `{ unregister() }`. Sockets emit `data` (an event
     * with `length` and `buffer()`), `end` (the peer finished), `error` (`{ errno, name }`), `drain`
     * (the send queue emptied) and `close`. The first `data` handler starts the flow. Handlers run
     * in registration order. Registrations never keep the program alive: `await io.run()` does,
     * until every flowing handle has closed. After `close`, handlers are dropped.
     */
    register(event, handler) {
      return live(this).register(event, handler);
    }
    /**
     * Stops event delivery: after this returns no `data`, `end`, `error` event is dispatched until
     * `resume()`. What already arrived is kept in order, and reading stops once a few chunks are
     * held, so the peer is held back through TCP.
     */
    pause() {
      live(this).pause();
    }
    /** Undoes `pause()`; held events are dispatched first, in order. Idempotent. */
    resume() {
      live(this).resume();
    }
    /** True after `pause()`, or while no handler listens for `data`. */
    get paused() {
      return live(this).paused;
    }
    /**
     * Returns a `PullSocket` over the same connection and consumes this handle (registered handlers
     * are dropped). Throws `Unsupported` once a `data` handler started the flow: the chunks the
     * runtime already read belong to the events.
     */
    toPull() {
      return new PullSocket(token, revoke(this, core => core.toPull()));
    }
  }

  const makeSocket = (mode, id, io, port, limit) =>
    new (mode === 'event' ? EventSocket : PullSocket)(token, new Core(id, io, port, limit, false, null));

  for (const C of [Lease, DataEvent, Handle, Server, PullServer, EventServer, SendQueue, Direct, Socket, PullSocket, EventSocket]) {
    freezeMethods(C);
    freezeMethods(C.prototype);
  }

  // A live `io` handle made by this scope's `api.io`; the natives validate the id again.
  const ioId = io => {
    if (io === null || typeof io !== 'object' || !ioHandles.has(io) || closedIo.has(io)) throw failure(BadHandle);
    return io.id;
  };
  const address = (options, portRequired) => {
    if (options !== undefined && (options === null || typeof options !== 'object')) throw new TypeError('options must be an object');
    const host = own(options, 'host') ?? '127.0.0.1';
    const port = own(options, 'port') ?? (portRequired ? undefined : 0);
    if (typeof host !== 'string') throw new TypeError('host must be a string');
    if (port === undefined) throw new TypeError('port is required');
    if (!Number.isInteger(port) || port < 0 || port > 65535) throw new TypeError('port must be an integer in 0..65535');
    return [host, port];
  };
  const modeOf = (options, key) => {
    const mode = own(options, key);
    if (mode !== 'event' && mode !== 'pull') throw new TypeError(`${key} must be 'event' or 'pull'`);
    return mode;
  };
  const queueLimit = options => {
    const limit = own(options, 'sendQueueLimit') ?? QUEUE_LIMIT;
    if (!Number.isSafeInteger(limit) || limit < 1) throw new TypeError('sendQueueLimit must be a positive integer');
    return limit;
  };
  return () =>
    freeze({
      Handle,
      Server,
      PullServer,
      EventServer,
      Socket,
      PullSocket,
      EventSocket,
      /**
       * Binds and listens (loopback only). Synchronous; throws `{ errno, name }`. `mode` ('event' or
       * 'pull', required) picks the server class, `socketMode` (required) the class of the sockets it
       * accepts. `host`: an IP literal as given, `localhost` binds 127.0.0.1 (pass '::1' for IPv6).
       */
      listen(io, options) {
        const [host, port] = address(options, false);
        const mode = modeOf(options, 'mode');
        const socketMode = modeOf(options, 'socketMode');
        const limit = queueLimit(options);
        const made = native.net.listen(ioId(io), host, port);
        const core = new Core(made.id, io, made.port, limit, true, socketMode);
        return new (mode === 'event' ? EventServer : PullServer)(token, core);
      },
      /**
       * Connects to a loopback listener; `port` and `mode` are required. `localhost` tries 127.0.0.1
       * then ::1 without the system resolver.
       */
      connect(io, options) {
        try {
          const [host, port] = address(options, true);
          const mode = modeOf(options, 'mode');
          const limit = queueLimit(options);
          return native.net.connect(ioId(io), host, port).then(r => makeSocket(mode, r.id, io, r.port, limit));
        } catch (e) {
          return Promise.reject(e);
        }
      },
    });
};
