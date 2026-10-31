# Module graph examples: notes

Seven examples of `api.graph` and `api.context`, one directory each. They were written against the first
build of the graph API and run again on `a29f7df`: all seven exit 0 and print what each header says.
This file is what is left of the friction list the first run produced.

## How to run

From the repository root (an example's own directory is not the working directory it expects):

- `graph-basic`: `zig-out/bin/origine examples/graph-basic/init.js`
- `graph-resolve`: `zig-out/bin/origine examples/graph-resolve/init.js`
- `graph-hooks`: `zig-out/bin/origine examples/graph-hooks/init.js`
- `graph-transform`: `zig-out/bin/origine examples/graph-transform/init.js`
- `graph-cache`: `zig-out/bin/origine examples/graph-cache/init.js` (writes `__codecache__/`, git-ignored)
- `graph-cross-context`: `zig-out/bin/origine examples/graph-cross-context/init.js`
- `graph-migrate-scope`: `zig-out/bin/origine examples/graph-migrate-scope/init.js`

## Solved

- **Errors lose their names and their subject (was 4):** a failed import is a `ModuleError` whose `errno` is the kind of its
  cause (a hook's `PermissionDenied`, a missing file `NotFound`), with `subject` (the specifier) and `cause`; sync and async fs
  errors carry `subject` (the path) and, from async, `os`. See `src/js/docs/errno.md`.
- **An uncaught `ModuleError` printed `[object Object]` (was 5):** it is a real `Error` now and prints its message and stack.
- **A module's exports can be read from the host:** `graph.exports(ref)` is the live namespace.
- **The graph is passed twice:** `api.context.create` requires `graph`, with no default, and rejects a missing one
  with `InvalidInput`.
- **`origineNamespace: true` had no spelling:** `origineProvider()` and `origineProvider({ std: true })` serve every
  `origine:@std/*` the creating context has.
- **`load()` skipped dependencies:** fixed; a dependency reference loads like any other.
- **The code cache directory did not match the docs:** the docs and types now say `__codecache__/<32 hex>.v8-code-cache`,
  and `.gitignore` covers it.
- **Docs and types disagreed on status and said the API was not implemented:** `instantiated` is a real status
  (reported while a bound module links), and the header of `types/std/graph.d.ts` no longer says "not implemented".
- **The `app:/map.json` base of import maps was undocumented:** it is now in `src/js/docs/graph.md`.

## Open by decision

- **`NotFound` of a missing file in an uncaught import still ends the process with `reached unreachable code`, exit 134,
  after printing the error.** The message and kind are printed now (`ModuleError: ./zzz.js: NotFound`); the
  trailing `unreachable` is the shell's `MainFailed` path. Deferred.
- **`ModuleError` names the failing module and its immediate importer, not the whole chain.** Entries are shared between
  importers, so a path from the root is not one thing; the root is what the caller asked for.

## Open, undecided

- **Import maps cannot point at files.** Values are virtual URLs, so `importMap({ imports: { greet: 'app:/greet.js' } })`
  with `fsProvider` gives `FileNotFound` (`fsProvider` reads plain ids). Import maps fit virtual modules served by
  `fromLoader`; relative ids fit files.
- **A print capability costs a preload in six of seven examples.** `origine:@std/debug` needs `origine()` plus an
  `origineProvider` naming `debug`; the preload is the cheaper path and nothing in the types says so.
- **The migrated entry point is a specifier, not a file.** `ctx.import(main)` needs the specifier to resolve, so
  `graph-migrate-scope` maps `main` in the import map. Unmapped it fails with `NotFound`.
- **A missing module is `InvalidData`, not `NotFound`.** `fromLoader` rejects `InvalidData` when the loader returns
  `undefined`, so a migrated `loader: id => sources[id]` reports every unknown id as bad data.
- **`ImportCache` is config and handle at once.** `cache.in(ctx)` is a method on the frozen descriptor, so code
  keeps the cache object it passed to `ImportHandler.make`.
- **`flush()` counts writes, not state.** It resolves `1` on a fresh run and `0` on the next (the file exists),
  and `1` every time for `CodeCache.memory()`. The name suggests persistence.

## Not covered by the examples

- No async fs grant: every example uses `api.fs.requestSync`.
- `oxc` is not used (`graph-migrate-scope` keeps the old `transformers` shape with a JS function).
