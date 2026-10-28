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
// (`steps`: one layer, hook, maker, transformer or `meta` at a time), in the creating realm. The
// host runs the chain and calls the driver only when it reaches a function, so a handler with no
// function in it never reaches the driver. See docs/graph-api.md.
(native, util) => {
  'use strict';
  const { freeze, take, failure, own, errors } = util;
  const { InvalidInput, NotFound, PermissionDenied, Unsupported, InvalidData } = errors;

  const HANDLER = Symbol.for('origine:@std/graph/handler');
  const RECIPE = Symbol.for('origine:@std/graph/recipe');
  const SOURCE = Symbol.for('origine:@std/graph/source');
  const CREATE = Symbol.for('origine:@std/graph/create');
  const dispose = Symbol.dispose ?? Symbol.for('Symbol.dispose');

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
  /// A host transformer on its own, as the host's `transform` native takes it.
  const hostSpec = t => ({ host: t.host, transform: t.transform, options: t.options ?? null });

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
    for (const hook of handler.hooks) {
      hookHosts.push(typeof hook === 'function' ? null : hook.host);
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
      cache: { retain: handler.cache.retain, entries: handler.cache.entries ?? null },
      meta: handler.meta !== null,
    };
    return { spec, layerFns, hookFns, hookHosts, transformerFns };
  };

  const register = handler => {
    if (handler === null || typeof handler !== 'object' || handler[HANDLER] !== true) throw invalid('expected an ImportHandler');
    prune();
    const known = handlers.get(handler);
    if (known !== undefined && byId.get(known.id) === known) return known;
    bindDriver();
    const { spec, layerFns, hookFns, hookHosts, transformerFns } = flatten(handler);
    const id = host(native.graph.handler, JSON.stringify(spec));
    const record = freeze({
      id,
      handler,
      layerFns,
      hookFns,
      hookHosts,
      transformerFns,
      native: handler.native,
      retain: handler.cache.retain,
      entries: handler.cache.entries,
    });
    handlers.set(handler, record);
    byId.set(id, record);
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
    const ops = util.shared.fsAsync;
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

  // ---- the driver ------------------------------------------------------------------------------

  /// The host's chain of a handler runs its host elements itself and calls `step` only for a function
  /// of this realm: one layer, hook, maker, transformer or `meta` at a time, each answering data. The
  /// host calls it synchronously, and a child's `import()` is such a call from inside the child's own
  /// evaluation, so every step waits one microtask first: no function of the creating realm ever runs
  /// on the child's stack, they run when it has unwound.
  const settled = () => Promise.resolve();

  /// The `custom` code cache of each graph by graph id.
  const graphCache = new Map();

  /// Asks the graph's `custom` cache for the blob it kept for `id` compiled from `text` (`hash` is the
  /// lowercase hex BLAKE3 digest of `text`) and hands it to the host, which keeps it only if the hash
  /// inside it is `hash`. A cache that throws, or returns anything else, is a miss.
  const loadCache = async (graphId, id, hash, text) => {
    const cache = graphCache.get(graphId);
    if (cache === undefined) return;
    try {
      const blob = await cache.load(freeze({ id, hash }), text);
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

  const attributesJson = attributes => (Object.keys(attributes).length === 0 ? '' : JSON.stringify(attributes));
  const NEXT = freeze({ kind: 'next' });

  /// Reads the state behind a reference (`link` verdicts name another context's module).
  const referenceState = new WeakMap();

  const metaOf = async (record, id) => {
    const metaFn = record.handler.meta;
    if (metaFn === null) return undefined;
    const data = await metaFn(freeze({ id }));
    if (data === null || typeof data !== 'object') throw named(InvalidData, 'meta must return an object');
    return JSON.stringify(data);
  };

  const steps = {
    /// A resolver layer that is a function: the id it answers, or undefined to pass.
    layer: async (hid, ctxId, index, specifier, referrer, attributes) => {
      await settled();
      const request = freeze({ specifier, referrer, attributes: freeze({ ...attributes }), phase: 'evaluation' });
      const answer = await byId.get(hid).layerFns[index](request);
      if (answer === undefined) return undefined;
      const id = typeof answer === 'string' ? answer : own(answer, 'id');
      if (typeof id !== 'string' || id === '') throw named(InvalidData, 'a resolver layer must answer an id');
      return id;
    },
    /// A hook that is a function: its verdict as data `{ kind: 'next' | 'accept' | 'provide' | 'final' | 'link' }`.
    hook: async (hid, ctxId, graphId, index, id, attributes, specifier, referrer) => {
      await settled();
      const resolved = freeze({ id, attributes: freeze({ ...attributes }), specifier, referrer, phase: 'evaluation' });
      const verdict = await byId.get(hid).hookFns[index](resolved);
      if (verdict === null || typeof verdict !== 'object' || typeof verdict.kind !== 'string')
        throw named(InvalidData, 'a hook must return an Import verdict');
      switch (verdict.kind) {
        case 'next':
          return NEXT;
        case 'accept':
          return freeze({ kind: 'accept' });
        case 'provide':
          if (verdict.recipe !== undefined) {
            const source = await sourceText(verdict.recipe.source, graphId, id);
            return freeze({ kind: 'final', source, handler: register(verdict.recipe.import).id });
          }
          return freeze({ kind: 'provide', source: await sourceText(verdict.source, graphId, id) });
        case 'link': {
          const state = referenceState.get(verdict.reference);
          if (state === undefined || state.context === null || state.status !== 'evaluated')
            throw named(InvalidInput, 'link needs a reference that is evaluated in a context');
          const reply = { kind: 'link', context: state.context, name: state.name, mode: verdict.mode };
          // A hardened link from another context brings copies of the exports, made here.
          if (verdict.mode === 'hardened' && state.context !== ctxId) {
            const namespace = host(native.context.namespaceOf, state.context, state.name);
            const exports = {};
            const seen = new Map();
            for (const key of Object.keys(namespace)) exports[key] = copyData(namespace[key], seen);
            reply.exports = exports;
          }
          return freeze(reply);
        }
        case 'reject':
          throw verdict.error;
        default:
          throw named(InvalidData, 'unknown verdict');
      }
    },
    /// A maker that is a function: the made module's source and the handler of its imports.
    maker: async (hid, ctxId, id, text) => {
      await settled();
      const record = byId.get(hid);
      const source = freeze({ kind: 'text', text, map: freeze({ kind: 'none' }), transformers: freeze([]), native: true });
      const options = (await record.handler.maker.fn(freeze({ id, source }))) ?? {};
      const made = await applyTransformer(options.transformer, id, text);
      const child = options.import !== undefined ? register(options.import) : record;
      return freeze({ text: made, handler: child.id });
    },
    /// A transformer function the host's maker reached (the `index`th of the handler's).
    transform: async (hid, index, id, text) => {
      await settled();
      return applyTransformer(byId.get(hid).transformerFns[index], id, text);
    },
    /// The `import.meta` data of a made module, as JSON.
    meta: async (hid, id) => {
      await settled();
      return metaOf(byId.get(hid), id);
    },
    /// The graph's `custom` code cache gets to load what it kept for the final source of `id`.
    cacheload: async (graphId, id, hash, text) => {
      await settled();
      await loadCache(graphId, id, hash, text);
    },
  };
  const stepByKind = [steps.layer, steps.hook, steps.maker, steps.transform, steps.meta, steps.cacheload];

  /// The pipeline of a handler with functions in it, run from JS: for `reference.load()`, which asks
  /// for the sources of a module's dependencies and has no request to park.
  const resolveInJs = async (hid, specifier, referrer, attributes) => {
    const record = byId.get(hid);
    for (let index = 0; index < record.layerFns.length; index++) {
      const id =
        record.layerFns[index] !== null
          ? await steps.layer(hid, 0, index, specifier, referrer, attributes)
          : host(native.graph.layer, hid, index, specifier, referrer);
      if (id !== undefined) return id;
    }
    throw named(NotFound, `cannot resolve ${specifier}`);
  };

  /// The `source` reply of `reference.load()`: `handler` is the handler object that governs the module's own imports.
  const finished = (child, source, id) =>
    pinned(child, async () => freeze({ kind: 'source', source, handler: child.handler, meta: await metaOf(child, id) }));

  /// Answers `{ kind: 'source', source, handler, meta }` or the `link` reply of a hook.
  const loadInJs = async (hid, graphId, id, attributes, specifier, referrer) => {
    const record = byId.get(hid);
    const json = attributesJson(attributes);
    let supplied;
    for (let index = 0; index < record.hookFns.length && supplied === undefined; index++) {
      let reply;
      if (record.hookFns[index] !== null) {
        reply = await steps.hook(hid, 0, graphId, index, id, attributes, specifier, referrer);
      } else if (graphFs.get(graphId)?.kind === 'async' && (record.hookHosts[index] === 'fs' || record.hookHosts[index] === 'json')) {
        // The host's hook cannot wait for an async read; this loop can.
        const isJson = attributes.type === 'json';
        const serves = !id.startsWith('origine:') && (record.hookHosts[index] === 'json' ? isJson : !isJson);
        if (!serves) reply = NEXT;
        else {
          const text = await readText(graphId, id);
          reply = freeze({ kind: 'provide', source: isJson ? host(native.graph.jsonModule, text) : text });
        }
      } else {
        const text = host(native.graph.hook, hid, index, graphId, 0, id, json);
        reply = text === undefined ? NEXT : freeze({ kind: 'provide', source: text });
      }
      if (reply.kind === 'accept') supplied = await readText(graphId, id);
      else if (reply.kind === 'provide') supplied = reply.source;
      else if (reply.kind === 'final') return finished(byId.get(reply.handler), reply.source, id);
      else if (reply.kind === 'link') return reply;
    }
    if (supplied === undefined) throw named(NotFound, `${id} is not provided`);
    const maker = record.handler.maker;
    let text;
    let child;
    if (typeof maker.fn === 'function') {
      const made = await steps.maker(hid, 0, id, supplied);
      text = made.text;
      child = byId.get(made.handler);
    } else {
      text = await applyTransformer(maker.transformer, id, supplied);
      child = maker.import !== undefined ? register(maker.import) : register(record.handler);
    }
    return finished(child, text, id);
  };

  let bound = false;
  /// Hands the driver to the host the first time a handler is registered (a snapshot has no natives).
  const bindDriver = () => {
    if (bound) return;
    host(native.graph.bind, (kind, ...args) => stepByKind[kind](...args));
    bound = true;
  };

  /// The native pipeline of a `native` handler, or the driver, for code that is not a context
  /// (`reference.load()` asks for the sources of a module's dependencies this way).
  const pipeline = async (handler, graphId, specifier, referrer, attributes) => {
    const record = register(handler);
    if (record.native && graphFs.get(graphId)?.kind !== 'async') {
      const id = host(native.graph.pipelineResolve, record.id, specifier, referrer);
      if (id === undefined) throw named(NotFound, `cannot resolve ${specifier}`);
      const loaded = host(native.graph.pipelineLoad, record.id, graphId, id, attributesJson(attributes));
      if (loaded.diagnostics !== undefined) throw new SyntaxError(loaded.diagnostics);
      return { id, source: loaded.source, handler: byId.get(loaded.handler).handler, meta: undefined };
    }
    return pinned(record, async () => {
      const id = await resolveInJs(record.id, specifier, referrer, attributes);
      const answer = await loadInJs(record.id, graphId, id, attributes, specifier, referrer);
      return { id, answer };
    });
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
        const answer = await pipeline(state.handler, graphId(state.graph), specifier, state.name, attributes);
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
        out.push(freeze({ specifier, attributes: freeze({ ...attributes }), phase, reference }));
      }
      state.requests = freeze(out);
      state.status = 'loaded';
      return this;
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
          const cacheGraph = graphId(state.graph);
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

  const contexts = new WeakMap();
  /// context object -> the references bound to it
  const contextRefs = new WeakMap();
  /// context id -> the references bound to it (the same sets as `contextRefs`); `link` verdicts name a module by context id
  const refsById = new Map();

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
      handler: recipe !== null ? recipe.import : extra.handler,
      status: extra?.status ?? 'declared',
      requests: undefined,
      text: recipe === null ? extra?.text : undefined,
      context: extra?.context ?? null,
      contextObject: extra?.contextObject,
      meta: undefined,
      pin: 0,
      evaluation: undefined,
      released: false,
    };
    const reference = new ModuleReference(state);
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
      derive(options) {
        const fs = own(options, 'fs') ?? config.fs;
        const codeCache = own(options, 'codeCache') ?? config.codeCache;
        return build(fs, codeCache, own(options, 'sourceBytes') ?? config.sourceBytes);
      },
      /// The largest source file the graph reads through its fs grant, in bytes.
      sourceBytes: config.sourceBytes,
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
      /// Ends the graph: no more contexts or references can be made with it, and the host frees what it
      /// kept (code caches not yet flushed are dropped) once the contexts using it are gone.
      close() {
        host(native.graph.close, id);
        graphFs.delete(id);
        graphCache.delete(id);
      },
      [dispose]() {
        native.graph.close(id);
        take();
        graphFs.delete(id);
        graphCache.delete(id);
      },
      [CREATE](recipe) {
        if (recipe === null || typeof recipe !== 'object' || recipe[RECIPE] !== true) throw invalid('expected a ModuleRecipe');
        return makeReference(graph, recipe, null);
      },
    };
    graphs.set(graph, { id, config });
    return freeze(graph);
  };

  /// The largest source file a graph reads unless `derive({ sourceBytes })` says otherwise.
  const DEFAULT_SOURCE_BYTES = 64 * 1024 * 1024;

  const build = (fs, codeCache, sourceBytes = DEFAULT_SOURCE_BYTES) => {
    if (!Number.isSafeInteger(sourceBytes) || sourceBytes < 1) throw invalid('sourceBytes must be a positive integer');
    // The host decides what is a grant (it stamped the object itself); `kind` and `id` are read only
    // after it accepted the object, and a grant is frozen.
    if (fs !== undefined && (fs === null || typeof fs !== 'object')) throw invalid('graph fs must be a fs grant made by api.fs');
    let kind = 0;
    let bytes = 0;
    let cacheFs;
    if (codeCache !== undefined) {
      if (codeCache.kind !== 'codeCache') throw invalid('codeCache must be a CodeCache');
      if (codeCache.native === false) kind = 3;
      else {
        kind = cacheKinds[codeCache.host] ?? -1;
        if (kind < 0) throw invalid('unknown CodeCache');
        if (kind === 2) {
          cacheFs = codeCache.fs;
          if (cacheFs === null || typeof cacheFs !== 'object') throw invalid('CodeCache.dir needs a sync fs grant made by api.fs');
        }
      }
      bytes = codeCache.bytes ?? 0;
    }
    if (fs !== undefined && fs.kind === 'async' && util.shared.fsAsync === undefined) throw invalid('async fs is not available');
    const id = host(native.graph.create, fs, kind, bytes, cacheFs, sourceBytes);
    if (kind === 3) graphCache.set(id, codeCache);
    if (fs !== undefined) {
      if (fs.kind === 'async')
        host(native.graph.asyncFs, id, fs, util.shared.fsAsync.openFile, util.shared.fsAsync.readAll, util.shared.fsAsync.close);
      graphFs.set(id, freeze({ kind: fs.kind, id: fs.id, limit: sourceBytes }));
    }
    return makeGraph(id, freeze({ fs, codeCache, sourceBytes }));
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
    refsById,
    makeReference,
    referenceState,
    host,
    invalid,
    named,
  });

  const makeGraphCap = () => {
    // The root graph is made on first use: building it calls the host, which a snapshot cannot.
    const cap = {
      derive: options => rootGraph().derive(options),
      flush: () => rootGraph().flush(),
      sourceBytes: DEFAULT_SOURCE_BYTES,
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
