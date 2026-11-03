// `api.net` sockets (`PullSocket`, `EventSocket`) and `makeSocket`. Built by net.js.
import { failure, errors } from '../util.js';
import { constants } from '../errors.js';
const { BadHandle } = errors;
const DONE = Promise.resolve();
const MAX_READ = 1 << 28;
const READ_CHUNK = 65536;
export default (k, { Core, Handle, live, coreOf, revoke, endQueue }) => {
  const { native, token } = k;

  /** Base of the sockets: the write side. */
  class Socket extends Handle {
    #remotePort;
    constructor(made, core) {
      super(made, core);
      if (new.target === Socket) throw new TypeError(constants.ILLEGAL_CONSTRUCTOR);
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
      try {
        if (side !== 'write' && side !== 'read' && side !== 'both') throw new TypeError("side must be 'write', 'read' or 'both'");
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
          core.readEnded
            ? Promise.resolve({ bytes: 0, buffer: buffer instanceof ArrayBuffer ? buffer : buffer.buffer })
            : native.net.readInto(core.id, buffer),
          r => r.bytes === 0,
        );
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /**
     * Reads once into `buffer` (at least one byte) by copy: resolves the byte count, 0 at end of stream. The buffer is
     * not detached, so one buffer can serve every read, but the bytes are copied.
     */
    readCopy(buffer) {
      try {
        if (!(buffer instanceof ArrayBuffer) && !ArrayBuffer.isView(buffer)) throw new TypeError('buffer must be an ArrayBuffer or a view');
        // 0 means end of stream here: an empty buffer could not tell it from nothing read.
        if (buffer.byteLength === 0) throw new TypeError('buffer must not be empty');
        const core = live(this);
        return core.track(core.readEnded ? Promise.resolve(0) : native.net.readCopy(core.id, buffer), n => n === 0);
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /**
     * `for await (const chunk of socket)`: the bytes as `read(65536)` returns them (each a
     * `Uint8Array` of 1 to 65536 bytes), until the end of the stream. Use `read(length)` for another
     * chunk size.
     */
    async *[Symbol.asyncIterator]() {
      for (;;) {
        const chunk = await this.read(READ_CHUNK);
        if (chunk.length === 0) return;
        yield chunk;
      }
    }
    /**
     * Returns an `EventSocket` over the same connection and consumes this handle (it throws
     * `BadHandle` afterwards; its `queued`/`direct` writers carry over). Throws `WouldBlock` while a
     * read is pending.
     */
    toEvent() {
      return new EventSocket(
        token,
        revoke(this, core => core.toEvent()),
      );
    }
  }

  /** A socket that emits events: `register('data', event => ...)`, `pause()`, `resume()`. */
  class EventSocket extends Socket {
    /**
     * Subscribes `handler` to `event` and returns `{ unregister() }`. Sockets emit `data` (an event
     * with `length` and `buffer()`), `end` (the peer finished), `error` (an OrigineError subclass), `drain`
     * (the send queue emptied) and `close`. The first `data` handler starts the flow. Handlers run
     * in registration order. Registrations never keep the program alive: `await io.run()` does,
     * until every flowing handle has closed. After `close`, handlers are dropped.
     */
    register(event, handler) {
      return live(this).register(event, handler);
    }
    /**
     * Stops event delivery: after this returns no `data`, `end`, `error`, `close` event is dispatched
     * until `resume()`. What already arrived is kept in order, and reading stops once a few chunks are
     * held, so the peer is held back through TCP. The write side goes on: `drain` fires, sends proceed.
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
      return new PullSocket(
        token,
        revoke(this, core => core.toPull()),
      );
    }
  }

  const makeSocket = (mode, id, io, port, limit) =>
    new (mode === 'event' ? EventSocket : PullSocket)(token, new Core(id, io, port, limit, false, null));
  return { Socket, PullSocket, EventSocket, makeSocket };
};
