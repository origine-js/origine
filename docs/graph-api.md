# The module graph API (design)

How origine will load, link, cache and snapshot modules, replacing the `main`/`importMap`/`loader`/`transformers`/`origineNamespace` options of `api.scope.create`. This page is the design reference. Reference documentation for what exists is [src/js/docs/graph.md](../src/js/docs/graph.md); the rules every name here follows are in [api-guidelines.md](api-guidelines.md).

## Status

All of it is implemented except what the last row lists. Tests: `src/tests/managed/api.zig` (the `graph:` tests), `shared_link.zig`, `async_resolve.zig`; types: `types/std/graph.d.ts`, `types/graph.d.ts`, `types/context.d.ts`.

| Part | State |
|---|---|
| `origine:@std/graph/*`: sources, recipes, resolver layers, `ImportHandler` (hooks, maker, cache), `Import` verdicts, providers, caches; `origine:@std/transformer/oxc` descriptors | JS validation and JS class instances, snapshot-safe (`src/js/std/graph/`). |
| `api.graph` (`derive`, `flush`), `recipe.create(graph)`, `ModuleReference` (`load`, `evaluate`, `requests`, `release`) | `src/api/graph.zig`, `src/api/context.zig`, `src/js/glue/graph.js`. |
| `api.context` (`create`, `import`, `references`, `close`, preload) | Replaces `api.scope`, which is gone. |
| Async or layered resolution in `ModuleMap` | `Resolver.resolve_async`, `Runtime.completeResolve` (`src/managed/module_map.zig`). |
| Native plans | A handler with no JS function runs entirely in Zig (`Handler.native`); see Native plans. |
| `Import.link` | `'hardened'` over `Content.exports` (data copied in the creating realm), `'shared'` over `Content.module`; the spike below showed V8 accepts the latter. |
| Refcounted module table | `retain: 'all' \| 'used'`, pins (`ModuleMap.pin`), `delete`, `clear`, `entries` cap, `ModuleMap.sweep`. |
| Code caches | `none`, `memory`, `dir` (one file per distinct source text under `__codecache__` of the cache grant, named from a hash of the runtime, the module kind and the source) and `custom` (`load` before a module compiles, `store` at `graph.flush()`). |
| `Snapshot.prepare` and baked contexts (multi-context `init_snapshot`) | Later, and the module graph's: the `api.isolate` snapshot step stays single-context. |
| Source and defer phases | Not implemented; `ModuleImportPhase` names them, only `Evaluation` works. |

## Deviations from the first design

What the implementation does differently from the proposal this page started as:

