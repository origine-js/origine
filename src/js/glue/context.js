// `api.context`: realms whose imports run through an ImportHandler. An ES module factory used by
// index.js. It builds on the parts the graph glue
// publishes in shared module state (index.js prepares `graph` before `context`).
import { Data } from './handles.js';
import { freeze, failure, own, shared, errors, seal } from './util.js';
class Context extends Data {}
seal(Context);
export default (native, { take }) => {
  const dispose = Symbol.dispose ?? Symbol.for('Symbol.dispose');

  /// `security.codeGeneration` of the create options: whether the realm may compile strings (`eval`, `new Function`).
  /// Off unless it is the boolean `true`; an unknown key or a non-boolean is `InvalidInput`.
  const securityOf = (security, invalid) => {
    if (security === undefined) return false;
    if (security === null || typeof security !== 'object') throw invalid('create: security must be an object');
    let codeGeneration = false;
    for (const key of Reflect.ownKeys(security)) {
      if (key !== 'codeGeneration') throw invalid(`create: unknown security option ${String(key)}`);
      const descriptor = Object.getOwnPropertyDescriptor(security, key);
      if (!('value' in descriptor) || (descriptor.value !== undefined && typeof descriptor.value !== 'boolean'))
        throw invalid('create: security.codeGeneration must be a boolean');
      codeGeneration = descriptor.value === true;
    }
    return codeGeneration;
  };

  const attributesJson = attributes => (Object.keys(attributes).length === 0 ? '' : JSON.stringify(attributes));

  const makeContextCap = () => {
    const graphShared = () => shared.graph;
    return freeze({
      /// A realm. `import` (an ImportHandler) answers the `import()` of code that has no module around it
      /// (scripts, `ctx.import`) and is required: it decides what the realm can load. `graph` is required too:
      /// the artifacts and authority the realm's modules are produced with (`api.graph` or a graph derived
      /// from it); a choice with consequences has no default.
      async create(options) {
        const { register, graphId, contexts, contextRefs, refsById, makeReference, host, invalid, named } = graphShared();
        const handler = own(options, 'import');
        const graph = own(options, 'graph');
        const preload = own(options, 'preload') ?? [];
        if (handler === undefined) throw invalid('create: import (an ImportHandler) is required');
        if (graph === undefined) throw invalid('create: graph is required (pass api.graph or a graph derived from it)');
        let graphNumber;
        try {
          graphNumber = graphId(graph);
        } catch {
          throw invalid('create: graph must be api.graph or a graph derived from it');
        }
        const codeGeneration = securityOf(own(options, 'security'), invalid);
        if (!Array.isArray(preload)) throw invalid('create: preload must be an array');
        for (const entry of preload) {
          const script = own(entry, 'source');
          const module = own(entry, 'module');
          if ((typeof script === 'string') === (typeof module === 'string'))
            throw invalid('create: a preload is exactly one of source and module');
        }
        const record = register(handler);
        let id;
        try {
          id = host(native.context.create, record.id, graphNumber, codeGeneration);
        } catch (error) {
          // The handler was registered a moment ago, so a stale handle here is the graph's.
          if (error?.name === 'StaleHandle' || error?.name === 'BadHandle')
            throw invalid('create: graph is closed, or not a graph of this realm');
          throw error;
        }
        const refs = new Set();
        const context = new Context({
          graph,
          /// Imports `specifier` as a script's `import()` would, through this context's handler. Resolves a
          /// reference to the evaluated module.
          async import(specifier, o) {
            if (typeof specifier !== 'string') throw invalid('import: specifier must be a string');
            const attributes = own(o, 'attributes') ?? {};
            const phase = own(o, 'phase') ?? 'evaluation';
            if (phase !== 'evaluation') throw named(errors.Unsupported, `${phase} imports are not implemented`);
            const name = await native.context.importSpecifier(id, specifier, attributesJson(attributes));
            const code = take();
            if (code !== 0) throw failure(code);
            for (const known of refs) if (known.name === name) return known;
            const imported = makeReference(graph, null, {
              name,
              text: undefined,
              handler,
              status: 'evaluated',
              context: id,
              contextObject: context,
            });
            graphShared().referenceState.get(imported).pin = host(native.context.pin, id, name);
            return imported;
          },
          /// The references bound to this context.
          get references() {
            return freeze([...refs]);
          },
          close() {
            refsById.delete(id);
            host(native.context.close, id);
          },
          [dispose]() {
            refsById.delete(id);
            native.context.close(id);
            take();
          },
        });
        contexts.set(context, id);
        contextRefs.set(context, refs);
        refsById.set(id, refs);
        for (let index = 0; index < preload.length; index++) {
          const values = own(preload[index], 'values');
          const script = own(preload[index], 'source');
          try {
            if (typeof script === 'string') {
              host(native.context.preload, id, script, 'preload:' + index, values);
            } else {
              const done = native.context.preloadModule(id, 'preload:' + index, own(preload[index], 'module'), values);
              const code = take();
              if (code !== 0) throw failure(code);
              await done;
            }
          } catch (error) {
            refsById.delete(id);
            native.context.close(id);
            take();
            throw error;
          }
        }
        return context;
      },
    });
  };

  return makeContextCap;
};
