// `origine:@std/graph/providers`: hooks that supply module content. The host ones are descriptors
// the graph runs natively, bounded by the grants they name (an fs grant, the `origine:` allowlist);
// a descriptor widens nothing by itself.
//
//   hooks: [policy, origineProvider({ std: { include: ['text'] } }), fsProvider({ fs, read: 'copy' })]
import * as h from 'origine:@internal/handles';
import { ERRNO } from 'origine:@std/errno';
import { IoError } from 'origine:@std/errors';
import { ImportHook, ImportError } from 'origine:@std/graph/import';
import { ModuleSource } from 'origine:@std/graph/module';

const freeze = Object.freeze;
const invalid = message => new IoError(ERRNO.io.InvalidInput, message);
const own = (object, key) => {
  if (object === null || typeof object !== 'object') return undefined;
  const descriptor = Object.getOwnPropertyDescriptor(object, key);
  return descriptor !== undefined && 'value' in descriptor ? descriptor.value : undefined;
};

/// The fs grant a file source or provider reads with: an object `api.fs` made (the graph checks it).
const checkFs = (what, fs) => {
  if (fs === null || typeof fs !== 'object') throw invalid(`${what}: fs must be an fs grant made by api.fs`);
  return fs;
};

/// What a file that is not in a provider's root does: `'abort'` unless the program chose.
const missingOf = (what, options) => {
  const missing = own(options, 'missing') ?? 'abort';
  if (missing !== 'skip' && missing !== 'abort') throw invalid(`${what}: missing must be 'skip' or 'abort'`);
  return missing;
};

const provider = (host, rest) => new h.Provider({ host, kind: 'provider', ...rest });

/// Names of std modules, without the `origine:@std/` prefix (`'text'`, `'transformer/oxc'`).
const names = (what, list) => {
  if (!Array.isArray(list)) throw invalid(`origineProvider: ${what} must be an array of names`);
  const copy = [];
  for (const name of list) {
    if (typeof name !== 'string' || name === '' || name.startsWith('origine:') || name.includes('..'))
      throw invalid(`origineProvider: bad std module name in ${what}`);
    if (!copy.includes(name)) copy.push(name);
  }
  return freeze(copy);
};

/// Serves `origine:@std/*` modules from the host, with their natives bound to the importing
/// context. With no options, or `std: true`, it serves every one the creating context itself may
/// import; `std: { include: [...] }` or `{ exclude: [...] }` (exactly one) names fewer. It can only
/// narrow what the creating context itself may import, whatever it asks for.
export const origineProvider = (options = {}) => {
  const std = own(options, 'std');
  if (std === undefined || std === true) return provider(h.HookHost.Origine, { std: freeze({ all: true }) });
  const include = own(std, 'include');
  const exclude = own(std, 'exclude');
  if ((include === undefined) === (exclude === undefined)) throw invalid('origineProvider: std needs exactly one of include and exclude');
  return provider(
    'origine',
    include === undefined
      ? { std: freeze({ exclude: names('exclude', exclude) }) }
      : { std: freeze({ include: names('include', include) }) },
  );
};

/// Reads source files through `fs`, a grant `api.fs` made (sync or async); an id is a path relative to its
/// root. The whole file is read: check its size in a hook of your own if it matters. `read` is required
/// because it has a cost: `'copy'` reads the file into memory; `'mmap'` is for large sources on a sync
/// grant: a file that is all ASCII is read in place by V8, and must not change while the module lives
/// (truncating it crashes the process). Any other file is copied; an async grant is `Unsupported`.
/// `missing` says what a file that is not in this root does: `'abort'` (the default) fails the import with
/// `NotFound`, `'skip'` passes to the next hook, so that several roots can be tried in order.
export const fsProvider = options => {
  const fs = checkFs('fsProvider', own(options, 'fs'));
  const read = own(options, 'read');
  if (read !== 'copy' && read !== 'mmap') throw invalid("fsProvider: read must be 'copy' or 'mmap'");
  return provider(h.HookHost.Fs, { fs, read, missing: missingOf('fsProvider', options) });
};

/// Serves `type: 'json'` imports as an ES module whose default export is the parsed value, read through
/// `fs`, a grant `api.fs` made. `missing` is the same choice as in `fsProvider`: `'abort'` (the default) or `'skip'`.
export const json = options => provider(h.HookHost.Json, { fs: checkFs('json', own(options, 'fs')), missing: missingOf('json', options) });

/// Adapts a loader function to a hook: `loader(id, attributes)` returns the source
/// text, `{ source }`, or a promise of either.
export const fromLoader = loader => {
  if (typeof loader !== 'function') throw invalid('fromLoader: expected a function');
  return async resolved => {
    const content = await loader(resolved.id, resolved.attributes);
    const text = typeof content === 'string' ? content : own(content, 'source');
    if (typeof text !== 'string') return ImportHook.reject(ImportError.InvalidData);
    return ImportHook.source(ModuleSource.text(text));
  };
};
