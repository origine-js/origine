# `origine:@std/graph/*`

Source: [std/graph/](../std/graph/) (data), [glue/graph.js](../glue/graph.js) and [glue/context.js](../glue/context.js) (`api.graph`, `api.context`). The module graph: frozen descriptions of modules, import pipelines and caches, and the capabilities that load and evaluate them ([docs/graph-api.md](../../../docs/graph-api.md) has the design, the deviations and the checklist). The builders below are authority-free, pure JS and snapshot-safe; reading files, compiling and evaluating happen in `api.graph` and `api.context`.

```js
const graph = api.graph.derive({ fs: api.fs.requestSync({ access: 'r' }), codeCache: CodeCache.memory() });
const handler = ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [fsProvider({ read: 'copy' })] });
const recipe = ModuleRecipe({ source: ModuleSource.file('main.js'), import: handler });
using ctx = await api.context.create({ import: handler, graph });
const reference = recipe.create(graph);            // declared; nothing read yet
await reference.load();                            // loaded; reference.requests lists its imports
await reference.evaluate(ctx);                     // bound to ctx and evaluated
await graph.flush();                               // persists the code caches
```

Types: [types/std/graph.d.ts](../../../types/std/graph.d.ts). Every builder throws a frozen `{ errno, name: 'InvalidInput', message }` for a malformed argument. Option bags are read as own data properties (a getter counts as missing) and copied.

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

- `ModuleSource.file(path, map?)`: a source read later by the graph's fs grant (`path` non-empty, no NUL). `ModuleSource.text(text, map?)`: in-memory text. Both return a frozen `Source` (`kind`, `path` or `text`, `map`, `transformers`, `native`). `source.withTransformer(t)` returns a **new** source with `t` chained last and leaves the receiver unchanged; `t` is a function `(source, id) => string | { source, map } | Promise` or a transformer descriptor (`Transform.byExtension`). `native` is true when no chained transformer is a function.
- `SourceMap.None` (default), `SourceMap.url(url)`, `SourceMap.text(json)`: carried with the source, not applied (no stack remapping).
- `ModuleRecipe({ source, import, name?, codeCache? })`: `source` and `import` (an `ImportHandler`) are required because `import` decides what the module can load. `name` defaults to the file path and is required for a text source. `codeCache: null` means the graph's. `recipe.native` is true when neither the source's transformers nor the handler enter the JS realm, which is what makes a recipe plain data.
- `ModuleImportPhase`: `Evaluation`, `Source`, `Defer`. Only `Evaluation` is implemented by the engine.

### `resolve` and `resolve/layers`

- `ImportResolver.layered()` is a resolver with no layers; `.layer(l)` returns a new one. The first layer that returns `{ id, attributes? }` wins, `undefined` passes, no answer is `NotFound`. A layer is a function `({ specifier, referrer, attributes, phase })` run in the creating realm (it may be async) or a descriptor.
- `relative()` (`./x`, `../x`), `origine()` (recognises `origine:` ids, serves nothing), `importMap({ imports, scopes })` (web import-map data, copied and frozen). Descriptors are frozen `{ host, kind: 'layer', ... }` values the host will compile to native steps.

### `import`

- `ImportHandler.make({ resolver, hooks, maker?, cache?, meta? })`. `resolver` needs at least one layer. `hooks` is required (a function or provider, or an array; `[]` is allowed and resolves nothing). `maker` defaults to `MakeRecipe.inherit()`, `cache` to `ImportCache.native({ retain: 'all' })`. `meta({ id })` is called when a module is made and returns plain data. The handler exposes `plan` (every element in order as `{ stage, kind: 'native' | 'js', name? }`) and `native` (true when no import enters the JS realm).
- Verdicts a hook returns (all frozen): `Import.next()`, `Import.accept()` (use the default maker), `Import.provide(source | recipe)` (a source goes through the maker, a recipe is final; the importer gets its own module), `Import.link(reference, { mode })` (use a module already evaluated in some context; `mode` is required: `'hardened'` links a synthetic module of its exports as a snapshot: plain data (primitives, arrays and objects with a plain prototype, cycles kept) is **copied**, so the exporting module's own objects stay as mutable as they were, and the copies are frozen; a function, a class and any other object cannot be copied, so it is **shared and frozen in place** in its own realm together with what it reaches (a class's statics and prototype chain), and anything the exporter later mutates through it fails there; an accessor property is `Unsupported`; `'shared'` links the module itself (live bindings, same objects) and leaks the realm boundary), `Import.reject(code | ImportError.other(message))`.
- `ImportError`: `NotFound`, `PermissionDenied`, `Unsupported`, `InvalidInput`, `InvalidData` (the `IoError` numbers), `other(message)` and `is(value, code)`.
- `MakeRecipe.inherit({ import?, transformer? })` (native: the made recipe inherits this handler unless `import` names another, and applies `transformer` to the supplied source) and `MakeRecipe.fn(({ id, source }) => options)` (yours, returns the same options, never a recipe).
- `Transform.byExtension({ '.ts': t, ... })`: the longest suffix wins (`.d.ts` over `.ts`); at most 64 extensions; an extension starts with `.` and has no `/ \ ? #`, no trailing dot and no `..`.

### `providers`

