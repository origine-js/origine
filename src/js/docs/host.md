# `api.host`

Facts about the machine and process the program runs on. Types: `types/host.d.ts`.

## `host.env`

`args()`, `get(name)`, `list()` and `narrow({ allow })`; see `docs/api-design.md` (4.2).

## `host.Snapshot`

A heap snapshot in memory (types: `types/host.d.ts`). A new isolate started from one (`api.isolate.create({ snapshot })`) begins with the init module graph already evaluated, so it skips loading and running that code.

```js
const snapshot = api.host.Snapshot.create({ init: './worker.js' });   // blocks this thread while the graph is evaluated
const bytes = snapshot.origineDataBlob();     // same format as a file in the global cache
const later = api.host.Snapshot.fromOrigineDataBlob(bytes, { init: './worker.js' });
api.isolate.create({ init: './worker.js', snapshot: later });
```

| | |
|---|---|
| `Snapshot.create({ init })` | Evaluates the module graph of `init` (not its `main`) in a throwaway isolate **on this thread**, which stays blocked until it is done; run it in a worker isolate to keep an event loop responsive. `InvalidData` for an init that throws or needs I/O to finish, `Unsupported` for a graph a snapshot cannot carry, `PermissionDenied` where the embedder allows no isolates. |
| `Snapshot.fromRaw(bytes)` | A snapshot over a copy of a bare V8 blob (`blob()`'s result). It has no module table and no `init`: an isolate started from it begins with that heap and evaluates its init normally. `InvalidData` for bytes V8 refuses. |
| `Snapshot.fromOrigineDataBlob(bytes, { init })` | From the bytes `origineDataBlob()` made. A file only fits the build that made it, the same `init` and the same source files: anything else is `InvalidData` (a packed file in a build without LZ4 snapshots is `Unsupported`). |
| `snapshot.init` | The specifier it was made for, `undefined` after `fromRaw`. |
| `snapshot.blob()` | A `Uint8Array` copy of the raw V8 blob. |
| `snapshot.origineDataBlob({ compress? })` | A `Uint8Array` copy in the file format of the global cache (a `meta` word, then the module table and the blob), so JavaScript can keep it on disk. `compress: true` packs it with LZ4 and needs a build with LZ4 snapshots (`Unsupported` otherwise). `Unsupported` after `fromRaw`. |
| `snapshot.close()` | Releases the memory; isolates already started from it keep their own hold. `BadHandle` afterwards. |

## `host.threading`

- `parallelism`: logical CPUs the process may use (a number, at least 1). Read-only.
- `Channel`: `new Channel({ mode, capacity? })` makes two connected ports, `[port, remotePort]` (see below). Types: `types/host.d.ts`.

### Channels and ports

A channel connects two ports, in this isolate or in different ones (a port travels in a message or in `api.isolate.create`'s `data`, see below). Like the handles of `api.net`, a port is made in one of two **read modes**, chosen explicitly (`mode` has no default) and visible in its class, so they cannot be mixed: methods of the other mode do not exist on a port.

```js
const [port, remote] = new api.host.threading.Channel({ mode: 'pull' });
await port.send({ hello: 'world' }, { transfer: [buffer] });
const { identity, data, transfer } = await remote.recv();   // a frozen MessageEvent
for await (const event of remote) { /* until the peer closes its port */ }
```

| Mode | Receiving |
|---|---|
| `'pull'` | `recv(): Promise<MessageEvent>`, `for await (const event of port)`, `toEvent()` |
| `'event'` | `register('message' \| 'close' \| 'error', fn)` returns `{ unregister() }`; `pause()`, `resume()`, `paused`, `toPull()` |

Both: `send(data, { transfer }): Promise<void>` (waits while `capacity` messages are queued; default capacity 16 per direction), `close()`, `mode`. `toEvent()`/`toPull()` return a new port over the same channel and consume the old one (`BadHandle` afterwards); `toEvent()` throws `WouldBlock` with a `recv` pending, `toPull()` `Unsupported` once a `message` handler started the flow.

A `MessageEvent` is `{ identity, data, transfer }`: `identity` is the id of the sending isolate (0 for the first one, `Isolate.id` for one made by `create`), `data` the structured clone of what was sent, `transfer` the objects that moved with it, in the order of the sender's list.

**Cloning.** `Map`, `Set`, typed arrays, `BigInt`, plain objects and arrays work; functions and symbols throw `TypeError` at `send` and queue nothing. `SharedArrayBuffer`s are shared by reference (`Atomics` works across isolates). `Date` objects are not part of the guest: use `Temporal` (`Date.now()` exists).

**Transfer.** `send(data, { transfer: [...] })` moves the listed `ArrayBuffer`s (detached here once the message is queued; `Unsupported` for one that cannot be detached) and ports. As on the Web, a port in the message must be listed: an unlisted port is a `TypeError`. A listed port stops working here (`BadHandle`) and the receiver gets a working port of the same mode; its peer now talks to the receiver. A port with a `recv` pending or a started `message` flow cannot move (`WouldBlock`).

**Closing.** `close()` on a port ends the peer's reads once what was sent is read (`NotConnected` for `recv`, the end of the `for await`, the `close` event) and makes the peer's sends reject `BrokenPipe`. A port belongs to the isolate that has it; when that isolate ends, its ports close, so a peer is never left waiting for a crashed isolate. An event port with a `message` handler keeps the isolate's work pending: `close()` it to let the program end.

Natives: `rust/crates/origine_api/src/channel.rs` (`native.channel.*`), codec in `message.rs`.
