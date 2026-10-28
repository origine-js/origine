# The module graph API (design)

How origine will load, link, cache and snapshot modules, replacing the `main`/`importMap`/`loader`/`transformers`/`origineNamespace` options of `api.scope.create`. This page is the design reference. Reference documentation for what exists is [src/js/docs/graph.md](../src/js/docs/graph.md); the rules every name here follows are in [api-guidelines.md](api-guidelines.md).

## Status

All of it is implemented except what the last row lists. Tests: `src/tests/managed/api.zig` (the `graph:` tests), `shared_link.zig`, `async_resolve.zig`; types: `types/std/graph.d.ts`, `types/graph.d.ts`, `types/context.d.ts`.

| Part | State |
|---|---|
| `origine:@std/graph/*`: sources, recipes, resolver layers, `ImportHandler` (hooks, maker, cache), `Import` verdicts, providers, caches; `origine:@std/transformer/oxc` descriptors | Pure JS, frozen data, snapshot-safe (`src/js/std/graph/`). |
| `api.graph` (`narrow`, `flush`), `recipe.create(graph)`, `ModuleReference` (`load`, `evaluate`, `requests`, `release`) | `src/api/graph.zig`, `src/api/context.zig`, `src/js/glue/graph.js`. |
| `api.context` (`create`, `import`, `references`, `close`, preload) | Replaces `api.scope`, which is gone. |
| Async or layered resolution in `ModuleMap` | `Resolver.resolve_async`, `Runtime.completeResolve` (`src/managed/module_map.zig`). |
| Native plans | A handler with no JS function runs entirely in Zig (`Handler.native`); see Native plans. |
| `Import.link` | `'hardened'` over `Content.exports`, `'shared'` over `Content.module`; the spike below showed V8 accepts the latter. |
| Refcounted module table | `retain: 'all' \| 'used'`, pins (`ModuleMap.pin`), `delete`, `clear`, `entries` cap, `ModuleMap.sweep`. |
| Code caches | `none`, `memory`, `dir` (the `__oricache__` format) and `custom` (stores only). |
| `Snapshot.prepare` and baked contexts | Deferred; coordinated with the `api.isolate` snapshot work. |
| Source and defer phases | Not implemented; `ModuleImportPhase` names them, only `Evaluation` works. |

## Deviations from the first design

What the implementation does differently from the proposal this page started as:

