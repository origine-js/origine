// api.env, api.io, api.scope, quansync, errno, globals. Type-checked only, never run.
import type { Api, Main } from "@origine/types";
import { ERRNO } from "origine:@std/errno";
import { quansync, run } from "origine:@std/quansync";
import { ts } from "origine:@std/transformer/oxc";

export const main: Main = async (api: Api) => {
  print("args", api.env.args().length, api.env.get("HOME") ?? "unset");
  const narrowed = api.env.narrow({ allow: ["HOME"] });
  const names: readonly string[] = narrowed.list();
  void names;

  const io = api.io.create({ backend: "auto", entries: 256 });
  const narrowIo = api.io.narrow({ backends: ["threaded"], maxRuntimes: 2 });
  const timer = narrowIo.create().timer(10);
  const stopped: boolean = timer.cancel();
  await timer.promise.catch(() => {});
  await io.sleep(5);
  await io.sleepUntil(io.now() + 5);
  void stopped;

  await using child = {
    scope: await api.scope.create({
      main: "app:/main.js",
      loader: id => (id === "app:/main.js" ? "export function main() {}" : { source: "" }),
      transformers: { ".ts": ts({ jsx: "automatic" }), ".txt": (source, id) => `/* ${id} */ ${source}` },
      preload: [{ source: "(values) => {}", values: { n: 1 } }, { module: "export default () => {}" }],
      importMap: { imports: { a: "app:/a.js" } },
      origineNamespace: false,
    }),
    async [Symbol.asyncDispose]() {
      this.scope.close();
    },
  };
  await child.scope.run();

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

  // @ts-expect-error `transformers` need a `loader`
  await api.scope.create({ main: "a.js", transformers: { ".ts": ts() } });
  // @ts-expect-error `main` is required
  await api.scope.create({ loader: () => "" });
  // @ts-expect-error a preload is a script or a module, not both
  await api.scope.create({ main: "a.js", preload: [{ source: "", module: "" }] });
  // @ts-expect-error misspelled option
  await api.scope.create({ main: "a.js", origineNamespce: true });
  // @ts-expect-error `narrow` needs `allow`
  api.env.narrow({});
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
