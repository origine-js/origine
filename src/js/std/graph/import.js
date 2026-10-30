// `origine:@std/graph/import`: what happens to an import once it is resolved.
//
//   specifier --resolver--> id --hooks--> verdict --maker--> recipe options --cache--> module
//
// `hooks` answer "what does this id map to, is it allowed, who supplies it?": an ordered chain, the
// first verdict that is not `next` wins. `maker` answers "given the supplied source, which recipe
// options apply, and which handler governs its own imports?" and runs once. See docs/graph-api.md.
//
// Elements of the pipeline are JS descriptor instances from the
// sibling modules (run natively) or functions (run in the creating realm during the load stage).
// `ImportHandler.make` classifies them: `handler.plan` lists them in order and `handler.native` is
// true when no import of this handler needs the JS realm.
import { define, is as recordIs } from 'origine:@internal/records';
import { ERRNO } from 'origine:@std/errno';
import { IoError, ImportError } from 'origine:@std/errors';
import { ImportCache } from 'origine:@std/graph/cache';

const freeze = Object.freeze;
const invalid = message => new IoError(ERRNO.io.InvalidInput, message);
const own = (object, key) => {
  if (object === null || typeof object !== 'object') return undefined;
  const descriptor = Object.getOwnPropertyDescriptor(object, key);
  return descriptor !== undefined && 'value' in descriptor ? descriptor.value : undefined;
};

const isTransformer = value => typeof value === 'function' || recordIs(value, 'Transformer');

const CODES = freeze({
  NotFound: ERRNO.io.NotFound,
  PermissionDenied: ERRNO.io.PermissionDenied,
  InvalidInput: ERRNO.io.InvalidInput,
  InvalidData: ERRNO.io.InvalidData,
  Unsupported: ERRNO.io.Unsupported,
});
const NAMES = new Map([...Object.entries(CODES).map(([name, code]) => [code, name]), [ERRNO.host.Unexpected, 'Unexpected']]);

/// Why an import fails. The members are the `io` codes a pipeline can raise (the same numbers as
/// `IoError`); `other(message)` is the open case, for failures that have no better kind.
export { ImportError };

const verdict = define('ImportVerdict');
const transformRecord = define('Transformer');
const makerRecord = define('Maker');
const planRecord = define('PlanEntry');
const handlerRecord = define('ImportHandler');
const NEXT = verdict({ kind: 'next' });
const ACCEPT = verdict({ kind: 'accept' });

/// Verdicts a hook returns. All are immutable JS class instances.
export const Import = freeze({
  /// Not mine: continue with the next hook.
  next: () => NEXT,
  /// Stop the chain and use the default `maker` on whatever the pipeline supplies itself.
  accept: () => ACCEPT,
  /// Stop the chain with `target`: a `ModuleSource` (the `maker` turns it into a recipe) or a
  /// `ModuleRecipe` (final: the maker is skipped). The importing context gets its own module.
  provide(target) {
    if (recordIs(target, 'ModuleSource')) return verdict({ kind: 'provide', source: target });
    if (recordIs(target, 'ModuleRecipe')) return verdict({ kind: 'provide', recipe: target });
    throw invalid('Import.provide: expected a ModuleSource or a ModuleRecipe');
  },
  /// Stop the chain and use `reference`, a module already evaluated in some context, instead of a
  /// fresh copy. `mode` is required when that context is not the importer's. `'hardened'` links a
  /// synthetic module of its exports as a snapshot: plain data (primitives, arrays and objects with a
  /// plain prototype, cycles kept) is copied and the copies are frozen, so the exporting module's own
  /// objects stay as mutable as they were; a function, a class and any other object cannot be copied, so
  /// it is shared and frozen in place in its own realm with what it reaches (a class's statics and
  /// prototype chain); an accessor property is `Unsupported`. `'shared'` links the module itself (live
  /// bindings, same objects: it leaks the realm boundary, on purpose).
  link(reference, options) {
    if (reference === null || typeof reference !== 'object') throw invalid('Import.link: reference must be a ModuleReference');
    const mode = own(options, 'mode');
    if (mode !== 'hardened' && mode !== 'shared') throw invalid("Import.link: mode must be 'hardened' or 'shared'");
    return verdict({ kind: 'link', reference, mode });
  },
  /// Stop the chain with an error: a code of `ImportError` or the value of `ImportError.other(...)`.
  reject(error) {
    if (typeof error === 'number') {
      const name = NAMES.get(error);
      if (name === undefined || error === ERRNO.host.Unexpected) throw invalid('Import.reject: not an ImportError code');
      return verdict({ kind: 'reject', error: new ImportError(error) });
    }
    const code = own(error, 'errno');
    const message = own(error, 'message');
    if (code !== ERRNO.host.Unexpected || typeof message !== 'string')
      throw invalid('Import.reject: expected an ImportError code or ImportError.other(message)');
    return verdict({ kind: 'reject', error: new ImportError(code, message) });
  },
});

