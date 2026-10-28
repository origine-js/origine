# `api.isolate`

Isolates (V8 isolates, each with its own heap, `Host` and I/O runtimes) on other threads. Types: `types/isolate.d.ts`. Only where the embedder passes `Config.isolates` (the `origine` shell does); otherwise accessing `api.isolate` fails `PermissionDenied`. It is not part of the basic api.

```js
const iso = api.isolate.create({ init: './worker.js', capacity: 8, args: ['x'], env: { MODE: 'fast' }, data: { sab } });
await iso.tx.send({ n: 21 });          // -> parent.rx in the worker
const reply = await iso.rx.recv();     // <- parent.tx in the worker
iso.tx.close();                        // ends the worker's `for await (... of parent.rx)`
const { status, error } = await iso.join();
```

```js
// worker.js
export async function main(api) {
  const parent = api.isolate.parent;   // { tx, rx, data }; null in the first isolate
  for await (const message of parent.rx) await parent.tx.send(message.n * 2);
}
```

- `create(options)` takes an options object or a `CreateConfig` (`CreateConfig(options)` validates once and freezes; passing a config to it returns it). `init` and `capacity` are required; `capacity` sizes both default channels. `args` default `[]` (the child sees `[init, ...args]`), `env` defaults to `{}`: nothing is inherited. `data` is structured-cloned (`SharedArrayBuffer`s are shared); `transfer` lists the `ArrayBuffer`s of `data` to move.
- The new isolate is not narrowed by its creator. Its init module decides what it does, within the embedder's ceiling (the same fs root and runtime limits as the creator's host, and `max` isolates per host).
- `join()` resolves once the thread has ended, with `{ status: 'completed' | 'failed' | 'terminated', error? }` (`error` is the error name of a failed isolate, such as `MainFailed`). Always the same object. `terminate()` interrupts running JavaScript; a child blocked on I/O notices within about 100 ms.
- Channel ends given to a child are closed when it ends, however it ends, so `iso.rx` finishes and `iso.tx.send` rejects `BrokenPipe` after a crash. Destroying a host terminates and joins every isolate it created.
- Messages: see [host.md](host.md#channels). `Date` objects are not part of the guest (use `Temporal`); `Date.now()` is.
