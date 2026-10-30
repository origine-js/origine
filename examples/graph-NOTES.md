# Module graph examples: notes

Seven examples of `api.graph` and `api.context`, one directory each. All seven were run with the
already built `zig-out/bin/origine` (built 2026-10-28 20:22; not rebuilt, the tree is being edited
elsewhere). Every run exited 0 and printed what each file's header says. The outputs are in the headers.

## How to run

From the repository root (`zig build run -- <init>` works too, but rebuilds):

- `graph-basic`: `zig-out/bin/origine examples/graph-basic/init.js`
- `graph-resolve`: `zig-out/bin/origine examples/graph-resolve/init.js`
- `graph-hooks`: `zig-out/bin/origine examples/graph-hooks/init.js`
- `graph-transform`: `zig-out/bin/origine examples/graph-transform/init.js`
- `graph-cache`: `zig-out/bin/origine examples/graph-cache/init.js` (writes `__codecache__/`, see friction 9)
- `graph-cross-context`: `zig-out/bin/origine examples/graph-cross-context/init.js`
- `graph-migrate-scope`: `zig-out/bin/origine examples/graph-migrate-scope/init.js`

## Friction

What felt awkward, verbose, surprising or inconsistent while writing the examples, most important first.

1. **A module's exports cannot be read from the host.** `ctx.import()` and `ModuleReference` have no
   namespace. A value leaves a module only as a side effect (a `print` function handed in through
   `preload` values), as a preload value, or as a hardened link into another context. For a judgement
   on the API shape this is the biggest gap.
2. **A print capability costs a preload in six of seven examples.** The line
   `preload: [{ source: '(values) => { globalThis.print = values.print; }', values: { print } }]` is
   repeated because `origine:@std/debug` needs `origine()` plus an `origineProvider` naming `debug` in
   the handler. The preload is the cheaper path, and it is not obvious from the types.
3. **The graph is passed twice.** `api.graph.derive({ fs })` and `api.context.create({ graph })`. Leaving
   the second one out gives no error at create time: the context uses the root `api.graph`, and the
   import then fails with `PermissionDenied` (probed in `graph-basic`).
4. **Errors lose their names and their subject.** A hook's `Import.reject(ImportError.PermissionDenied)`
   reaches the caller as `ModuleError: Error: PermissionDenied`. `ImportError.NotFound` shows up as
   `Error: FileNotFound`, which is the fs errno name, and an unmapped specifier as `Error: NotFound`.
   No message names the module id, so the caller has to know which import failed.
5. **An uncaught `ModuleError` ends the process as `MainFailed` / `[object Object]` /
   `reached unreachable code`, exit 134.** The message is lost. This is the shell's error print, but
   graph errors reach it first (it happened in `graph-migrate-scope` before I mapped the entry).
6. **Import maps cannot point at files.** `importMap` values and scope keys are virtual URLs against
   `app:/map.json`. `importMap({ imports: { greet: 'app:/greet.js' } })` with `fsProvider` gives
   `FileNotFound`, because `fsProvider` reads plain ids (`greet.js`). A bare `'greet.js'` value passes
   `ImportHandler.make` and then `api.context.create` fails with `InvalidInput` and no message. Import
   maps work for virtual modules served by `fromLoader`, and relative ids work for files. The docs say
   neither. I found the `app:/` base in `src/managed/import_map.zig`.
7. **`origineNamespace: true` has no spelling.** The closest is `origineProvider({ std: { exclude: [] } })`,
   which reads as a trick. The list form (`include: [...]`) is the one a migration should end with.
8. **The migrated entry point is a specifier, not a file.** The old `main` went through the loader. Now
   `ctx.import(main)` needs the specifier to resolve, so `graph-migrate-scope` maps `main` in the import
   map. Unmapped, it fails with `Error: NotFound`.
9. **The code cache directory is not what the docs say.** `CodeCache.dir` writes
   `examples/graph-cache/__codecache__/<32 hex digits>.v8-code-cache`. The name is a digest of the source
   text (`codeFileName` in `src/api/init_cache.zig`). `src/js/docs/graph.md`, `docs/graph-api.md` and
   `types/std/graph.d.ts` say `__oricache__/<16 hex digits of BLAKE3(id)>`. Also `.gitignore` covers
   `__oricache__/` only, so running `graph-cache` leaves an untracked directory.
10. **`load()` does not compile a dependency (bug).** `ModuleReference.load()` returns early when
    `state.recipe === null` (`src/js/glue/graph.js`, before `compileRequests`), and dependency references
    have no recipe. So `requests` stays `undefined` one level down. Observed: `legacy.load()` left
    `status` at `declared` and `requests` at `undefined`. `graph-api.md` (deviation 4) says a dependency is
    `declared` until `load()` is called on it, and that suggests the walk works. `graph-resolve` shows the
    scope through evaluation instead.
11. **A missing module is `InvalidData`, not `NotFound`.** `fromLoader` returns `InvalidData` when the
    loader gives `undefined` for an id. A migrated `loader: id => sources[id]` reports every unknown id
    as bad data (`graph-migrate-scope`).
12. **`ImportCache` is config and handle at once.** `cache.in(ctx)` is a method on the frozen descriptor,
    so the code has to keep the cache object it passed to `ImportHandler.make`. It works, but it reads
    oddly.
13. **`flush()` counts writes, not state.** It printed `1` on a fresh run and `0` on the next one (the
    file exists), and `1` every time for `CodeCache.memory()`, which dies with the process. The name
    suggests persistence, not "compiled without a usable cache this time".
14. **Docs and types disagree on status.** `types/std/graph.d.ts` has `'instantiated'` in
    `ModuleReferenceStatus`, while `docs/graph-api.md` says there is no separate `instantiated`. The
    header of `types/std/graph.d.ts` still says `api.graph` and `api.context` are "not implemented".
15. **Positive.** `handler.plan` made the cost visible at once (`graph-transform` shows the byExtension
    transformer as the only `js` stage in the maker). The hardened link matched the docs exactly (copies
    frozen in the importer, the exporter's own object unfrozen, a shared function changes the exporter).
    A failed `ctx.import()` leaves the context usable for the next one.

## Not done

- No `shared` link example: the task asked for `hardened`.
- No async fs grant example: every example uses `api.fs.requestSync`.
- `oxc` is not used (`graph-migrate-scope` keeps the old `transformers` shape with a JS function).
