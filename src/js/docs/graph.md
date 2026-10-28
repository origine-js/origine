# `origine:@std/graph/*`

Source: [std/graph/](../std/graph/). The data side of the module graph: frozen descriptions of modules, import pipelines and caches. **Nothing loads or evaluates a recipe yet**: `api.graph` and `api.context` are designed in [docs/graph-api.md](../../../docs/graph-api.md) and not implemented, and `api.scope` is unchanged. Everything here is authority-free, pure JS and snapshot-safe; a builder reads no file and calls no native.

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

Nothing here blocks, allocates natively, detaches or retains a host resource. The costs a call site cannot see are made options.

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
- Verdicts a hook returns (all frozen): `Import.next()`, `Import.accept()` (use the default maker), `Import.provide(source | recipe)` (a source goes through the maker, a recipe is final; the importer gets its own module), `Import.link(reference, { mode })` (use a module already evaluated in some context; `mode` is required: `'hardened'` links its exports through the hardener, `'shared'` links the module itself and leaks the realm boundary), `Import.reject(code | ImportError.other(message))`.
- `ImportError`: `NotFound`, `PermissionDenied`, `Unsupported`, `InvalidInput`, `InvalidData` (the `IoError` numbers), `other(message)` and `is(value, code)`.
- `MakeRecipe.inherit({ import?, transformer? })` (native: the made recipe inherits this handler unless `import` names another, and applies `transformer` to the supplied source) and `MakeRecipe.fn(({ id, source }) => options)` (yours, returns the same options, never a recipe).
- `Transform.byExtension({ '.ts': t, ... })`: the longest suffix wins (`.d.ts` over `.ts`); at most 64 extensions; an extension starts with `.` and has no `/ \ ? #`, no trailing dot and no `..`.

### `providers`

- `origineProvider({ std: { include } | { exclude } })`: serves `origine:@std/*` modules (names without the prefix, for example `'text'`, `'transformer/oxc'`). `std` is required and exactly one of `include`/`exclude`: there is no "everything" default. It can only narrow the creating context's own set.
- `fsProvider({ read })`: `read` is required, `'copy'` or `'mmap'`. `'mmap'` avoids a copy for ASCII/Latin-1 text, but a file changed while mapped changes under V8.
- `json()`: `type: 'json'` imports as a module whose default export is the parsed value.
- `fromLoader(loader)`: adapts the `loader(id, attributes)` of `api.scope.create` (a string, `{ source }`, or a promise of either) to a hook; anything else rejects `InvalidData`.

### `cache`

- `ImportCache.native({ retain, entries? })`: `retain` is required. `'all'` keeps entries for the context's lifetime; `'used'` drops an entry once nothing holds it, so a later import evaluates the module again. `entries` caps the table.
- `ResolveCache.native({ entries? })`.
- `CodeCache.none`, `CodeCache.memory({ bytes? })`, `CodeCache.dir(fs, { bytes? })` (the `__oricache__` format; touches the disk when used), `CodeCache.custom({ load, store })` (yours, may be async, run in the creating realm).
