// `api.net` core: the state of one native handle and the routing of its events. Built by net.js.
import { Registration } from '../handles.js';
import { freeze, failure, closedIo, errors } from '../util.js';
const { Unsupported, WouldBlock, Canceled } = errors;
export default (k, { SendQueue, Direct, DataEvent, beginData, endData }) => {
  const { native, token } = k;
  // Bytes per read while draining a socket whose reading was ended.
  const DRAIN_READ = 1 << 16;
  // `dispatch(kind, a, b)` kinds: the same numbers as rust/crates/origine_api/src/sub.rs.
  const DATA = 0;
  const END = 1;
  const ERROR = 2;
  const DRAIN = 3;
  const CONNECTION = 4;
  const CLOSE = 5;
  const FAILED = 6;
  // `pause` of the native: what a handle holds back, by why it is paused (see `net_pause` in sub.rs).
  const PAUSE_NONE = 0;
  const PAUSE_NO_HANDLER = 1;
  const PAUSE_EXPLICIT = 2;
  const SOCKET_EVENTS = freeze(['data', 'end', 'error', 'drain', 'close']);
  const SERVER_EVENTS = freeze(['connection', 'error', 'close']);

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
      this.applied = PAUSE_NONE;
      // Pull-mode operations in flight, and a server's accepts among them (closing waits for those).
      this.pending = 0;
      this.accepts = new Set();
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
        hub.shut?.(failure(Canceled));
        this.fire(hub, 'close');
        hub.handlers.clear();
        return;
      }
      if (kind === FAILED) {
        hub.shut?.(failure(a));
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
          const socket = k.makeSocket(this.socketMode, a, this.io, b, this.limit);
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
      return new Registration({
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
      const want = this.userPaused ? PAUSE_EXPLICIT : this.autoPaused ? PAUSE_NO_HANDLER : PAUSE_NONE;
      if (this.hub === null || this.closed || want === this.applied) return;
      this.applied = want;
      if (want === PAUSE_NONE) native.net.resume(this.id);
      else native.net.pause(this.id, want === PAUSE_NO_HANDLER);
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
      return this.userPaused || this.flowing === 0;
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
  return { Core };
};
