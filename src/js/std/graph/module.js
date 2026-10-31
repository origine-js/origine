// `origine:@std/graph/module`: what a module is made of. Pure data: building any of these confers no
// authority and reads nothing; a file source names the fs grant it is read with. JS descriptor
// instances are immutable and safe to build in the init snapshot.
//
//   const recipe = ModuleRecipe({
//     source: ModuleSource.file('./main.ts', { fs }).withTransformer(ts()),
//     import: handler,                    // an ImportHandler: who answers this module's imports
//     name: 'main',                       // v8 ScriptOrigin resource name (default: the file path)
//   });
import * as h from 'origine:@internal/handles';
import { ERRNO } from 'origine:@std/errno';
import { IoError } from 'origine:@std/errors';

const freeze = Object.freeze;
const invalid = message => new IoError(ERRNO.io.InvalidInput, message);
/// A data property of `object` (a getter or a missing property is `undefined`).
const own = (object, key) => {
  if (object === null || typeof object !== 'object') return undefined;
  const descriptor = Object.getOwnPropertyDescriptor(object, key);
  return descriptor !== undefined && 'value' in descriptor ? descriptor.value : undefined;
};

// Descriptor identity comes from the record kinds of `origine:@internal/records`. Their private-field
// checks reject copied fields, forged prototypes, and calls through a borrowed constructor.

/// A transformer is a function `(source, id) => string | { source, map } | Promise`, or a host
/// descriptor of kind `transformer` (run natively, see `Transform`).
const isTransformer = value => typeof value === 'function' || value instanceof h.Transformer;
/// Whether a descriptor or function runs without entering JS.
const isNative = value => typeof value !== 'function' && value?.native !== false;

/// `'evaluation'`, `'source'` or `'defer'`: which phase an import asks for (`import x`,
/// `import source x`, `import defer * as x`). Only `Evaluation` is implemented by the engine.
export const ModuleImportPhase = h.ModuleImportPhase;

const mapOf = (kind, value) => new h.SourceMap({ kind, value });
/// Where the source map of a module comes from. `None` is the default.
export const SourceMap = freeze({
  None: new h.SourceMap({ kind: h.SourceMapKind.None }),
  /// A map served from `url` (not fetched by the engine; carried for tools that read it).
  url(url) {
    if (typeof url !== 'string' || url === '') throw invalid('SourceMap.url: url must be a non-empty string');
    return mapOf(h.SourceMapKind.Url, url);
  },
  /// A map given as JSON text.
  text(json) {
    if (typeof json !== 'string' || json === '') throw invalid('SourceMap.text: json must be a non-empty string');
    return mapOf(h.SourceMapKind.Text, json);
  },
});
const isMap = value => value instanceof h.SourceMap;

class Source {
  constructor(kind, content, map, transformers, fs) {
    this.kind = kind;
    if (kind === h.SourceKind.File) {
      this.path = content;
      /// The grant `path` is read with (checked by the graph when it reads).
      this.fs = fs;
    } else this.text = content;
    this.map = map;
    this.transformers = freeze(transformers);
    /// True when no transformer of the chain needs the JS realm.
    this.native = transformers.every(isNative);
    return new h.ModuleSource({ ...this, withTransformer: Source.prototype.withTransformer });
  }

  /// A new source with `transformer` applied after the ones already chained. The receiver is unchanged.
  withTransformer(transformer) {
    if (!(this instanceof h.ModuleSource)) throw invalid('withTransformer: expected a ModuleSource receiver');
    if (!isTransformer(transformer)) throw invalid('withTransformer: expected a function or a transformer descriptor');
    return new Source(this.kind, this.kind === h.SourceKind.File ? this.path : this.text, this.map, [...this.transformers, transformer], this.fs);
  }
}

const checkMap = (what, map) => {
  if (!isMap(map)) throw invalid(`${what}: map must be a SourceMap`);
  return map;
};

/// The fs grant a file source or provider reads with: an object `api.fs` made (the graph checks it).
const checkFs = (what, fs) => {
  if (fs === null || typeof fs !== 'object') throw invalid(`${what}: fs must be an fs grant made by api.fs`);
  return fs;
};

/// Module source text: a file read through an fs grant, or text given directly.
export const ModuleSource = freeze({
  /// A file at `path`, relative to the root of `options.fs`, a grant `api.fs` made. The whole file is
  /// read when the graph loads it: check its size beforehand if it matters.
  file(path, options, map = SourceMap.None) {
    if (typeof path !== 'string' || path === '' || path.includes('\0'))
      throw invalid('ModuleSource.file: path must be a non-empty string without NUL');
    const fs = checkFs('ModuleSource.file', own(options, 'fs'));
    return new Source(h.SourceKind.File, path, checkMap('ModuleSource.file', map), [], fs);
  },
  /// Source text held in memory. A recipe made from it needs a `name`.
  text(text, map = SourceMap.None) {
    if (typeof text !== 'string') throw invalid('ModuleSource.text: text must be a string');
    return new Source(h.SourceKind.Text, text, checkMap('ModuleSource.text', map), []);
  },
  is: value => value instanceof h.ModuleSource,
});

const make = options => {
  const source = own(options, 'source');
  if (!(source instanceof h.ModuleSource)) throw invalid('ModuleRecipe: source must be a ModuleSource');
  const handler = own(options, 'import');
  if (!(handler instanceof h.ImportHandler)) throw invalid('ModuleRecipe: import must be an ImportHandler');
  let name = own(options, 'name');
  if (name === undefined) {
    if (source.kind !== h.SourceKind.File) throw invalid('ModuleRecipe: name is required for a text source');
    name = source.path;
  } else if (typeof name !== 'string' || name === '') {
    throw invalid('ModuleRecipe: name must be a non-empty string');
  }
  const codeCache = own(options, 'codeCache');
  if (codeCache !== undefined && !(codeCache instanceof h.Cache && codeCache.kind === 'codeCache'))
    throw invalid('ModuleRecipe: codeCache must be a CodeCache');
  const recipe = new h.ModuleRecipe({
    source,
    import: handler,
    name,
    /// `null`: the import handler's `codeCache` applies.
    codeCache: codeCache ?? null,
    /// True when neither the source's transformers nor the import handler need the JS realm, which
    /// lets the host run its pipeline without calling back into this realm.
    native: source.native && handler.native,
  });
  return recipe;
};

/// An immutable description of a module: its source, the handler that answers its imports and its
/// name. Construction allocates an immutable descriptor; the graph loads and compiles it.
export const ModuleRecipe = freeze(Object.assign(make, { is: value => value instanceof h.ModuleRecipe }));
