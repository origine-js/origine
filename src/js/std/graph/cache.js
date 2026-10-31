// `origine:@std/graph/cache`: JS class descriptors for caches the host manages natively.
//
//   ImportCache    (id, attributes) -> module. One native table per context, made from the descriptor
//                  (a V8 module belongs to a single context). `retain` says how long an entry lives.
//   ResolveCache   (referrer, specifier, attributes, phase) -> resolved id. Native memo.
//   CodeCache      (id, source hash) -> V8 code-cache bytes. Persistent or in memory.
//
// ImportCache and ResolveCache are consulted on every import and behind V8's synchronous link, so
// they cannot call back into JS. CodeCache is off that path and may be backed by JS (`custom`).
import { define, internal } from 'origine:@internal/records';
import { ERRNO } from 'origine:@std/errno';
import { IoError } from 'origine:@std/errors';

const freeze = Object.freeze;
const invalid = message => new IoError(ERRNO.io.InvalidInput, message);
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
const makeCache = define('Cache');
const withCapacity = (host, kind, name, value, rest) =>
  makeCache({ host, kind, ...rest, ...(value === undefined ? {} : { [name]: value }) });

/// What reaches the host: `api.graph` (or `api.context`) publishes it in the realm's records module.
const ops = () => {
  const found = internal('graph/cache-ops');
  if (found === undefined) throw new IoError(ERRNO.io.Unsupported, 'ImportCache needs api.graph or api.context');
  return found;
};

export const ImportCache = freeze({
  /// A table of modules (id + attributes -> module), named by this object: handlers made with the same
  /// object keep their modules in the same table, handlers made with two objects keep two modules for
  /// one id, also inside one context. `retain` is required because it changes what re-importing does:
  /// `'all'` keeps every entry for the context's lifetime (module identity as in ESM); `'used'` drops an
  /// entry once no handle, dependent or live reference holds it, so a later import evaluates the module
  /// again. There is no `entries`: an identity table never evicts one module while others stay (a partly
  /// evicted table would hand out two instances of one id), so its only bounds are `retain: 'used'` and
  /// `delete`/`clear`. `size` counts the modules it holds, `delete(id)` forgets one (and
  /// what imported it) so the next import makes and evaluates a new module while the old one keeps
  /// working, and `clear()` forgets all of them.
  native(options) {
    const retain = own(options, 'retain');
    if (retain !== 'all' && retain !== 'used') throw invalid("ImportCache.native: retain must be 'all' or 'used'");
    if (own(options, 'entries') !== undefined)
      throw invalid("ImportCache.native: there is no entries cap, an identity table never evicts one module while others stay; bound it with retain: 'used' or delete/clear");
    const descriptor = withCapacity('importCache', 'cache', 'entries', undefined, { retain });
    const cache = makeCache({
      ...descriptor,
      get size() {
        return ops().size(cache);
      },
      delete(id) {
        if (typeof id !== 'string') throw invalid('ImportCache#delete: id must be a string');
        return ops().delete(cache, id);
      },
      clear() {
        return ops().clear(cache);
      },
    });
    return cache;
  },
});

export const ResolveCache = freeze({
  /// The native memo of resolver results. `entries` caps it.
  native(options = {}) {
    return withCapacity('resolveCache', 'cache', 'entries', capacity('ResolveCache.native', 'entries', own(options, 'entries')), {});
  },
});

const none = makeCache({ host: 'codeCacheNone', kind: 'codeCache' });

export const CodeCache = freeze({
  /// No code cache: every compile parses.
  none,
  /// Bytes kept in the graph's memory and shared by all of its contexts. `bytes` caps it.
  memory(options = {}) {
    return withCapacity('codeCacheMemory', 'codeCache', 'bytes', capacity('CodeCache.memory', 'bytes', own(options, 'bytes')), {});
  },
  /// Files in the directory `fs` (a grant of `api.fs` with write access) grants, one per distinct source
  /// text at `__codecache__/<32 hex digits of BLAKE3(runtime, module kind, source text)>.v8-code-cache`:
  /// the module id is not in the name, so a virtual id or one with `..` stays inside `__codecache__` and
  /// identical sources share a file. Each file holds the hash of the source it was made from and is
  /// ignored for any other text. Reads and writes touch the disk; writes happen at `graph.flush()`.
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
    return makeCache({ kind: 'codeCache', native: false, load, store });
  },
});
