// `api.graph` module references (`graph.declare(recipe)`) and the cache operations of `ImportCache`. Built by graph.js.
import { ModuleStatus, provide } from '../handles.js';
import { CodeCacheKey, ModuleRequest } from './data.js';
import { freeze, errors, moduleSettled } from '../util.js';
export default g => {
  const { native, take, takeError, host, named, invalid } = g;
  const { cacheIds, codeCacheId, codeCacheIds, contextRefs, contexts, customCaches, loadCache, metaOf, pipeline, recipeCacheId, referenceState, refsById, register, sourceText } = g;

  // ---- references -------------------------------------------------------------------------------

  /// An inert ticket for an entry in a graph's table (a Deno-style module id): it names a module and shows
  /// its `name`, `status` and `context`, and can do nothing. The graph that declared it loads, runs,
  /// reads and frees it (`graph.load(reference)` ...); the operations below are the graph's.
  class ModuleReference {
    #state;
    constructor(state) {
      this.#state = state;
      referenceState.set(this, state);
      freeze(this);
    }
    get name() {
      return this.#state.name;
    }
    /// `declared`, `loaded`, `evaluating` (linking included), `evaluated` or `errored`.
    get status() {
      return this.#state.status;
    }
    /// The context the reference is bound to, `undefined` while it is not.
    get context() {
      return this.#state.context === null ? undefined : this.#state.contextObject;
    }
  }

  /// Reads, transforms and compiles the module and makes a `declared` reference for each of its imports
  /// (one level: load those to go deeper). A reference found as a dependency has its source
  /// already, so it loads the same way. Calls that overlap share one load.
  const loadRef = reference => {
    const state = referenceState.get(reference);
    if (state.released) return Promise.reject(named(errors.BadHandle, 'released'));
    if (state.status !== ModuleStatus.Declared) return Promise.resolve(reference);
    state.loading ??= loadState(reference, state).finally(() => {
      state.loading = undefined;
    });
    return state.loading;
  };
  const loadState = async (reference, state) => {
    await ensureText(state);
    // A module with no source text of its own (nothing was read for it) imports nothing.
    if (state.text === undefined) {
      state.requests = freeze([]);
      state.status = ModuleStatus.Loaded;
      return reference;
    }
    const requests = host(native.graph.compileRequests, state.text, state.name);
    const out = [];
    for (const [specifier, attributes, phase] of requests) {
      const answer = await pipeline(state.handler, specifier, state.name, attributes);
      let dependency;
      if (answer.answer.kind === 'link') {
        for (const candidate of refsById.get(answer.answer.context) ?? []) {
          if (candidate.name === answer.answer.name) dependency = candidate;
        }
      } else {
        const { source, handler, codeCache = 0 } = answer.answer;
        dependency = makeReference(state.graph, null, { name: answer.id, text: source, handler, status: ModuleStatus.Declared, codeCache });
      }
      out.push(new ModuleRequest({ specifier, attributes: freeze({ ...attributes }), phase, reference: dependency }));
    }
    state.requests = freeze(out);
    state.status = ModuleStatus.Loaded;
    return reference;
  };

  /// The imports of a loaded reference, `undefined` until it is `loaded`.
  const requestsOf = reference => referenceState.get(reference).requests;

  /// The live namespace of the module, in the context it is bound to (`status` must be `evaluated`): no copy,
  /// no freezing, every export type, bindings that follow the module. It is the other realm's own object, so
  /// reading it crosses the realm boundary; `snapshot` and `seal` of `origine:@std/...` hand over data instead.
  const exportsOf = reference => {
    const state = referenceState.get(reference);
    if (state.released) throw named(errors.BadHandle, 'released');
    if (state.status !== ModuleStatus.Evaluated || state.context === null) throw invalid('exports needs a reference that is evaluated in a context');
    return host(native.context.namespaceOf, state.context, state.name);
  };

  /// Binds the reference to `ctx` (one context per reference) and evaluates it there. Another call
  /// for the same context waits for the first one and settles the same way.
  const evaluateRef = (reference, ctx) => {
    const state = referenceState.get(reference);
    if (state.released) return Promise.reject(named(errors.BadHandle, 'released'));
    const contextId = contexts.get(ctx);
    if (contextId === undefined) return Promise.reject(invalid('evaluate: expected a context'));
    if (state.context !== null && state.context !== contextId) return Promise.reject(invalid('this reference is bound to another context'));
    if (state.evaluation !== undefined) return state.evaluation;
    state.context = contextId;
    state.contextObject = ctx;
    contextRefs.get(ctx)?.add(reference);
    state.status = ModuleStatus.Evaluating;
    state.evaluation = (async () => {
      try {
        await ensureText(state);
        const meta = state.meta ?? (await metaOf(register(state.handler), state.name));
        // The recipe's code cache wins over the handler's (`NO_CODE_CACHE`: none, whatever the handler says).
        const cacheId = state.codeCache === 0 ? codeCacheId(state.handler.codeCache) : state.codeCache === 0xffffffff ? 0 : state.codeCache;
        if (customCaches.has(cacheId)) await loadCache(cacheId, state.name, host(native.graph.sourceHash, state.text), state.text);
        // A synchronous failure is in the cell as the call returns; read it before awaiting anything.
        const evaluating = native.context.evaluateSource(contextId, state.name, state.text, register(state.handler).id, meta ?? '', state.codeCache);
        const failed = takeError();
        if (failed !== undefined) throw failed;
        await moduleSettled(evaluating);
        // Released while it ran: nothing will ever give a pin back.
        if (!state.released) state.pin = host(native.context.pin, contextId, state.name);
        state.status = ModuleStatus.Evaluated;
      } catch (error) {
        state.status = ModuleStatus.Errored;
        contextRefs.get(ctx)?.delete(reference);
        state.context = null;
        state.contextObject = undefined;
        state.evaluation = undefined;
        throw error;
      }
    })();
    return state.evaluation;
  };

  /// Lets the host free what the reference pins; the reference is unusable afterwards. With
  /// `retain: 'used'` the module is freed once nothing else holds it.
  const releaseRef = reference => {
    const state = referenceState.get(reference);
    if (state.released) return;
    state.released = true;
    if (state.contextObject !== undefined) contextRefs.get(state.contextObject)?.delete(reference);
    if (state.pin !== 0 && state.context !== null) {
      native.context.unpin(state.context, state.pin);
      take();
    }
    state.pin = 0;
  };

  // `ImportCache#size`, `delete` and `clear` (origine:@std/graph/cache) reach the host through this one object:
  // std cache descriptors hold private JS identity but no graph authority. They act on the contexts this realm created. A reference
  // to a module the cache forgot leaves `context.references`; it stays a usable handle of the old module.
  const forgetRefs = (cache, moduleId) => {
    const id = cacheIds.get(cache);
    for (const refs of refsById.values()) {
      for (const known of refs) {
        const state = referenceState.get(known);
        if (state !== undefined && cacheIds.get(state.handler.cache) === id && (moduleId === undefined || known.name === moduleId))
          refs.delete(known);
      }
    }
  };
  const cacheOps = freeze({
    size: cache => (cacheIds.has(cache) ? host(native.context.cacheSize, cacheIds.get(cache)) : 0),
    delete(cache, moduleId) {
      if (!cacheIds.has(cache)) return 0;
      const count = host(native.context.cacheDelete, cacheIds.get(cache), moduleId);
      forgetRefs(cache, moduleId);
      return count;
    },
    clear(cache) {
      if (!cacheIds.has(cache)) return 0;
      const count = host(native.context.cacheClear, cacheIds.get(cache));
      forgetRefs(cache);
      return count;
    },
  });
  provide('graph/cache-ops', {
    ...cacheOps,
    /// `CodeCache#flush`: the code of the modules made with `cache` that compiled without a usable cache is stored.
    async flush(cache) {
      const id = codeCacheIds.get(cache);
      if (id === undefined) return 0;
      const out = host(native.context.flush, id);
      if (cache.native !== false) return out[0];
      let stored = 0;
      for (let index = 1; index < out.length; index++) {
        try {
          await cache.store(new CodeCacheKey({ id: out[index][0], hash: out[index][1] }), out[index][2]);
          stored++;
        } catch {
          // A failed write is a miss: the module compiled and runs, and the others still get their turn.
        }
      }
      return stored;
    },
    /// `CodeCache#close`.
    close(cache) {
      const id = codeCacheIds.get(cache);
      if (id === undefined) return;
      host(native.graph.codeCacheClose, id);
      customCaches.delete(id);
    },
  });

  /// The text of a reference made from a recipe (read, transformed) once.
  const ensureText = async state => {
    if (state.text !== undefined || state.recipe === null) return;
    state.text = await sourceText(state.recipe.source, state.name);
  };

  const makeReference = (graph, recipe, extra) => {
    const state = {
      graph,
      recipe,
      name: recipe !== null ? recipe.name : extra.name,
      handler: recipe !== null ? recipe.import : extra.handler,
      /// The recipe's own `codeCache` for the host (0: the handler's applies, `0xffffffff`: none).
      codeCache: recipe !== null ? recipeCacheId(recipe) : (extra?.codeCache ?? 0),
      status: extra?.status ?? ModuleStatus.Declared,
      requests: undefined,
      text: recipe === null ? extra?.text : undefined,
      context: extra?.context ?? null,
      contextObject: extra?.contextObject,
      meta: undefined,
      pin: 0,
      loading: undefined,
      evaluation: undefined,
      released: false,
    };
    const reference = new ModuleReference(state);
    if (state.contextObject !== undefined) contextRefs.get(state.contextObject)?.add(reference);
    return reference;
  };

  return { makeReference, loadRef, requestsOf, exportsOf, evaluateRef, releaseRef, isReference: value => referenceState.has(value) };
};
