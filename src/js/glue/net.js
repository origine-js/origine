// `api.net`: loopback TCP on an io runtime. An ES module factory used by index.js:
// Its default export imports the per-realm native and shared helpers. `makeNetCap()` returns the frozen `{ listen, connect, ... }`.
// Handles are instances of the classes of the `net/` files, built here: the native id lives in a `Core`
// that only they can reach (a private field of the handle holds it), only they can construct handles
// (`token`), and methods brand-check their receiver. Every native call still re-validates owner
// and runtime in Rust. `net/event.js` has the data event, `net/send.js` the send queue and the direct lane,
// `net/core.js` the state of one native handle, `net/server.js` the base handle and the servers, `net/socket.js`
// the sockets.
//
// A handle has one of two read modes, fixed when it is made and visible in its class:
// `PullSocket`/`PullServer` (promise reads, `accept()`) and `EventSocket`/`EventServer`
// (`register`, `pause`, `resume`). The write side (`direct`, `queued`, `end`, `close`) is shared
// by both. `toEvent()`/`toPull()` move the native handle into a new instance of the other class
// and consume the old one.
import { freeze, freezeMethods, own, failure, ioHandles, closedIo, errors, shared } from './util.js';
import event from './net/event.js';
import send from './net/send.js';
import core from './net/core.js';
import server from './net/server.js';
import socket from './net/socket.js';
const { BadHandle, WouldBlock, Unsupported } = errors;
// Default `queued.limit`: bytes the outbox holds for a slow peer.
const QUEUE_LIMIT = 1 << 20;
export default native => {
  // The construction token: only the net files can make handles. `makeSocket` is filled once the sockets
  // exist, for the core and the servers that make sockets from native events.
  const k = { native, token: {}, makeSocket: undefined };
  const { token } = k;
  const { Lease, DataEvent, beginData, endData } = event(k);
  const { SendQueue, Direct, endQueue } = send(k);
  const { Core } = core(k, { SendQueue, Direct, DataEvent, beginData, endData });
  const { Handle, Server, PullServer, EventServer, live, coreOf, revoke } = server(k);
  const { Socket, PullSocket, EventSocket, makeSocket } = socket(k, { Core, Handle, live, coreOf, revoke, endQueue });
  k.makeSocket = makeSocket;

  // For `api.tls`: the native id of a pull socket that can be handed over, and the call that consumes the JS
  // handle once the native took the socket (a refused handover leaves the handle usable).
  shared.netTake = socket => {
    if (!(socket instanceof PullSocket)) throw new TypeError('socket must be a pull-mode api.net socket');
    const core = live(socket);
    if (core.pending > 0 || core.queued.bytes > 0 || core.queued.waiting > 0) throw failure(WouldBlock);
    if (core.hub !== null || core.readEnded || core.writeEnded) throw failure(Unsupported);
    return { id: core.id, io: core.io, port: core.port, consume: () => revoke(socket, () => {}) };
  };
  // For `api.tls`: a socket of the given mode over native id `id`, the native id of a live socket, and the
  // `queued.limit` of an options object.
  shared.netMake = (mode, id, io, port, limit) => makeSocket(mode, id, io, port, limit);
  shared.netId = socket => live(socket).id;

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
    const queued = own(options, 'queued');
    if (queued !== undefined && (queued === null || typeof queued !== 'object')) throw new TypeError('queued must be an object');
    const limit = own(queued, 'limit') ?? QUEUE_LIMIT;
    if (!Number.isSafeInteger(limit) || limit < 1) throw new TypeError('queued.limit must be a positive integer');
    return limit;
  };
  shared.netQueueLimit = queueLimit;
  // Published for `api.http`'s `connect` and `serve`, which dial and listen through it.
  return () =>
    (shared.net = freeze({
      Handle,
      Server,
      PullServer,
      EventServer,
      Socket,
      PullSocket,
      EventSocket,
      /**
       * Binds and listens (loopback only). Synchronous; throws an OrigineError subclass. `mode` ('event' or
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
    }));
};
