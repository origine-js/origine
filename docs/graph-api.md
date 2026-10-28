# The module graph API (design)

How origine will load, link, cache and snapshot modules, replacing the `main`/`importMap`/`loader`/`transformers`/`origineNamespace` options of `api.scope.create`. This page is the design reference. Reference documentation for what exists is [src/js/docs/graph.md](../src/js/docs/graph.md); the rules every name here follows are in [api-guidelines.md](api-guidelines.md).

## Status

| Part | State |
|---|---|
| `origine:@std/graph/*`: `ModuleSource`, `ModuleRecipe`, `ImportResolver`, resolver layers, `ImportHandler`, `Import`, `ImportError`, `MakeRecipe`, `Transform`, providers, `ImportCache`/`ResolveCache`/`CodeCache` descriptors | **Implemented** as pure JS: frozen data, no natives, snapshot-safe (`src/js/std/graph/`, tests in `src/tests/managed/api.zig`, types in `types/std/graph.d.ts`). Nothing consumes them yet. |
| `api.graph`, `recipe.create(graph)`, `ModuleReference` (`load`, `evaluate`), `api.context` replacing `api.scope`, native plans, `Import.link` | Designed here, not implemented. |
| Async or layered resolution inside `ModuleMap` | Not implemented; the largest native change (see Facts). |
| `Snapshot.prepare` and baked contexts | Deferred; coordinated with the `api.isolate` snapshot work. |
| Source and defer phases | Not implemented; `ModuleImportPhase` names them, only `Evaluation` works. |

## Facts that shape the design

1. A `v8::Module` is compiled per isolate but instantiated and evaluated in **one** context. A `ModuleReference` is therefore bound to the first context that evaluates it; the same code in a second context is a second reference made from the same recipe, cheap when sources and code-cache bytes are shared.
2. V8's resolve callback is synchronous, so the static closure is loaded before instantiate. Loading is async-capable (`Loader.load` returns `.pending`); **resolution is not**: `ModuleMap.compile` resolves and fetches each request synchronously, and `Scope.Options` allows one resolver. Layered or async resolution means parking the entry and resuming when the resolver settles.
3. Heap snapshots exist only at isolate boot, and `init_snapshot.Table` has one context today.
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

**Spike result (`src/tests/managed/shared_link.zig`).** Two scopes of one isolate: `Module::InstantiateModule` in the importer's context accepts a dependency that was already instantiated and evaluated in the other context. The importer reads live bindings (a counter bumped in A is seen by B's imported binding) and receives A's own objects (their creation context is A's, not B's). So `'shared'` ships; it is the documented realm leak, available only to code that holds both the reference and the importer's handler. Node's `vm.Module` refuses this combination by policy; V8 itself does not. Authority is the handle: only code holding both the reference and the importer's handler can write the verdict, and hooks run in the creating realm.

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

The checklist for the unimplemented names (`api.graph`, `ModuleReference`, `api.context`) is answered when they land, in the same change.

## Open

- How a declared dependency reference is adopted when the evaluating context's table already holds its key (alias or error).
- Whether `ref.requests` is `undefined` before `load()` or throws.
- `CodeCache.dir` key and location for virtual ids like `app:/x.js` (today's `cachePath` is next to the importing file).
- Who owns the multi-context `init_snapshot` change (shared with the isolate design).
