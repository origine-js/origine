// `api.graph` module references (`graph.declare(recipe)`) and the cache operations of `ImportCache`. Built by graph.js.
import { provide } from '../handles.js';
import { ModuleRequest } from './data.js';
import { freeze, errors, moduleSettled } from '../util.js';
export default g => {
  const { native, take, takeError, host, named, invalid } = g;
  const { cacheIds, contextRefs, contexts, graphCache, loadCache, metaOf, pipeline, referenceState, refsById, register, sourceText } = g;

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
    /// `declared`, `loaded`, `instantiated`, `evaluating`, `evaluated` or `errored` (the V8 module's
    /// states). `instantiated` is reported while a bound module links its dependencies.
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
    if (state.status !== 'declared') return Promise.resolve(reference);
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
      state.status = 'loaded';
      return reference;
    }
    const requests = host(native.graph.compileRequests, state.text, state.name);
    const out = [];
    for (const [specifier, attributes, phase] of requests) {
      const answer = await pipeline(state.handler, g.graphId(state.graph), specifier, state.name, attributes);
      let dependency;
      if (answer.answer !== undefined && answer.answer.kind === 'link') {
        for (const candidate of refsById.get(answer.answer.context) ?? []) {
          if (candidate.name === answer.answer.name) dependency = candidate;
        }
      } else {
        const source = answer.answer !== undefined ? answer.answer.source : answer.source;
        const handler = answer.answer !== undefined ? answer.answer.handler : answer.handler;
        dependency = makeReference(state.graph, null, { name: answer.id, text: source, handler, status: 'declared' });
      }
      out.push(new ModuleRequest({ specifier, attributes: freeze({ ...attributes }), phase, reference: dependency }));
    }
    state.requests = freeze(out);
    state.status = 'loaded';
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
    if (state.status !== 'evaluated' || state.context === null) throw invalid('exports needs a reference that is evaluated in a context');
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
    state.status = 'evaluating';
    state.evaluation = (async () => {
      try {
        await ensureText(state);
        const meta = state.meta ?? (await metaOf(register(state.handler), state.name));
        const cacheGraph = g.graphId(state.graph);
        if (graphCache.has(cacheGraph)) await loadCache(cacheGraph, state.name, host(native.graph.sourceHash, state.text), state.text);
        // A synchronous failure is in the cell as the call returns; read it before awaiting anything.
        const evaluating = native.context.evaluateSource(contextId, state.name, state.text, register(state.handler).id, meta ?? '');
        const failed = takeError();
        if (failed !== undefined) throw failed;
        await moduleSettled(evaluating);
        state.pin = host(native.context.pin, contextId, state.name);
        state.status = 'evaluated';
      } catch (error) {
        state.status = 'errored';
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
  provide('graph/cache-ops', cacheOps);

  /// The text of a reference made from a recipe (read, transformed) once.
  const ensureText = async state => {
    if (state.text !== undefined || state.recipe === null) return;
    state.text = await sourceText(state.recipe.source, g.graphId(state.graph), state.name);
  };

  const makeReference = (graph, recipe, extra) => {
    const state = {
      graph,
      recipe,
      name: recipe !== null ? recipe.name : extra.name,
      handler: recipe !== null ? recipe.import : extra.handler,
      status: extra?.status ?? 'declared',
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
