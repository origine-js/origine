// `api.graph` driver: the steps the host calls for the functions of a handler, and the pipeline run from JS. Built by graph.js.
import { SourceMap, ImportVerdict } from '../handles.js';
import { PipelineResult, ResolveRequest, ResolvedImport, ProvidedSource, MakerRequest, TransformResult } from './data.js';
import { freeze, own, errors } from '../util.js';
export default g => {
  const { native, host, named } = g;
  const { applyTransformer, byId, copyData, graphFs, loadCache, metaOf, pinned, readText, referenceState, register, sourceText } = g;
  const { InvalidInput, NotFound, InvalidData } = errors;

  /// The host's chain of a handler runs its host elements itself and calls `step` only for a function
  /// of this realm: one layer, hook, maker, transformer or `meta` at a time, each answering data. The
  /// host calls it synchronously, and a child's `import()` is such a call from inside the child's own
  /// evaluation, so every step waits one microtask first: no function of the creating realm ever runs
  /// on the child's stack, they run when it has unwound.
  const settled = () => Promise.resolve();

  const attributesJson = attributes => (Object.keys(attributes).length === 0 ? '' : JSON.stringify(attributes));
  const NEXT = new PipelineResult({ kind: 'next' });

  const steps = {
    /// A resolver layer that is a function: the id it answers, or undefined to pass.
    layer: async (hid, ctxId, index, specifier, referrer, attributes) => {
      await settled();
      const request = new ResolveRequest({ specifier, referrer, attributes: freeze({ ...attributes }), phase: 'evaluation' });
      const answer = await byId.get(hid).layerFns[index](request);
      if (answer === undefined) return undefined;
      const id = typeof answer === 'string' ? answer : own(answer, 'id');
      if (typeof id !== 'string' || id === '') throw named(InvalidData, 'a resolver layer must answer an id');
      return id;
    },
    /// A hook that is a function: its verdict as data `{ kind: 'next' | 'accept' | 'provide' | 'final' | 'link' }`.
    hook: async (hid, ctxId, graphId, index, id, attributes, specifier, referrer) => {
      await settled();
      const resolved = new ResolvedImport({
        id,
        attributes: freeze({ ...attributes }),
        specifier,
        referrer,
        phase: 'evaluation',
      });
      const verdict = await byId.get(hid).hookFns[index](resolved);
      if (!(verdict instanceof ImportVerdict)) throw named(InvalidData, 'a hook must return an Import verdict');
      switch (verdict.kind) {
        case 'next':
          return NEXT;
        case 'accept':
          return new PipelineResult({ kind: 'accept' });
        case 'provide':
          if (verdict.recipe !== undefined) {
            const source = await sourceText(verdict.recipe.source, graphId, id);
            return new PipelineResult({ kind: 'final', source, handler: register(verdict.recipe.import).id });
          }
          return new PipelineResult({ kind: 'provide', source: await sourceText(verdict.source, graphId, id) });
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
          return new PipelineResult(reply);
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
      const source = new ProvidedSource({
        kind: 'text',
        text,
        map: new SourceMap({ kind: 'none' }),
        transformers: freeze([]),
        native: true,
      });
      const options = (await record.handler.maker.fn(new MakerRequest({ id, source }))) ?? {};
      const made = await applyTransformer(options.transformer, id, text);
      const child = options.import !== undefined ? register(options.import) : record;
      return new TransformResult({ text: made, handler: child.id });
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
    pinned(child, async () =>
      new PipelineResult({ kind: 'source', source, handler: child.handler, meta: await metaOf(child, id) }),
    );

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
          reply = new PipelineResult({ kind: 'provide', source: isJson ? host(native.graph.jsonModule, text) : text });
        }
      } else {
        const text = host(native.graph.hook, hid, index, graphId, 0, id, json);
        reply = text === undefined ? NEXT : new PipelineResult({ kind: 'provide', source: text });
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
  /// Hands the driver to the host the first time a handler is registered (live graph authority is bound after snapshot restoration).
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

  return { pipeline, bindDriver };
};
