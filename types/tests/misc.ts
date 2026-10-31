// api.host.env, api.io, api.context, quansync, errno, globals. Type-checked only, never run.
import type { Api, Main } from "@origine/types";
import { ERRNO } from "origine:@std/errno";
import { quansync, run } from "origine:@std/quansync";
import { ts } from "origine:@std/transformer/oxc";
import { ImportHandler, MakeRecipe, Transform } from "origine:@std/graph/import";
import { ImportResolver } from "origine:@std/graph/resolve";
import { importMap } from "origine:@std/graph/resolve/layers";
import { fromLoader } from "origine:@std/graph/providers";
import { eprintln } from "origine:@std/debug";

export const main: Main = async (api: Api) => {
  eprintln("args", api.host.env.args().length, api.host.env.get("HOME") ?? "unset");
  const cpus: number = api.host.threading.parallelism;
  // @ts-expect-error parallelism is read-only
  api.host.threading.parallelism = 2;
  eprintln("cpus", cpus);
  const [port, remote] = new api.host.threading.Channel({ mode: "pull" });
  await port.send({ a: 1 }, { transfer: [new ArrayBuffer(1)] });
  const event = await remote.recv();
  eprintln("message", event.identity, String(event.data), event.transfer.length);
  for await (const each of remote) eprintln("message", String(each.data));
  const [pushed, remotePushed] = new api.host.threading.Channel({ mode: "event", capacity: 4 });
  const registration = remotePushed.register("message", (each) => eprintln("event", each.identity));
  remotePushed.register("close", () => registration.unregister());
  pushed.close();
  const worker = api.isolate.create({ init: "child.js", args: ["a"], env: { A: "b" }, data: { remote }, transfer: [remote] });
  const exit = await worker.join();
  eprintln(exit.status, exit.error ?? "ok", worker.id);
  // @ts-expect-error the mode is required
  new api.host.threading.Channel({});
  // @ts-expect-error a pull port has no register
  port.register("message", () => {});
  const snapshot = api.host.Snapshot.create({ init: "child.js" });
  const file: Uint8Array = snapshot.origineDataBlob({ compress: false });
  const loaded = api.host.Snapshot.fromOrigineDataBlob(file, { init: "child.js" });
  api.host.Snapshot.fromRaw(loaded.blob()).close();
  api.isolate.create({ init: "child.js", snapshot });
  // @ts-expect-error a snapshot is made by Snapshot's static methods
  new api.host.Snapshot();
  // @ts-expect-error init is required
  api.isolate.create({});
  const names: readonly string[] = api.host.env.list();
  void names;

  const io = api.io.create({ backend: "auto", entries: 256 });
  const narrowIo = api.io.narrow({ backends: ["threaded"], maxRuntimes: 2 });
  const timer = narrowIo.create().timer(10);
  const stopped: boolean = timer.cancel();
  await timer.promise.catch(() => {});
  await io.sleep(5);
  await io.sleepUntil(io.now() + 5);
  void stopped;

  const handler = ImportHandler.make({
    resolver: ImportResolver.layered().layer(importMap({ imports: { a: "app:/a.js" } })),
    hooks: [fromLoader(id => (id === "app:/a.js" ? "export function main() {}" : { source: "" }))],
    maker: MakeRecipe.inherit({ transformer: Transform.byExtension({ ".ts": ts({ jsx: "automatic" }), ".txt": (source, id) => `/* ${id} */ ${source}` }) }),
  });
  using child = await api.context.create({
    import: handler,
    graph: api.graph.derive({ fs: api.fs.requestSync({ access: "r" }) }),
    preload: [{ source: "(values) => {}", values: { n: 1 } }, { module: "export default () => {}" }],
  });
  const imported = await child.import("a");
  const status: string = imported.status;
  void status;

  // The types of ERRNO come from errno_codes.zig: two domains, each with its own names.
  const notFound: 10 = ERRNO.io.NotFound;
  const badHandle: 2 = ERRNO.host.BadHandle;
  void [notFound, badHandle];
  // @ts-expect-error a host name is not in the io table
  ERRNO.io.BadHandle;
  // @ts-expect-error an io name is not in the host table
  ERRNO.host.NotFound;

  // quansync
  const double = quansync({ sync: (n: number) => n * 2, async: async (n: number) => n * 2 });
  const total = quansync(function* (a: number) {
    const x: number = yield* double(a);
    return x + 1;
  });
  const s: number = total.sync(1);
  const p: Promise<number> = total.async(1);
  const viaRun: number = run("sync", total(2));
  void [s, p, viaRun];

  // @ts-expect-error `import` is required: it decides what the realm can load
  await api.context.create({});
  // @ts-expect-error a preload is a script or a module, not both
  await api.context.create({ graph: api.graph, import: handler, preload: [{ source: "", module: "" }] });
  // @ts-expect-error misspelled option
  await api.context.create({ import: handler, grph: api.graph });
  // @ts-expect-error `graph` is required: there is no default
  await api.context.create({ import: handler });
  // @ts-expect-error `context` has no `narrow`
  api.context.narrow({});
  // @ts-expect-error environment views have no narrowing API
  api.host.env.narrow({});
  // @ts-expect-error `narrow` takes the same `backends`, no `max`
  api.io.narrow({ max: 1 });
  // @ts-expect-error not a backend
  api.io.create({ backend: "epoll" });
  // @ts-expect-error `fs` has no `narrow`
  api.fs.narrow({});
  // @ts-expect-error `main` returns nothing (or a promise of nothing)
  const bad: Main = () => 42;
  // @ts-expect-error there is no `setTimeout`: the context has no DOM and no timers global
  setTimeout(() => {}, 1);
  // @ts-expect-error there is no `TextEncoder`: use origine:@std/text
  new TextEncoder();
  // @ts-expect-error there is no `fetch`
  fetch("http://127.0.0.1");
  void bad;
};
