# `api.net`: loopback TCP

`api.net` exists wherever `api.io` does (the embedder's runtime ceiling). Every socket belongs to the `io` runtime it was created with; closing the runtime invalidates its sockets. **Only loopback addresses are allowed** (`127.0.0.1`, `localhost`, `::1`); other hosts reject with `PermissionDenied`. There is no embedder permission for wider network access yet.

```js
const io = api.io.create();
const server = api.net.listen(io, { port: 0, mode: 'pull', socketMode: 'pull' });  // sync; PullServer
const client = await api.net.connect(io, { port: server.port, mode: 'pull' });      // PullSocket
const conn = await server.accept();                         // PullSocket (the server's socketMode)
await client.queued.send(new Uint8Array([1, 2, 3]));       // resolves once all bytes are in the kernel
const chunk = await conn.read(4096);                        // Uint8Array, empty = end of stream
await client.close();
await server.close();
```

## Modes

Every handle is made in one of two **read modes**, chosen explicitly (there is no default) and visible in its class, so a handle cannot mix them:

- `'pull'`: you ask for each read with a promise: `read`, `readInto`, `readCopy` on a socket, `accept()` on a server.
- `'event'`: the runtime pushes: `register`, `pause`, `resume` on both, `register('data' | 'connection', ...)` starts the flow (see [Events](#events)).

The write side (`direct`, `queued`, `end`, `close`, `closed`, `io`) is the same in both. Methods of the other mode **do not exist** on a handle (`socket.register === undefined` on a `PullSocket`), so mixing fails at runtime as well as in types.

`socket.toEvent()` / `socket.toPull()` (and the same on servers) hand the native handle to a **new** handle of the other mode and **consume the old one**: it reports `closed === true` and every operation on it throws or rejects `BadHandle` (it never closes the connection). `queued` and `direct` of the old handle keep working on the new one. A transfer fails rather than losing data:

- `toEvent()` throws `WouldBlock` while a `read`/`readInto`/`readCopy`/`accept()` is pending.
- `toPull()` throws `Unsupported` once a `data` (`connection`) handler started the flow (the runtime already read ahead into the events); before that, registered handlers are dropped and the handle behaves as a fresh pull handle.

### TypeScript surface (for the `.d.ts`)

```ts
type Mode = 'event' | 'pull';
interface SocketOptions { host?: string; port?: number; sendQueueLimit?: number }
declare class Handle { readonly io: Io; readonly closed: boolean; close(): Promise<void>; [Symbol.asyncDispose](): Promise<void> }
declare class Socket<M extends Mode> extends Handle {            // Socket<'pull'> = PullSocket, Socket<'event'> = EventSocket
  readonly remotePort: number; readonly queued: SendQueue; readonly direct: DirectWriter; end(): Promise<void>;
}
declare class PullSocket extends Socket<'pull'> {
  read(length: number): Promise<Uint8Array>; readInto(buffer: ArrayBuffer | ArrayBufferView): Promise<{ bytes: number; buffer: ArrayBuffer }>;
  readCopy(buffer: ArrayBuffer | ArrayBufferView): Promise<number>; toEvent(): EventSocket;
}
declare class EventSocket extends Socket<'event'> {
  register(event: 'data', fn: (e: DataEvent) => void): Registration; register(event: 'end' | 'drain' | 'close', fn: () => void): Registration;
  register(event: 'error', fn: (e: { errno: number; name: string }) => void): Registration;
  pause(): void; resume(): void; readonly paused: boolean; toPull(): PullSocket;
}
declare class Server<M extends Mode, S extends Mode> extends Handle { readonly port: number }
declare class PullServer<S extends Mode> extends Server<'pull', S> { accept(): Promise<Socket<S>>; toEvent(): EventServer<S> }
declare class EventServer<S extends Mode> extends Server<'event', S> {
  register(event: 'connection', fn: (socket: Socket<S>) => void): Registration; register(event: 'error' | 'close', ...): Registration;
  pause(): void; resume(): void; readonly paused: boolean; toPull(): PullServer<S>;
}
// listen/connect pick the class from `mode` (a literal type); a server's `socketMode` types the sockets it hands out.
declare function listen<M extends Mode, S extends Mode>(io: Io, o: SocketOptions & { mode: M; socketMode: S }): Server<M, S>;
declare function connect<M extends Mode>(io: Io, o: SocketOptions & { port: number; mode: M }): Promise<Socket<M>>;
```

## Classes

Handles are instances of classes the guest cannot construct (`TypeError`), whose native id lives in state the guest cannot reach; methods brand-check their receiver. The classes and `api.net` are frozen.

| | |
|---|---|
| `Handle` | base: `io`, `closed`, `close()` (idempotent, `Promise<void>`; discards what is still queued), `[Symbol.asyncDispose]()` when the engine has it |
| `Server extends Handle` | base of servers: `port` |
| `PullServer extends Server` | `accept(): Promise<PullSocket \| EventSocket>` (by the server's `socketMode`), `toEvent(): EventServer` |
| `EventServer extends Server` | `register`, `pause()`, `resume()`, `paused`, `toPull(): PullServer` |
| `Socket extends Handle` | base of sockets, the write side: `remotePort`, `queued` and `direct` (the two write lanes, below), `end(side): Promise<void>` (see [Closing](#closing)) |
| `PullSocket extends Socket` | `read(length): Promise<Uint8Array>` (1 to 2^28 bytes), `readInto(buffer): Promise<{ bytes, buffer }>` (zero-copy: your buffer is detached while the read runs and comes back as a new ArrayBuffer; `Unsupported` if it cannot be detached; best for large reads), `readCopy(buffer): Promise<number>` (copies into your buffer without detaching it, so one buffer serves every read; best for small reads; 0 = end of stream), `toEvent(): EventSocket` |
| `EventSocket extends Socket` | `register`, `pause()`, `resume()`, `paused`, `toPull(): PullSocket` |
| `api.net.listen(io, { mode, socketMode, host?, port?, sendQueueLimit? })` | `PullServer` or `EventServer` by `mode`; `socketMode` (`'event'` \| `'pull'`, required) is the mode of the sockets it accepts. Throws `TypeError` for a missing or unknown `mode`/`socketMode`, `{ errno, name }` (`AddressInUse`, `PermissionDenied`, `BadHandle`, ...) otherwise |
| `api.net.connect(io, { mode, port, host?, sendQueueLimit? })` | `Promise<PullSocket \| EventSocket>` by `mode`; `port` is required (`TypeError` without it); rejects `ConnectionRefused`, ... |

### Hosts

Only loopback is reachable. An IP literal (`127.0.0.1`, `::1`, any loopback address) is used exactly as given. `localhost` is a name and is **never** looked up in the system resolver (RFC 6761): `connect` tries `127.0.0.1`, then `::1` if that fails, one after the other; `listen` binds `127.0.0.1` (pass `'::1'` to listen on IPv6). Any other host rejects with `PermissionDenied`. `connect` never blocks: the socket is created non-blocking and the loop finishes the handshake.

### Closing

The runtime **never closes a socket just because the peer sent its FIN**: that only fires `end` (pull mode: a read resolves empty) and the socket stays open and writable. `socket.end(side)` ends your side; `side` is required (`TypeError` without it, or for anything else) and follows `shutdown(2)`:

- `'write'`: once everything queued (and waiting sends) is out, sends the FIN; resolves when it is sent. Later writes fail with `BrokenPipe`.
- `'read'`: stops reading and discards what arrives: reads started afterwards resolve empty, no more `data`/`end` events. The kernel side stays open (the runtime drains the socket until the peer's FIN), because a `shutdown(SHUT_RD)` makes some systems reset the connection when the peer sends.
- `'both'`: both, the read side after the flush.

**A socket closes itself once both directions are finished**: the peer's FIN was seen (or you ended `'read'`) *and* your write side was ended (`'write'` or `'both'`, after the FIN was sent). Then `close` fires (event mode). `close()` is the explicit release at any time and discards what is still queued. Because `io.run()` waits for sockets to close, an `end` handler should call `end('write')` (to answer first, write, then end) or `close()`.

## Events

Instead of one promise per read, an `'event'` handle is *subscribed*. Handlers are called directly from the host loop, with no promise or task per message:

```js
const running = io.run();                      // keeps the program alive (see Lifetime)
server.register('connection', conn => {      // listen(io, { mode: 'event', socketMode: 'event' })
  conn.register('data', ev => {
    const chunk = ev.buffer();                 // a lease: give it back with chunk.unref() (or `using`)
    conn.pause();                              // no more data events until resume()
    conn.queued.send(chunk).then(() => { chunk.unref(); conn.resume(); });
  });
});
await running;
```

| Handle | Events |
| --- | --- |
| `EventSocket` | `data` (`ev.length`, `ev.buffer()`), `end` (peer finished), `error` (`{ errno, name }`), `drain` (the send queue became empty), `close` |
| `EventServer` | `connection` (a socket of the server's `socketMode`), `error`, `close` |

- `handle.register(event, fn)` returns `{ unregister() }` (`true` if it was registered). Handlers of one event run in registration order. The first `data` (or `connection`) handler starts reading. When the last one is unregistered the handle pauses itself, so nothing is read just to be dropped; registering one again resumes it. After `close` the handlers are dropped; `register` on a closed handle throws `BadHandle`.
- A socket that failed (`error`) is closed by the runtime, then `close` fires; a peer's FIN only fires `end` (see [Closing](#closing)). `close()` on your side fires `close` once and nothing else.
- A handler that throws goes to the `error` handlers (the other handlers still run); with none, or if one of those throws, it becomes an unhandled rejection.
- `ev` is valid only while its handlers run. `ev.buffer()` returns the same **lease** within one event: a `Uint8Array` over an ArrayBuffer of **exactly** the received bytes (`lease.buffer.byteLength === lease.length`, `byteOffset` 0). The bytes are received into slabs of the V8 sandbox's allocator and the buffer is carved out of the slab without a copy; no other byte of the socket's memory (earlier chunks, neighbouring chunks) is reachable through it. A handler that never calls `buffer()` costs nothing. Give a lease back with `unref()` or `using` (`Symbol.dispose`): that detaches its ArrayBuffer (a view you kept becomes empty) and frees its hold on the slab, which is freed with its last lease. A lease you never release is garbage collected like any buffer.

### Writing

A socket has two write lanes that share **one order**: bytes leave in the order they were accepted. The queue has priority; the direct lane is the unbuffered fast lane that may only run when nothing is queued.

| | `socket.direct.write(data): number` | `socket.queued.put(data): number` | `socket.queued.send(data): Promise<void>` |
|---|---|---|---|
| What it does | One non-blocking `write(2)`; no copy, nothing kept | Queues as much as fits under `queued.limit` | Queues all of `data`, waiting for room |
| Returns | Bytes the kernel took (0 if it would block) | Bytes accepted (0 if the queue is full) | Resolves when the last byte is in the kernel |
| Queue idle | Writes | Tries the kernel first, then copies the rest into the queue | Same, whole `data` |
| Queue busy | Returns 0, writes nothing | Appends | Appends, or waits its turn if it does not fit |
| Sends waiting | Returns 0 | Returns 0 | Waits behind them (FIFO) |

- "Sent" means accepted by the kernel (`write(2)` returned), not received by the peer.
- `socket.queued` also has `bytes` (waiting in the queue), `waiting` (sends not admitted yet), `limit` (settable; default 1 MiB, or `sendQueueLimit` at `connect`/`listen`; accepted sockets inherit it) and `drained(): Promise<void>` (the queue is empty and nothing waits). A `send` into an empty queue is always admitted, whatever its size; otherwise it is admitted when `bytes + data.byteLength <= limit`. Waiting sends are admitted in order each time the queue empties.
- `put` and `direct.write` copy nothing they do not queue; `send` reads `data` when it is admitted (at once unless the queue is full), so leave `data` untouched until the promise settles. A `put` is copied; the buffer can be reused right after it returns.
- The `drain` event fires every time the queue becomes empty, after the sends it settles. To wait for room with `put`, wait for `drain` (or `await queued.drained()`).
- A write error rejects every pending `send`, throws from `put`/`direct.write`, and the socket emits `error` once and closes. `close()` discards the queue and rejects pending and waiting sends with `Canceled`.
- `socket.end('write')` stops sending once everything queued (and waiting) is out: the peer reads end of stream, this side keeps reading. Later writes fail with `BrokenPipe`. See [Closing](#closing) for `'read'`, `'both'` and the auto-close rule.

### Reading

- `pause()` / `resume()` / `paused` (event sockets and servers; idempotent). After `pause()` returns no `data`, `end` or `error` (for a server, `connection`) event is dispatched; what already arrived is held in order and dispatched first on `resume()`. A paused socket holds at most 8 undelivered chunks (128 KiB) and then stops reading, so the peer is held back through TCP; a paused server stops accepting and connections wait in the kernel backlog. `close()` works while paused, and `io.run()` waits for a paused socket to close.
- A handler that needs to do asynchronous work per chunk pauses first (see the example above): the runtime does not wait for a handler's promise.
- While 8 chunks are undelivered the runtime stops reading anyway, so a slow handler backpressures the peer even without `pause()`.

### Lifetime

Registrations never keep the program alive on their own, so a program that registers handlers and returns from `main` ends, dropping them silently. `io.run()` returns a promise that resolves once every handle of that runtime that started flowing (`data` or `connection` registered) has closed, and keeps the program alive while pending; an `await` on a promise that only a handler resolves needs a pending `io.run()` too, or the host reports that nothing can make progress. `io.close()` drops all handlers without calling them.

## Notes

- `closed` is true after `close()` or once the `io` runtime is closed; later calls reject with `BadHandle`.
- Closing a `Socket` shuts it down, so a pending `read` resolves with an empty array. Closing a `Server` with a pending `accept` leaves that accept (and the listener) pending until the runtime closes.
- `read` allocates its result (zero-initialised `length` bytes, compacted to the bytes read when that is at most half of a 4 KiB+ buffer).
- Backends: sockets work on `uring`, `kqueue` and `threaded` (the threaded backend waits for readiness on its workers).
- The Rust side: [natives.md](../../../rust/crates/origine_api/docs/natives.md#net-loopback-tcp-needs--runtime).
