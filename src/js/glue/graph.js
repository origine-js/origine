// `api.graph` and the machinery `api.context` (glue/context.js) shares with it. An ES module factory used by
// index.js. The factory also publishes the shared parts in imported `shared.graph` (handler registry,
// JS driver, references) for the context glue; both modules import the shared state directly.
//
// A graph holds the authority modules are produced with (an fs grant, a code cache) and the table of the
// modules made with it. It is the entry point: a recipe is declared in it (`graph.declare(recipe)`), which
// gives an inert `ModuleReference`, and the graph loads it (`graph.load(reference)`), evaluates it in one
// context (`graph.evaluate(reference, ctx)`), reads its exports and frees it.
//
// Import handlers (origine:@std/graph/import) are registered with the host once, flattened to JSON:
// every host descriptor is run by the host, every function is run here, by the *driver*
// (`steps`: one layer, hook, maker, transformer or `meta` at a time), in the creating realm. The
// host runs the chain and calls the driver only when it reaches a function, so a handler with no
// function in it never reaches the driver. See docs/graph-api.md.
import { issuerOf, FsGrant, Cache, ModuleRecipe } from './handles.js';
import { CodeCacheKey, Graph, GraphFs } from './graph/data.js';
import { freeze, failure, own, errors, shared } from './util.js';
import source from './graph/source.js';
import handlers from './graph/handlers.js';
import driver from './graph/driver.js';
import reference from './graph/reference.js';
export default (native, { take, takeError }) => {
  const { InvalidInput } = errors;

  const dispose = Symbol.dispose ?? Symbol.for('Symbol.dispose');

  const named = (code, message) => failure(code, message);
  const invalid = message => named(InvalidInput, message);
  /// Calls a host native and throws what it left in the errno cell.
  const host = (fn, ...args) => {
    const value = fn(...args);
    const failed = takeError();
    if (failed !== undefined) throw failed;
    return value;
  };

  // State the parts share. Each part adds what the later ones use: `source`, then `handlers`, then the
  // `driver` (which `handlers` reaches through `g.bindDriver`), then the `reference`s (which reach
  // `g.graphId`, set below).
  const g = {
    native,
    take,
    takeError,
    host,
    named,
    invalid,
    /// Reads the state behind a reference (`link` verdicts name another context's module).
    referenceState: new WeakMap(),
    contexts: new WeakMap(),
    /// context object -> the references bound to it
    contextRefs: new WeakMap(),
    /// context id -> the references bound to it (the same sets as `contextRefs`); `link` verdicts name a module by context id
    refsById: new Map(),
  };
  Object.assign(g, source(g));
  Object.assign(g, handlers(g));
  Object.assign(g, driver(g));
  Object.assign(g, reference(g));
  const { byId, contextRefs, contexts, graphCache, graphFs, makeReference, referenceState, refsById, register } = g;
  const { loadRef, requestsOf, exportsOf, evaluateRef, releaseRef, isReference } = g;

  // ---- graphs ------------------------------------------------------------------------------------

  const graphs = new WeakMap();

  /// The native grant behind an `api.fs` grant, or undefined for anything else.
  const rawOf = fs => (fs instanceof FsGrant ? issuerOf(fs) : undefined);
  const cacheKinds = freeze({ codeCacheNone: 0, codeCacheMemory: 1, codeCacheDir: 2 });

  /// Ids of the graphs that were closed: their references are stale.
  const closedGraphs = new Set();

  /// The reference `reference` names in the graph numbered `id`: `InvalidInput` for anything that is not a
  /// reference this graph declared (a reference belongs to one graph, a derived graph cannot use its
  /// parent's), `StaleHandle` once the graph is closed.
  const own_ = (id, reference) => {
    if (!isReference(reference)) throw invalid('expected a ModuleReference');
    if (graphId(referenceState.get(reference).graph) !== id) throw invalid('this reference belongs to another graph');
    if (closedGraphs.has(id)) throw named(errors.StaleHandle, 'the graph is closed');
    return reference;
  };
  const settle = (id, reference, run) => {
    try {
      return run(own_(id, reference));
    } catch (error) {
      return Promise.reject(error);
    }
  };

  const makeGraph = (id, config) => {
    const graph = new Graph({
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
            await cache.store(new CodeCacheKey({ id: out[index][0], hash: out[index][1] }), out[index][2]);
        }
        return out[0];
      },
      /// Ends the graph: no more contexts or references can be made with it, its references are stale, and
      /// the host frees what it kept (code caches not yet flushed are dropped) once the contexts using it are gone.
      close() {
        host(native.graph.close, id);
        closedGraphs.add(id);
        graphFs.delete(id);
        graphCache.delete(id);
      },
      [dispose]() {
        native.graph.close(id);
        take();
        closedGraphs.add(id);
        graphFs.delete(id);
        graphCache.delete(id);
      },
      ...tableOps(id, () => graph),
    });
    graphs.set(graph, { id, config });
    return graph;
  };

  /// The operations of a graph on its table of modules; `self` is the graph object they belong to.
  const tableOps = (id, self) => ({
    /// A `declared` reference to the module `recipe` describes; nothing is read or compiled yet.
    declare(recipe) {
      if (!(recipe instanceof ModuleRecipe)) throw invalid('declare: expected a ModuleRecipe');
      if (closedGraphs.has(id)) throw named(errors.StaleHandle, 'the graph is closed');
      return makeReference(self(), recipe, null);
    },
    load: reference => settle(id, reference, loadRef),
    requests: reference => requestsOf(own_(id, reference)),
    evaluate(reference, ctx) {
      return settle(id, reference, ref => {
        const ctxGraph = ctx?.graph;
        let ctxId;
        try {
          ctxId = ctxGraph === undefined ? undefined : graphId(ctxGraph);
        } catch {
          ctxId = undefined;
        }
        if (contexts.get(ctx) === undefined) throw invalid('evaluate: expected a context');
        if (ctxId !== id) throw invalid('evaluate: the context belongs to another graph');
        return evaluateRef(ref, ctx);
      });
    },
    exports: reference => exportsOf(own_(id, reference)),
    release: reference => releaseRef(own_(id, reference)),
  });

  /// The largest source file a graph reads unless `derive({ sourceBytes })` says otherwise.
  const DEFAULT_SOURCE_BYTES = 64 * 1024 * 1024;

  const build = (fs, codeCache, sourceBytes = DEFAULT_SOURCE_BYTES) => {
    if (!Number.isSafeInteger(sourceBytes) || sourceBytes < 1) throw invalid('sourceBytes must be a positive integer');
    // JS private-field identity protects the wrapper. Only its closure-private state
    // reaches the native graph operation, which checks grant ownership and liveness.
    const rawFs = fs === undefined ? undefined : rawOf(fs);
    if (fs !== undefined && rawFs === undefined) throw invalid('graph fs must be a fs grant made by api.fs');
    let kind = 0;
    let bytes = 0;
    let cacheFs;
    let rawCacheFs;
    if (codeCache !== undefined) {
      if (!(codeCache instanceof Cache) || codeCache.kind !== 'codeCache') throw invalid('codeCache must be a CodeCache');
      if (codeCache.native === false) kind = 3;
      else {
        kind = cacheKinds[codeCache.host] ?? -1;
        if (kind < 0) throw invalid('unknown CodeCache');
        if (kind === 2) {
          cacheFs = codeCache.fs;
          rawCacheFs = rawOf(cacheFs);
          if (rawCacheFs === undefined) throw invalid('CodeCache.dir needs a sync fs grant made by api.fs');
        }
      }
      bytes = codeCache.bytes ?? 0;
    }
    if (fs !== undefined && fs.kind === 'async' && shared.fsAsync === undefined) throw invalid('async fs is not available');
    const id = host(native.graph.create, rawFs, kind, bytes, rawCacheFs, sourceBytes);
    if (kind === 3) graphCache.set(id, codeCache);
    if (fs !== undefined) {
      if (fs.kind === 'async') host(native.graph.asyncFs, id, rawFs, shared.fsAsync.openFile, shared.fsAsync.readAll, shared.fsAsync.close);
      graphFs.set(id, new GraphFs({ kind: fs.kind, id: fs.id, limit: sourceBytes }));
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

  shared.graph = freeze({
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
      declare: recipe => rootGraph().declare(recipe),
      load: reference => rootGraph().load(reference),
      requests: reference => rootGraph().requests(reference),
      evaluate: (reference, ctx) => rootGraph().evaluate(reference, ctx),
      exports: reference => rootGraph().exports(reference),
      release: reference => rootGraph().release(reference),
    };
    graphs.set(cap, {
      get id() {
        return graphId(rootGraph());
      },
      config: freeze({}),
    });
    return freeze(cap);
  };
  g.graphId = graphId;

  return makeGraphCap;
};
