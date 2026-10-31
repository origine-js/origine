# `origine:@std/graph/*`

Source: [std/graph/](../std/graph/) (data), [glue/graph.js](../glue/graph.js) and [glue/context.js](../glue/context.js) (`api.graph`, `api.context`). The module graph: immutable JS class descriptions of modules, import pipelines and caches, and the capabilities that load and evaluate them ([docs/graph-api.md](../../../docs/graph-api.md) has the design, the deviations and the checklist). The builders below are authority-free JS class instances, validated in JS and snapshot-safe; reading files, compiling and evaluating happen in `api.graph` and `api.context`.

```js
const graph = api.graph.derive({ fs: api.fs.requestSync({ access: 'r' }), codeCache: CodeCache.memory() });
const handler = ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [fsProvider({ read: 'copy' })] });
const recipe = ModuleRecipe({ source: ModuleSource.file('main.js'), import: handler });
using ctx = await api.context.create({ import: handler, graph });
const reference = graph.declare(recipe);           // declared; nothing read yet
await graph.load(reference);                       // loaded; graph.requests(reference) lists its imports
await graph.evaluate(reference, ctx);              // bound to ctx and evaluated
await graph.flush();                               // persists the code caches
```

Types: [types/std/graph.d.ts](../../../types/std/graph.d.ts). Every builder throws a an `IoError` instance with errno `InvalidInput` and a message for a malformed argument. Option bags are read as own data properties (a getter counts as missing) and copied.

| Module | Exports |
| --- | --- |
| `origine:@std/graph/module` | `ModuleSource`, `SourceMap`, `ModuleRecipe`, `ModuleImportPhase` |
| `origine:@std/graph/import` | `ImportHandler`, `Import`, `ImportError`, `MakeRecipe`, `Transform` |
| `origine:@std/graph/resolve` | `ImportResolver` |
| `origine:@std/graph/resolve/layers` | `relative`, `origine`, `importMap` |
| `origine:@std/graph/providers` | `origineProvider`, `fsProvider`, `json`, `fromLoader` |
| `origine:@std/graph/cache` | `ImportCache`, `ResolveCache`, `CodeCache` |

```js
import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
import { ImportHandler, Import, ImportError, MakeRecipe, Transform } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { relative, origine } from 'origine:@std/graph/resolve/layers';
import { origineProvider, fsProvider } from 'origine:@std/graph/providers';

const handler = ImportHandler.make({
  resolver: ImportResolver.layered().layer(relative()).layer(origine()),
  hooks: [
    resolved => (resolved.id === 'secret' ? Import.reject(ImportError.PermissionDenied) : Import.next()),
    origineProvider({ std: { include: ['text'] } }),
    fsProvider({ read: 'copy' }),
  ],
});
handler.native;                  // false: the first hook is a function, so some imports enter the JS realm
handler.plan[0];                 // { stage: 'resolver', kind: 'native', name: 'relative' }
const recipe = ModuleRecipe({ source: ModuleSource.file('./main.js'), import: handler });
```

## Cost and errors, by name

The builders block nothing, allocate nothing natively, detach nothing and retain no host resource; the costs a call site cannot see are made options. `api.graph` and `api.context` read files with the graph's fs grant inside the load stage: a sync grant (`requestSync`) blocks the isolate thread like any sync call, an async one (`requestAsync`) reads on its io runtime and blocks nothing.

### `module`

- `ModuleSource.file(path, map?)`: a source read later by the graph's fs grant (`path` non-empty, no NUL). `ModuleSource.text(text, map?)`: in-memory text. Both return a native `ModuleSource` instance (`kind`, `path` or `text`, `map`, `transformers`, `native`). `source.withTransformer(t)` returns a **new** source with `t` chained last and leaves the receiver unchanged; `t` is a function `(source, id) => string | { source, map } | Promise` or a transformer descriptor (`Transform.byExtension`). `native` is true when no chained transformer is a function.
- `SourceMap.None` (default), `SourceMap.url(url)`, `SourceMap.text(json)`: carried with the source, not applied (no stack remapping).
- `ModuleRecipe({ source, import, name?, codeCache? })`: `source` and `import` (an `ImportHandler`) are required because `import` decides what the module can load. `name` defaults to the file path and is required for a text source. `codeCache: null` means the graph's. `recipe.native` is true when neither the source's transformers nor the handler enter the JS realm, which is what makes a recipe plain data.
- `ModuleImportPhase`: `Evaluation`, `Source`, `Defer`. Only `Evaluation` is implemented by the engine.

