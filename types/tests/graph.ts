// origine:@std/graph/*: the data side of the module graph. Type-checked only, never run.
import { ModuleRecipe, ModuleSource, SourceMap, ModuleImportPhase } from "origine:@std/graph/module";
import type { ModuleRecipe as Recipe } from "origine:@std/graph/module";
import { ImportHandler, ImportHook, ImportError, MakeRecipe, Transform } from "origine:@std/graph/import";
import type { Verdict } from "origine:@std/graph/import";
import { ImportResolver } from "origine:@std/graph/resolve";
import { relative, origine, importMap } from "origine:@std/graph/resolve/layers";
import { origineProvider, fsProvider, json, fromLoader } from "origine:@std/graph/providers";
import { ImportCache, ResolveCache, CodeCache } from "origine:@std/graph/cache";
import { ts } from "origine:@std/transformer/oxc";
import { snapshot, deepFreeze } from "origine:@std/data";

declare const files: object;

const resolver = ImportResolver.layered()
  .layer(relative())
  .layer(origine())
  .layer(importMap({ imports: { a: "app:/a.js" }, scopes: { "app:/x/": { b: "app:/b.js" } } }))
  .layer(({ specifier, referrer, phase }) => (phase === ModuleImportPhase.Evaluation ? { id: `${referrer}/${specifier}` } : undefined));

const handler = ImportHandler.make({
  resolver,
  hooks: [
    async resolved => {
      if (resolved.id === "secret") return ImportHook.reject(ImportError.PermissionDenied);
      if (resolved.id.startsWith("node:")) return ImportHook.reject(ImportError.other("no node builtins"));
      return ImportHook.next();
    },
    origineProvider({ std: { include: ["text"] } }),
    json({ fs: files }),
    fsProvider({ fs: files, read: "copy" }),
  ],
  maker: MakeRecipe.inherit({ transformer: Transform.byExtension({ ".ts": ts(), ".txt": (source, id) => `/* ${id} */ ${source}` }) }),
  cache: ImportCache.native({ retain: "used" }),
  codeCache: CodeCache.memory({ limits: { size: 1 << 20 } }),
  meta: ({ id }) => ({ url: id }),
});
const planned: "native" | "js" = handler.plan[0]!.kind;
const allNative: boolean = handler.native;
void [planned, allNative, ResolveCache.native({ entries: 10 })];

const recipe: Recipe = ModuleRecipe({
  source: ModuleSource.file("./main.ts", { fs: files }, SourceMap.None).withTransformer(ts()).withTransformer((source) => source),
  import: handler,
  name: "main",
  codeCache: CodeCache.none,
});
const inline = ModuleRecipe({ source: ModuleSource.text("export {}", SourceMap.text("{}")), import: handler, name: "inline" });
const pure: boolean = recipe.native && inline.native;
export async function graphUse(api: import("@origine/types").Api): Promise<void> {
  const graph = api.graph.create();
  // An async grant is read on its io runtime, without blocking; the hook or source that names it says so.
  const io = api.io.create({});
  const remote = await api.fs.requestAsync({ handle: 'plain', io, access: "r" });
  void ModuleSource.file("./a.js", { fs: remote });
  // A created graph is the caller's: it can be closed (or disposed); `api.graph.root` cannot.
  api.graph.create().close();
  {
    using scoped = api.graph.create();
    void scoped;
  }
  // @ts-expect-error there is no derive: a graph holds no fs grant and no code cache
  api.graph.derive();
  // @ts-expect-error api.graph is a namespace, not a graph
  api.graph.declare(recipe);
  // @ts-expect-error the root graph lives as long as the realm
  api.graph.root.close();
  const reference = graph.declare(recipe);
  await graph.load(reference);
  const requests: number = graph.requests(reference)?.length ?? 0;
  await using ctx = { context: await api.context.create({ import: handler, graph }), async [Symbol.asyncDispose]() { this.context.close(); } };
  await graph.evaluate(reference, ctx.context);
  const exported: Readonly<Record<string, unknown>> = graph.exports(reference);
  void exported;
  // @ts-expect-error exports() takes the reference only
  graph.exports(reference, ctx.context);
  const stored: number = await CodeCache.memory().flush();
  const view = ImportCache.native({ retain: "used" });
  void [requests, stored, view.size, view.delete("a"), view.clear()];
  // @ts-expect-error a table is not looked up through a context
  view.in(ctx.context);
  graph.release(reference);
  // @ts-expect-error a reference is an inert handle: the graph loads, evaluates, reads and frees it
  reference.load();
  // @ts-expect-error
  reference.evaluate(ctx.context);
  // @ts-expect-error
  reference.exports();
  // @ts-expect-error
  reference.release();
  // @ts-expect-error
  reference.requests;
  // @ts-expect-error a recipe is declared in a graph; it has no `create`
  recipe.create(graph);
  // @ts-expect-error declare takes a recipe
  graph.declare({});
}
const provided: Verdict = ImportHook.recipe(recipe);
const sourced: Verdict = ImportHook.source(ModuleSource.text("export default 1"));
const linked: Verdict = ImportHook.link({});
const synthetic: Verdict = ImportHook.exports({ answer: 42, default: () => 1 });
void [pure, provided, sourced, linked, synthetic, ImportHook.accept({ fs: files }), CodeCache.none, CodeCache.custom({ load: () => undefined, store: () => {} })];
void ImportHandler.make({ resolver, hooks: fromLoader((id, attributes) => (attributes.type === "json" ? { source: "{}" } : id)) });
void ImportHandler.make({ resolver, hooks: [], maker: MakeRecipe.fn(async ({ id, source }) => (id.endsWith(".ts") ? { transformer: ts(), import: handler } : {})) });
const equal: boolean = ImportError.is({ errno: ImportError.NotFound }, ImportError.NotFound);
void equal;

