# `@origine/types`

TypeScript declarations for origine programs: the `main(api)` entry, every capability of `api`,
the `origine:@std/*` modules and a `tsconfig` preset. The runtime is neither Web nor Node, so
these types declare what origine really has and nothing else (no DOM, no `setTimeout`, no
`TextEncoder`). The API rules of [docs/api-guidelines.md](../docs/api-guidelines.md) apply to these
types too: a required option is a required property, a mode is a type, a name is the runtime's name.

TypeScript only **checks**. origine strips types with oxc, never type-checks and does no
type-directed emit; run `tsc` yourself.

## Use

The package is not published; point at the directory (a workspace, `file:` dependency or symlink as
`node_modules/@origine/types`). Then:

```jsonc
// tsconfig.json
{ "extends": "@origine/types/tsconfig.json", "include": ["src"] }
```

```ts
// init.ts
import type { Main } from '@origine/types';
import { fs } from 'origine:@std/fs';

export const main: Main = async api => {
  const rs = fs(api.fs.requestSync({ access: 'r' }));
  print(rs.read_to_string('README.md').length);
};
```

`main` may also be written `export async function main(api: Api)` (`import type { Api }`). A
JavaScript file gets the same checks with JSDoc: `/** @param {import('@origine/types').Api} api */`
and `"allowJs": true, "checkJs": true` (see `tests/tsconfig.examples.json`).

Run the check with `tsc -p .`. The repository pins TypeScript 7.0.2 (`just check-types`); the preset is checked with 7.0.2 and was also checked with 5.9.3 (it uses only options both accept, and `esnext.*` libs that exist in both). Older than 5.8 is unsupported (`erasableSyntaxOnly`).

For REPL code add the global `api`: `"types": ["@origine/types", "@origine/types/repl"]`.

Editors need no plugin: VS Code, Zed, Neovim (`ts_ls`/`vtsls`) and JetBrains read `tsconfig.json`
and the workspace's TypeScript. Use the workspace version (VS Code: *TypeScript: Select TypeScript
Version*) so the editor and `tsc` agree. Hover docs come from the JSDoc on every declaration.

## What is declared

| File | Declares |
| --- | --- |
| `api.d.ts` | `Api`, `BasicApi`, `Main` |
| `fs.d.ts` | `api.fs`: `FsCap`, `SyncFs`/`AsyncFs` grants and their raw operations, `Access` (`'r' \| 'w' \| 'rw'`, required) |
| `io.d.ts` | `api.io`: `IoCap`, `Io` (runtime handle: `run`, `sleep`, `timer`, ...) |
| `net.d.ts` | `api.net`: `Socket<'event'>`/`Socket<'pull'>`, `Server<M, S>`, `listen`/`connect` with required `mode`, `end(side)`, `queued`/`direct`, `toEvent()`/`toPull()` |
| `env.d.ts`, `scope.d.ts` | `api.env`, `api.scope` |
| `errors.d.ts` | `IoError` and `HostError`, the `{ errno, name }` values thrown or rejected (plain objects, not an `Error`), one per error domain |
| `generated/errno.d.ts` | **Generated** from `src/api/errno_codes.zig`: `IoErrnoTable`/`HostErrnoTable` (and their `*Name`, `*Code`), `ErrnoTable` |
| `std/*.d.ts` | `declare module` for `origine:@std/errno`, `io`, `fs`, `text`, `quansync`, `transformer/oxc` |
| `globals.d.ts`, `repl.d.ts` | the global `print`; the REPL's global `api` (opt in) |