- `origineProvider()`, `origineProvider({ std: true })`, `origineProvider({ std: { include } | { exclude } })`: serves `origine:@std/*` modules (names without the prefix, for example `'text'`, `'transformer/oxc'`). With no options, or `std: true`, it serves every `origine:@std/*` module the creating context itself may import; `std: { include }` or `{ exclude }` (exactly one) names fewer. It can only narrow the creating context's own set: the default is that set, and a hook that names more is `PermissionDenied`.
- `fsProvider({ read })`: `read` is required, `'copy'` or `'mmap'`. `'mmap'` avoids a copy for ASCII/Latin-1 text, but a file changed while mapped changes under V8.
- `json()`: `type: 'json'` imports as a module whose default export is the parsed value.
- `fromLoader(loader)`: adapts a loader `loader(id, attributes)` (a string, `{ source }`, or a promise of either) to a hook; anything else rejects `InvalidData`.

### `cache`

- `ImportCache.native({ retain, entries? })`: `retain` is required. `'all'` keeps entries for the context's lifetime; `'used'` drops an entry once nothing holds it, so a later import evaluates the module again. `entries` caps the table (per context: it caps the modules a context is the home of).
- `ResolveCache.native({ entries? })`.
- `CodeCache.none`, `CodeCache.memory({ bytes? })`, `CodeCache.dir(fs, { bytes? })` (files at `__codecache__/<32 hex digits of BLAKE3(runtime, module kind, source text)>.v8-code-cache` in the directory the grant allows (the grant needs write access); the module id is not in the name, so a virtual id such as `app:/x.js` or `https://...`, or one with `..`, stays inside `__codecache__`, never depends on the working directory, and identical sources share a file; each file holds the hash of the source it was made from and is ignored for any other text; touches the disk when used), `CodeCache.custom({ load, store })` (yours, may be async, run in the creating realm): `key` is `{ id, hash }` with the lowercase hex BLAKE3 digest of the exact text V8 compiles (after every transformer); `store(key, blob)` runs at `graph.flush()` with an opaque `Uint8Array` to keep whole; `load(key, source)` runs once a module's source is final and before it compiles, and returns the blob kept under that key or `undefined`. A blob made for another text (each blob carries the hash of its own source), by another V8 build or with other flags, a throwing `load` and any other answer are misses, never errors.

### `api.graph` and `api.context`

- `api.graph.derive({ fs?, codeCache?, sourceBytes? })`: a new graph with those replaced. Deriving never widens authority (the graph holds nothing the realm does not already hold), so it can only narrow. `sourceBytes` (a positive integer, default 64 MiB, readable as `graph.sourceBytes`) is the largest source file the graph reads through its fs grant: a larger one fails the import with `FileTooLarge` and is never cut short. `CodeCache.dir` needs a sync grant (a compile cannot wait for an async read); `CodeCache.custom` can use async io. `fs` is a grant `api.fs` made, sync (`api.fs.requestSync`) or async (`await api.fs.requestAsync({ io, ... })`); the root `api.graph` has none, so it can only supply text sources and `origine:` modules. `graph.flush()` resolves how many modules' code caches were stored. A derived graph is yours to end: `graph.close()` (or `using graph = ...`) stops it taking contexts and references, and the host frees it and the code caches it kept once the contexts using it are gone; `api.graph` has no `close`.
- `recipe.create(graph)` returns a `ModuleReference`: `name`, `status` (`declared`, `loaded`, `evaluating`, `evaluated`, `errored`), `requests` (`undefined` until loaded; each `{ specifier, attributes, phase, reference }`), `context` (the context it is bound to), `load()` (one level: it makes a `declared` reference per import, and `load()` on those goes deeper; overlapping calls share one load), `evaluate(ctx)` (binds to one context; evaluating in a second is `InvalidInput`), `exports()` (needs `evaluated`: a snapshot of the module's exports for this realm, copied on every call with the rules of a hardened link; plain data copied and frozen, functions shared and frozen in place and still running in the context, an accessor or a `Map` `Unsupported`; the result has no prototype), `release()` / `Symbol.dispose` (unpins the module).
- `api.context.create({ import, graph?, preload? })` returns a `Context`: `import(specifier, { attributes? })` (a reference to the evaluated module), `references`, `graph`, `close()` / `Symbol.dispose`. `import` is required. `preload` entries are `{ source, values }` or `{ module, values }`, run before anything is imported; `values` is deep-frozen plain data and functions only. A context gets no capability unless you pass one through `values`, and never sees the graph.
- An `ImportCache` object is the name of a table of modules: `size`, `delete(id)` (the next import makes and evaluates a new module) and `clear()` are on the object, and count every context this realm created. Handlers made with the same object keep their modules in one table; two objects are two tables, also inside one context. **Contexts that use the same object share its modules**: the first to import an id evaluates it, the others link that module (live bindings, the same objects, it runs once; a context that asks meanwhile waits). That leaks the realm boundary on purpose (intrinsics, `fn.constructor` and mutation cross), so a cache shared with a less trusted context is a hole, and it hands a context what the home read with its own authority. `ImportHandler.make` makes its default cache once per handler, so two contexts created from one handler object share module instances; use a handler per context, or distinct `ImportCache` objects, to keep them apart. If the home context closes, the others drop what they linked from it and the next import evaluates a new module (the first to ask becomes the home).
