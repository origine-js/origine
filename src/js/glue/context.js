// `api.context`: realms whose imports run through an ImportHandler. An ES module factory used by
// index.js. It builds on the parts the graph glue
// publishes in shared module state (index.js prepares `graph` before `context`).
import { recordOf, freeze, failure, own, shared, errors } from './util.js';
export default (native, { take }) => {
  const dispose = Symbol.dispose ?? Symbol.for('Symbol.dispose');

  const attributesJson = attributes => (Object.keys(attributes).length === 0 ? '' : JSON.stringify(attributes));

  const makeContextCap = () => {
    const graphShared = () => shared.graph;
    return freeze({
      /// A realm. `import` (an ImportHandler) answers the `import()` of code that has no module around it
      /// (scripts, `ctx.import`) and is required: it decides what the realm can load. `graph` defaults to
      /// `api.graph`.
      async create(options) {
        const { register, rootGraph, graphId, contexts, contextRefs, refsById, makeReference, host, invalid, named } = graphShared();
        const handler = own(options, 'import');
        const graph = own(options, 'graph') ?? rootGraph();
        const preload = own(options, 'preload') ?? [];
        if (handler === undefined) throw invalid('create: import (an ImportHandler) is required');
        if (!Array.isArray(preload)) throw invalid('create: preload must be an array');
        for (const entry of preload) {
          const script = own(entry, 'source');
          const module = own(entry, 'module');
          if ((typeof script === 'string') === (typeof module === 'string'))
            throw invalid('create: a preload is exactly one of source and module');
        }
        const record = register(handler);
        const id = host(native.context.create, record.id, graphId(graph));
        const refs = new Set();
        const context = recordOf('Context', {
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