1. **An `ImportCache` object names a table of modules.** Each context keeps the tables of the cache objects its handlers use in its `ModuleMap` (the module's table number is part of its key), so one id imported through two cache objects is two modules, also inside one context; handlers made with the same object share one table. **Contexts that use the same `ImportCache` object share its modules**, with no option: the first context to import an id is its home (it compiles, instantiates and evaluates the module), and every other context gets that module through the `'shared'` link machinery (live bindings, the same objects, the module runs once). A context that asks while the home is still loading or evaluating waits for it (`Loader.poll`); a module that failed in its home is not shared, so the asking context loads one of its own. Separate caches are separate `ImportCache` objects. `retain` and `entries` are per table, and `size`, `delete(id)` and `clear()` are on the object (no `cache.in(ctx)`): `size` counts the modules the table holds (a shared one once, in its home), `delete(id)` and `clear()` forget them in every context of this realm that holds them. `retain: 'used'` counts users across contexts: a context that links a module pins it in its home, and releases the pin when its own entry is released. When the home context closes, the contexts that used its modules drop them (and what imported them), and their next import evaluates a new module there (the first one to ask becomes the new home); a reference they already held stops resolving (`exports()` is `NotFound`). Not done: `entries` still caps the modules each context is the home of, not the cache as a whole.
2. **A graph reads with one fs grant, sync or async, and only one `api.fs` made.** `derive({ fs })` takes `api.fs.requestSync(...)` or `await api.fs.requestAsync(...)`; a grant is the object `api.fs` returned: the host built it with a V8 private symbol that no script can read, copy, clone, spread, proxy or inherit (the glue only adds the operations and freezes it), and `derive` and `CodeCache.dir` ask the host (natively) whether the object carries it for this realm and is still open. A lookalike with every property of a real grant is `InvalidInput`, so a realm that was handed `api.graph` cannot reach the grants of the realm that gave it. A sync grant is read by the host with its own blocking read inside the load stage. An async grant is read on its io runtime: the context's chain calls the grant's Rust natives (open, read all, close) itself and parks on their promises, so the read completes through `completeLoad` and no JS function runs A source file is read whole up to the graph's `sourceBytes` (default 64 MiB, set by `derive({ sourceBytes })`, readable as `graph.sourceBytes`); a larger file fails the import with `FileTooLarge` and is never cut short. `CodeCache.dir` stays on a sync grant on purpose: V8 asks for a module's cached bytes while it compiles, and a compile cannot wait, so an async-grant `dir` would need a chain step of its own that reads the file before compiling. `CodeCache.custom({ load, store })` is that step today and may use any async io.
3. **`meta` lives on the handler only.** The maker returns `{ import?, transformer? }`.
4. **`ModuleReference.status` has no separate `instantiated`**: a reference goes `declared`, `loaded`, `evaluating`, `evaluated` or `errored`. `requests[].reference` are one level deep: they are `declared` until `load()` is called on them, and `load()` works the same on such a dependency (its source was read when it was made), so a program that wants a whole tree calls it level by level. Overlapping `load()` calls on one reference share one load.
5. **The origine ceiling** (what `origineProvider` may include) comes from the context's import handler only; the init scope is unrestricted. A hook that names more than that is `PermissionDenied` (`Unsupported` in a context whose handler serves nothing). `origineProvider()` and `origineProvider({ std: true })` mean "whatever that context may import": the host copies the creating context's own set, so the default can never widen it.
6. **A root module is addressed by its name.** `evaluate` and preloads register the source under the module's `name` and import that name, bypassing the resolver; the name must be unused in the context's table (`InvalidInput`).
7. **Errors from JS hooks**: an `ImportError` kind keeps its kind; anything else, `ImportError.other(message)` included, reaches the importing module as an `Error` with `name: message`.
8. **Oxc transformers are JS descriptor instances** (`ts()` returns a `Transformer` with read-only host, kind, transform, and options fields), no longer callable functions.

## Facts that shape the design

1. A `v8::Module` is compiled per isolate but instantiated and evaluated in **one** context. A `ModuleReference` is therefore bound to the first context that evaluates it; the same code in a second context is a second reference made from the same recipe, cheap when sources and code-cache bytes are shared.
2. V8's resolve callback is synchronous, so the static closure is loaded before instantiate. Loading is async-capable (`Loader.load` returns `.pending`); **resolution is not**: `ModuleMap.compile` resolves and fetches each request synchronously, and `Scope.Options` allows one resolver. Layered or async resolution means parking the entry and resuming when the resolver settles.
3. Heap snapshots exist only at isolate boot, and `init_snapshot.Table` has one context today (baked contexts are deferred).
4. Values do not cross realms (`Scope.harden`). **Every user callback (resolver layer, hook, maker, transformer, meta, code-cache store) runs in the creating realm during the async load stage and returns data; natives never call JS during instantiate or evaluate.** `meta` therefore runs when a module is made and its plain-data result becomes `import.meta`. The JS driver waits one microtask before it runs any of them, so none runs on the stack of a child's own `import()` (that call reaches the host synchronously); a hook may create contexts, since it runs from the microtask checkpoint, outside the runtime's scope iteration.
5. `compile` rejects any phase but `Evaluation`, and `instantiateModule` takes no source callback yet.

## The pieces

| Noun | What it is |
|---|---|
| `ModuleSource` | `file(path)` or `text(str)`, an optional `SourceMap`, and a `withTransformer(t)` chain. Immutable data. |
| `ModuleRecipe` | `source`, `import` (an `ImportHandler`), `name`. Immutable; building it reads nothing. |
| `ImportHandler` | The pipeline for a module's imports: `resolver` -> `hooks` -> `maker`, plus `cache` and `meta`. |
| `ModuleGraph` (`api.graph`) | Shared artifacts (source text, transform output, code-cache bytes, resolve results) and the authority used to produce them (fs grant, `origine:` allowlist, code-cache store). `derive({...})` makes a new graph from it; the invariant is that it can replace the fs grant, code cache or source limit but never hold more authority than the realm already does, so the name says what it does. |
| `ModuleReference` | Handle to the V8 module, made by `recipe.create(graph)` or found in `ref.requests[].reference`. Status mirrors V8: `declared`, `loaded`, `instantiated`, `evaluating`, `evaluated`, `errored`. `evaluate(ctx)` binds it to one context. |
| `ImportCache` | The name of a table of modules (id, attributes) -> reference, shared by the contexts that use the object, with `retain`/`entries`, and the handle to inspect it (`size`, `delete`, `clear`). |
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

There is no `origineNamespace` flag. `origine()` only canonicalises `origine:` ids; `origineProvider()`, `origineProvider({ std: true })`, `origineProvider({ std: { include | exclude } })` serve them (the first two: every one the creating context itself may import), bound to the importing context's natives, and can only narrow the creating context's own set. Entries made by the native provider carry a host-origin bit that no JS verdict can set; an `origine:` id without it is `PermissionDenied`, so working-directory files still cannot take the namespace.

### Native plans

`ImportHandler.make` classifies each element: a JS descriptor instance is validated against the graph's grants and compiled to a native step; a function is a JS barrier. Consecutive native steps are fused into one plan exposed through the existing managed `Resolver` and `Loader`; a barrier parks the entry, runs in the creating realm during the load stage, and resumes the native steps. A fully native handler never enters JS (`init_loader.zig` is that chain written by hand today), and in a handler that also has functions the host elements still run in Zig: the context's chain (`context.zig`: `advanceResolve`, `advanceHooks`, the maker, `made`) runs them itself and calls the driver once per function it reaches, with the same token until the request completes (`host.driver_calls` counts those calls; tests assert them). `reference.load()` has no request to park, so it runs a handler with functions through a small loop in JS (`resolveInJs`, `loadInJs`) that calls the same steps. `ImportCache` and `ResolveCache` are native only: they sit behind V8's synchronous link. The cost is visible: `handler.plan` and `handler.native`. A handler with `native === true` needs no JS pipeline callbacks; its private JS identity does not grant graph authority.

### Cross-context imports

| Verb | The importer gets | Safety |
|---|---|---|
| `Import.provide(recipe)` | a fresh reference of the recipe in its own context | safe |
| `Import.link(ref, { mode: 'hardened' })` | a synthetic module of `ref`'s exports as a snapshot: plain data is copied (and the copies frozen), functions, classes and other objects are shared and frozen in place in their own realm (they cannot be copied); accessors are `Unsupported` | safe for the exporter's data; its code objects are frozen |
| `Import.link(ref, { mode: 'shared' })` | the other context's module itself (live bindings, same objects) | leaks the realm boundary on purpose; V8 accepts it (spike below) |

`link` takes a reference bound and evaluated in another context; `mode` is required there.

**Hardened links.** The exporter's data and code are treated differently because only data can be copied. `Scope.harden` freezes a graph in place, which is right for values the creator hands over (preload `values`) but would break an exporting module that mutates its own exports after it was linked, so a hardened link copies plain data in the creating realm (the glue's `copyData`) and lets the importer's hardener freeze the copies. Functions and classes cannot be copied: they are shared and frozen in place, with their statics and prototype chain, and a class static the exporter keeps mutating will throw there. `Import.link` of a function-heavy module is therefore best done with `'shared'` when the exporter must keep working.

