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
