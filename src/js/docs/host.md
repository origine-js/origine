# `api.host`

Facts about the machine and process the program runs on. Types: `types/host.d.ts`.

## `host.env`

`args()`, `get(name)`, `list()` and `narrow({ allow })`; see `docs/api-design.md` (4.2).

## `host.threading`

- `parallelism`: logical CPUs the process may use (a number, at least 1). Read-only.
- `channel({ capacity })`: a bounded channel between isolates, `{ tx, rx }`. `capacity` is required (no default).
- `sender(handle)`, `receiver(handle)`: rebuild an end from the `handle` number of one made elsewhere (an argument or a message to another isolate).

### Channels

Messages are copied with the structured clone algorithm (V8 `ValueSerializer`): `Map`, `Set`, typed arrays, `BigInt`, plain objects and arrays work; functions and symbols throw `TypeError` at `send` and queue nothing. `SharedArrayBuffer`s are shared by reference, not copied (`Atomics` works across isolates). `send(value, { transfer: [buffer] })` moves the listed `ArrayBuffer`s: they are detached in the sender once the whole value was serialized (`Unsupported` for a buffer that cannot be detached; the buffers stay intact when `send` throws).

| Call | Result |
|---|---|
| `tx.send(value, options?)` | `Promise<void>`; waits while the channel holds `capacity` messages. Rejects `BrokenPipe` when the receiver is closed. |
| `tx.clone()` | another sender; receivers see the end of the channel only when every sender is closed. |
| `tx.close()` / `rx.close()` | `BadHandle` when already closed. Closing the receiver drops queued messages. |
| `rx.recv()` | `Promise` of the oldest message; waits while the channel is empty. Rejects `NotConnected` once drained with no sender left. |
| `for await (const m of rx)` | the messages until that end. |

A handle names an end process-wide: the same number closes the same end for every isolate that holds it. Ends are not closed when an isolate dies; close them explicitly.
Order is kept per channel. Natives: `rust/crates/origine_api/src/channel.rs` (`native.channel.*`), codec in `message.rs`.