**Spike result (`src/tests/managed/shared_link.zig`, also exercised end to end by the `graph: link` test).** Two scopes of one isolate: `Module::InstantiateModule` in the importer's context accepts a dependency that was already instantiated and evaluated in the other context. The importer reads live bindings (a counter bumped in A is seen by B's imported binding) and receives A's own objects (their creation context is A's, not B's). So `'shared'` ships; it is the documented realm leak, available only to code that holds both the reference and the importer's handler. Node's `vm.Module` refuses this combination by policy; V8 itself does not. Authority is the handle: only code holding both the reference and the importer's handler can write the verdict, and hooks run in the creating realm.

### Caches and lifetime

| | Key -> value | Notes |
|---|---|---|
| `ResolveCache` | (referrer, specifier, attributes, phase) -> id | native memo |
| `ImportCache` | (id, attributes) -> reference | one table per cache object, shared by every context of the realm that uses it (home context + users); `retain: 'all' \| 'used'` is required |
| `CodeCache` | (id, source hash) -> V8 code-cache bytes | `none`, `memory`, `dir` (`__codecache__/<32 hex digits of BLAKE3(runtime, module kind, source text)>.v8-code-cache` of the cache grant: the id is not in the name, so virtual ids and ids with `..` stay inside it; each file holds its source's hash), `custom` (`key` is `{ id, hash }`, the hash being the lowercase hex BLAKE3 digest of the exact text V8 compiles; `load(key, source)` runs once a module's source is final and before it compiles, `store(key, blob)` at `graph.flush()`; the blob is opaque and carries the hash of its source, so one made for another text, a throwing `load` or a non-blob answer is a miss, never an error) |

