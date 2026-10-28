// origine:@std/graph/*: the data side of the module graph. Type-checked only, never run.
import { ModuleRecipe, ModuleSource, SourceMap, ModuleImportPhase } from "origine:@std/graph/module";
import type { ModuleRecipe as Recipe } from "origine:@std/graph/module";
import { ImportHandler, Import, ImportError, MakeRecipe, Transform } from "origine:@std/graph/import";
import type { Verdict } from "origine:@std/graph/import";
import { ImportResolver } from "origine:@std/graph/resolve";
import { relative, origine, importMap } from "origine:@std/graph/resolve/layers";
import { origineProvider, fsProvider, json, fromLoader } from "origine:@std/graph/providers";
import { ImportCache, ResolveCache, CodeCache } from "origine:@std/graph/cache";
import { ts } from "origine:@std/transformer/oxc";

const resolver = ImportResolver.layered()
  .layer(relative())
  .layer(origine())
  .layer(importMap({ imports: { a: "app:/a.js" }, scopes: { "app:/x/": { b: "app:/b.js" } } }))
  .layer(({ specifier, referrer, phase }) => (phase === ModuleImportPhase.Evaluation ? { id: `${referrer}/${specifier}` } : undefined));

const handler = ImportHandler.make({
  resolver,
  hooks: [
    async resolved => {
      if (resolved.id === "secret") return Import.reject(ImportError.PermissionDenied);
      if (resolved.id.startsWith("node:")) return Import.reject(ImportError.other("no node builtins"));
      return Import.next();
    },
    origineProvider({ std: { include: ["text"] } }),
    json(),
    fsProvider({ read: "copy" }),
  ],
  maker: MakeRecipe.inherit({ transformer: Transform.byExtension({ ".ts": ts(), ".txt": (source, id) => `/* ${id} */ ${source}` }) }),
  cache: ImportCache.native({ retain: "used", entries: 1000 }),
  meta: ({ id }) => ({ url: id }),
});
const planned: "native" | "js" = handler.plan[0]!.kind;
const allNative: boolean = handler.native;
void [planned, allNative, ResolveCache.native({ entries: 10 })];

const recipe: Recipe = ModuleRecipe({
  source: ModuleSource.file("./main.ts", SourceMap.None).withTransformer(ts()).withTransformer((source) => source),
  import: handler,
  name: "main",
  codeCache: CodeCache.memory({ bytes: 1 << 20 }),
});
const inline = ModuleRecipe({ source: ModuleSource.text("export {}", SourceMap.text("{}")), import: handler, name: "inline" });
const pure: boolean = recipe.native && inline.native;
export async function graphUse(api: import("@origine/types").Api): Promise<void> {
  const graph = api.graph.narrow({ fs: api.fs.requestSync({ access: "r" }), codeCache: CodeCache.memory() });
  const reference = recipe.create(graph);
  await reference.load();
  const requests: number = reference.requests?.length ?? 0;
  await using ctx = { context: await api.context.create({ import: handler, graph }), async [Symbol.asyncDispose]() { this.context.close(); } };
  await reference.evaluate(ctx.context);
  const stored: number = await graph.flush();
  const view = ImportCache.native({ retain: "used" }).in(ctx.context);
  void [requests, stored, view.size, view.delete("a"), view.clear()];
  reference.release();
}
const provided: Verdict = Import.provide(recipe);
const sourced: Verdict = Import.provide(ModuleSource.text("export default 1"));
const linked: Verdict = Import.link({}, { mode: "hardened" });
void [pure, provided, sourced, linked, Import.accept(), CodeCache.none, CodeCache.custom({ load: () => undefined, store: () => {} })];
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
// @ts-expect-error a graph is not a recipe
recipe.create({});
// @ts-expect-error `read` is required (it has a cost)
fsProvider({});
// @ts-expect-error `std` is required, there is no "everything" default
origineProvider({});
// @ts-expect-error exactly one of include and exclude
origineProvider({ std: { include: ["text"], exclude: ["fs"] } });
// @ts-expect-error `mode` is required
Import.link({});
// @ts-expect-error mode is 'hardened' or 'shared'
Import.link({}, { mode: "live" });
// @ts-expect-error `import` is required: it decides what the module can load
ModuleRecipe({ source: ModuleSource.file("./a.js") });
// @ts-expect-error a source is not a recipe
Import.provide({ kind: "file" });
// @ts-expect-error `maker` returns options (import, transformer), not a source or a recipe
MakeRecipe.fn(() => ({ source: ModuleSource.file("./a.js") }));
// @ts-expect-error only the codes of ImportError can be rejected
Import.reject(123);
// @ts-expect-error the receiver of withTransformer is immutable data without a `transformers` setter
ModuleSource.file("./a.js").transformers = [];
// @ts-expect-error a layer is not a hook
ImportHandler.make({ resolver, hooks: [relative()] });
