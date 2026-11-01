// `api.graph` and the machinery `api.context` (glue/context.js) shares with it. An ES module factory used by
// index.js. The factory also publishes the shared parts in imported `shared.graph` (handler registry,
// JS driver, references) for the context glue; both modules import the shared state directly.
//
// A graph holds the table of the modules made with it and no authority: the fs grants and code caches are
// named by the hooks, sources, handlers and recipes that use them. It is the entry point: a recipe is declared in it (`graph.declare(recipe)`), which
// gives an inert `ModuleReference`, and the graph loads it (`graph.load(reference)`), evaluates it in one
// context (`graph.evaluate(reference, ctx)`), reads its exports and frees it.
//
// Import handlers (origine:@std/graph/import) are registered with the host once, flattened to JSON:
// every host descriptor is run by the host, every function is run here, by the *driver*
// (`steps`: one layer, hook, maker, transformer or `meta` at a time), in the creating realm. The
// host runs the chain and calls the driver only when it reaches a function, so a handler with no
// function in it never reaches the driver. See docs/graph-api.md.
import { ModuleRecipe } from './handles.js';
import { Graph } from './graph/data.js';
import { freeze, failure, own, errors, shared } from './util.js';
import source from './graph/source.js';
import handlers from './graph/handlers.js';
import driver from './graph/driver.js';
import reference from './graph/reference.js';
export default (native, { take, takeError }) => {
  const { InvalidInput } = errors;

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
  const { byId, contextRefs, contexts, makeReference, referenceState, refsById, register } = g;
  const { loadRef, requestsOf, exportsOf, evaluateRef, releaseRef, isReference } = g;

  // ---- graphs ------------------------------------------------------------------------------------

  const graphs = new WeakMap();

  /// Ids of the graphs that were closed: their references are stale.
  const closedGraphs = new Set();

  /// The reference `reference` names in the graph numbered `id`: `InvalidInput` for anything that is not a
  /// reference this graph declared (a reference belongs to one graph), `StaleHandle` once the graph is closed.
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

  const makeGraph = (id, owned) => {
    const graph = new Graph({
      // Only a graph made by `create` is the caller's to end; the root lives as long as the realm.
      ...(owned
        ? {
            /// Ends the graph: no more contexts or references can be made with it, its references are stale, and
            /// the host frees what it kept once the contexts using it are gone.
            close() {
              host(native.graph.close, id);
              closedGraphs.add(id);
            },
            [Symbol.dispose]() {
              native.graph.close(id);
              take();
              closedGraphs.add(id);
            },
          }
        : {}),
      ...tableOps(id, () => graph),
    });
    graphs.set(graph, { id });
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

  /// A graph. It has no options yet: files are read through the grants hooks and sources name, and code caches
  /// are named by handlers and recipes. An option is `InvalidInput` so a stale `fs`, `codeCache` or `sourceBytes` is loud.
  const build = (options, owned) => {
    if (options !== undefined) {
      if (options === null || typeof options !== 'object') throw invalid('graph.create: options must be an object');
      for (const key of Reflect.ownKeys(options)) throw invalid(`graph.create: unknown option ${String(key)}`);
    }
    const id = host(native.graph.create);
    withoutAsyncOps.add(id);
    if (shared.fsAsync !== undefined) shared.graphAsyncOps();
    return makeGraph(id, owned);
  };

  /// Gives graphs the natives that read a file of an async grant a hook names; they hold no authority
  /// themselves. Those natives exist once `api.fs` is bound, which may be after a graph was made, and an
  /// async grant cannot exist before `requestAsync` calls this.
  const withoutAsyncOps = new Set();
  shared.graphAsyncOps = () => {
    const { openFile, readAll, close } = shared.fsAsync;
    for (const id of withoutAsyncOps) if (!closedGraphs.has(id)) host(native.graph.asyncOps, id, openFile, readAll, close);
    withoutAsyncOps.clear();
  };

  let root;
  /// Graph ids by graph object, for `api.context`.
  const graphId = graph => {
    const found = graphs.get(graph);
    if (found === undefined) throw invalid('expected a graph');
    return found.id;
  };

  const rootGraph = () => (root ??= build(undefined, false));

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

  // `api.graph` is a namespace: `root` is the shared graph (no `close`), `create` makes a separate one.
  const makeGraphCap = () =>
    freeze({
      create: options => build(options, true),
      /// Made on first use: building it calls the host, which a snapshot cannot.
      get root() {
        return rootGraph();
      },
    });
  g.graphId = graphId;

  return makeGraphCap;
};