// @ts-expect-error `hooks` is required (an empty array resolves nothing)
ImportHandler.make({ resolver });
// @ts-expect-error `resolver` is required
ImportHandler.make({ hooks: [] });
// @ts-expect-error `retain` has no default: it decides what re-importing does
ImportCache.native({});
// @ts-expect-error `retain` is 'all' or 'used'
ImportCache.native({ retain: "some" });
// @ts-expect-error `fs` and `read` are required (a grant is named where it is used; reading has a cost)
fsProvider({});
// With no options, or `std: true`, it serves everything the creating context may import.
origineProvider();
origineProvider({ std: true });
// @ts-expect-error `std: false` is not a spelling: leave the provider out
origineProvider({ std: false });
// @ts-expect-error exactly one of include and exclude
origineProvider({ std: { include: ["text"], exclude: ["fs"] } });
// @ts-expect-error values are an object of exports, not a function
ImportHook.exports(() => {});
// @ts-expect-error there is no mode: a link is the module itself, nothing is copied
ImportHook.link({}, { mode: "shared" });
// @ts-expect-error `import` is required: it decides what the module can load
ModuleRecipe({ source: ModuleSource.file("./a.js", { fs: files }) });
// @ts-expect-error a source is not a recipe
ImportHook.source({ kind: "file" });
// @ts-expect-error a source is not a recipe
ImportHook.recipe(ModuleSource.text(""));
// @ts-expect-error `maker` returns options (import, transformer), not a source or a recipe
MakeRecipe.fn(() => ({ source: ModuleSource.file("./a.js", { fs: files }) }));
// @ts-expect-error only the codes of ImportError can be rejected
ImportHook.reject(123);
// @ts-expect-error the receiver of withTransformer is immutable data without a `transformers` setter
ModuleSource.file("./a.js", { fs: files }).transformers = [];
// @ts-expect-error a layer is not a hook
ImportHandler.make({ resolver, hooks: [relative()] });

const copied: { a: number[] } = snapshot({ a: [1] }, { deepFreeze: true });
const frozenInPlace: { a: number } = deepFreeze({ a: 1 });
void [copied, frozenInPlace];
// @ts-expect-error `deepFreeze` is a boolean
snapshot({}, { deepFreeze: "yes" });
// @ts-expect-error the option is `deepFreeze`; there is no `seal` or `freeze`
snapshot({}, { seal: true });