Things the types cannot say (they are in the JSDoc): a handle consumed by `toEvent()`/`toPull()` is
still typed usable (it throws `BadHandle` at run time); the sync grant operations report failure
through `errno[0]` and return `undefined`, so `IoError.check(fs, value)` is the typed way to get the
value; `Temporal` and `console` exist in the context but are not declared (TypeScript 5.9 has no
`Temporal` types; V8's `console` is not connected to the terminal; use `print`).

## `tsconfig.json`, option by option

| Option | Why |
| --- | --- |
| `lib: ES2024, esnext.disposable, esnext.collection, esnext.array, esnext.iterator, esnext.promise, esnext.float16, esnext.error` | Probed in the bundled V8 15.8: ES2024 and `using`/`Symbol.dispose`/`DisposableStack`, Set methods, `Array.fromAsync`, iterator helpers, `Promise.try`, `Float16Array`, `Error.isError` all exist. Not listed: `esnext.sharedmemory` (`Atomics.pause`, not probed), `esnext.decorators`, `esnext.intl`. **No `DOM`**: the context has no `window`, `fetch`, `setTimeout`, `TextEncoder`, `structuredClone`, `queueMicrotask` or `WebAssembly`. |
| `target: ES2024`, `module: ESNext` | V8 runs the output as written; nothing is downleveled (oxc only strips types). |
| `types: ["@origine/types"]` | No ambient `@types/*` (a stray `@types/node` would declare `process`, `Buffer` and `setTimeout` that do not exist). Only this package is global. |
| `moduleResolution: bundler` | Programs import with explicit extensions (`./greeter.ts`) and `origine:` ids, as a bundler-style resolver expects. |
| `allowImportingTsExtensions` | The runtime loads `.ts` files by their real name, so `import './a.ts'` is the correct specifier. Needs `noEmit`. |
| `isolatedModules` | Each file is transformed alone (oxc has no type information). Rules out constructs whose emit needs other files, such as `const enum` across files and ambiguous re-exports of types. |
| `verbatimModuleSyntax` | oxc strips imports by syntax only, so the types must say which imports are types: `import type`. Otherwise an import kept at run time names a module that has no value. |
| `erasableSyntaxOnly` | Keeps the code to syntax that erasing types removes. (oxc does compile enums, namespaces and parameter properties; `examples/typescript` shows them. The flag keeps new code portable to other type-stripping runtimes.) |
| `strict` | Includes `useUnknownInCatchVariables`: a caught error is `unknown`, which is right, since an origine error is an `IoError` value, a `TypeError` or anything a handler threw; narrow with `IoError.is`. |
| `exactOptionalPropertyTypes` | `{ port: undefined }` is not `{}`. The option bags declare what the runtime accepts; `entries?: number` rejects an explicit `undefined`. |
| `noUncheckedIndexedAccess`, `noImplicitOverride`, `noFallthroughCasesInSwitch` | Ordinary hygiene: `chunk[i]` may be `undefined`. |
| `noEmit` | `tsc` only checks; there is nothing to emit. |

## Maintenance

* Hand-written, one source of truth: the `.d.ts` files. The `origine:@std/*` modules are plain
  ES modules with `///` comments, not JSDoc, and their types depend on the grant (`io.kind` decides
  whether an operation returns a value or a promise), which JSDoc generics from the sources cannot
  express without rewriting them. Emitting `.d.ts` with `tsc --allowJs --declaration` would give `any`
  for those methods and no hover docs, so the declarations are written by hand and *checked*:
  `scripts/check-surface.sh` fails when a name is public in the JS and missing here.
* Generated: `generated/errno.d.ts`, from the `IoErrno` and `HostErrno` enums (`just gen-contracts`; `just check-contracts`
  fails when it is stale; [docs/contracts.md](../docs/contracts.md), surface D).
* Tests: `tests/*.ts` are positive cases and `// @ts-expect-error` negatives (a missing `mode`,
  mixing event and pull methods, a missing `access`, a misspelled option, `end()` without a side,
  a wrong `send` argument); `tests/tsconfig.examples.json` checks `examples/` and `bench/`.
  `just check-types` runs all of it.
* Changing the API (a name, an option, a default): change the glue, the docs in `src/js/docs/`, and these
  declarations in the same change.