### `resolve` and `resolve/layers`

- `ImportResolver.layered()` is a resolver with no layers; `.layer(l)` returns a new one. The first layer that returns `{ id, attributes? }` wins, `undefined` passes, no answer is `NotFound`. A layer is a function `({ specifier, referrer, attributes, phase })` run in the creating realm (it may be async) or a descriptor.
- `relative()` (`./x`, `../x`), `origine()` (recognises `origine:` ids, serves nothing), `importMap({ imports, scopes })` (web import-map data, copied and frozen). Descriptors are JS `ResolveLayer` instances the host will compile to native steps.

### `import`

- `ImportHandler.make({ resolver, hooks, maker?, cache?, meta? })`. `resolver` needs at least one layer. `hooks` is required (a function or provider, or an array; `[]` is allowed and resolves nothing). `maker` defaults to `MakeRecipe.inherit()`, `cache` to `ImportCache.native({ retain: 'all' })`. `meta({ id })` is called when a module is made and returns plain data. The handler exposes `plan` (every element in order as `{ stage, kind: 'native' | 'js', name? }`) and `native` (true when no import enters the JS realm).
- Verdicts a hook returns (immutable JS class instances): `Import.next()`, `Import.accept()` (use the default maker), `Import.source(source)` (stop with a `ModuleSource`; the maker turns it into a module; the importer gets its own) and `Import.recipe(recipe)` (stop with a `ModuleRecipe`: final, the maker is skipped and the recipe's own handler answers its imports; the importer gets its own fresh module), `Import.link(reference)` (use a module already evaluated in some context: the module itself, with live bindings and the other realm's own objects; nothing is copied or frozen, so it **crosses the realm boundary** and a function the importer calls runs in the exporting realm), `Import.exports(values)` (stop with one synthetic module whose namespace is `values`: own enumerable string-keyed data properties, `default` allowed, an accessor is `InvalidInput`; nothing is copied or frozen, so each value is shared with the importer as it is and an `origine:` id is `PermissionDenied`), `Import.reject(code | ImportError.other(message))`.
- `ImportError`: `NotFound`, `PermissionDenied`, `Unsupported`, `InvalidInput`, `InvalidData` (the `IoError` numbers), `other(message)` and `is(value, code)`.
- `MakeRecipe.inherit({ import?, transformer? })` (native: the made recipe inherits this handler unless `import` names another, and applies `transformer` to the supplied source) and `MakeRecipe.fn(({ id, source }) => options)` (yours, returns the same options, never a recipe).
- `Transform.byExtension({ '.ts': t, ... })`: the longest suffix wins (`.d.ts` over `.ts`); at most 64 extensions; an extension starts with `.` and has no `/ \ ? #`, no trailing dot and no `..`.

### `providers`

- `origineProvider()`, `origineProvider({ std: true })`, `origineProvider({ std: { include } | { exclude } })`: serves `origine:@std/*` modules (names without the prefix, for example `'text'`, `'transformer/oxc'`). With no options, or `std: true`, it serves every `origine:@std/*` module the creating context itself may import; `std: { include }` or `{ exclude }` (exactly one) names fewer. It can only narrow the creating context's own set: the default is that set, and a hook that names more is `PermissionDenied`.
- `fsProvider({ read })`: `read` is required, `'copy'` or `'mmap'`. `'mmap'` avoids a copy for ASCII/Latin-1 text, but a file changed while mapped changes under V8.
- `json()`: `type: 'json'` imports as a module whose default export is the parsed value.
- `fromLoader(loader)`: adapts a loader `loader(id, attributes)` (a string, `{ source }`, or a promise of either) to a hook; anything else rejects `InvalidData`.

### `cache`

