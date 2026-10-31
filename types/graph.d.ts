import type { AsyncFs, SyncFs } from "./fs.d.ts";
import type { Context } from "./context.d.ts";
import type { ModuleRecipe } from "origine:@std/graph/module";

/** The states of a {@link ModuleReference}, those of a V8 module. */
export type ModuleReferenceStatus = "declared" | "loaded" | "instantiated" | "evaluating" | "evaluated" | "errored";

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
 * `graph.release(reference)`). A reference belongs to one graph; another graph, a derived graph included,
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

/** What {@link ModuleGraph.derive} may replace. */
export interface GraphOptions {
  /**
   * A grant `api.fs` made: the only authority sources are read with. A sync grant (`requestSync`) is read
   * with the host's blocking read; an async one (`await requestAsync({ handle: 'plain', io })`) on its io runtime, without
   * blocking and without entering JS. Anything but a grant `api.fs` made is `InvalidInput`.
   */
  readonly fs?: SyncFs | AsyncFs;
  /** `origine:@std/graph/cache`: where V8 code caches are kept. Default: none. */
  readonly codeCache?: import("origine:@std/graph/cache").CodeCache;
  /**
   * The largest source file the graph reads through its fs grant, in bytes (a positive integer). A larger
   * file fails the import with `FileTooLarge`; it is never cut short. Default: the graph's own
   * ({@link ModuleGraph.sourceBytes}), 64 MiB for `api.graph`.
   */
  readonly sourceBytes?: number;
}

/**
 * `api.graph`, and what {@link ModuleGraph.derive} returns: the artifacts shared by the contexts
 * that use it (sources, V8 code caches) and the authority they are produced with (an fs grant, a
 * code cache store). `api.graph` itself holds no fs grant: derive one with an fs grant to read files.
 */
export interface ModuleGraph {
  /**
   * A new graph derived from this one, with `options` replacing the fs grant, the code cache or the source
   * limit. Deriving can only narrow authority, never widen it: the graph holds nothing the realm does
   * not already hold. Throws `InvalidInput` for a grant that is not sync or a malformed cache.
   */
  derive(options?: GraphOptions): DerivedGraph;
  /** The largest source file the graph reads through its fs grant, in bytes. */
  readonly sourceBytes: number;
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
   * over with `snapshot` and `seal` instead.
   */
  exports(reference: ModuleReference): Readonly<Record<string, unknown>>;
  /** Lets the host free what the reference pins; with `retain: 'used'` the module goes once nothing else holds it. */
  release(reference: ModuleReference): void;
  /**
   * Persists the V8 code caches of modules that compiled without a usable one (a `dir` cache writes
   * its files, a `custom` one gets `store` calls). Resolves how many modules were stored.
   */
  flush(): Promise<number>;
}

/**
 * What {@link ModuleGraph.derive} returns: a graph the caller owns. `api.graph` has no `close`: it lives
 * as long as the realm.
 */
export interface DerivedGraph extends ModuleGraph, Disposable {
  /**
   * Ends the graph. It takes no more contexts or references (`StaleHandle`), and the references it declared are stale, and the host frees what it
   * kept, the code caches among them, once the contexts using it are gone. Code caches that were not
   * `flush`ed are dropped. Closing again is `StaleHandle`; `using` closes it and ignores a second close.
   */
  close(): void;
}
