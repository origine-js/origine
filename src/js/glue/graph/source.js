// `api.graph` sources: reading and transforming module text, the `custom` code cache, copies of exports. Built by graph.js.
import { issuerOf, FsGrant, SourceKind } from '../handles.js';
import { CodeCacheKey, MetaRequest } from './data.js';
import { own, errors, shared } from '../util.js';
export default g => {
  const { native, take, host, named, invalid } = g;
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

  /// A grant `api.fs` made, checked by the host: `{ async, id, raw }` (`raw` is the host's own object, kept only
  /// for the sync natives). Anything else, a lookalike included, is `InvalidInput`.
  const grantOf = (fs, what) => {
    const raw = fs instanceof FsGrant ? issuerOf(fs) : undefined;
    if (raw === undefined) throw invalid(`${what}: fs must be a fs grant made by api.fs`);
    const [isAsync, id] = host(native.graph.grantRef, raw);
    if (isAsync === 1 && shared.fsAsync === undefined) throw invalid('async fs is not available');
    return { async: isAsync === 1, id, raw };
  };

  /// A file of the grant `fs` as text, whole: a sync grant is read by the host at once; an async one
  /// through its io runtime (open, read all, close: the natives of `api.fs.requestAsync`).
  const readText = async (fs, path) => {
    const grant = grantOf(fs, 'read');
    if (!grant.async) return host(native.graph.readSource, grant.raw, path);
    const ops = shared.fsAsync;
    const file = await ops.openFile(grant.id, 0, path, 0);
    try {
      const bytes = await ops.readAll(grant.id, file, Number.MAX_SAFE_INTEGER);
      return host(native.graph.utf8, bytes);
    } finally {
      await ops.close(grant.id, file).catch(() => {});
    }
  };

  /// The text of a `ModuleSource`: read through the grant it names or given, then its transformer chain.
  const sourceText = async (source, id) => {
    let text = source.kind === SourceKind.Text ? source.text : await readText(source.fs, source.path);
    for (const t of source.transformers) text = await applyTransformer(t, id, text);
    return text;
  };

  /// The `custom` code cache of each host cache, by id.
  const customCaches = new Map();

  /// Asks the `custom` code cache `cacheId` for the blob it kept for `id` compiled from `text` (`hash` is the
  /// lowercase hex BLAKE3 digest of `text`) and hands it to the host, which keeps it only if the hash
  /// inside it is `hash`. A cache that throws, or returns anything else, is a miss.
  const loadCache = async (cacheId, id, hash, text) => {
    const cache = customCaches.get(cacheId);
    if (cache === undefined) return;
    try {
      const blob = await cache.load(new CodeCacheKey({ id, hash }), text);
      if (blob instanceof Uint8Array) {
        native.context.cachePut(cacheId, id, hash, blob);
        take();
      }
    } catch {}
  };

  const metaOf = async (record, id) => {
    const metaFn = record.handler.meta;
    if (metaFn === null) return undefined;
    const data = await metaFn(new MetaRequest({ id }));
    if (data === null || typeof data !== 'object') throw named(InvalidData, 'meta must return an object');
    return JSON.stringify(data);
  };

  return { applyTransformer, customCaches, grantOf, loadCache, metaOf, readText, sourceText };
};