1. **One identity table per context, shared by all its handlers** (the scope's `ModuleMap`), not one per cache object. `ImportCache.native({ retain, entries })` of the context's `import` handler sets how the table keeps modules; the cache option of other handlers is not consulted.
2. **A handler that is not fully native runs its whole pipeline in the JS driver.** The driver calls the host for the native elements (`layer`, `hook`, `transform`, `readSource`), but the loop is JS. Only `handler.native === true` guarantees that no import enters JS (tests assert `host.driver_calls`).
3. **Reading files needs a sync fs grant.** `narrow({ fs })` takes `api.fs.requestSync(...)`; an async grant is `InvalidInput`. The host reads with its own blocking read inside the load stage (native handlers) or in the driver.
4. **`CodeCache.custom` is store-only.** `load` is not consulted; `store(key, bytes)` is called at `graph.flush()`.
5. **`meta` lives on the handler only.** The maker returns `{ import?, transformer? }`.
6. **`ModuleReference.status` has no separate `instantiated`**: a reference goes `declared`, `loaded`, `evaluating`, `evaluated` or `errored`. `requests[].reference` are one level deep: they are `declared` until `load()` is called on them.
7. **The origine ceiling** (what `origineProvider` may include) comes from the context's import handler only; the init scope is unrestricted. A hook that names more than that is `PermissionDenied` (`Unsupported` in a context whose handler serves nothing).
8. **A root module is addressed by its name.** `evaluate` and preloads register the source under the module's `name` and import that name, bypassing the resolver; the name must be unused in the context's table (`InvalidInput`).
9. **`'hardened'` freezes the exported graph in place** (the hardener's rule), so the source context's exported objects become frozen too.
10. **Errors from JS hooks**: an `ImportError` kind keeps its kind; anything else, `ImportError.other(message)` included, reaches the importing module as an `Error` with `name: message`.
11. **Oxc transformers are plain descriptors** (`ts()` returns `{ host: 'oxc', kind: 'transformer', transform, options }`), no longer callable functions.

## Facts that shape the design

1. A `v8::Module` is compiled per isolate but instantiated and evaluated in **one** context. A `ModuleReference` is therefore bound to the first context that evaluates it; the same code in a second context is a second reference made from the same recipe, cheap when sources and code-cache bytes are shared.
2. V8's resolve callback is synchronous, so the static closure is loaded before instantiate. Loading is async-capable (`Loader.load` returns `.pending`); **resolution is not**: `ModuleMap.compile` resolves and fetches each request synchronously, and `Scope.Options` allows one resolver. Layered or async resolution means parking the entry and resuming when the resolver settles.
3. Heap snapshots exist only at isolate boot, and `init_snapshot.Table` has one context today (baked contexts are deferred).
4. Values do not cross realms (`Scope.harden`). **Every user callback (resolver layer, hook, maker, transformer, meta, code-cache store) runs in the creating realm during the async load stage and returns data; natives never call JS during instantiate or evaluate.** `meta` therefore runs when a module is made and its plain-data result becomes `import.meta`.
5. `compile` rejects any phase but `Evaluation`, and `instantiateModule` takes no source callback yet.

## The pieces

| Noun | What it is |
|---|---|
| `ModuleSource` | `file(path)` or `text(str)`, an optional `SourceMap`, and a `withTransformer(t)` chain. Immutable data. |
| `ModuleRecipe` | `source`, `import` (an `ImportHandler`), `name`. Immutable; building it reads nothing. |
| `ImportHandler` | The pipeline for a module's imports: `resolver` -> `hooks` -> `maker`, plus `cache` and `meta`. |
| `ModuleGraph` (`api.graph`) | Shared artifacts (source text, transform output, code-cache bytes, resolve results) and the authority used to produce them (fs grant, `origine:` allowlist, code-cache store). `narrow({...})` only narrows. |
| `ModuleReference` | Handle to the V8 module, made by `recipe.create(graph)` or found in `ref.requests[].reference`. Status mirrors V8: `declared`, `loaded`, `instantiated`, `evaluating`, `evaluated`, `errored`. `evaluate(ctx)` binds it to one context. |
| `ImportCache` | Descriptor of the identity table (id, attributes) -> reference; each context gets its own native table. |
| `Context` (`api.context`) | A realm. Replaces `api.scope`. |

```js
const handler = ImportHandler.make({
  resolver: ImportResolver.layered().layer(relative()).layer(origine()).layer(nodeModules()),
  hooks: [
    async resolved => (resolved.id === 'secret' ? Import.reject(ImportError.PermissionDenied) : Import.next()),
    origineProvider({ std: { include: ['text'] } }),     // serves origine:@std/text and nothing else
    fsProvider({ read: 'copy' }),                        // native, no JS per import
  ],
  maker: MakeRecipe.inherit({ transformer: Transform.byExtension({ '.ts': ts() }) }),
  cache: ImportCache.native({ retain: 'used' }),
});
const mod = ModuleRecipe({ source: ModuleSource.file('./main.ts'), import: handler }).create(graph);
using ctx = await api.context.create({ import: handler, graph });
await mod.evaluate(ctx);
```

### Hooks and `maker` answer different questions

| | `hooks` | `maker` |
|---|---|---|
| Question | What does this resolved id map to, is it allowed, who supplies it? | Given supplied content, which recipe options apply, and which handler governs its own imports? |
| Shape | ordered; the first verdict that is not `next` wins | one function, runs once, for `provide(source)` and `accept()` |
| Output | `next`, `accept`, `provide`, `link`, `reject` | `{ import?, transformer? }` (options, never a recipe) |

Nearly every provider returns text, and the module it becomes must be made the same way for all providers; without `maker` each provider would rebuild a recipe. Its non-redundant power is choosing a different child handler per module (a no-fs handler for `node_modules/`). `Import.provide(recipe)` and `Import.link(...)` skip it.

### Transformers

A transformer is a property of a source (`ModuleSource.file(p).withTransformer(t)`) and an option of `maker`, with the same meaning. A hook cannot apply one because hooks stop at the first verdict. A function transformer `(source, id) => string | { source, map } | Promise` runs in the creating realm and may be async; the oxc transformers become host descriptors. V8 compiles the post-transform text, so code-cache keys stay correct. Source maps are carried, not applied (no stack remapping).

### `origine:` modules

There is no `origineNamespace` flag. `origine()` only canonicalises `origine:` ids; `origineProvider({ std: { include | exclude } })` serves them, bound to the importing context's natives, and can only narrow the creating context's own set. Entries made by the native provider carry a host-origin bit that no JS verdict can set; an `origine:` id without it is `PermissionDenied`, so working-directory files still cannot take the namespace.

### Native plans

`ImportHandler.make` classifies each element: a host descriptor (frozen `{ host, kind, ... }`) is validated against the graph's grants and compiled to a native step; a function is a JS barrier. Consecutive native steps are fused into one plan exposed through the existing managed `Resolver` and `Loader`; a barrier parks the entry, runs in the creating realm during the load stage, and resumes the native steps. A fully native handler never enters JS (`init_loader.zig` is that chain written by hand today). `ImportCache` and `ResolveCache` are native only: they sit behind V8's synchronous link. The cost is visible: `handler.plan` and `handler.native`. A recipe with `native === true` is plain data and can cross to another isolate.

### Cross-context imports

| Verb | The importer gets | Safety |
|---|---|---|
| `Import.provide(recipe)` | a fresh reference of the recipe in its own context | safe |
| `Import.link(ref, { mode: 'hardened' })` | a synthetic module of `ref`'s exports through the hardener (plain data and functions, a snapshot of the values) | safe |
| `Import.link(ref, { mode: 'shared' })` | the other context's module itself (live bindings, same objects) | leaks the realm boundary on purpose; V8 accepts it (spike below) |

`link` takes a reference bound and evaluated in another context; `mode` is required there.

**Spike result (`src/tests/managed/shared_link.zig`, also exercised end to end by the `graph: link` test).** Two scopes of one isolate: `Module::InstantiateModule` in the importer's context accepts a dependency that was already instantiated and evaluated in the other context. The importer reads live bindings (a counter bumped in A is seen by B's imported binding) and receives A's own objects (their creation context is A's, not B's). So `'shared'` ships; it is the documented realm leak, available only to code that holds both the reference and the importer's handler. Node's `vm.Module` refuses this combination by policy; V8 itself does not. Authority is the handle: only code holding both the reference and the importer's handler can write the verdict, and hooks run in the creating realm.

### Caches and lifetime

| | Key -> value | Notes |
|---|---|---|
| `ResolveCache` | (referrer, specifier, attributes, phase) -> id | native memo |
| `ImportCache` | (id, attributes) -> reference | one native table per context; `retain: 'all' \| 'used'` is required |
| `CodeCache` | (id, source hash) -> V8 code-cache bytes | `none`, `memory`, `dir` (the `__oricache__` format), `custom` |

Artifacts (source, transform output, code-cache bytes) are evictable and bounded. A reference is freed when its table entry, live JS handles and dependents' edges are gone; `delete(key)` is an identity reset (the next import makes a new reference and evaluates again). `'used'` frees unused entries automatically at the price of re-evaluation. A module a context already linked cannot be unloaded from it. Handles are explicit (`release()`, `using`); freeing on GC is a known gap shared with scopes.

### `api.context`

`api.scope.create` mixes the realm, what it loads and what it runs. The graph takes the second, `ref.evaluate(ctx)` the third; what is left is `api.context.create({ import, graph?, preload? })` with `import(specifier)` and `close()`. `api.scope` is replaced outright, no alias. The old call is `fromLoader(loader)` as a hook, `Transform.byExtension(transformers)` in the maker, and `ctx.import(main)`. A child never receives the graph.

## Snapshots

- **Code cache** (works today in the init scope): `CodeCache` over `src/api/init_cache.zig`; `graph.flush()` writes what compiled without a usable cache.
- **Baked contexts** (deferred): N contexts per boot blob, so a child context restores in about 0.2 ms with no parse or evaluation. Needs a multi-context `init_snapshot`; owned jointly with the `api.isolate` snapshot work, whose `Snapshot` class and `snapshot({ init })` would take a recipe and a handler instead of a specifier and an import map.

## Name decisions

- PascalCase for values and variants (`ImportError.NotFound`, `SourceMap.None`), camelCase for functions (`SourceMap.url`, `Import.next`), so a variant with a payload is a function (`ImportError.other(message)`).
- `hooks` for the chain and `Import.*` verdicts, flattened from `Bail.*`: `next`, `accept`, `provide`, `link`, `reject`.
- Dropped as second ways to one thing: `ImportResolver.custom(fn)` (a layered resolver with a function layer) and `ImportHandler.makeCustom(fn)` (a function layer plus a hook).
- `withTransformer` keeps the `with` prefix the guidelines discourage: it is an immutable builder on data, and the name was chosen by the maintainer. This is the one deliberate exception.
- `ImportCache` and `ResolveCache` capacity is `entries`, `CodeCache` is `bytes`: the unit is in the name.

## Checklist (api-guidelines.md), by name

Question 1: what the name promises. 2: hidden cost. 3: another way. 4: shed words. 5: errors. All builders throw a frozen `{ errno, name: 'InvalidInput', message }` for a malformed argument; nothing here touches I/O, so nothing blocks, allocates natively or retains a host resource.

| Name | Returns / does | Cost the call site hides | Survives because | Errors |
|---|---|---|---|---|
| `ModuleSource.file/text` | a frozen source; reads nothing | none (the path is read later by the graph's fs) | the only constructors | `InvalidInput` |
| `source.withTransformer(t)` | a new source; the receiver is unchanged | allocates one small frozen object | the only way to chain on a source | `InvalidInput` |
| `ModuleRecipe(options)` | a frozen recipe | none | the only recipe constructor | `InvalidInput` (missing `import`, text without `name`) |
| `ImportResolver.layered().layer(l)` | a new resolver | none | `custom` was dropped | `InvalidInput` |
| layers `relative`, `origine`, `importMap` | frozen descriptors | none; the map is copied once | descriptors, not functions, so they stay native | `InvalidInput` |
| `ImportHandler.make` | a frozen handler with `plan` and `native` | none; `plan` shows which elements enter JS | `makeCustom` was dropped | `InvalidInput` |
| `Import.next/accept/provide/link/reject` | frozen verdicts | none | flattened `Bail` | `InvalidInput` (`link` without `mode`, `reject` of a code outside `ImportError`) |
| `MakeRecipe.inherit/fn` | a maker | none | `fn` returns options so it cannot be a second provider | `InvalidInput` |
| `Transform.byExtension` | a frozen transformer descriptor | none | the one combinator | `InvalidInput` (extension syntax, more than 64) |
| `origineProvider`, `fsProvider`, `json`, `fromLoader` | providers/hooks | `fsProvider.read` and `origineProvider.std` are required because they choose a cost and an authority | `fromLoader` is a migration adapter for the old loader | `InvalidInput` |
| `ImportCache.native`, `ResolveCache.native`, `CodeCache.*` | frozen descriptors | `retain` is required (it decides whether a re-import evaluates again); `dir` touches the disk when the graph uses it | caches are not pluggable in JS except `CodeCache.custom` | `InvalidInput` |

| `api.graph.narrow(options)` | a graph with the fs grant or code cache replaced | none; holds no more than the realm already holds | the only way to give a graph authority; the root `api.graph` reads nothing | `InvalidInput` (not a sync grant, malformed cache), `PermissionDenied` (a grant without the needed access) |
| `graph.flush()` | resolves how many modules' code caches were stored | writes files for `dir`, calls `store` for `custom`; explicit because lazy functions are cached only after the code ran | the only persistence call | `Unsupported`-free; a failed write is a miss |
| `recipe.create(graph)` | a `declared` `ModuleReference`; reads nothing | none | the only way to make a reference | `InvalidInput` (not a graph) |
| `reference.load()` | resolves the reference once its source is read, transformed and compiled and its imports are loaded one level | reads files, runs transformers and hooks (JS ones in the creating realm) | `evaluate` does not need it; it exists for `requests` | `NotFound`, `PermissionDenied`, a `SyntaxError` for source a transformer rejects |
| `reference.evaluate(ctx)` | binds the reference to `ctx` and evaluates it; resolves when done | binds the reference to one context for good | the V8 shape (`Module::Evaluate(context)`); no `ctx.evaluate` | `InvalidInput` (bound elsewhere, name in use), `StaleHandle` (closed context), `ModuleError` (a failure in the module) |
| `reference.release()` / `[Symbol.dispose]` | unpins the module; with `retain: 'used'` it is freed once nothing holds it | later imports of it evaluate again | the lifetime control; no GC-driven release yet | none |
| `api.context.create(options)` | a `Context`; resolves after preloads | creates a V8 context; preloads run | replaces `api.scope.create` (decided) | `InvalidInput` (no `import`, malformed preload), `Unsupported` (from inside a driver call), `ModuleError` (a preload failed; the context is closed) |
| `ctx.import(specifier, options)` | a reference to the evaluated module | loads and evaluates | the `import()` of a script; `phase` other than `'evaluation'` is `Unsupported` | `ModuleError`, `StaleHandle` |
| `ctx.references`, `ctx.graph` | the references bound to it; its graph | a copy of the list | getters | none |
| `ctx.close()` | disposes the realm | rejects imports in flight; handles go stale | `Symbol.dispose` is the same call | `BadHandle`, `StaleHandle` |
| `ImportCache#in(ctx)` | the context's identity table: `size`, `delete(id)`, `clear()` | `delete` and `clear` forget modules, so the next import evaluates again | the only view of the table | `InvalidInput` (not a context) |

## Open

- How a declared dependency reference is adopted when the evaluating context's table already holds its key (today `evaluate` of the dependency's reference would fail `InvalidInput` for the taken name).
- Prefetching `CodeCache.custom` loads in the driver (would need a source hash in JS).
- Async fs grants for native reads (would complete on the io runtime).
- Who owns the multi-context `init_snapshot` change (shared with the isolate design).
