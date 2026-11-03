// `api.graph` import handlers: the registry that flattens a handler to the host and frees it again. Built by graph.js.
import { HookHost, CodeCacheHost, CodeCacheKind, ImportHandler } from '../handles.js';
import { freeze } from '../util.js';
export default g => {
  const { native, take, host, invalid, grantOf, customCaches } = g;

  // ---- import handlers -------------------------------------------------------------------------

  /// handler object -> its record, and id -> record. The host frees a handler no live context reaches
  /// (when a context is freed); `register` then drops its record and makes a new one on the next use. So
  /// code that waits keeps the handler object, never an id, unless it pins the record (`pinned`).
  const handlers = new WeakMap();
  const byId = new Map();
  const prune = () => {
    for (const id of host(native.graph.handlersFreed)) {
      const record = byId.get(id);
      if (record === undefined) continue;
      byId.delete(id);
      if (handlers.get(record.handler) === record) handlers.delete(record.handler);
    }
  };
  /// Runs `fn` with the host keeping the handler of `record` (and what its maker names) alive.
  const pinned = async (record, fn) => {
    host(native.graph.handlerPin, record.id);
    try {
      return await fn();
    } finally {
      native.graph.handlerUnpin(record.id);
      take();
    }
  };

  const descriptorHost = value => value !== null && typeof value === 'object' && typeof value.host === 'string';
  /// The part of a transformer the host needs, as plain data: the oxc ones are descriptors that
  /// carry `{ host: 'oxc', transform, options }`; a function is a JS barrier, the `fns.length - 1`th
  /// of the handler's transformer functions (`fns` collects them, in the order the host numbers them).
  const transformerSpec = (t, fns) => {
    if (t === undefined || t === null) return null;
    if (typeof t === 'function') {
      fns.push(t);
      return { js: fns.length - 1 };
    }
    if (descriptorHost(t) && t.host === 'byExtension')
      return { host: 'byExtension', entries: t.entries.map(([extension, inner]) => [extension, transformerSpec(inner, fns)]) };
    if (descriptorHost(t)) return { host: t.host, transform: t.transform, options: t.options ?? null };
    throw invalid('not a transformer');
  };
  /// The host's table for an `ImportCache` object: made when a handler first names it, again if the host freed it
  /// (it goes with the last handler that names it).
  const cacheIds = new WeakMap();
  const cacheId = cache => {
    const known = cacheIds.get(cache);
    if (known !== undefined && host(native.graph.cacheAlive, known)) return known;
    const id = host(native.graph.cacheCreate, cache.retain === 'used' ? 1 : 0);
    cacheIds.set(cache, id);
    return id;
  };

  /// The host's `CodeCache` for a descriptor, made when a handler or recipe first names it. 0: none. A cache
  /// that was closed (or whose realm ended) cannot be named again.
  const codeCacheIds = new WeakMap();
  const codeCacheId = cache => {
    if (cache.host === CodeCacheHost.None) return 0;
    const known = codeCacheIds.get(cache);
    if (known !== undefined) {
      if (!host(native.graph.codeCacheAlive, known)) throw invalid('the CodeCache is closed');
      return known;
    }
    let grant;
    if (cache.host === CodeCacheHost.Dir) {
      grant = grantOf(cache.fs, 'CodeCache.dir');
      if (grant.async) throw invalid('CodeCache.dir needs a sync fs grant made by api.fs');
    }
    const kind = cache.native === false ? CodeCacheKind.Custom : cache.host === CodeCacheHost.Dir ? CodeCacheKind.Dir : CodeCacheKind.Memory;
    const id = host(native.graph.codeCacheCreate, kind, cache.limits?.size ?? Infinity, grant?.raw, cache.path ?? '');
    codeCacheIds.set(cache, id);
    if (kind === CodeCacheKind.Custom) customCaches.set(id, cache);
    return id;
  };
  /// What a recipe's `codeCache` says to the host: 0 unset (its handler's applies), `NO_CODE_CACHE` none.
  const NO_CODE_CACHE = 0xffffffff;
  const recipeCacheId = recipe => {
    const cache = recipe.codeCache;
    if (cache === null) return 0;
    return cache.host === CodeCacheHost.None ? NO_CODE_CACHE : codeCacheId(cache);
  };

  const flatten = handler => {
    const resolver = handler.resolver;
    const layers = [];
    const layerFns = [];
    for (const layer of resolver.layers) {
      if (typeof layer === 'function') {
        layers.push({ js: true });
        layerFns.push(layer);
      } else {
        layers.push(
          layer.host === 'importMap' ? { host: 'importMap', imports: layer.imports, scopes: layer.scopes } : { host: layer.host },
        );
        layerFns.push(null);
      }
    }
    const hooks = [];
    const hookFns = [];
    const hookHosts = [];
    const hookGrants = [];
    for (const hook of handler.hooks) {
      hookHosts.push(typeof hook === 'function' ? null : hook.host);
      hookGrants.push(typeof hook !== 'function' && (hook.host === HookHost.Fs || hook.host === HookHost.Json) ? grantOf(hook.fs, hook.host === HookHost.Fs ? 'fsProvider' : 'json') : null);
      if (typeof hook === 'function') {
        hooks.push({ js: true });
        hookFns.push(hook);
      } else {
        hooks.push(
          hook.host === HookHost.Origine
            ? { host: HookHost.Origine, std: hook.std }
            : hook.host === HookHost.Fs
              ? { host: HookHost.Fs, read: hook.read, missing: hook.missing, fs: { async: hookGrants.at(-1).async, id: hookGrants.at(-1).id } }
              : hook.host === HookHost.Json
                ? { host: HookHost.Json, missing: hook.missing, fs: { async: hookGrants.at(-1).async, id: hookGrants.at(-1).id } }
                : { host: hook.host },
        );
        hookFns.push(null);
      }
    }
    const maker = handler.maker;
    const transformerFns = [];
    let makerSpec;
    let makerImport = 0;
    if (typeof maker.fn === 'function') {
      makerSpec = { js: true };
    } else {
      if (maker.import !== undefined) makerImport = register(maker.import).id;
      makerSpec = { host: 'maker', import: makerImport, transformer: transformerSpec(maker.transformer, transformerFns) };
    }
    const spec = {
      layers,
      hooks,
      maker: makerSpec,
      cache: { id: cacheId(handler.cache) },
      codeCache: codeCacheId(handler.codeCache),
      meta: handler.meta !== null,
    };
    return { spec, layerFns, hookFns, hookHosts, hookGrants, transformerFns };
  };

  const register = handler => {
    if (!(handler instanceof ImportHandler)) throw invalid('expected an ImportHandler');
    prune();
    const known = handlers.get(handler);
    if (known !== undefined && byId.get(known.id) === known) return known;
    g.bindDriver();
    const { spec, layerFns, hookFns, hookHosts, hookGrants, transformerFns } = flatten(handler);
    const id = host(native.graph.handler, JSON.stringify(spec));
    const record = freeze({
      id,
      handler,
      layerFns,
      hookFns,
      hookHosts,
      hookGrants,
      transformerFns,
    });
    handlers.set(handler, record);
    byId.set(id, record);
    return record;
  };

  return { byId, cacheIds, codeCacheIds, codeCacheId, recipeCacheId, pinned, register };
};