- `ImportCache.native({ retain })`: `retain` is required. `'all'` keeps entries for the context's lifetime; `'used'` drops an entry once nothing holds it, so a later import evaluates the module again. There is no `entries` cap (passing one is `InvalidInput`): an identity table never evicts one module while others stay, so its bounds are `retain: 'used'`, `delete` and `clear`. `ResolveCache.native({ entries })` keeps its cap, because what it holds can be recomputed.
- `ResolveCache.native({ entries? })`.
- `CodeCache.none`, `CodeCache.memory({ bytes? })`, `CodeCache.dir(fs, { bytes? })` (files at `__codecache__/<32 hex digits of BLAKE3(runtime, module kind, source text)>.v8-code-cache` in the directory the grant allows (the grant needs write access); the module id is not in the name, so a virtual id such as `app:/x.js` or `https://...`, or one with `..`, stays inside `__codecache__`, never depends on the working directory, and identical sources share a file; each file holds the hash of the source it was made from and is ignored for any other text; touches the disk when used), `CodeCache.custom({ load, store })` (yours, may be async, run in the creating realm): `key` is `{ id, hash }` with the lowercase hex BLAKE3 digest of the exact text V8 compiles (after every transformer); `store(key, blob)` runs at `graph.flush()` with an opaque `Uint8Array` to keep whole; `load(key, source)` runs once a module's source is final and before it compiles, and returns the blob kept under that key or `undefined`. A blob made for another text (each blob carries the hash of its own source), by another V8 build or with other flags, a throwing `load` and any other answer are misses, never errors.

### `api.graph` and `api.context`

- `api.graph.derive({ fs?, codeCache?, sourceBytes? })`: a new graph with those replaced. Deriving never widens authority (the graph holds nothing the realm does not already hold), so it can only narrow. `sourceBytes` (a positive integer, default 64 MiB, readable as `graph.sourceBytes`) is the largest source file the graph reads through its fs grant: a larger one fails the import with `FileTooLarge` and is never cut short. `CodeCache.dir` needs a sync grant (a compile cannot wait for an async read); `CodeCache.custom` can use async io. `fs` is a grant `api.fs` made, sync (`api.fs.requestSync`) or async (`await api.fs.requestAsync({ io, ... })`); the root `api.graph` has none, so it can only supply text sources and `origine:` modules. `graph.flush()` resolves how many modules' code caches were stored. A derived graph is yours to end: `graph.close()` (or `using graph = ...`) stops it taking contexts and references, and the host frees it and the code caches it kept once the contexts using it are gone; `api.graph` has no `close`.
- `graph.declare(recipe)` returns a `ModuleReference`, an inert ticket for an entry in that graph's table: read-only `name`, `status` (`declared`, `loaded`, `evaluating`, `evaluated`, `errored`) and `context` (the context it is bound to), nothing else; it has no methods and no `Symbol.dispose`, so holding one is not the power to run, read or free the module. The graph does that, and a reference belongs to one graph (`InvalidInput` for another graph's, a derived graph's included; closing a derived graph makes its references `StaleHandle`).
- `graph.load(reference)` (one level: it makes a `declared` reference per import, and loading those goes deeper; overlapping calls share one load), `graph.requests(reference)` (`undefined` until loaded; each `{ specifier, attributes, phase, reference }`), `graph.evaluate(reference, ctx)` (binds to one context, which must be made with this graph; evaluating in a second is `InvalidInput`), `graph.exports(reference)` (needs `evaluated`: the live module namespace of the context the reference is bound to, the same object every call; nothing is copied or frozen, so reading it crosses the realm boundary) and `graph.release(reference)` (unpins the module).
- `api.context.create({ import, graph, preload? })` returns a `Context`: `import(specifier, { attributes? })` (a reference to the evaluated module), `references`, `graph`, `close()` / `Symbol.dispose`. `import` and `graph` are required (`graph` is `api.graph` or a graph derived from it; a missing, forged or closed one is `InvalidInput` naming `graph`; there is no default). `preload` entries are `{ source, values }` or `{ module, values }`, run before anything is imported; `values` is deep-frozen plain data and functions only. A context gets no capability unless you pass one through `values`, and never sees the graph.
- An `ImportCache` object is the name of a table of modules: `size`, `delete(id)` (the next import makes and evaluates a new module) and `clear()` are on the object, and count every context this realm created. Handlers made with the same object keep their modules in one table; two objects are two tables, also inside one context. **Contexts that use the same object share its modules**: the first to import an id evaluates it, the others link that module (live bindings, the same objects, it runs once; a context that asks meanwhile waits). That leaks the realm boundary on purpose (intrinsics, `fn.constructor` and mutation cross), so a cache shared with a less trusted context is a hole, and it hands a context what the home read with its own authority. `ImportHandler.make` makes its default cache once per handler, so two contexts created from one handler object share module instances; use a handler per context, or distinct `ImportCache` objects, to keep them apart. If the home context closes, the others drop what they linked from it and the next import evaluates a new module (the first to ask becomes the home).