const extensionOk = extension =>
  typeof extension === 'string' &&
  extension.length > 1 &&
  extension[0] === '.' &&
  !/[\\/?#]/.test(extension) &&
  !extension.endsWith('.') &&
  !extension.includes('..');
const MAX_EXTENSIONS = 64;

/// Transformers for the `maker` and for `ModuleSource.withTransformer`.
export const Transform = freeze({
  /// Picks a transformer by the extension of the module id (`'.ts'`, starting with a dot; the longest
  /// suffix wins, so `.d.ts` beats `.ts`). A value is a function or a host transformer.
  byExtension(map) {
    if (map === null || typeof map !== 'object') throw invalid('Transform.byExtension: expected an object');
    const keys = Object.keys(map);
    if (keys.length > MAX_EXTENSIONS) throw invalid(`Transform.byExtension: at most ${MAX_EXTENSIONS} extensions`);
    const entries = [];
    let native = true;
    for (const extension of keys) {
      const transformer = own(map, extension);
      if (!extensionOk(extension)) throw invalid(`Transform.byExtension: bad extension ${JSON.stringify(extension)}`);
      if (!isTransformer(transformer)) throw invalid(`Transform.byExtension: ${extension} is not a transformer`);
      if (typeof transformer === 'function' || transformer.native === false) native = false;
      entries.push(freeze([extension, transformer]));
    }
    return transformRecord({ host: 'byExtension', kind: 'transformer', native, entries: freeze(entries) });
  },
});

const makerOptions = (what, options) => {
  const handler = own(options, 'import');
  const transformer = own(options, 'transformer');
  if (handler !== undefined && !recordIs(handler, 'ImportHandler')) throw invalid(`${what}: import must be an ImportHandler`);
  if (transformer !== undefined && !isTransformer(transformer)) throw invalid(`${what}: transformer must be a transformer`);
  return { handler, transformer };
};

/// The `maker` of a handler. It returns recipe options (`import`, `transformer`), never a recipe.
export const MakeRecipe = freeze({
  /// Native: the recipe inherits this handler for its own imports unless `import` names another one
  /// (for example a no-fs handler for code under `node_modules/`), and applies `transformer` to
  /// the source a hook supplied.
  inherit(options = {}) {
    const { handler, transformer } = makerOptions('MakeRecipe.inherit', options);
    return makerRecord({
      host: 'maker',
      kind: 'maker',
      ...(handler === undefined ? {} : { import: handler }),
      ...(transformer === undefined ? {} : { transformer }),
    });
  },
  /// Your own: `fn({ id, source }) => { import?, transformer? } | Promise<...>`, run in the creating
  /// realm for every supplied source.
  fn(fn) {
    if (typeof fn !== 'function') throw invalid('MakeRecipe.fn: expected a function');
    return makerRecord({ kind: 'maker', native: false, fn });
  },
});

/// One element of the plan: which stage it belongs to and whether it runs natively.
const planEntry = (stage, element) => {
  if (typeof element !== 'function' && typeof element.host === 'string' && element.native !== false)
    return planRecord({ stage, kind: 'native', name: element.host });
  return planRecord({ stage, kind: 'js' });
};

const asList = value => (Array.isArray(value) ? value : [value]);
const isHook = value => typeof value === 'function' || recordIs(value, 'Provider');

/// A recipe's import pipeline.
export const ImportHandler = freeze({
  /// Options: `resolver` (required, an `ImportResolver` with at least one layer), `hooks` (required: a
  /// function or provider, or an array of them; may be empty), `maker` (default `MakeRecipe.inherit()`),
  /// `cache` (default `ImportCache.native({ retain: 'all' })`), `meta` (optional
  /// `({ id }) => data`, called when a module is made; the plain-data result becomes its `import.meta`).
  make(options) {
    const resolver = own(options, 'resolver');
    if (!recordIs(resolver, 'ImportResolver') || resolver.layers.length === 0)
      throw invalid('ImportHandler.make: resolver must be an ImportResolver with at least one layer');
    const given = own(options, 'hooks');
    if (given === undefined) throw invalid('ImportHandler.make: hooks is required (an empty array resolves nothing)');
    const hooks = asList(given);
    for (const hook of hooks) if (!isHook(hook)) throw invalid('ImportHandler.make: a hook must be a function or a provider descriptor');
    const maker = own(options, 'maker') ?? MakeRecipe.inherit();
    if (!recordIs(maker, 'Maker')) throw invalid('ImportHandler.make: maker must come from MakeRecipe');
    const cache = own(options, 'cache') ?? ImportCache.native({ retain: 'all' });
    if (!recordIs(cache, 'Cache') || cache.host !== 'importCache') throw invalid('ImportHandler.make: cache must be an ImportCache');
    const meta = own(options, 'meta');
    if (meta !== undefined && typeof meta !== 'function') throw invalid('ImportHandler.make: meta must be a function');

    const plan = [];
    for (const layer of resolver.layers) plan.push(planEntry('resolver', layer));
    for (const hook of hooks) plan.push(planEntry('hooks', hook));
    plan.push(planEntry('maker', maker));
    if (maker.transformer !== undefined) plan.push(planEntry('transformer', maker.transformer));
    plan.push(planEntry('cache', cache));
    if (meta !== undefined) plan.push(planRecord({ stage: 'meta', kind: 'js' }));
    return handlerRecord({
      resolver,
      hooks: freeze([...hooks]),
      maker,
      cache,
      meta: meta ?? null,
      /// Every element in pipeline order, `{ stage, kind: 'native' | 'js', name? }`.
      plan: freeze(plan),
      /// True when no import of this handler enters the JS realm.
      native: plan.every(entry => entry.kind === 'native'),
    });
  },
  is: value => recordIs(value, 'ImportHandler'),
});