Artifacts (source, transform output, code-cache bytes) are evictable and bounded. A reference is freed when its table entry, live JS handles and dependents' edges are gone; `delete(key)` is an identity reset (the next import makes a new reference and evaluates again). `'used'` frees unused entries automatically at the price of re-evaluation. A module a context already linked cannot be unloaded from it. Handles are explicit (`release()`, `using`); freeing on GC is a known gap shared with scopes (`WeakRef` and `FinalizationRegistry` exist in a realm, but their instances are not exportable values, and nothing here relies on them).

What the host keeps is bounded by what is live. A context is freed with its scope once it is closed (its record, resolution cache, `import.meta` data, import and preload records). An import handler is freed when a context is freed and no live context, call in flight or `reference.load()` reaches it, and the JS side then drops its record and the closures in it; the same handler object registers again if it is used later. A graph made by `narrow` is freed after `close()` once the contexts that use it are gone (the root `api.graph` lives as long as the realm). Ids are never reused, so a handle to a freed record is `StaleHandle`. A call into a JS element whose promise never settles keeps a small record until the host is destroyed.

### `api.context`

`api.scope.create` mixes the realm, what it loads and what it runs. The graph takes the second, `ref.evaluate(ctx)` the third; what is left is `api.context.create({ import, graph?, preload? })` with `import(specifier)` and `close()`. `api.scope` is replaced outright, no alias. The old call is `fromLoader(loader)` as a hook, `Transform.byExtension(transformers)` in the maker, and `ctx.import(main)`. A child never receives the graph.

## Snapshots

- **Code cache** (works today in the init scope): `CodeCache` over `src/api/init_cache.zig`; `graph.flush()` writes what compiled without a usable cache.
- **Baked contexts** (later): N contexts per boot blob, so a child context restores in about 0.2 ms with no parse or evaluation. Needs a multi-context `init_snapshot`; that change belongs to this design, not to `api.isolate`, whose snapshot step stays single-context.
- **Child isolates** (the `api.isolate` design): `api.isolate.Snapshot.create(options)` (with `Snapshot.fromRaw`, `Snapshot.fromOrigineDataBlob`, `.blob()`, `.origineDataBlob(options)`) takes `init: string | ModuleRecipe`, `import: ImportHandler` and `graph?` instead of a specifier and an import map (`importMap` and `meta` are dropped). No graph or grant crosses to a child isolate: its init script decides everything, and the parent controls that by choosing the init script. Only a handler with `handler.native === true` (plain data) is cloneable, as part of the child's `import` option; one with JS hooks, layers or makers is `Unsupported`, and `handler.plan` names the element.

## Name decisions

- PascalCase for values and variants (`ImportError.NotFound`, `SourceMap.None`), camelCase for functions (`SourceMap.url`, `Import.next`), so a variant with a payload is a function (`ImportError.other(message)`).
- `hooks` for the chain and `Import.*` verdicts, flattened from `Bail.*`: `next`, `accept`, `provide`, `link`, `reject`.
- Dropped as second ways to one thing: `ImportResolver.custom(fn)` (a layered resolver with a function layer) and `ImportHandler.makeCustom(fn)` (a function layer plus a hook).
- `withTransformer` keeps the `with` prefix the guidelines discourage: it is an immutable builder on data, and the name was chosen by the maintainer. This is the one deliberate exception.
- `ImportCache` and `ResolveCache` capacity is `entries`, `CodeCache` is `bytes`: the unit is in the name.

## Checklist (api-guidelines.md), by name

Question 1: what the name promises. 2: hidden cost. 3: another way. 4: shed words. 5: errors. All builders throw an `IoError` instance with errno `InvalidInput` and a message for a malformed argument; nothing here touches I/O, so nothing blocks or retains a host resource; factories allocate JS class instances and JS copies input data.

