// `api.net` data events: the leased chunk and the `data` event. Built by net.js.
export default ({ native, token }) => {
  let beginData;
  let endData;

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
  return { Lease, DataEvent, beginData, endData };
};
