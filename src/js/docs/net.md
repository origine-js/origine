# `api.net`: loopback TCP

`api.net` exists wherever `api.io` does (the embedder's runtime ceiling). Every socket belongs to the `io` runtime it was created with; closing the runtime invalidates its sockets. **Only loopback addresses are allowed** (`127.0.0.1`, `localhost`, `::1`); other hosts reject with `AccessDenied`. There is no embedder permission for wider network access yet.

```js
const io = api.io.create();
const server = api.net.listen(io, { port: 0 });            // sync; Server
const client = await api.net.connect(io, { port: server.port });
const conn = await server.accept();                         // Socket
await client.write(new Uint8Array([1, 2, 3]));              // all bytes sent
const chunk = await conn.read(4096);                        // Uint8Array, empty = end of stream
await client.close();
await server.close();
```

## Classes

Handles are instances of classes the guest cannot construct (`TypeError`), whose native id is a private field it cannot read or swap; methods brand-check their receiver. The classes and `api.net` are frozen.

| | |
|---|---|
| `Handle` | base: `io`, `closed`, `close()` (idempotent, `Promise<void>`), `[Symbol.asyncDispose]()` when the engine has it |
| `Server extends Handle` | `port`, `accept(): Promise<Socket>` |
| `Socket extends Handle` | `remotePort`, `read(length): Promise<Uint8Array>` (1 to 2^28 bytes), `readInto(buffer): Promise<{ bytes, buffer }>` (zero-copy: your buffer is detached while the read runs and comes back as a new ArrayBuffer; `Unsupported` if it cannot be detached; best for large reads), `readCopy(buffer): Promise<number>` (copies into your buffer without detaching it, so one buffer serves every read; best for small reads; 0 = end of stream), `write(data): Promise<number>` (ArrayBuffer or view; copied) |
| `api.net.listen(io, { host?, port? })` | `Server`; throws `{ errno, name }` (`AddressInUse`, `AccessDenied`, `BadHandle`, ...) |
| `api.net.connect(io, { host?, port })` | `Promise<Socket>`; rejects `ConnectionRefused`, ... |

## Events

Instead of one promise per read, a handle can be *subscribed*. Handlers are called directly from the host loop, with no promise or task per message:

```js
const running = io.run();                      // keeps the program alive (see Lifetime)
server.register('connection', conn => {
  conn.register('data', ev => {
    using chunk = ev.buffer();                 // or: const chunk = ev.buffer(); ...; chunk.unref()
    if (!conn.send(chunk)) { /* wait for 'ready' */ }
  });
});
await running;
```

| Handle | Events |
| --- | --- |
| `Socket` | `data` (`ev.length`, `ev.buffer()`), `end` (peer finished), `error` (`{ errno, name }`), `ready` (writable again after `send` answered `false`), `close` |
| `Server` | `connection` (a `Socket`), `error`, `close` |

- `handle.register(event, fn)` returns `{ unregister() }` (`true` if it was registered). Handlers of one event run in registration order. The first `data` (or `connection`) handler starts reading; chunks that arrive with no `data` handler are dropped. After `close` the handlers are dropped; `register` on a closed handle throws `BadHandle`.
- A socket whose peer finished (`end`) or failed (`error`) is closed by the runtime, then `close` fires. `close()` on your side fires `close` once and nothing else.
- A handler that throws goes to the `error` handlers (the other handlers still run); with none, or if one of those throws, it becomes an unhandled rejection.
- `ev` is valid only while its handlers run. `ev.buffer()` returns the same **lease** within one event: a `Uint8Array` of exactly the received bytes, copied once into a V8 buffer from a per-socket pool (a handler that never calls it costs no copy). Keep it as long as you like and give it back with `unref()` or `using` (`Symbol.dispose`): that detaches its ArrayBuffer (a view you kept becomes empty, it can never alias a later chunk) and returns the store to the pool. A lease you never release is garbage collected like any buffer and the pool allocates a replacement. `lease.buffer` may be larger than the lease (16 KiB stores) and holds earlier chunks of the same socket beyond `lease.length`; do not hand it to code that should not see those.
- `socket.send(data): boolean` writes synchronously (a plain non-blocking write; only what the kernel does not take is copied and queued) and returns whether to keep writing. `false` means more than 64 KiB is queued: stop until `ready`. A failed write is an `error` event, not an exception. `write()` (promise) and `send()` share the socket but not an ordering guarantee between them; use one.
- Flow control: while 8 chunks are undelivered the runtime stops reading, so a slow handler backpressures the peer through TCP.

### Lifetime

Registrations never keep the program alive on their own, so a program that registers handlers and returns from `main` ends, dropping them silently. `io.run()` returns a promise that resolves once every handle of that runtime that started flowing (`data` or `connection` registered) has closed, and keeps the program alive while pending; an `await` on a promise that only a handler resolves needs a pending `io.run()` too, or the host reports that nothing can make progress. `io.close()` drops all handlers without calling them.

## Notes

- `closed` is true after `close()` or once the `io` runtime is closed; later calls reject with `BadHandle`.
- Closing a `Socket` shuts it down, so a pending `read` resolves with an empty array. Closing a `Server` with a pending `accept` leaves that accept (and the listener) pending until the runtime closes.
- `connect` is a blocking connect (loopback only) and `read` allocates its result (zero-initialised `length` bytes, compacted to the bytes read when that is at most half of a 4 KiB+ buffer).
- Backends: sockets work on `uring`, `kqueue` and `threaded` (the threaded backend waits for readiness on its workers).
- The Rust side: [natives.md](../../../rust/crates/origine_api/docs/natives.md#net-loopback-tcp-needs--runtime).
