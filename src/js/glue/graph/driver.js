// `api.graph` driver: the steps the host calls for the functions of a handler, and the pipeline run from JS. Built by graph.js.
import { SourceMap, ImportVerdict, HookHost, ModuleImportPhase, SourceMapKind, SourceKind, ModuleStatus, PipelineKind, VerdictKind } from '../handles.js';
import { PipelineResult, ResolveRequest, ResolvedImport, ProvidedSource, MakerRequest, TransformResult } from './data.js';
import { freeze, own, errors } from '../util.js';
export default g => {
  const { native, host, named } = g;
  const { applyTransformer, byId, grantOf, loadCache, metaOf, pinned, readText, recipeCacheId, referenceState, register, sourceText } = g;
  const { InvalidInput, NotFound, NotADirectory, InvalidData } = errors;

  /// The host's chain of a handler runs its host elements itself and calls `step` only for a function
  /// of this realm: one layer, hook, maker, transformer or `meta` at a time, each answering data. The
  /// host calls it synchronously, and a child's `import()` is such a call from inside the child's own
  /// evaluation, so every step waits one microtask first: no function of the creating realm ever runs
  /// on the child's stack, they run when it has unwound.
  const settled = () => Promise.resolve();

  const attributesJson = attributes => (Object.keys(attributes).length === 0 ? '' : JSON.stringify(attributes));
  const NEXT = new PipelineResult({ kind: PipelineKind.Next });

  const steps = {
    /// A resolver layer that is a function: the id it answers, or undefined to pass.
    layer: async (hid, ctxId, index, specifier, referrer, attributes) => {
      await settled();
      const request = new ResolveRequest({ specifier, referrer, attributes: freeze({ ...attributes }), phase: ModuleImportPhase.Evaluation });
      const answer = await byId.get(hid).layerFns[index](request);
      if (answer === undefined) return undefined;
      const id = typeof answer === 'string' ? answer : own(answer, 'id');
      if (typeof id !== 'string' || id === '') throw named(InvalidData, 'a resolver layer must answer an id');
      // The attributes of an import are what its statement wrote; a layer cannot change them.
      if (own(answer, 'attributes') !== undefined) throw named(InvalidData, 'a resolver layer answers an id, not attributes');
      return id;
    },
    /// A hook that is a function: its verdict as data `{ kind: 'next' | 'accept' | 'provide' | 'final' | 'link' | 'exports' }`.
    hook: async (hid, ctxId, index, id, attributes, specifier, referrer) => {
      await settled();
      const resolved = new ResolvedImport({
        id,
        attributes: freeze({ ...attributes }),
        specifier,
        referrer,
        phase: ModuleImportPhase.Evaluation,
      });
      const verdict = await byId.get(hid).hookFns[index](resolved);
      if (!(verdict instanceof ImportVerdict)) throw named(InvalidData, 'a hook must return an ImportHook');
      switch (verdict.kind) {
        case VerdictKind.Next:
          return NEXT;
        case VerdictKind.Accept: {
          // The host checks the grant again when it reads; `grant` is for this realm's own reads.
          const grant = grantOf(verdict.fs, 'ImportHook.accept');
          return new PipelineResult({ kind: PipelineKind.Accept, fs: grant.id, fsAsync: grant.async ? 1 : 0, grant: verdict.fs });
        }
        case VerdictKind.Recipe: {
          const source = await sourceText(verdict.recipe.source, id);
          return new PipelineResult({
            kind: PipelineKind.Final,
            source,
            handler: register(verdict.recipe.import).id,
            codeCache: recipeCacheId(verdict.recipe),
          });
        }
        case VerdictKind.Source:
          return new PipelineResult({ kind: PipelineKind.Provide, source: await sourceText(verdict.source, id) });
        case VerdictKind.Link: {
          const state = referenceState.get(verdict.reference);
          if (state === undefined || state.released || state.context === null || state.status !== ModuleStatus.Evaluated)
            throw named(InvalidInput, 'link needs a reference that is evaluated in a context and not released');
          return new PipelineResult({ kind: PipelineKind.Link, context: state.context, name: state.name });
        }
        case VerdictKind.Exports:
          return new PipelineResult({ kind: PipelineKind.Exports, exports: verdict.values });
        case VerdictKind.Reject:
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
        kind: SourceKind.Text,
        text,
        map: new SourceMap({ kind: SourceMapKind.None }),
        transformers: freeze([]),
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
    /// The `custom` code cache of the module (by its host id) gets to load what it kept for the final source of `id`.
    cacheload: async (cacheId, id, hash, text) => {
      await settled();
      await loadCache(cacheId, id, hash, text);
    },
  };
  const stepByKind = [steps.layer, steps.hook, steps.maker, steps.transform, steps.meta, steps.cacheload];

  /// The pipeline of a handler, run from JS: for `reference.load()`, which asks for the sources of a module's
  /// dependencies and has no request to park. Like the host's chain it goes element by element: a native one
  /// runs in the host, a function here.
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
  const finished = (child, source, id, codeCache = 0) =>
    pinned(child, async () => new PipelineResult({ kind: PipelineKind.Source, source, handler: child.handler, meta: await metaOf(child, id), codeCache }));

  /// Answers `{ kind: 'source', source, handler, meta }` or the `link` reply of a hook.
  const loadInJs = async (hid, id, attributes, specifier, referrer) => {
    const record = byId.get(hid);
    const json = attributesJson(attributes);
    let supplied;
    for (let index = 0; index < record.hookFns.length && supplied === undefined; index++) {
      let reply;
      if (record.hookFns[index] !== null) {
        reply = await steps.hook(hid, 0, index, id, attributes, specifier, referrer);
      } else if (record.hookGrants[index]?.async === true) {
        // The host's hook cannot wait for an async read; this loop can.
        const isJson = attributes.type === 'json';
        const serves = !id.startsWith('origine:') && (record.hookHosts[index] === HookHost.Json ? isJson : !isJson);
        if (!serves) reply = NEXT;
        else {
          try {
            const text = await readText(record.handler.hooks[index].fs, id);
            reply = new PipelineResult({ kind: PipelineKind.Provide, source: isJson ? host(native.graph.jsonModule, text) : text });
          } catch (error) {
            // `missing: 'skip'`: not in this provider's root, so the next hook gets its turn, as in the host's chain.
            if (record.handler.hooks[index].missing !== 'skip' || (error?.errno !== NotFound && error?.errno !== NotADirectory)) throw error;
            reply = NEXT;
          }
        }
      } else {
        const text = host(native.graph.hook, hid, index, 0, id, json);
        reply = text === undefined ? NEXT : new PipelineResult({ kind: PipelineKind.Provide, source: text });
      }
      if (reply.kind === PipelineKind.Accept) supplied = await readText(reply.grant, id);
      else if (reply.kind === PipelineKind.Provide) supplied = reply.source;
      else if (reply.kind === PipelineKind.Final) return finished(byId.get(reply.handler), reply.source, id, reply.codeCache);
      else if (reply.kind === PipelineKind.Link) return reply;
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

  /// The pipeline for code that is not a context (`reference.load()` asks for the sources of a module's
  /// dependencies this way).
  const pipeline = async (handler, specifier, referrer, attributes) => {
    const record = register(handler);
    return pinned(record, async () => {
      const id = await resolveInJs(record.id, specifier, referrer, attributes);
      const answer = await loadInJs(record.id, id, attributes, specifier, referrer);
      return { id, answer };
    });
  };

  return { pipeline, bindDriver };
};
