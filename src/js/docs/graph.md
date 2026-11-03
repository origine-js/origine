# `origine:@std/graph/*`

Source: [std/graph/](../std/graph/) (data), [glue/graph.js](../glue/graph.js) and [glue/context.js](../glue/context.js) (`api.graph`, `api.context`). The module graph: immutable JS class descriptions of modules, import pipelines and caches, and the capabilities that load and evaluate them ([docs/graph-api.md](../../../docs/graph-api.md) has the design, the deviations and the checklist). The builders below are authority-free JS class instances, validated in JS and snapshot-safe; reading files, compiling and evaluating happen in `api.graph` and `api.context`.

```js
const src = api.fs.requestSync({ access: 'r', handle: 'plain' }); // the grant that reads the files: named where it is used
const cache = CodeCache.memory();
const graph = api.graph.create();
const handler = ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [fsProvider({ fs: src, read: 'copy' })], codeCache: cache });
const recipe = ModuleRecipe({ source: ModuleSource.file('main.js', { fs: src }), import: handler });
using ctx = await api.context.create({ import: handler, graph });
const reference = graph.declare(recipe);           // declared; nothing read yet
await graph.load(reference);                       // loaded; graph.requests(reference) lists its imports
await graph.evaluate(reference, ctx);              // bound to ctx and evaluated
await cache.flush();                               // persists the code caches of the modules made with it
```

Types: [types/std/graph.d.ts](../../../types/std/graph.d.ts). Every builder throws a an `IoError` instance with errno `InvalidInput` and a message for a malformed argument. Option bags are read as own data properties (a getter counts as missing) and copied.

| Module | Exports |
| --- | --- |
| `origine:@std/graph/module` | `ModuleSource`, `SourceMap`, `ModuleRecipe`, `ModuleImportPhase` |
| `origine:@std/graph/import` | `ImportHandler`, `ImportHook`, `ImportError`, `MakeRecipe`, `Transform` |
| `origine:@std/graph/resolve` | `ImportResolver` |
| `origine:@std/graph/resolve/layers` | `relative`, `origine`, `importMap` |
| `origine:@std/graph/providers` | `origineProvider`, `fsProvider`, `json`, `fromLoader` |
| `origine:@std/graph/cache` | `ImportCache`, `CodeCache` |

```js
import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
import { ImportHandler, ImportHook, ImportError, MakeRecipe, Transform } from 'origine:@std/graph/import';
import { ImportResolver } from 'origine:@std/graph/resolve';
import { relative, origine } from 'origine:@std/graph/resolve/layers';
import { origineProvider, fsProvider } from 'origine:@std/graph/providers';

const handler = ImportHandler.make({
  resolver: ImportResolver.layered().layer(relative()).layer(origine()),
  hooks: [
    resolved => (resolved.id === 'secret' ? ImportHook.reject(ImportError.PermissionDenied) : ImportHook.next()),
    origineProvider({ std: { include: ['text'] } }),
    fsProvider({ fs: src, read: 'copy' }),
  ],
});
handler.plan[0];                 // { stage: 'resolver', kind: 'native', name: 'relative' }
handler.plan[1];                 // { stage: 'hooks', kind: 'js' }: the first hook is a function, so an import enters the JS realm there
const recipe = ModuleRecipe({ source: ModuleSource.file('./main.js', { fs: src }), import: handler });
```

## Cost and errors, by name

The builders block nothing, allocate nothing natively, detach nothing and retain no host resource; the costs a call site cannot see are made options. `api.graph` and `api.context` read files through the grant a hook or source names, inside the load stage: a sync grant (`requestSync`) blocks the isolate thread like any sync call, an async one (`requestAsync`) reads on its io runtime and blocks nothing.

### `module`

