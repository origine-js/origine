// `api.graph` and the machinery `api.context` (glue/context.js) shares with it. Evaluated as an
// expression by src/api/glue.zig: `(native, util) => makeGraphCap`. The factory also publishes the
// shared parts in `util.shared.graph` (handler registry, JS driver, references) for the context glue.
//
// A graph holds the authority modules are produced with (an fs grant, a code cache); a recipe is
// turned into a `ModuleReference` with `recipe.create(graph)`; a reference is loaded
// (`reference.load()`) and evaluated in one context (`reference.evaluate(ctx)`).
//
// Import handlers (origine:@std/graph/import) are registered with the host once, flattened to JSON:
// every host descriptor is run by the host, every function is run here, by the *driver*
// (`driverResolve`, `driverLoad`), in the creating realm. A handler with no function in it never
// reaches the driver: the host runs its whole pipeline natively. See docs/graph-api.md.
(native, util) => {
  'use strict';
  const { freeze, take, failure, own, errors } = util;
  const { InvalidInput, NotFound, PermissionDenied, Unsupported, InvalidData } = errors;

  const HANDLER = Symbol.for('origine:@std/graph/handler');
  const RECIPE = Symbol.for('origine:@std/graph/recipe');
  const SOURCE = Symbol.for('origine:@std/graph/source');
  const CREATE = Symbol.for('origine:@std/graph/create');

  const named = (code, message) => freeze({ errno: code, name: util.failure(code).name, message });
  const invalid = message => named(InvalidInput, message);
  /// Calls a host native and throws what it left in the errno cell.
  const host = (fn, ...args) => {
    const value = fn(...args);
    const code = take();
    if (code !== 0) throw failure(code);
    return value;
  };

  // ---- import handlers -------------------------------------------------------------------------

  /// handler object -> its record, and id -> record.
  const handlers = new WeakMap();
  const byId = [];

  const descriptorHost = value => value !== null && typeof value === 'object' && typeof value.host === 'string';
  /// The part of a transformer the host needs, as plain data: the oxc ones are native functions that
  /// carry `{ host: 'oxc', transform, options }`; a plain function is a JS barrier.
  const transformerSpec = t => {
    if (t === undefined || t === null) return null;
    if (typeof t === 'function') return { js: true };
    if (descriptorHost(t) && t.host === 'byExtension')
      return { host: 'byExtension', entries: t.entries.map(([extension, inner]) => [extension, transformerSpec(inner)]) };
    if (descriptorHost(t)) return { host: t.host, transform: t.transform, options: t.options ?? null };
    throw invalid('not a transformer');
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
    for (const hook of handler.hooks) {
      if (typeof hook === 'function') {
        hooks.push({ js: true });
        hookFns.push(hook);
      } else {
        hooks.push(
          hook.host === 'origine'
            ? { host: 'origine', std: hook.std }
            : hook.host === 'fs'
              ? { host: 'fs', read: hook.read }
              : { host: hook.host },
        );
        hookFns.push(null);
      }
    }
    const maker = handler.maker;
    let makerSpec;
    let makerImport = 0;
    if (typeof maker.fn === 'function') {
      makerSpec = { js: true };
    } else {
      if (maker.import !== undefined) makerImport = register(maker.import).id;
      makerSpec = { host: 'maker', import: makerImport, transformer: transformerSpec(maker.transformer) };
    }
    const spec = {
      layers,
      hooks,
      maker: makerSpec,
      cache: { retain: handler.cache.retain, entries: handler.cache.entries ?? null },
      meta: handler.meta !== null,
    };
    return { spec, layerFns, hookFns };
  };

  const register = handler => {
    if (handler === null || typeof handler !== 'object' || handler[HANDLER] !== true) throw invalid('expected an ImportHandler');
    const known = handlers.get(handler);
    if (known !== undefined) return known;
    bindDriver();
    const { spec, layerFns, hookFns } = flatten(handler);
    const id = host(native.graph.handler, JSON.stringify(spec));
    const record = freeze({
      id,
      handler,
      layerFns,
      hookFns,
      native: handler.native,
      retain: handler.cache.retain,
      entries: handler.cache.entries,
    });
    handlers.set(handler, record);
    byId[id] = record;
    return record;
  };

  // ---- sources and transformers -----------------------------------------------------------------

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
    return host(native.graph.transform, JSON.stringify(transformerSpec(t)), id, text);
  };

  /// The text of a `ModuleSource`: read through the graph's fs grant or given, then its transformer chain.
  const sourceText = async (source, graphId, id) => {
    let text = source.kind === 'text' ? source.text : host(native.graph.readSource, graphId, source.path);
    for (const t of source.transformers) text = await applyTransformer(t, id, text);
    return text;
  };

  // ---- the driver ------------------------------------------------------------------------------

  /// The host calls the driver synchronously, and a child's `import()` is such a call from inside the
  /// child's own evaluation. Waiting one microtask first means no layer, hook, maker, transformer or
  /// `meta` of the creating realm ever runs on the child's stack: they run when it has unwound.
  const settled = () => Promise.resolve();

  const attributesJson = attributes => (Object.keys(attributes).length === 0 ? '' : JSON.stringify(attributes));

  /// Resolves `specifier` through the layers of handler `hid`; functions run here, host layers in the host.
  const driverResolve = async (hid, ctxId, specifier, referrer, attributes) => {
    await settled();
    const record = byId[hid];
    const request = freeze({ specifier, referrer, attributes: freeze({ ...attributes }), phase: 'evaluation' });
    for (let index = 0; index < record.layerFns.length; index++) {
      const fn = record.layerFns[index];
      const answer = fn !== null ? await fn(request) : host(native.graph.layer, hid, index, specifier, referrer);
      if (answer === undefined) continue;
      const id = typeof answer === 'string' ? answer : own(answer, 'id');
      if (typeof id !== 'string' || id === '') throw named(InvalidData, 'a resolver layer must answer an id');
      return id;
    }
    throw named(NotFound, `cannot resolve ${specifier}`);
  };

  /// Reads the state behind a reference (`link` verdicts name another context's module).
  const referenceState = new WeakMap();

  const metaOf = async (record, id) => {
    const metaFn = record.handler.meta;
    if (metaFn === null) return undefined;
    const data = await metaFn(freeze({ id }));
    if (data === null || typeof data !== 'object') throw named(InvalidData, 'meta must return an object');
    return JSON.stringify(data);
  };

  /// Makes a module of `text` supplied for `id`: runs the maker and returns the load answer.
  const make = async (record, hid, id, text) => {
    const maker = record.handler.maker;
    let options;
    if (typeof maker.fn === 'function') {
      options =
        (await maker.fn(
          freeze({ id, source: freeze({ kind: 'text', text, map: freeze({ kind: 'none' }), transformers: freeze([]), native: true }) }),
        )) ?? {};
    } else {
      options = { import: maker.import, transformer: maker.transformer };
    }
    const childRecord = options.import !== undefined ? register(options.import) : record;
    const out = await applyTransformer(options.transformer, id, text);
    return { text: out, handler: childRecord.id, record: childRecord };
  };

  /// The load stage for handler `hid`: hooks in order, then the maker. Answers the data the host
  /// completes the load with: `{ kind: 'source', source, handler, meta }` or `{ kind: 'link', ... }`.
  const driverLoad = async (hid, ctxId, graphId, id, attributes, specifier, referrer) => {
    await settled();
    const record = byId[hid];
    const resolved = freeze({ id, attributes: freeze({ ...attributes }), specifier, referrer, phase: 'evaluation' });
    const json = attributesJson(attributes);
    let supplied;
    let final = null;
    for (let index = 0; index < record.hookFns.length && supplied === undefined; index++) {
      const fn = record.hookFns[index];
      let verdict;
      if (fn !== null) {
        verdict = await fn(resolved);
        if (verdict === null || typeof verdict !== 'object' || typeof verdict.kind !== 'string')
          throw named(InvalidData, 'a hook must return an Import verdict');
      } else {
        const text = host(native.graph.hook, hid, index, graphId, ctxId, id, json);
        verdict = text === undefined ? freeze({ kind: 'next' }) : freeze({ kind: 'text', text });
      }
      switch (verdict.kind) {
        case 'next':
          break;
        case 'text':
          supplied = verdict.text;
          break;
        case 'accept':
          supplied = host(native.graph.readSource, graphId, id);
          break;
        case 'provide':
          if (verdict.recipe !== undefined) {
            supplied = await sourceText(verdict.recipe.source, graphId, id);
            final = verdict.recipe;
          } else {
            supplied = await sourceText(verdict.source, graphId, id);
          }
          break;
        case 'link': {
          const state = referenceState.get(verdict.reference);
          if (state === undefined || state.context === null) throw named(InvalidInput, 'link needs a reference bound to a context');
          return freeze({ kind: 'link', context: state.context, name: state.name, mode: verdict.mode });
        }
        case 'reject':
          throw verdict.error;
        default:
          throw named(InvalidData, 'unknown verdict');
      }
    }
    if (supplied === undefined) throw named(NotFound, `${id} is not provided`);
    if (final !== null) {
      const finalRecord = register(final.import);
      return freeze({ kind: 'source', source: supplied, handler: finalRecord.id, meta: await metaOf(finalRecord, id) });
    }
    const made = await make(record, hid, id, supplied);
    return freeze({ kind: 'source', source: made.text, handler: made.handler, meta: await metaOf(made.record, id) });
  };

  let bound = false;
  /// Hands the driver to the host the first time a handler is registered (a snapshot has no natives).
  const bindDriver = () => {
    if (bound) return;
    host(native.graph.bind, driverResolve, driverLoad);
    bound = true;
  };

  /// The native pipeline of a `native` handler, or the driver, for code that is not a context
  /// (`reference.load()` asks for the sources of a module's dependencies this way).
  const pipeline = async (record, graphId, specifier, referrer, attributes) => {
    if (record.native) {
      const id = host(native.graph.pipelineResolve, record.id, specifier, referrer);
      if (id === undefined) throw named(NotFound, `cannot resolve ${specifier}`);
      const loaded = host(native.graph.pipelineLoad, record.id, graphId, id, attributesJson(attributes));
      if (loaded.diagnostics !== undefined) throw new SyntaxError(loaded.diagnostics);
      return { id, source: loaded.source, handler: loaded.handler, meta: undefined };
    }
    const id = await driverResolve(record.id, 0, specifier, referrer, attributes);
    const answer = await driverLoad(record.id, 0, graphId, id, attributes, specifier, referrer);
    return { id, answer };
  };

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
    async load() {
      const state = this.#state;
      if (state.released) throw named(errors.BadHandle, 'released');
      if (state.status !== 'declared') return this;
      await ensureText(state);
      if (state.recipe === null) return this;
      const requests = host(native.graph.compileRequests, state.text, state.name);
      const out = [];
      for (const [specifier, attributes, phase] of requests) {
        const answer = await pipeline(state.record, graphId(state.graph), specifier, state.name, attributes);
        let reference;
        if (answer.answer !== undefined && answer.answer.kind === 'link') {
          reference = [...allReferences].find(candidate => {
            const other = referenceState.get(candidate);
            return other.context === answer.answer.context && other.name === answer.answer.name;
          });
        } else {
          const source = answer.answer !== undefined ? answer.answer.source : answer.source;
          const handler = answer.answer !== undefined ? answer.answer.handler : answer.handler;
          reference = makeReference(state.graph, null, { name: answer.id, text: source, record: byId[handler], status: 'declared' });
        }
        out.push(freeze({ specifier, attributes: freeze({ ...attributes }), phase, reference }));
      }
      state.requests = freeze(out);
      state.status = 'loaded';
      return this;
    }
    /// Binds the reference to `ctx` (one context per reference) and evaluates it there.
    async evaluate(ctx) {
      const state = this.#state;
      if (state.released) throw named(errors.BadHandle, 'released');
      const contextId = contexts.get(ctx);
      if (contextId === undefined) throw invalid('evaluate: expected a context');
      if (state.context !== null) {
        if (state.context !== contextId) throw invalid('this reference is bound to another context');
        return;
      }
      await ensureText(state);
      state.context = contextId;
      state.contextObject = ctx;
      contextRefs.get(ctx)?.add(this);
      state.status = 'evaluating';
      try {
        const meta = state.meta ?? (await metaOf(state.record, state.name));
        await native.context.evaluateSource(contextId, state.name, state.text, state.record.id, meta ?? '');
        const code = take();
        if (code !== 0) throw failure(code);
        state.pin = host(native.context.pin, contextId, state.name);
        state.status = 'evaluated';
      } catch (error) {
        state.status = 'errored';
        contextRefs.get(ctx)?.delete(this);
        state.context = null;
        state.contextObject = undefined;
        throw error;
      }
    }
    /// Lets the host free what the reference pins; the handle is unusable afterwards. With
    /// `retain: 'used'` the module is freed once nothing else holds it.
    release() {
      const state = this.#state;
      if (state.released) return;
      state.released = true;
      allReferences.delete(this);
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

  const contexts = new WeakMap();
  /// context object -> the references bound to it
  const contextRefs = new WeakMap();
  const allReferences = new Set();

  /// The text of a reference made from a recipe (read, transformed) once.
  const ensureText = async state => {
    if (state.text !== undefined) return;
    state.text = await sourceText(state.recipe.source, graphId(state.graph), state.name);
  };

  const makeReference = (graph, recipe, extra) => {
    const state = {
      graph,
      recipe,
      name: recipe !== null ? recipe.name : extra.name,
      record: recipe !== null ? register(recipe.import) : extra.record,
      status: extra?.status ?? 'declared',
      requests: undefined,
      text: recipe === null ? extra?.text : undefined,
      context: extra?.context ?? null,
      contextObject: extra?.contextObject,
      meta: undefined,
      pin: 0,
      released: false,
    };
    const reference = new ModuleReference(state);
    allReferences.add(reference);
    if (state.contextObject !== undefined) contextRefs.get(state.contextObject)?.add(reference);
    return reference;
  };

  // ---- graphs ------------------------------------------------------------------------------------

  const graphs = new WeakMap();

  const cacheKinds = freeze({ codeCacheNone: 0, codeCacheMemory: 1, codeCacheDir: 2 });

  const makeGraph = (id, config) => {
    const graph = {
      /// A graph with the same authority except what `options` replaces: `fs` (a grant of `api.fs.requestSync`)
      /// and `codeCache` (`origine:@std/graph/cache`). It cannot hold more than the realm already does.
      narrow(options) {
        const fs = own(options, 'fs') ?? config.fs;
        const codeCache = own(options, 'codeCache') ?? config.codeCache;
        return build(fs, codeCache);
      },
      /// Persists the code caches of modules compiled without one; resolves how many modules were stored.
      async flush() {
        const out = host(native.context.flush, id);
        const cache = config.codeCache;
        if (cache !== undefined && cache.native === false) {
          for (let index = 1; index < out.length; index++)
            await cache.store(freeze({ id: out[index][0], hash: out[index][1] }), out[index][2]);
        }
        return out[0];
      },
      [CREATE](recipe) {
        if (recipe === null || typeof recipe !== 'object' || recipe[RECIPE] !== true) throw invalid('expected a ModuleRecipe');
        return makeReference(graph, recipe, null);
      },
    };
    graphs.set(graph, { id, config });
    return freeze(graph);
  };

  const build = (fs, codeCache) => {
    let fsId = 0;
    if (fs !== undefined) {
      if (fs === null || typeof fs !== 'object' || fs.kind !== 'sync' || !Number.isSafeInteger(fs.id))
        throw invalid('graph fs must be a sync fs grant');
      fsId = fs.id;
    }
    let kind = 0;
    let bytes = 0;
    let cacheFsId = 0;
    if (codeCache !== undefined) {
      if (codeCache.kind !== 'codeCache') throw invalid('codeCache must be a CodeCache');
      if (codeCache.native === false) kind = 3;
      else {
        kind = cacheKinds[codeCache.host] ?? -1;
        if (kind < 0) throw invalid('unknown CodeCache');
        if (kind === 2) {
          const grant = codeCache.fs;
          if (grant === null || typeof grant !== 'object' || grant.kind !== 'sync' || !Number.isSafeInteger(grant.id))
            throw invalid('CodeCache.dir needs a sync fs grant');
          cacheFsId = grant.id;
        }
      }
      bytes = codeCache.bytes ?? 0;
    }
    const id = host(native.graph.create, fsId, kind, bytes, cacheFsId);
    return makeGraph(id, freeze({ fs, codeCache }));
  };

  let root;
  /// Graph ids by graph object, for `api.context`.
  const graphId = graph => {
    const found = graphs.get(graph);
    if (found === undefined) throw invalid('expected a graph');
    return found.id;
  };

  const rootGraph = () => (root ??= build(undefined, undefined));

  util.shared.graph = freeze({
    register,
    byId,
    graphId,
    rootGraph,
    contexts,
    contextRefs,
    makeReference,
    referenceState,
    host,
    invalid,
    named,
  });

  const makeGraphCap = () => {
    // The root graph is made on first use: building it calls the host, which a snapshot cannot.
    const cap = {
      narrow: options => rootGraph().narrow(options),
      flush: () => rootGraph().flush(),
      [CREATE]: recipe => rootGraph()[CREATE](recipe),
    };
    graphs.set(cap, {
      get id() {
        return graphId(rootGraph());
      },
      config: freeze({}),
    });
    return freeze(cap);
  };
  return makeGraphCap;
};