| Name | Returns / does | Cost the call site hides | Survives because | Errors |
|---|---|---|---|---|
| `ModuleSource.file/text` | a frozen source; reads nothing | none (the path is read later by the graph's fs) | the only constructors | `InvalidInput` |
| `source.withTransformer(t)` | a new source; the receiver is unchanged | allocates one immutable JS class instance | the only way to chain on a source | `InvalidInput` |
| `ModuleRecipe(options)` | a frozen recipe | none | the only recipe constructor | `InvalidInput` (missing `import`, text without `name`) |
| `ImportResolver.layered().layer(l)` | a new resolver | none | `custom` was dropped | `InvalidInput` |
| layers `relative`, `origine`, `importMap` | immutable JS class descriptors | allocates a JS class instance; the map is copied once | descriptors, not functions, so they stay native | `InvalidInput` |
| `ImportHandler.make` | a JS ImportHandler instance with read-only `plan` and `native` | none; `plan` shows which elements enter JS | `makeCustom` was dropped | `InvalidInput` |
| `Import.next/accept/provide/link/reject` | immutable native verdicts | none when built; when a hook returns `link` with `'hardened'`, the creating realm copies the exporter's plain data and the importer's hardener freezes the copies and any function or class the exporter shares (see Cross-context imports) | flattened `Bail` | `InvalidInput` (`link` without `mode`, of a reference that is not evaluated, `reject` of a code outside `ImportError`), `Unsupported` (a hardened link of an accessor property) |
| `MakeRecipe.inherit/fn` | a maker | none | `fn` returns options so it cannot be a second provider | `InvalidInput` |
| `Transform.byExtension` | a immutable native transformer descriptor | none | the one combinator | `InvalidInput` (extension syntax, more than 64) |
| `origineProvider`, `fsProvider`, `json`, `fromLoader` | providers/hooks | `fsProvider.read` is required because it chooses a cost. `origineProvider.std` is optional: the default serves everything the creating context itself may import, never more. The earlier rule ("`std` is required, no everything default") assumed a default would hand out authority the author did not see; it cannot, because the default is the creator's own set, clipped natively, and the narrower spellings (`include`, `exclude`) stay for code that wants less | `fromLoader` is a migration adapter for the old loader | `InvalidInput` |
| `ImportCache.native`, `ResolveCache.native`, `CodeCache.*` | immutable JS class descriptors | `retain` is required (it decides whether a re-import evaluates again). **A cache shared by contexts shares more than modules, and this is a security fact, not a detail:** objects of the home context reach the other contexts (intrinsics, `fn.constructor`, live mutation both ways), so a cache shared with a less trusted context leaks the realm boundary; it also hands a context what the home read with its own authority (a graph with a narrower fs grant gets the module a wider one loaded). Authority is the handle: only code that can name the `ImportCache` object (or a handler made with it) can attach it to a context, and there is no option to turn sharing off, you use two objects. `ImportHandler.make` makes its default `ImportCache.native({ retain: 'all' })` once per handler, so **two contexts created from the same handler object share module instances by default**, and a handler per context keeps them apart; `dir` touches the disk when the graph uses it; `custom.load` runs once per module that compiles, in the creating realm, and its failure is a miss | caches are not pluggable in JS except `CodeCache.custom` | `InvalidInput` |
| `api.graph.derive(options)` | a graph with the fs grant, code cache or source limit replaced | none; holds no more than the realm already holds. A sync grant is read with the host's blocking read, an async grant on its io runtime; a source file is read whole up to `sourceBytes` | the only way to give a graph authority; the root `api.graph` reads nothing; the limit is a number, readable as `graph.sourceBytes` | `InvalidInput` (not a grant `api.fs` made, malformed cache, `CodeCache.dir` with an async grant, `sourceBytes` not a positive integer), `PermissionDenied` (a grant without the needed access); an import of a larger file fails with `FileTooLarge` |
| `api.fs.requestSync` / `requestAsync` result (a grant) | a JS FsGrant instance with the existing operation names | allocates a JS FsGrant instance; the host builds its authority (`fs.request`, `fs.requestAsync`) with a V8 private symbol set at construction, for a sync grant the host also builds every operation (references, stats, and directory entries are native instances; listings are frozen arrays, a malformed argument is `InvalidInput` before anything runs), and the glue only adds the scope's `errno` array and freezes it; an async grant's operations are still JS wrappers over the Rust natives, added by the glue; its consumers (`derive({ fs })`, `CodeCache.dir`) check the symbol natively, for this realm. It is a JS FsGrant instance; structural copies and forged prototypes do not reproduce its identity or authority | one mechanism: the JS `WeakSet` of grants, the `{ kind, id }` lookup and the stamping native are gone; `kind` and `id` stay as read-only fields and confer nothing. A sync grant is closed with its realm; an async one when its `io` closes (`io.close()` tells the host) or its realm ends | `InvalidInput` (not a grant of this realm, a copy or clone of one, a closed grant) |
| `graph.close()` / `[Symbol.dispose]` (on a derived graph) | ends the graph; no more contexts or references can be made with it | contexts that use it keep working; the host frees the graph and the code caches it kept once they are gone; caches not yet flushed are dropped | the lifetime control for what `narrow` made; `api.graph` has none | `StaleHandle` (closed already) |
| `graph.flush()` | resolves how many modules' code caches were stored | writes files for `dir`, calls `store(key, blob)` for `custom` with an opaque blob; explicit because lazy functions are cached only after the code ran | the only persistence call | `Unsupported`-free; a failed write is a miss |
| `recipe.create(graph)` | a `declared` `ModuleReference`; reads nothing | none | the only way to make a reference | `InvalidInput` (not a graph) |
| `reference.load()` | resolves the reference once its source is read, transformed and compiled and a `declared` reference exists for each import (one level; call `load()` on those to go deeper) | reads files, runs transformers and hooks (JS ones in the creating realm) | `evaluate` does not need it; it exists for `requests` | `NotFound`, `PermissionDenied`, a `SyntaxError` for source a transformer rejects |
| `reference.exports()` | a snapshot of the evaluated module's exports in the creating realm: a null-prototype object | copies plain data on every call (the same copy rules as a hardened link: data copied and frozen, functions and classes shared and frozen in place and still running in the context, accessor properties `Unsupported`), and reads the bindings as they are at that moment; the name is a call, not a property, so a cost the caller sees | the only way for the host to read a module's values besides a preload print or a hardened link; no second set of rules | `InvalidInput` (the reference is not `evaluated`), `StaleHandle` (the context is closed), `BadHandle` (released), `Unsupported` (an accessor, a `Map`, a typed array, a promise or a proxy in the exports) |
| `reference.evaluate(ctx)` | binds the reference to `ctx` and evaluates it; resolves when done | binds the reference to one context for good | the V8 shape (`Module::Evaluate(context)`); no `ctx.evaluate` | `InvalidInput` (bound elsewhere, name in use), `StaleHandle` (closed context), `ModuleError` (a failure in the module) |
| `reference.release()` / `[Symbol.dispose]` | unpins the module; with `retain: 'used'` it is freed once nothing holds it | later imports of it evaluate again | the lifetime control; no GC-driven release yet | none |
| `api.context.create(options)` | a `Context`; resolves after preloads | creates a V8 context; preloads run | replaces `api.scope.create` (decided) | `InvalidInput` (no `import`, malformed preload), `ModuleError` (a preload failed; the context is closed) |
| `ctx.import(specifier, options)` | a reference to the evaluated module | loads and evaluates | the `import()` of a script; `phase` other than `'evaluation'` is `Unsupported` | `ModuleError`, `StaleHandle` |
| `ctx.references`, `ctx.graph` | the references bound to it; its graph | a copy of the list | getters | none |
| `ctx.close()` | disposes the realm | rejects imports in flight; handles go stale | `Symbol.dispose` is the same call | `BadHandle`, `StaleHandle` |
| `ImportCache#size`, `#delete(id)`, `#clear()` | how many modules the table holds; how many `delete`/`clear` dropped | `delete` and `clear` forget modules in every context of this realm, so the next import evaluates again; `size` counts every context | the only view of a table; replaces `cache.in(ctx)`, no alias | `InvalidInput` (`id` not a string), `Unsupported` (no `api.graph`/`api.context` in the realm) |

## Open

- How a declared dependency reference is adopted when the evaluating context's table already holds its key (today `evaluate` of the dependency's reference would fail `InvalidInput` for the taken name).

Native descriptor identity, allocation, validation, and snapshot behavior are documented in [native handles](native-handles.md).
