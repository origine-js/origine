// `api.net` send side: the send queue (`socket.queued`) and the direct lane (`socket.direct`). Built by net.js.
import { failure, errors, ioClosers } from '../util.js';
import { constants } from '../errors.js';
const { BadHandle } = errors;
const DONE = Promise.resolve();
export default ({ native, token }) => {
  let waitingOf;
  let endQueue;

  const isBytes = data => data instanceof ArrayBuffer || ArrayBuffer.isView(data);
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
      if (made !== token) throw new TypeError(constants.ILLEGAL_CONSTRUCTOR);
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
        // Three ways to end what waits here: the socket fails (even while paused), it closes, or its
        // runtime closes, which dispatches nothing.
        const { io } = this.#core;
        let closers = ioClosers.get(io);
        if (closers === undefined) ioClosers.set(io, (closers = new Set()));
        const cancel = error => {
          closers.delete(cancel);
          this.#cancel(error);
        };
        closers.add(cancel);
        hub.drain = () => this.#admit();
        hub.shut = cancel;
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
        const { promise, resolve, reject } = Promise.withResolvers();
        this.#waiting.push({ data, resolve, reject });
        return promise;
      } catch (e) {
        return Promise.reject(e);
      }
    }
    /** Resolves once the queue is empty and no send is waiting. */
    drained() {
      try {
        const id = this.#attach();
        if (this.#waiting.length > 0) {
          const { promise, resolve, reject } = Promise.withResolvers();
          this.#idle.push({ resolve, reject });
          return promise;
        }
        return this.#settled(id);
      } catch (e) {
        return Promise.reject(e);
      }
    }
    #end() {
      const id = this.#attach();
      if (this.#waiting.length === 0) return this.#finish(id);
      const { promise, resolve, reject } = Promise.withResolvers();
      this.#waiting.push({ data: null, resolve, reject });
      return promise;
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
    // Nothing waiting will ever be sent.
    #cancel(error) {
      const pending = this.#waiting.splice(0);
      const idle = this.#idle.splice(0);
      for (const waiter of [...pending, ...idle]) waiter.reject(error);
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
      if (made !== token) throw new TypeError(constants.ILLEGAL_CONSTRUCTOR);
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
  return { SendQueue, Direct, endQueue };
};
