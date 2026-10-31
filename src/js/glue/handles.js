// Realm-private classes that more than one module makes or checks. Glue imports this module; embedded
// std modules get the same instance as `origine:@internal/handles`. Guests can import neither. A class
// only one module uses is declared in that module, extending `Handle` or `Data` from here.
import { Handle, Data } from './handle.js';
import { seal } from './util.js';

export { Handle, Data, issuerOf } from './handle.js';
export { seal };

// Realm-private values one glue factory provides for the std modules that import this module.
// The first provision of a name stands; later ones are ignored.
const provisions = new Map();
export function provide(name, value) {
  if (!provisions.has(name)) provisions.set(name, value);
}
export const provided = name => provisions.get(name);

// Enum-like values the glue and the std modules share. Compare with these, never with a string literal.
const freezeAll = Object.freeze;
/// `ModuleReference.status`: the V8 module states.
export const ModuleStatus = freezeAll({
  Declared: 'declared',
  Loaded: 'loaded',
  Instantiated: 'instantiated',
  Evaluating: 'evaluating',
  Evaluated: 'evaluated',
  Errored: 'errored',
});
/// `ImportVerdict.kind`: what a hook answered through `ImportHook.*`.
export const VerdictKind = freezeAll({
  Next: 'next',
  Accept: 'accept',
  Source: 'source',
  Recipe: 'recipe',
  Link: 'link',
  Exports: 'exports',
  Reject: 'reject',
});
/// `PipelineResult.kind`: the data the host reads from a hook's answer (the same strings as `src/api/context.zig`).
export const PipelineKind = freezeAll({
  Next: 'next',
  Accept: 'accept',
  Provide: 'provide',
  Final: 'final',
  Link: 'link',
  Exports: 'exports',
  Source: 'source',
});
/// `Cache.host` of a code cache descriptor.
export const CodeCacheHost = freezeAll({ None: 'codeCacheNone', Memory: 'codeCacheMemory', Dir: 'codeCacheDir' });
/// `CodeCacheCreate` kinds the host numbers (`CodeCacheKind` in `src/api/graph.zig`).
export const CodeCacheKind = freezeAll({ Memory: 0, Dir: 1, Custom: 2 });
/// Which phase an import asks for (`import x`, `import source x`, `import defer * as x`). Only `Evaluation` is implemented.
export const ModuleImportPhase = freezeAll({ Evaluation: 'evaluation', Source: 'source', Defer: 'defer' });
/// `SourceMap.kind`.
export const SourceMapKind = freezeAll({ None: 'none', Url: 'url', Text: 'text' });
/// `ModuleSource.kind`.
export const SourceKind = freezeAll({ File: 'file', Text: 'text' });
/// `Provider.host` of the host's own hooks (the names `parseHandler` in `src/api/graph.zig` reads).
export const HookHost = freezeAll({ Origine: 'origine', Fs: 'fs', Json: 'json' });
/// How a handler's native steps read files: `Sync` ones are read by the host at once, `Async` ones need this realm's loop.
export const ReadMode = freezeAll({ Sync: 'sync', Async: 'async' });

// A file or directory of one fs grant: `fs` is the grant's id, `id` the resource inside it. `fs` 0, `id` 0
// is the sentinel each grant resolves to its own root.
export class FileHandle extends Handle {
  constructor(fs, id, issuer) {
    super(issuer);
    this.kind = 'file';
    this.fs = fs;
    this.id = id;
    return seal(this);
  }
  static {
    seal(this);
  }
}
export class DirHandle extends Handle {
  constructor(fs, id, issuer) {
    super(issuer);
    this.kind = 'dir';
    this.fs = fs;
    this.id = id;
    return seal(this);
  }
  static {
    seal(this);
  }
}

// An fs grant: its issuer is the native grant behind it, which only `issuerOf` of the real object reaches,
// so a copy, a proxy or an object inheriting from a grant is not one.
export class FsGrant extends Handle {
  constructor(fields, granted) {
    super(granted);
    Object.defineProperties(this, Object.getOwnPropertyDescriptors(fields));
    return seal(this);
  }
  static {
    seal(this);
  }
}
export class Registration extends Data {}
export class SourceMap extends Data {}
export class Cache extends Data {}
export class ModuleSource extends Data {}
export class ModuleRecipe extends Data {}
export class ImportHandler extends Data {}
export class ImportVerdict extends Data {}
export class ImportResolver extends Data {}
export class ResolveLayer extends Data {}
export class Provider extends Data {}
export class Transformer extends Data {}
seal(Registration, SourceMap, Cache, ModuleSource, ModuleRecipe, ImportHandler, ImportVerdict, ImportResolver, ResolveLayer, Provider, Transformer);
