import type { AsyncFs, SyncFs } from "./fs.d.ts";
import type { Context } from "./context.d.ts";

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
 * A handle to a module of a {@link ModuleGraph}: the V8 module. Made by `recipe.create(graph)`
 * (`origine:@std/graph/module`) or returned by `context.import`. It is bound to the first context
 * that evaluates it and to no other; to run the same code in a second context, `recipe.create(graph)`
 * again (sources and code caches are shared through the graph).
 */
export interface ModuleReference extends Disposable {
  /** The module's name in its context (a recipe's `name`, an import's resolved id). */
  readonly name: string;
  readonly status: ModuleReferenceStatus;
  /** `undefined` until the reference is `loaded`. */
  readonly requests: readonly ModuleRequest[] | undefined;
  /** The context the reference is bound to; `undefined` while it is not. */
  readonly context: Context | undefined;
  /** Reads, transforms and compiles the module and loads its static imports. Resolves the reference itself. */
  load(): Promise<ModuleReference>;
  /**
   * Binds the reference to `ctx` and evaluates it there (top-level await included). Rejects with a
   * fresh `ModuleError` when the module or something it imports fails, and with `InvalidInput` when the
   * reference is bound to another context. Evaluating again in the same context resolves at once.
   */
  evaluate(ctx: Context): Promise<void>;
  /** Lets the host free what the reference pins; with `retain: 'used'` the module goes once nothing else holds it. */
  release(): void;
}

/** What {@link ModuleGraph.narrow} may replace. */
export interface GraphOptions {
  /**
   * A grant `api.fs` made: the only authority sources are read with. A sync grant (`requestSync`) is read
   * with the host's blocking read; an async one (`await requestAsync({ io })`) on its io runtime, without
   * blocking and without entering JS. Anything but a grant `api.fs` made is `InvalidInput`.
   */
  readonly fs?: SyncFs | AsyncFs;
  /** `origine:@std/graph/cache`: where V8 code caches are kept. Default: none. */
  readonly codeCache?: import("origine:@std/graph/cache").CodeCache;
}

/**
 * `api.graph`, and what {@link ModuleGraph.narrow} returns: the artifacts shared by the contexts
 * that use it (sources, V8 code caches) and the authority they are produced with (an fs grant, a
 * code cache store). `api.graph` itself holds no fs grant: narrow it to read files.
 */
export interface ModuleGraph {
  /**
   * A graph with `options` replacing the fs grant or the code cache. It holds nothing the realm does
   * not already hold. Throws `InvalidInput` for a grant that is not sync or a malformed cache.
   */
  narrow(options?: GraphOptions): NarrowedGraph;
  /**
   * Persists the V8 code caches of modules that compiled without a usable one (a `dir` cache writes
   * its files, a `custom` one gets `store` calls). Resolves how many modules were stored.
   */
  flush(): Promise<number>;
}

/**
 * What {@link ModuleGraph.narrow} returns: a graph the caller owns. `api.graph` has no `close`: it lives
 * as long as the realm.
 */
export interface NarrowedGraph extends ModuleGraph, Disposable {
  /**
   * Ends the graph. It takes no more contexts or references (`StaleHandle`), and the host frees what it
   * kept, the code caches among them, once the contexts using it are gone. Code caches that were not
   * `flush`ed are dropped. Closing again is `StaleHandle`; `using` closes it and ignores a second close.
   */
  close(): void;
}
