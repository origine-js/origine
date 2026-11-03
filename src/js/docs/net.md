# TCP and UDP: `io.tcp`, `io.udp` and the `api.net` classes

The network is reached through an `Io` (`api.io.create()`): its tables `io.tcp` and `io.udp` make every socket. Every object belongs to that runtime; closing the runtime closes its descriptors. **Which addresses are reachable is the embedder's [network ceiling](../../../docs/net-grant.md)**: loopback only by default (`127.0.0.1`, `::1`), wider when the embedder says so (the shell's `--net-connect` and `--net-listen`). An address no rule allows is `PermissionDenied`, the address with its port (`10.0.0.1:80`) as the error's `subject`. `api.net` is the facade: it holds the classes, for `instanceof`, and makes nothing.

```js
import { SocketAddr } from 'origine:@std/net';
const io = api.io.create();
const listener = io.tcp.listen(SocketAddr.parse('127.0.0.1:0')).pulling();   // sync; PullTcpListener
const accepting = listener.accept();                                           // Promise<TcpStreamUnshaped>
const client = (await io.tcp.connect(listener.localAddr)).pulling();         // PullTcpStream
const conn = (await accepting).pulling();
await client.queued.send(new Uint8Array([1, 2, 3]));       // resolves once all bytes are in the kernel
const chunk = await conn.read(4096);                        // Uint8Array, empty = end of stream
await client.close();
await listener.close();
```

## Unshaped, then shaped

The factories return **unshaped** objects that own the descriptor and flow nothing: `io.tcp.connect(addr)` a `TcpStreamUnshaped`, `io.tcp.listen(addr)` a `TcpListenerUnshaped`, `io.udp.bind(addr)` a `UdpSocketUnshaped`. An unshaped stream is already a stream for a native engine: `api.tls` and `api.http` take it as it is and do their I/O natively. `.pulling()` or `.evented()` **consumes** the object (it answers `BadHandle` afterwards) and returns the shaped class:

| Unshaped | `.pulling()` | `.evented()` |
|---|---|---|
| `TcpStreamUnshaped` | `PullTcpStream`: `read`, `readInto`, `readCopy` | `EventTcpStream`: `register('data' \| 'end' \| 'error' \| 'drain' \| 'close')` |
| `TcpListenerUnshaped` | `PullTcpListener`: `accept()` | `EventTcpListener`: `register('connection' \| 'error' \| 'close')` |
| `UdpSocketUnshaped` | `PullUdpSocket`: `recvFrom(length)` | `EventUdpSocket`: `register('datagram' \| 'error' \| 'close')` |

A stream's `pulling(options)` / `evented(options)` take `{ queued: { limit } }` (default 1 MiB). An accepted connection is again unshaped and takes its own shape. Methods of the other shape **do not exist** on an object (`register === undefined` on a `PullTcpStream`).

`stream.toEvented()` / `stream.toPulling()` move the connection into a **new** object of the other shape and **consume the old one**. The new object has its own `queued` and `direct` over the same connection (what is queued stays queued). A transfer fails rather than losing data: `toEvented()` throws `WouldBlock` while a read is pending; `toPulling()` throws `Unsupported` once a `data` handler started the flow (the runtime already read ahead into the events).

Every object is an instance of a class defined in Rust (`rust/crates/origine_api/src/{stream,udp}.rs`), owned by the garbage collector: `new` throws a `TypeError`, a member called on another object is a `TypeError`, the classes are frozen, and no id reaches the program. `close()` frees the descriptor at once; the object stays allocated until it is collected and answers `BadHandle` (`closed === true`). Collecting an object nothing uses closes its descriptor.

