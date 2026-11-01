// `origine:@std/graph/cache`: JS class descriptors for caches the host manages natively.
//
//   ImportCache    (id, attributes) -> module. One native table per context, made from the descriptor
//                  (a V8 module belongs to a single context). `retain` says how long an entry lives.
//   CodeCache      (id, source hash) -> V8 code-cache bytes. Persistent or in memory. A handler (or a
//                  recipe) names it; it has `flush()`.
//
// ImportCache is consulted on every import and behind V8's synchronous link, so it cannot call back
// into JS. CodeCache is off that path and may be backed by JS (`custom`).
import * as h from 'origine:@internal/handles';
import { ERRNO } from 'origine:@std/errno';
import { IoError } from 'origine:@std/errors';

const freeze = Object.freeze;
const invalid = message => new IoError(ERRNO.io.InvalidInput, message);
const own = (object, key) => {
  if (object === null || typeof object !== 'object') return undefined;
  const descriptor = Object.getOwnPropertyDescriptor(object, key);
  return descriptor !== undefined && 'value' in descriptor ? descriptor.value : undefined;
};

/// A byte capacity: a non-negative safe integer, or `undefined` for none.
const capacity = (what, name, value) => {
  if (value !== undefined && !(Number.isSafeInteger(value) && value >= 0)) throw invalid(`${what}: ${name} must be a non-negative integer`);
  return value;
};

/// What reaches the host: `api.graph` (or `api.context`) publishes it in the realm's records module.
const ops = () => {
  const found = h.provided('graph/cache-ops');
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
    const cache = new h.Cache({
      host: 'importCache',
      kind: 'cache',
      retain,
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

/// A code cache: the descriptor, plus the operations on the cache the host keeps for it.
const codeCache = fields => {
  const cache = new h.Cache({
    kind: 'codeCache',
    ...fields,
    /// Persists the code of the modules (made with this cache) that compiled without a usable cache and resolves
    /// how many were stored. A `memory` cache keeps them in memory, a `dir` cache writes its files, a
    /// `custom` cache calls its `store`.
    flush() {
      return ops().flush(cache);
    },
    /// Ends the cache: it stores and serves nothing from now on, and what it held is freed.
    close() {
      return ops().close(cache);
    },
  });
  return cache;
};

/// `limits.size`, the most bytes of compiled code a cache keeps (a non-negative integer, `undefined` for no cap, `0` keeps nothing).
const limitsOf = (what, options) => {
  const limits = own(options, 'limits');
  if (limits !== undefined && (limits === null || typeof limits !== 'object')) throw invalid(`${what}: limits must be an object`);
  return freeze({ size: capacity(what, 'limits.size', own(limits, 'size')) });
};

export const CodeCache = freeze({
  /// No code cache: every compile parses.
  none: new h.Cache({ host: h.CodeCacheHost.None, kind: 'codeCache', flush: () => Promise.resolve(0), close: () => {} }),
  /// Bytes kept in memory and shared by every module made with this cache. `limits.size` caps them.
  memory(options = {}) {
    return codeCache({ host: h.CodeCacheHost.Memory, limits: limitsOf('CodeCache.memory', options) });
  },
  /// Files in the directory `path` (relative to the root of `fs`, a sync grant of `api.fs` with write
  /// access) one per distinct source text, named
  /// `<32 hex digits of BLAKE3(runtime, module kind, source text)>.v8-code-cache`: the module id is not in the name, so a
  /// virtual id or one with `..` stays inside the directory and identical sources share a file. The files sit
  /// directly in `path`; the directory is made on the first write. Each file holds the hash of the source it was
  /// made from and is ignored for any other text. Reads and writes touch the disk; writes happen at `flush()`.
  /// V8 trusts these files: give `path` to no one who should not plant code.
  dir(options) {
    const fs = own(options, 'fs');
    if (fs === null || typeof fs !== 'object') throw invalid('CodeCache.dir: fs must be an fs grant made by api.fs');
    const path = own(options, 'path');
    if (typeof path !== 'string' || path === '' || path.includes('\0')) throw invalid('CodeCache.dir: path must be a non-empty string without NUL');
    if (own(options, 'limits') !== undefined) throw invalid('CodeCache.dir: limits applies to a memory cache');
    return codeCache({ host: h.CodeCacheHost.Dir, fs, path });
  },
  /// Your own store, for modules made with this cache. Both functions may be async and run in the
  /// creating realm.
  ///
  /// - `key` is `{ id, hash }`: the module id (its `name` for a root module) and the lowercase hex
  ///   BLAKE3 digest of the exact text V8 compiles, after every transformer, so a key identifies one
  ///   source text of one module.
  /// - `store(key, blob)` runs at `flush()` for each module that compiled without a usable
  ///   cache. `blob` is an opaque `Uint8Array`: keep it whole and unchanged. One that throws is a miss
  ///   for that module: the others are still stored and `flush` does not count it.
  /// - `load(key, source)` runs once the source of a module is final and before it compiles, with that
  ///   text. Return the blob kept under that same key, or `undefined`. A blob that was made for another
  ///   text, by another V8 build or with other flags, a rejection of `load`, or any other answer, is a
  ///   miss: the module compiles without a cache. Nothing here is an error.
  custom(options) {
    const load = own(options, 'load');
    const store = own(options, 'store');
    if (typeof load !== 'function' || typeof store !== 'function') throw invalid('CodeCache.custom: load and store must be functions');
    return codeCache({ native: false, load, store });
  },
});
