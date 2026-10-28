// `origine:@std/graph/providers`: hooks that supply module content. The host ones are descriptors
// the graph runs natively, bounded by its own grants (fs root, `origine:` allowlist); a descriptor
// widens nothing by itself.
//
//   hooks: [policy, origineProvider({ std: { include: ['text'] } }), fsProvider({ read: 'copy' })]
import { ERRNO } from 'origine:@std/errno';
import { Import, ImportError } from 'origine:@std/graph/import';
import { ModuleSource } from 'origine:@std/graph/module';

const freeze = Object.freeze;
const invalid = message => freeze({ errno: ERRNO.io.InvalidInput, name: 'InvalidInput', message });
const own = (object, key) => {
  if (object === null || typeof object !== 'object') return undefined;
  const descriptor = Object.getOwnPropertyDescriptor(object, key);
  return descriptor !== undefined && 'value' in descriptor ? descriptor.value : undefined;
};

const provider = (host, rest) => freeze({ host, kind: 'provider', ...rest });

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
/// context. `std` is required and says which ones: `{ include: [...] }` or `{ exclude: [...] }`
/// (exactly one). It can only narrow what the creating context itself may import.
export const origineProvider = options => {
  const std = own(options, 'std');
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

/// Reads source files with the graph's fs grant. `read` is required because it has a cost:
/// `'copy'` reads the file into memory; `'mmap'` maps it (no copy for ASCII/Latin-1 text, but a file
/// changed while mapped changes under V8).
export const fsProvider = options => {
  const read = own(options, 'read');
  if (read !== 'copy' && read !== 'mmap') throw invalid("fsProvider: read must be 'copy' or 'mmap'");
  return provider('fs', { read });
};

/// Serves `type: 'json'` imports as an ES module whose default export is the parsed value.
export const json = () => provider('json');

/// Adapts a loader function to a hook: `loader(id, attributes)` returns the source
/// text, `{ source }`, or a promise of either.
export const fromLoader = loader => {
  if (typeof loader !== 'function') throw invalid('fromLoader: expected a function');
  return async resolved => {
    const content = await loader(resolved.id, resolved.attributes);
    const text = typeof content === 'string' ? content : own(content, 'source');
    if (typeof text !== 'string') return Import.reject(ImportError.InvalidData);
    return Import.provide(ModuleSource.text(text));
  };
};