- `ModuleSource.file(path, { fs }, map?)`: a source read later through the grant `fs` (`path` non-empty, no NUL). `ModuleSource.text(text, map?)`: in-memory text. Both return a native `ModuleSource` instance (`kind`, `path` or `text`, `map`, `transformers`). `source.withTransformer(t)` returns a **new** source with `t` chained last and leaves the receiver unchanged; `t` is a function `(source, id) => string | { source, map } | Promise` or a transformer descriptor (`Transform.byExtension`).
- `SourceMap.None` (default), `SourceMap.url(url)`, `SourceMap.text(json)`: carried with the source, not applied (no stack remapping).
- `ModuleRecipe({ source, import, name?, codeCache? })`: `source` and `import` (an `ImportHandler`) are required because `import` decides what the module can load. `name` defaults to the file path and is required for a text source. Without `codeCache` the handler's applies.
- `ModuleImportPhase`: `Evaluation`, `Source`, `Defer`. Only `Evaluation` is implemented by the engine.

### `resolve` and `resolve/layers`

- `ImportResolver.layered()` is a resolver with no layers; `.layer(l)` returns a new one. The first layer that returns `{ id }` or an id wins (`attributes` in its answer is `InvalidData`: the import's attributes are what its statement wrote), `undefined` passes, no answer is `NotFound`. A layer is a function `({ specifier, referrer, attributes, phase })` run in the creating realm (it may be async) or a descriptor.
- `relative()` (`./x`, `../x`), `origine()` (recognises `origine:` ids, serves nothing), `importMap({ imports, scopes })` (web import-map data, copied and frozen; its values and scope keys are virtual URLs resolved against `app:/map.json`, so `./x.js` becomes the id `app:/x.js`, and a bare file name that is not a URL is `InvalidInput` at `context.create`. Ids are what the hooks see: a hook that reads plain paths, `fsProvider` among them, does not serve `app:/x.js`). Descriptors are JS `ResolveLayer` instances the host will compile to native steps.

### `import`

- `ImportHandler.make({ resolver, hooks, maker?, cache?, meta? })`. `resolver` needs at least one layer. `hooks` is required (a function or provider, or an array; `[]` is allowed and resolves nothing). `maker` defaults to `MakeRecipe.inherit()`, `cache` to `ImportCache.native({ retain: 'all' })`. `meta({ id })` is called when a module is made and returns plain data. The handler exposes `plan`: every element in order as `{ stage, kind: 'native' | 'js', name? }`. A chain runs natively until it reaches a JS element and goes back to native after it. `plan` lists this handler's own elements: a handler named by `MakeRecipe.inherit({ import })` has its own.
- Verdicts a hook returns (immutable JS class instances): `ImportHook.next()`, `ImportHook.accept({ fs })` (read the id as a file of the grant `fs` and use the default maker), `ImportHook.source(source)` (stop with a `ModuleSource`; the maker turns it into a module; the importer gets its own) and `ImportHook.recipe(recipe)` (stop with a `ModuleRecipe`: final, the maker is skipped and the recipe's own handler answers its imports; the importer gets its own fresh module), `ImportHook.link(reference)` (use a module already evaluated in some context: the module itself, with live bindings and the other realm's own objects; nothing is copied or frozen, so it **crosses the realm boundary** and a function the importer calls runs in the exporting realm), `ImportHook.exports(values)` (stop with one synthetic module whose namespace is `values`: own enumerable string-keyed data properties, `default` allowed, an accessor is `InvalidInput`; nothing is copied or frozen, so each value is shared with the importer as it is and an `origine:` id is `PermissionDenied`), `ImportHook.reject(code | ImportError.other(message))`.
- `ImportError`: `NotFound`, `PermissionDenied`, `Unsupported`, `InvalidInput`, `InvalidData` (the `IoError` numbers), `other(message)` and `is(value, code)`.
- `MakeRecipe.inherit({ import?, transformer? })` (native: the made recipe inherits this handler unless `import` names another, and applies `transformer` to the supplied source) and `MakeRecipe.fn(({ id, source }) => options)` (yours, returns the same options, never a recipe).
- `Transform.byExtension({ '.ts': t, ... })`: the longest suffix wins (`.d.ts` over `.ts`); at most 64 extensions; an extension starts with `.` and has no `/ \ ? #`, no trailing dot and no `..`.

### `providers`

- `origineProvider()`, `origineProvider({ std: true })`, `origineProvider({ std: { include } | { exclude } })`: serves `origine:@std/*` modules (names without the prefix, for example `'text'`, `'transformer/oxc'`). With no options, or `std: true`, it serves every `origine:@std/*` module the creating context itself may import; `std: { include }` or `{ exclude }` (exactly one) names fewer. It can only narrow the creating context's own set: the default is that set, and a hook that names more is `PermissionDenied`.
- `fsProvider({ fs, read })`: `fs` is the grant `api.fs` made (sync or async) that reads the ids, which are paths relative to its root. `missing` says what a file that is not in this root does: `'abort'` (the default) fails the import with `NotFound`, `'skip'` passes to the next hook, so several roots are several providers with `missing: 'skip'`, tried in hook order. The whole file is read: the graph has no size limit, so check a size in a hook of your own (for example `fs.metadata`) and fail the import with `ImportError.other(message)` if it matters. `read` is required, `'copy'` or `'mmap'`. `'copy'` reads the file into memory and V8 copies it again into its heap. `'mmap'` is for large sources: with a sync grant, a file that is all ASCII is mapped and V8 reads it in place, so its text never enters the V8 heap and is paged in and out by the OS. It costs more than `'copy'` for small files (about 25% at 4 KiB, even at 1 MiB), and **the file must not change while the module lives: V8 reads it lazily, so an edit can change code that compiles later, and truncating it crashes the process (`SIGBUS`)**. A file with a non-ASCII byte, an empty one, or one that goes through a transformer or a JS maker is copied as usual. An async grant is `Unsupported` when a handler names it: the io loop has no mapping operation.
- `json({ fs, missing? })`: `type: 'json'` imports, read through `fs`, as a module whose default export is the parsed value. `missing` is the same choice as in `fsProvider`, with the same default, `'abort'`.
- `fromLoader(loader)`: adapts a loader `loader(id, attributes)` (a string, `{ source }`, or a promise of either) to a hook; anything else rejects `InvalidData`.

### `cache`

- `ImportCache.native({ retain })`: `retain` is required. `'all'` keeps entries for the context's lifetime; `'used'` drops an entry once nothing holds it, so a later import evaluates the module again. There is no `entries` cap (passing one is `InvalidInput`): an identity table never evicts one module while others stay, so its bounds are `retain: 'used'`, `delete` and `clear`.
- `CodeCache.none`, `CodeCache.memory({ limits?: { size } })`, `CodeCache.dir({ fs, path })`, `CodeCache.custom({ load, store })`. A handler names its cache (`ImportHandler.make({ codeCache })`, default `CodeCache.none`) and a recipe may override it for its module (`ModuleRecipe({ codeCache })`; `CodeCache.none` turns it off for that module). `limits.size` is the most bytes of compiled code a `memory` cache keeps (unset: no cap; `0` keeps nothing); what does not fit is not stored. A `dir` cache takes no `limits` (`InvalidInput`). `dir` writes files named `<32 hex digits of BLAKE3(runtime, module kind, source text)>.v8-code-cache` directly in `path` (relative to the root of `fs`, a sync grant with write access; made on the first write; V8 trusts these files, so give `path` to no one who should not plant code); the module id is not in the name, so a virtual id such as `app:/x.js` or `https://...`, or one with `..`, stays inside `path`, and identical sources share a file; each file holds the hash of the source it was made from and is ignored for any other text. `cache.flush()` resolves how many modules the cache stored (it writes `dir` files, calls `custom.store`, `memory` keeps them); `cache.close()` ends the cache, and naming a closed cache is `InvalidInput`. `custom`: `key` is `{ id, hash }` with the lowercase hex BLAKE3 digest of the exact text V8 compiles (after every transformer); `store(key, blob)` runs at `flush()` with an opaque `Uint8Array` to keep whole (a `store` that throws is a miss for that module: the others are still stored and the count leaves it out); `load(key, source)` runs once a module's source is final and before it compiles, and returns the blob kept under that key or `undefined`. A blob made for another text, by another V8 build or with other flags, a throwing `load` and any other answer are misses, never errors.

### `api.graph` and `api.context`

- `api.graph` is a namespace: `api.graph.root` is the shared root graph (`declare`, `load`, `requests`, `evaluate`, `exports`, `release`; no `close`), and `api.graph.create()` makes a separate graph you own (`graph.close()` or `using`). It takes no options and holds no authority: files are read through the grants hooks and sources name (`fsProvider({ fs })`, `json({ fs })`, `ImportHook.accept({ fs })`, `ModuleSource.file(path, { fs })`), and code caches are named by handlers and recipes. An option is `InvalidInput`. `api.graph.root` has no `close`. `api.graph.declare` and the other direct methods do not exist.
- `graph.declare(recipe)` returns a `ModuleReference`, an inert ticket for an entry in that graph's table: read-only `name`, `status` (`declared`, `loaded`, `evaluating`, `evaluated`, `errored`) and `context` (the context it is bound to), nothing else; it has no methods and no `Symbol.dispose`, so holding one is not the power to run, read or free the module. The graph does that, and a reference belongs to one graph (`InvalidInput` for another graph's, another created graph's included; closing a created graph makes its references `StaleHandle`).
- `graph.load(reference)` (one level: it makes a `declared` reference per import, and loading those goes deeper; overlapping calls share one load), `graph.requests(reference)` (`undefined` until loaded; each `{ specifier, attributes, phase, reference }`), `graph.evaluate(reference, ctx)` (binds to one context, which must be made with this graph; evaluating in a second is `InvalidInput`), `graph.exports(reference)` (needs `evaluated`: the live module namespace of the context the reference is bound to, the same object every call; nothing is copied or frozen, so reading it crosses the realm boundary) and `graph.release(reference)` (unpins the module).
- `api.context.create({ import, graph, preload?, security? })` returns a `Context`: `import(specifier, { attributes? })` (a reference to the evaluated module), `references`, `graph`, `close()` / `Symbol.dispose`. `import` and `graph` are required (`graph` is `api.graph.root` or a graph made by `api.graph.create()`; a missing, forged or closed one is `InvalidInput` naming `graph`; there is no default). `preload` entries are `{ source, values }` or `{ module, values }`, run before anything is imported; `values` is deep-frozen plain data and functions only. A context gets no capability unless you pass one through `values`, and never sees the graph.
- `security: { codeGeneration? }` (default `false`): string-to-code (`eval`, `new Function`, the `AsyncFunction` / `GeneratorFunction` / `AsyncGeneratorFunction` constructors) is off in every realm and throws `EvalError: Code generation from strings disallowed for this context`. `codeGeneration: true` turns it on for that realm only. **CAUTION:** functions are shared across realms (links, `graph.exports`, `ImportHook.exports` values, preload `values`) and V8 checks the realm the constructor belongs to, so any function exported from a realm with this on lets its importers run arbitrary code in that realm (`Promise.resolve('return globalThis.secret').then(fn.constructor)`): it gives up the realm boundary. Do not enable it for a context whose functions reach less trusted code. An unknown key or a non-boolean is `InvalidInput`. `WebAssembly` is not affected.
- An `ImportCache` object is the name of a table of modules: `size`, `delete(id)` (the next import makes and evaluates a new module) and `clear()` are on the object, and count every context this realm created. Handlers made with the same object keep their modules in one table; two objects are two tables, also inside one context. **Contexts that use the same object share its modules**: the first to import an id evaluates it, the others link that module (live bindings, the same objects, it runs once; a context that asks meanwhile waits). That leaks the realm boundary on purpose (intrinsics, `fn.constructor` and mutation cross), so a cache shared with a less trusted context is a hole, and it hands a context what the home read with its own authority. `ImportHandler.make` makes its default cache once per handler, so two contexts created from one handler object share module instances; use a handler per context, or distinct `ImportCache` objects, to keep them apart. If the home context closes, the others drop what they linked from it and the next import evaluates a new module (the first to ask becomes the home).
