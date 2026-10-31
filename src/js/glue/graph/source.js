// `api.graph` sources: reading and transforming module text, the `custom` code cache, copies of exports. Built by graph.js.
import { CodeCacheKey, MetaRequest } from './data.js';
import { own, errors, shared } from '../util.js';
export default g => {
  const { native, take, host, named } = g;
  const { Unsupported, InvalidData } = errors;

  // ---- sources and transformers -----------------------------------------------------------------

  /// A host transformer on its own, as the host's `transform` native takes it.
  const hostSpec = t => ({ host: t.host, transform: t.transform, options: t.options ?? null });

  /// `text` through transformer `t` (a function, a host transformer or a by-extension table).
  const applyTransformer = async (t, id, text) => {
    if (t === undefined || t === null) return text;
    if (typeof t === 'function') {
      const result = await t(text, id);
      const out = typeof result === 'string' ? result : own(result, 'source');
      if (typeof out !== 'string') throw named(InvalidData, 'a transformer must return a string or { source }');
      return out;
    }
    if (t.host === 'byExtension') {
      const path = id.split(/[?#]/)[0];
      let best = null;
      for (const entry of t.entries) {
        const extension = entry[0];
        if (path.length > extension.length && path.endsWith(extension) && (best === null || extension.length > best[0].length))
          best = entry;
      }
      return best === null ? text : applyTransformer(best[1], id, text);
    }
    return host(native.graph.transform, JSON.stringify(hostSpec(t)), id, text);
  };

  /// The fs grant of each graph by graph id: `{ kind: 'sync' | 'async', id }`, or absent.
  const graphFs = new Map();

  /// A file of the graph's fs grant as text. A sync grant is read by the host at once; an async
  /// one through its io runtime (open, read all, close: the natives of `api.fs.requestAsync`).
  const readText = async (graphId, path) => {
    const grant = graphFs.get(graphId);
    if (grant === undefined || grant.kind !== 'async') return host(native.graph.readSource, graphId, path);
    const limit = grant.limit;
    const ops = shared.fsAsync;
    const file = await ops.openFile(grant.id, 0, path, 0);
    try {
      // One byte more than the limit tells a file that is too large from one that just fits.
      const bytes = await ops.readAll(grant.id, file, limit + 1);
      if (bytes.length > limit) throw named(errors.FileTooLarge, `${path} is larger than ${limit} bytes`);
      return host(native.graph.utf8, bytes);
    } finally {
      await ops.close(grant.id, file).catch(() => {});
    }
  };

  /// The text of a `ModuleSource`: read through the graph's fs grant or given, then its transformer chain.
  const sourceText = async (source, graphId, id) => {
    let text = source.kind === 'text' ? source.text : await readText(graphId, source.path);
    for (const t of source.transformers) text = await applyTransformer(t, id, text);
    return text;
  };

  /// The `custom` code cache of each graph by graph id.
  const graphCache = new Map();

  /// Asks the graph's `custom` cache for the blob it kept for `id` compiled from `text` (`hash` is the
  /// lowercase hex BLAKE3 digest of `text`) and hands it to the host, which keeps it only if the hash
  /// inside it is `hash`. A cache that throws, or returns anything else, is a miss.
  const loadCache = async (graphId, id, hash, text) => {
    const cache = graphCache.get(graphId);
    if (cache === undefined) return;
    try {
      const blob = await cache.load(new CodeCacheKey({ id, hash }), text);
      if (blob instanceof Uint8Array) {
        native.context.cachePut(graphId, id, hash, blob);
        take();
      }
    } catch {}
  };

  /// A hardened link's view of a value another realm exported: plain data (primitives, arrays and
  /// objects whose prototype is a realm's `Object.prototype` or null, cycles kept) is copied, so the
  /// exporting module's own objects stay as mutable as they were; a function, a class and any other
  /// object cannot be copied and is shared (the host freezes it in place, with what it reaches).
  /// An accessor property is `Unsupported`.
  const copyData = (value, seen) => {
    if (value === null || (typeof value !== 'object' && typeof value !== 'function')) return value;
    if (typeof value === 'function') return value;
    const known = seen.get(value);
    if (known !== undefined) return known;
    const copyProperties = (from, to) => {
      for (const key of Object.keys(from)) {
        const descriptor = Object.getOwnPropertyDescriptor(from, key);
        if (!('value' in descriptor)) throw named(Unsupported, `a hardened link cannot copy the accessor ${JSON.stringify(key)}`);
        to[key] = copyData(descriptor.value, seen);
      }
      return to;
    };
    if (Array.isArray(value)) {
      const copy = [];
      seen.set(value, copy);
      return copyProperties(value, copy);
    }
    const prototype = Object.getPrototypeOf(value);
    if (prototype === null || Object.getPrototypeOf(prototype) === null) {
      const copy = prototype === null ? Object.create(null) : {};
      seen.set(value, copy);
      return copyProperties(value, copy);
    }
    return value;
  };


  const metaOf = async (record, id) => {
    const metaFn = record.handler.meta;
    if (metaFn === null) return undefined;
    const data = await metaFn(new MetaRequest({ id }));
    if (data === null || typeof data !== 'object') throw named(InvalidData, 'meta must return an object');
    return JSON.stringify(data);
  };

  return { applyTransformer, copyData, graphCache, graphFs, loadCache, metaOf, readText, sourceText };
};
