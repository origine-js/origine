import type { Context } from "./context.d.ts";
import type { ModuleRecipe } from "origine:@std/graph/module";

/** The states of a {@link ModuleReference}, those of a V8 module. */
export type ModuleReferenceStatus = "declared" | "loaded" | "evaluating" | "evaluated" | "errored";

/** One static import of a loaded module. */
export interface ModuleRequest {
  readonly specifier: string;
  readonly attributes: Readonly<Record<string, string>>;
  /** Only `'evaluation'` is implemented by the engine. */
  readonly phase: "evaluation" | "source" | "defer";
  /** The module it resolved to: loaded from the same handler, bound to no context yet. */
  readonly reference: ModuleReference;
}

/**
 * An inert ticket for an entry in the table of the {@link ModuleGraph} that declared it (a module id): it
 * names a module and shows its state, and can do nothing. Holding one does not let you run, read or free the
 * module; the graph does that (`graph.load(reference)`, `graph.evaluate(reference, ctx)`, `graph.exports(reference)`,
 * `graph.release(reference)`). A reference belongs to one graph; another graph, another created graph included,
 * answers `InvalidInput` to it. It is bound to the first context that evaluates it and to no other; to run
 * the same code in a second context, declare the recipe again (sources and code caches are shared through the graph).
 */
export interface ModuleReference {
  /** The module's name in its context (a recipe's `name`, an import's resolved id). */
  readonly name: string;
  readonly status: ModuleReferenceStatus;
  /** The context the reference is bound to; `undefined` while it is not. */
  readonly context: Context | undefined;
}

/**
 * A graph: the table of modules shared by the contexts that use it (`api.graph.root`, or what
 * {@link GraphCap.create} returns). A graph holds no authority: files are read through the fs grants that hooks
 * (`fsProvider({ fs })`, `json({ fs })`, `ImportHook.accept({ fs })`) and sources (`ModuleSource.file(path, { fs })`)
 * name, and code caches are named by handlers and recipes (`codeCache`).
 */
export interface ModuleGraph {
  /**
   * A `declared` {@link ModuleReference} to the module `recipe` describes. Reads and compiles nothing; the
   * reference belongs to this graph. `InvalidInput` when `recipe` is not a `ModuleRecipe`; `StaleHandle`
   * on a closed graph.
   */
  declare(recipe: ModuleRecipe): ModuleReference;
  /**
   * Reads, transforms and compiles the module and makes a `declared` reference for each static import
   * ({@link ModuleGraph.requests}). One level at a time: load those references to go deeper; it works the same
   * on a dependency. Overlapping calls share one load. Resolves the reference itself. `InvalidInput` for a
   * reference another graph declared, `StaleHandle` once this graph is closed, `BadHandle` for a released one.
   */
  load(reference: ModuleReference): Promise<ModuleReference>;
  /** The static imports of a loaded reference; `undefined` until it is `loaded`. */
  requests(reference: ModuleReference): readonly ModuleRequest[] | undefined;
  /**
   * Binds `reference` to `ctx` and evaluates it there (top-level await included). Both must belong to this
   * graph: a reference of another graph, or a context made with another graph, is `InvalidInput` (so is a
   * reference already bound to another context). Rejects with a fresh `ModuleError` when the module or
   * something it imports fails. Evaluating again in the same context resolves at once.
   */
  evaluate(reference: ModuleReference, ctx: Context): Promise<void>;
  /**
   * The live module namespace, in the context the reference is bound to. Needs `status` to be `evaluated`
   * (otherwise `InvalidInput`); `StaleHandle` once the context is closed. Nothing is copied or frozen: every
   * export type works, bindings follow the module, and what you read is the context's own objects, so this
   * crosses the realm boundary (a function you call runs in that realm and can reach its globals). Hand data
   * over with `snapshot` and `deepFreeze` instead.
   */
  exports(reference: ModuleReference): Readonly<Record<string, unknown>>;
  /** Lets the host free what the reference pins; with `retain: 'used'` the module goes once nothing else holds it. */
  release(reference: ModuleReference): void;
}

/**
 * What {@link GraphCap.create} returns: a graph the caller owns. `api.graph.root` has no `close`: it lives
 * as long as the realm.
 */
export interface OwnedGraph extends ModuleGraph, Disposable {
  /**
   * Ends the graph. It takes no more contexts or references (`StaleHandle`), and the references it declared are stale, and the host frees what it
   * kept once the contexts using it are gone. Closing again is `StaleHandle`; `using` closes it and ignores a second close.
   */
  close(): void;
}

/** `api.graph`: a namespace of graphs. It is not a graph itself. */
export interface GraphCap {
  /** The shared root graph of the realm. It cannot be closed. */
  readonly root: ModuleGraph;
  /**
   * A new, separate graph the caller owns. It takes no options yet; any option is `InvalidInput`, so a stale
   * `fs`, `codeCache` or `sourceBytes` is loud.
   */
  create(options?: Record<never, never>): OwnedGraph;
}
