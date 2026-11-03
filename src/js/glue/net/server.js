// `api.net` handle base and the servers (`PullServer`, `EventServer`). Built by net.js.
import { failure, errors } from '../util.js';
import { constants } from '../errors.js';
const { BadHandle } = errors;
export default k => {
  const { native, token } = k;
  let coreOf;
  let revoke;

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
      if (made !== token || new.target === Handle) throw new TypeError(constants.ILLEGAL_CONSTRUCTOR);
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
  Object.defineProperty(Handle.prototype, Symbol.asyncDispose, {
    value: function () {
      return this.close();
    },
    writable: true,
    configurable: true,
  });

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
        const accepting = core.track(
          native.net.accept(core.id).then(r => k.makeSocket(core.socketMode, r.id, core.io, r.port, core.limit)),
          () => false,
        );
        const done = () => core.accepts.delete(accepting);
        core.accepts.add(accepting);
        accepting.then(done, done);
        return accepting;
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /**
     * Releases the listener; a pending `accept()` rejects `Canceled`. Resolves once the port is
     * free (those accepts were what kept it open). Idempotent.
     */
    close() {
      try {
        const core = coreOf(this);
        const accepts = core === null ? [] : [...core.accepts];
        const closing = super.close();
        return accepts.length === 0 ? closing : closing.then(() => Promise.allSettled(accepts)).then(() => undefined);
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /**
     * `for await (const socket of server)`: the connections as `accept()` resolves them, until the
     * server is closed (an error other than the close ends the loop by throwing).
     */
    async *[Symbol.asyncIterator]() {
      for (;;) {
        let socket;
        try {
          socket = await this.accept();
        } catch (e) {
          if (this.closed) return;
          throw e;
        }
        yield socket;
      }
    }
    /**
     * Returns an `EventServer` over the same listener and consumes this handle (it throws
     * `BadHandle` afterwards). Throws `WouldBlock` while an `accept()` is pending.
     */
    toEvent() {
      return new EventServer(
        token,
        revoke(this, core => core.toEvent()),
      );
    }
  }

  /** A server that emits events: `register('connection', socket => ...)`. */
  class EventServer extends Server {
    /**
     * Subscribes `handler` to `connection` (a socket of the server's `socketMode`), `error`
     * (an OrigineError subclass) or `close` and returns `{ unregister() }`. The first `connection` handler
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
      return new PullServer(
        token,
        revoke(this, core => core.toPull()),
      );
    }
  }
  return { Handle, Server, PullServer, EventServer, live, coreOf, revoke };
};
