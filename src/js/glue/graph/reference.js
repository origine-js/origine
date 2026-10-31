// `api.graph` module references (`recipe.create(graph)`) and the cache operations of `ImportCache`. Built by graph.js.
import { provide } from '../handles.js';
import { ModuleRequest } from './data.js';
import { freeze, failure, errors } from '../util.js';
export default g => {
  const { native, take, host, named, invalid } = g;
  const { cacheIds, contextRefs, contexts, copyData, graphCache, loadCache, metaOf, pipeline, referenceState, refsById, register, sourceText } = g;

  // ---- references -------------------------------------------------------------------------------

  /// Turns the handler of a recipe into its record and the id of its module name.
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
    /// `undefined` until the reference is `loaded`.
    get requests() {
      return this.#state.requests;
    }
    /// The context the reference is bound to, `undefined` while it is not.
    get context() {
      return this.#state.context === null ? undefined : this.#state.contextObject;
    }
    /// Reads, transforms and compiles the module and makes a `declared` reference for each of its imports
    /// (one level: call `load()` on those to go deeper). A reference found as a dependency has its source
    /// already, so it loads the same way. Calls that overlap share one load.
    load() {
      const state = this.#state;
      if (state.released) return Promise.reject(named(errors.BadHandle, 'released'));
      if (state.status !== 'declared') return Promise.resolve(this);
      state.loading ??= this.#load(state).finally(() => {
        state.loading = undefined;
      });
      return state.loading;
    }
    async #load(state) {
      await ensureText(state);
      // A module with no source text of its own (nothing was read for it) imports nothing.
      if (state.text === undefined) {
        state.requests = freeze([]);
        state.status = 'loaded';
        return this;
      }
      const requests = host(native.graph.compileRequests, state.text, state.name);
      const out = [];
      for (const [specifier, attributes, phase] of requests) {
        const answer = await pipeline(state.handler, g.graphId(state.graph), specifier, state.name, attributes);
        let reference;
        if (answer.answer !== undefined && answer.answer.kind === 'link') {
          for (const candidate of refsById.get(answer.answer.context) ?? []) {
            if (candidate.name === answer.answer.name) reference = candidate;
          }
        } else {
          const source = answer.answer !== undefined ? answer.answer.source : answer.source;
          const handler = answer.answer !== undefined ? answer.answer.handler : answer.handler;
          reference = makeReference(state.graph, null, { name: answer.id, text: source, handler, status: 'declared' });
        }
        out.push(new ModuleRequest({ specifier, attributes: freeze({ ...attributes }), phase, reference }));
      }
      state.requests = freeze(out);
      state.status = 'loaded';
      return this;
    }
    /// A snapshot of the module's exports, for the realm that created the context (`status` must be
    /// `evaluated`). The same copy rules as `Import.link(..., { mode: 'hardened' })`: plain data (primitives,
    /// arrays, objects with a plain prototype, cycles kept) is copied into this realm and frozen; a function,
    /// a class or any other object cannot be copied, so it is shared and frozen in place with what it reaches,
    /// and keeps running in the context's realm; an accessor property is `Unsupported`. Every call copies
    /// again and reads the bindings as they are now.
    exports() {
      const state = this.#state;
      if (state.released) throw named(errors.BadHandle, 'released');
      if (state.status !== 'evaluated' || state.context === null) throw invalid('exports needs a reference that is evaluated in a context');
      const namespace = host(native.context.namespaceOf, state.context, state.name);
      const seen = new Map();
      const out = Object.create(null);
      for (const key of Object.keys(namespace)) {
        Object.defineProperty(out, key, { value: copyData(namespace[key], seen), enumerable: true, writable: true, configurable: true });
      }
      host(native.context.hardenExports, out);
      return out;
    }
    /// Binds the reference to `ctx` (one context per reference) and evaluates it there. Another call
    /// for the same context waits for the first one and settles the same way.
    evaluate(ctx) {
      const state = this.#state;
      if (state.released) return Promise.reject(named(errors.BadHandle, 'released'));
      const contextId = contexts.get(ctx);
      if (contextId === undefined) return Promise.reject(invalid('evaluate: expected a context'));
      if (state.context !== null && state.context !== contextId)
        return Promise.reject(invalid('this reference is bound to another context'));
      if (state.evaluation !== undefined) return state.evaluation;
      state.context = contextId;
      state.contextObject = ctx;
      contextRefs.get(ctx)?.add(this);
      state.status = 'evaluating';
      state.evaluation = (async () => {
        try {
          await ensureText(state);
          const meta = state.meta ?? (await metaOf(register(state.handler), state.name));
          const cacheGraph = g.graphId(state.graph);
          if (graphCache.has(cacheGraph)) await loadCache(cacheGraph, state.name, host(native.graph.sourceHash, state.text), state.text);
          await native.context.evaluateSource(contextId, state.name, state.text, register(state.handler).id, meta ?? '');
          const code = take();
          if (code !== 0) throw failure(code);
          state.pin = host(native.context.pin, contextId, state.name);
          state.status = 'evaluated';
        } catch (error) {
          state.status = 'errored';
          contextRefs.get(ctx)?.delete(this);
          state.context = null;
          state.contextObject = undefined;
          state.evaluation = undefined;
          throw error;
        }
      })();
      return state.evaluation;
    }
    /// Lets the host free what the reference pins; the handle is unusable afterwards. With
    /// `retain: 'used'` the module is freed once nothing else holds it.
    release() {
      const state = this.#state;
      if (state.released) return;
      state.released = true;
      if (state.contextObject !== undefined) contextRefs.get(state.contextObject)?.delete(this);
      if (state.pin !== 0 && state.context !== null) {
        native.context.unpin(state.context, state.pin);
        take();
      }
      state.pin = 0;
    }
    [Symbol.dispose]() {
      this.release();
    }
  }

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

  return { makeReference };
};