| | |
|---|---|
| every object | `closed`, `localAddr` (a `SocketAddr`), `close()` (idempotent, `Promise<void>`), `[Symbol.asyncDispose]()` |
| streams | `peerAddr`; shaped: `queued`, `direct`, `end(side)` (see [Closing](#closing)) |
| `PullTcpStream` | `read(length)` (1 to 2^28 bytes, allocated), `readInto(buffer)` (zero-copy: your buffer is detached while the read runs and comes back as a new ArrayBuffer; `Unsupported` if it cannot be detached), `readCopy(buffer)` (copies into your buffer, which stays usable; 0 = end of stream), `toEvented()`, `for await (const chunk of stream)` |
| `PullTcpListener` | `accept()` (an unshaped stream; `Canceled` when the listener closes first), `for await (const stream of listener)`; `close()` resolves once the port is free |
| datagram sockets | `peerAddr` (after `connect`), `sendTo(data, addr?)` (resolves the bytes sent; without `addr`, to the connected peer, else `NotConnected`), `connect(addr)` |
| `PullUdpSocket` | `recvFrom(length)`: `{ data, addr }`, the first `length` (1 to 65535) bytes of the next datagram (the rest is dropped) and its source |

### Addresses

`addr` is always a `SocketAddr` of `origine:@std/net` (an IP literal and a port; IPv6 in brackets), and it crosses into the natives as its octets, port and scope id. Nothing is resolved: a name is not a `SocketAddr` (`SocketAddr.parse('localhost:80')` is a `TypeError`); look it up with `api.dns` and pass the address. The ceiling checks the address a call is about to use, canonicalised (an IPv4-mapped address is the IPv4 address): `listen` and `bind` against the `listen` rules, `connect` and every datagram destination (`sendTo`, `connect`) against the `connect` rules. `connect` never blocks: the socket is created non-blocking and the loop finishes the handshake. Datagram sockets wait for a datagram with a one-byte `MSG_PEEK` on the loop and take it with a non-blocking `recvfrom(2)`.

### Closing

The runtime **never closes a stream just because the peer sent its FIN**: that only fires `end` (pull: a read resolves empty) and the stream stays open and writable. `stream.end(side)` ends your side; `side` is required (rejects `TypeError` otherwise) and follows `shutdown(2)`:

- `'write'`: once everything queued (and waiting sends) is out, sends the FIN (under TLS `close_notify` first); resolves when it is sent. Later writes fail with `BrokenPipe`.
- `'read'`: stops reading and discards what arrives: reads started afterwards resolve empty, no more `data`/`end` events. The kernel side stays open (the runtime drains the socket until the peer's FIN), because a `shutdown(SHUT_RD)` makes some systems reset the connection when the peer sends.
- `'both'`: both, the read side after the flush.

**A stream closes itself once both directions are finished**: the peer's FIN was seen (or you ended `'read'`) *and* your write side was ended. Then `close` fires (event mode). `close()` is the explicit release at any time and discards what is still queued.

## Events

Instead of one promise per read, an evented object is *subscribed*. The handlers are held natively (in the Host, never in a JS table) and called directly from the host loop, with no promise or task per message:

```js
const running = io.run();                          // keeps the program alive (see Lifetime)
listener.register('connection', stream => {      // io.tcp.listen(addr).evented()
  const conn = stream.evented();                   // each connection takes its own shape
  conn.register('data', async ev => {
    using chunk = ev.buffer();                     // a lease, released at the end of the block
    await conn.queued.send(chunk);                 // the lease stays valid across the await
  });
});
await running;
```

| Handle | Events |
| --- | --- |
| `EventTcpStream` | `data` (a `DataEvent`: `ev.length`, `ev.buffer()`), `end` (peer finished), `error` (`OrigineError` subclass), `drain` (the send queue became empty), `close` |
| `EventTcpListener` | `connection` (a `TcpStreamUnshaped`), `error`, `close` |
| `EventUdpSocket` | `datagram` (a `DatagramEvent`: `ev.length`, `ev.from` (a `SocketAddr`), `ev.buffer()`: one whole datagram, one lease), `error`, `close` |

- `handle.register(event, fn)` returns `{ unregister() }` (`true` if it was registered). Handlers of one event run in registration order. The first `data` (or `connection`) handler starts reading. When the last one is unregistered the handle pauses itself, so nothing is read just to be dropped; registering one again resumes it. This pause holds only the chunks (connections), and an `end` behind them: with none held `end` fires, and `error` and `close` always do. After `close` the handlers are dropped; `register` on a closed handle throws `BadHandle`.
- A socket that failed (`error`) is closed by the runtime, then `close` fires; a peer's FIN only fires `end` (see [Closing](#closing)). `close()` on your side fires `close` once and nothing else.
- A handler that throws goes to the `error` handlers (the other handlers still run); with none, or if one of those throws, it becomes an unhandled rejection. A promise a handler returns is **not** awaited and the next event is delivered without waiting for it (its rejection is the program's to handle): backpressure is the bounded number of chunks the runtime keeps undelivered, and `pause()`.
- A `DataEvent` is reused for every chunk and valid only while its handlers run: call `ev.buffer()` before the first `await`. It returns the same **lease** within one event, which stays valid (across awaits) until released: a `Uint8Array` over an ArrayBuffer of **exactly** the received bytes (`lease.buffer.byteLength === lease.length`, `byteOffset` 0). The bytes are received into slabs of the V8 sandbox's allocator and the buffer is carved out of the slab without a copy; no other byte of the socket's memory (earlier chunks, neighbouring chunks) is reachable through it. A handler that never calls `buffer()` costs nothing. Give a lease back with `unref()` or `using` (`Symbol.dispose`): that detaches its ArrayBuffer (a view you kept becomes empty) and frees its hold on the slab, which is freed with its last lease. A lease you never release is garbage collected like any buffer.

### Writing

A stream has two write lanes that share **one order**: bytes leave in the order they were accepted. The queue has priority; the direct lane is the unbuffered fast lane that may only run when nothing is queued.

| | `stream.direct.write(data): number` | `stream.queued.put(data): number` | `stream.queued.send(data): Promise<void>` |
|---|---|---|---|
| What it does | One non-blocking `write(2)`; no copy, nothing kept | Queues as much as fits under `queued.limit` | Queues all of `data`, waiting for room |
| Returns | Bytes the kernel took (0 if it would block) | Bytes accepted (0 if the queue is full) | Resolves when the last byte is in the kernel |
| Queue idle | Writes | Tries the kernel first, then copies the rest into the queue | Same, whole `data` |
| Queue busy | Returns 0, writes nothing | Appends | Appends, or waits its turn if it does not fit |
| Sends waiting | Returns 0 | Returns 0 | Waits behind them (FIFO) |

- "Sent" means accepted by the kernel (`write(2)` returned), not received by the peer.
- `stream.queued` also has `bytes` (waiting in the queue), `waiting` (sends and ends not admitted yet), `limit` (settable; default 1 MiB, or `queued: { limit }` of `pulling()` / `evented()`) and `drained(): Promise<void>` (the queue is empty and nothing waits). A `send` into an empty queue is always admitted, whatever its size; otherwise it is admitted when `bytes + data.byteLength <= limit`. Waiting sends are admitted in order each time the queue empties.
- `put` and `direct.write` copy nothing they do not queue; `send` **copies** `data` when it is called (the buffer can be reused at once) and queues the copy when it is admitted. A `put` is copied too.
- The `drain` event fires every time the queue becomes empty, after the sends it settles. To wait for room with `put`, wait for `drain` (or `await queued.drained()`).
- A write error rejects every pending `send`, throws from `put`/`direct.write`, and the socket emits `error` once and closes. `close()` and `io.close()` discard the queue and reject pending and waiting sends and `drained()` with `Canceled`.
- `stream.end('write')` stops sending once everything queued (and waiting) is out: the peer reads end of stream, this side keeps reading. Later writes fail with `BrokenPipe`. See [Closing](#closing) for `'read'`, `'both'` and the auto-close rule.

### Reading

- `pause()` / `resume()` / `paused` (every evented object; idempotent). After `pause()` returns no `data`, `end`, `error` or `close` (for a server, `connection`) event is dispatched; what already arrived is held in order and dispatched first on `resume()`. Pausing is about the read side: `drain` still fires, waiting sends are still admitted, and a write error still rejects them. A paused socket holds at most 8 undelivered chunks (128 KiB) and then stops reading, so the peer is held back through TCP; a paused server stops accepting and connections wait in the kernel backlog. `close()` works while paused, and `io.run()` waits for a paused socket to close.
- A handler that must not see the next chunk before its asynchronous work is done pauses first and resumes after: the runtime does not wait for a handler's promise.
- While 8 chunks are undelivered the runtime stops reading anyway, so a slow handler backpressures the peer even without `pause()`.

### Lifetime

Registrations never keep the program alive on their own, so a program that registers handlers and returns from `main` ends, dropping them silently. `io.run()` returns a promise that resolves once every object of that runtime that started flowing (`data`, `connection` or `datagram` registered) has closed, and keeps the program alive while pending; an `await` on a promise that only a handler resolves needs a pending `io.run()` too, or the host reports that nothing can make progress. `io.close()` drops all handlers without calling them.

## Notes

- `closed` is true after a transfer, after `close()` or once the `io` runtime is closed; later calls reject with `BadHandle`. `io.close()` rejects what is pending (reads, accepts, sends, `drained()`) with `Canceled`.
- Closing a stream shuts it down, so a pending `read` resolves with an empty array. Closing a `PullTcpListener` rejects a pending `accept` with `Canceled`, and its promise resolves once the port is free.
- `read` allocates its result (zero-initialised `length` bytes, compacted to the bytes read when that is at most half of a 4 KiB+ buffer).
- Backends: sockets work on `uring`, `kqueue` and `threaded` (the threaded backend waits for readiness on its workers).
- The Rust side: [natives.md](../../../rust/crates/origine_api/docs/natives.md#the-network-classes-needs--runtime).
