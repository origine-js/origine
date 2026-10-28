// `origine:@std/graph/module`: what a module is made of. Pure data: building any of these confers no
// authority and reads nothing; the graph (`api.graph`, not implemented yet) reads sources with its
// own grants. Everything returned is frozen, so it is safe to build in the init snapshot.
//
//   const recipe = ModuleRecipe({
//     source: ModuleSource.file('./main.ts').withTransformer(ts()),
//     import: handler,                    // an ImportHandler: who answers this module's imports
//     name: 'main',                       // v8 ScriptOrigin resource name (default: the file path)
//   });
import { ERRNO } from 'origine:@std/errno';

const freeze = Object.freeze;
const invalid = message => freeze({ errno: ERRNO.io.InvalidInput, name: 'InvalidInput', message });
/// A data property of `object` (a getter or a missing property is `undefined`).
const own = (object, key) => {
  if (object === null || typeof object !== 'object') return undefined;
  const descriptor = Object.getOwnPropertyDescriptor(object, key);
  return descriptor !== undefined && 'value' in descriptor ? descriptor.value : undefined;
};

// Brands shared with the sibling modules through the symbol registry (no import cycle). They only
// tell the JS builders what they are holding; the native side validates again before trusting them.
const SOURCE = Symbol.for('origine:@std/graph/source');
const RECIPE = Symbol.for('origine:@std/graph/recipe');
const HANDLER = Symbol.for('origine:@std/graph/handler');

const isDescriptor = value =>
  value !== null && typeof value === 'object' && typeof value.host === 'string' && typeof value.kind === 'string';
/// A transformer is a function `(source, id) => string | { source, map } | Promise`, or a host
/// descriptor of kind `transformer` (run natively, see `Transform`).
const isTransformer = value => typeof value === 'function' || (isDescriptor(value) && value.kind === 'transformer');
/// Whether a descriptor or function runs without entering JS.
const isNative = value => typeof value !== 'function' && value?.native !== false;

/// `'evaluation'`, `'source'` or `'defer'`: which phase an import asks for (`import x`,
/// `import source x`, `import defer * as x`). Only `Evaluation` is implemented by the engine.
export const ModuleImportPhase = freeze({ Evaluation: 'evaluation', Source: 'source', Defer: 'defer' });

const mapOf = (kind, value) => freeze({ kind, value });
/// Where the source map of a module comes from. `None` is the default.
export const SourceMap = freeze({
  None: freeze({ kind: 'none' }),
  /// A map served from `url` (not fetched by the engine; carried for tools that read it).
  url(url) {
    if (typeof url !== 'string' || url === '') throw invalid('SourceMap.url: url must be a non-empty string');
    return mapOf('url', url);
  },
  /// A map given as JSON text.
  text(json) {
    if (typeof json !== 'string' || json === '') throw invalid('SourceMap.text: json must be a non-empty string');
    return mapOf('text', json);
  },
});
const isMap = value =>
  value !== null &&
  typeof value === 'object' &&
  (value.kind === 'none' || ((value.kind === 'url' || value.kind === 'text') && typeof value.value === 'string'));

class Source {
  constructor(kind, content, map, transformers) {
    this[SOURCE] = true;
    this.kind = kind;
    if (kind === 'file') this.path = content;
    else this.text = content;
    this.map = map;
    this.transformers = freeze(transformers);
    /// True when no transformer of the chain needs the JS realm.
    this.native = transformers.every(isNative);
    freeze(this);
  }

  /// A new source with `transformer` applied after the ones already chained. The receiver is unchanged.
  withTransformer(transformer) {
    if (!isTransformer(transformer)) throw invalid('withTransformer: expected a function or a transformer descriptor');
    return new Source(this.kind, this.kind === 'file' ? this.path : this.text, this.map, [...this.transformers, transformer]);
  }
}

const checkMap = (what, map) => {
  if (!isMap(map)) throw invalid(`${what}: map must be a SourceMap`);
  return map;
};

/// Module source text: a file the graph reads with its fs grant, or text given directly.
export const ModuleSource = freeze({
  /// A file at `path`, resolved by the graph's fs grant (relative to its root).
  file(path, map = SourceMap.None) {
    if (typeof path !== 'string' || path === '' || path.includes('\0'))
      throw invalid('ModuleSource.file: path must be a non-empty string without NUL');
    return new Source('file', path, checkMap('ModuleSource.file', map), []);
  },
  /// Source text held in memory. A recipe made from it needs a `name`.
  text(text, map = SourceMap.None) {
    if (typeof text !== 'string') throw invalid('ModuleSource.text: text must be a string');
    return new Source('text', text, checkMap('ModuleSource.text', map), []);
  },
  is: value => value?.[SOURCE] === true,
});

const make = options => {
  const source = own(options, 'source');
  if (source?.[SOURCE] !== true) throw invalid('ModuleRecipe: source must be a ModuleSource');
  const handler = own(options, 'import');
  if (handler?.[HANDLER] !== true) throw invalid('ModuleRecipe: import must be an ImportHandler');
  let name = own(options, 'name');
  if (name === undefined) {
    if (source.kind !== 'file') throw invalid('ModuleRecipe: name is required for a text source');
    name = source.path;
  } else if (typeof name !== 'string' || name === '') {
    throw invalid('ModuleRecipe: name must be a non-empty string');
  }
  const codeCache = own(options, 'codeCache');
  if (codeCache !== undefined && !(isDescriptor(codeCache) && codeCache.kind === 'codeCache'))
    throw invalid('ModuleRecipe: codeCache must be a CodeCache');
  return freeze({
    [RECIPE]: true,
    source,
    import: handler,
    name,
    /// `null`: use the graph's code cache.
    codeCache: codeCache ?? null,
    /// True when neither the source's transformers nor the import handler need the JS realm, which
    /// is what lets the recipe cross to another isolate as plain data.
    native: source.native && handler.native,
  });
};

/// An immutable description of a module: its source, the handler that answers its imports and its
/// name. Describing is free; the graph loads and compiles it.
export const ModuleRecipe = freeze(Object.assign(make, { is: value => value?.[RECIPE] === true }));
