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

## Notes

- `closed` is true after `close()` or once the `io` runtime is closed; later calls reject with `BadHandle`.
- Closing a `Socket` shuts it down, so a pending `read` resolves with an empty array. Closing a `Server` with a pending `accept` leaves that accept (and the listener) pending until the runtime closes.
- `connect` is a blocking connect (loopback only) and `read` allocates its result (zero-initialised `length` bytes, compacted to the bytes read when that is at most half of a 4 KiB+ buffer).
- Backends: sockets work on `uring`, `kqueue` and `threaded` (the threaded backend waits for readiness on its workers).
- The Rust side: [natives.md](../../../rust/crates/origine_api/docs/natives.md#net-loopback-tcp-needs--runtime).
