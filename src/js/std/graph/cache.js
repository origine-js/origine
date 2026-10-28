// `origine:@std/graph/cache`: the three caches of the graph, as descriptors the host builds natively.
//
//   ImportCache    (id, attributes) -> module. One native table per context, made from the descriptor
//                  (a V8 module belongs to a single context). `retain` says how long an entry lives.
//   ResolveCache   (referrer, specifier, attributes, phase) -> resolved id. Native memo.
//   CodeCache      (id, source hash) -> V8 code-cache bytes. Persistent or in memory.
//
// ImportCache and ResolveCache are consulted on every import and behind V8's synchronous link, so
// they cannot call back into JS. CodeCache is off that path and may be backed by JS (`custom`).
import { ERRNO } from 'origine:@std/errno';

const freeze = Object.freeze;
const invalid = message => freeze({ errno: ERRNO.io.InvalidInput, name: 'InvalidInput', message });
const own = (object, key) => {
  if (object === null || typeof object !== 'object') return undefined;
  const descriptor = Object.getOwnPropertyDescriptor(object, key);
  return descriptor !== undefined && 'value' in descriptor ? descriptor.value : undefined;
};

/// A count or byte capacity: a non-negative safe integer, or `undefined` for none.
const capacity = (what, name, value) => {
  if (value !== undefined && !(Number.isSafeInteger(value) && value >= 0)) throw invalid(`${what}: ${name} must be a non-negative integer`);
  return value;
};
const withCapacity = (host, kind, name, value, rest) => freeze({ host, kind, ...rest, ...(value === undefined ? {} : { [name]: value }) });

const TABLE = Symbol.for('origine:@std/graph/table');
/// The identity table of a context: `{ size, delete(id), clear() }`. `delete(id)` forgets the module
/// (and what imported it), so the next import of it makes and evaluates a new one, while the old one
/// keeps working; `clear()` forgets every module. All the handlers of a context share this one table.
function inContext(ctx) {
  const view = ctx?.[TABLE];
  if (typeof view !== 'function') throw invalid('ImportCache#in: expected a context');
  return view();
}

export const ImportCache = freeze({
  /// The native table. `retain` is required because it changes what re-importing does:
  /// `'all'` keeps every entry for the context's lifetime (module identity as in ESM);
  /// `'used'` drops an entry once no handle, dependent or live reference holds it, so a later import
  /// evaluates the module again. `entries` caps the table (readable as `size`/`entries` on the view).
  native(options) {
    const retain = own(options, 'retain');
    if (retain !== 'all' && retain !== 'used') throw invalid("ImportCache.native: retain must be 'all' or 'used'");
    const descriptor = withCapacity('importCache', 'cache', 'entries', capacity('ImportCache.native', 'entries', own(options, 'entries')), {
      retain,
    });
    return freeze({ ...descriptor, in: inContext });
  },
});

export const ResolveCache = freeze({
  /// The native memo of resolver results. `entries` caps it.
  native(options = {}) {
    return withCapacity('resolveCache', 'cache', 'entries', capacity('ResolveCache.native', 'entries', own(options, 'entries')), {});
  },
});

const none = freeze({ host: 'codeCacheNone', kind: 'codeCache' });

export const CodeCache = freeze({
  /// No code cache: every compile parses.
  none,
  /// Bytes kept in the graph's memory and shared by all of its contexts. `bytes` caps it.
  memory(options = {}) {
    return withCapacity('codeCacheMemory', 'codeCache', 'bytes', capacity('CodeCache.memory', 'bytes', own(options, 'bytes')), {});
  },
  /// Files in the directory `fs` (a grant of `api.fs` with write access) grants, one per module at
  /// `__oricache__/<16 hex digits of BLAKE3(module id)>.<engine tag>.v8-code-cache`: the id only picks the
  /// name, so a virtual id or one with `..` stays inside `__oricache__`. Each file holds the hash of the
  /// source it was made from and is ignored for any other text. Reads and
  /// writes touch the disk; writes happen at `graph.flush()`.
  dir(fs, options = {}) {
    if (fs === null || typeof fs !== 'object') throw invalid('CodeCache.dir: fs must be an fs grant');
    return withCapacity('codeCacheDir', 'codeCache', 'bytes', capacity('CodeCache.dir', 'bytes', own(options, 'bytes')), { fs });
  },
  /// Your own store, for modules the graph compiles. Both functions may be async and run in the
  /// creating realm.
  ///
  /// - `key` is `{ id, hash }`: the module id (its `name` for a root module) and the lowercase hex
  ///   BLAKE3 digest of the exact text V8 compiles, after every transformer, so a key identifies one
  ///   source text of one module.
  /// - `store(key, blob)` runs at `graph.flush()` for each module that compiled without a usable
  ///   cache. `blob` is an opaque `Uint8Array`: keep it whole and unchanged.
  /// - `load(key, source)` runs once the source of a module is final and before it compiles, with that
  ///   text. Return the blob kept under that same key, or `undefined`. A blob that was made for another
  ///   text, by another V8 build or with other flags, a rejection of `load`, or any other answer, is a
  ///   miss: the module compiles without a cache. Nothing here is an error.
  custom(options) {
    const load = own(options, 'load');
    const store = own(options, 'store');
    if (typeof load !== 'function' || typeof store !== 'function') throw invalid('CodeCache.custom: load and store must be functions');
    return freeze({ kind: 'codeCache', native: false, load, store });
  },
});
