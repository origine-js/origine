# `api.isolate`

Isolates (V8 isolates, each with its own heap, `Host` and I/O runtimes) on other threads. Types: `types/isolate.d.ts`. Only where the embedder passes `Config.isolates` (the `origine` shell does); otherwise accessing `api.isolate` fails `PermissionDenied`. It is not part of the basic api.

```js
// parent
const [port, remote] = new api.host.threading.Channel({ mode: 'pull' });
const iso = api.isolate.create({ init: './worker.js', args: ['x'], env: { MODE: 'fast' }, data: { port: remote, sab }, transfer: [remote] });
await port.send({ n: 21 });
const reply = await port.recv();       // reply.identity === iso.id
port.close();                          // ends the worker's `for await`
const { status, error } = await iso.join();
```

```js
// worker.js: `main(api, data)`, the second argument is what the parent passed as `data`
export async function main(api, { port, sab }) {
  for await (const event of port) await port.send(event.data.n * 2);
}
```

- `create(options)` takes an options object or a `CreateConfig` (`CreateConfig(options)` validates once and freezes; passing a config to it returns it). Only `init` is required. `args` default `[]` (the child sees `[init, ...args]`), `env` defaults to `{}`: nothing is inherited. There is no automatic channel: `data` is structured-cloned (`SharedArrayBuffer`s are shared), and ports and `ArrayBuffer`s in it must be listed in `transfer`, which moves them (see [host.md](host.md#channels-and-ports)).
- `snapshot` (a `api.host.Snapshot`, optional): start the isolate from it. The snapshot must have been made for the same `init` (`InvalidInput` otherwise); the isolate imports `init` and finds the graph already evaluated, without reading its sources again. The isolate keeps its own hold on the snapshot.
- `main(api, data)`: `data` is `undefined` in the first isolate.
- The new isolate is not narrowed by its creator. Its init module decides what it does, within the embedder's ceiling (the same fs root and runtime limits as the creator's host, and `max` isolates per host).
- `join()` resolves once the thread has ended, with `{ status: 'completed' | 'failed' | 'terminated', error? }` (`error` is the error name of a failed isolate, such as `MainFailed`). Always the same object. `terminate()` interrupts running JavaScript; a child blocked on I/O notices within about 100 ms.
- The ports the child was given are closed when it ends, however it ends, including when its init module fails to load, so the parent's port ends instead of waiting forever. Destroying a host terminates and joins every isolate it created.
