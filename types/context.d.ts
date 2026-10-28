import type { ModuleGraph, ModuleReference } from "./graph.d.ts";

/** A script (`source`, a function expression called with `values`) or an ES module (`module`, whose default export is called with `values` when it is a function) run in the context before it imports anything. */
export type Preload =
  | { readonly source: string; readonly module?: never; readonly values?: unknown }
  | { readonly module: string; readonly source?: never; readonly values?: unknown };

/** Options of {@link ContextCap.create}. */
export interface ContextOptions {
  /**
   * The handler that answers `import()` in code that has no module around it (scripts, preloads,
   * `context.import`). Required: it decides what the realm can load.
   */
  readonly import: import("origine:@std/graph/import").ImportHandler;
  /** Default `api.graph`. */
  readonly graph?: ModuleGraph;
  /** Run in order before anything is imported; `values` is deep-frozen plain data and functions only. */
  readonly preload?: readonly Preload[];
}

/** A realm (V8 context) whose imports run through an import handler. `using ctx = await api.context.create(...)` closes it. */
export interface Context extends Disposable {
  readonly graph: ModuleGraph;
  /**
   * Imports `specifier` as a script's `import()` would, through the context's own handler. Resolves a
   * reference to the evaluated module; rejects with a fresh `ModuleError` when the import fails.
   */
  import(specifier: string, options?: { readonly attributes?: Readonly<Record<string, string>>; readonly phase?: "evaluation" }): Promise<ModuleReference>;
  /** The references bound to this context. */
  readonly references: readonly ModuleReference[];
  /** Destroys the realm and everything it owns. Throws a `HostError` (`BadHandle`, `StaleHandle`) when it is not live. */
  close(): void;
}

/** `api.context`: realms. A context gets no capability unless the parent hands it a slice through `preload` values. */
export interface ContextCap {
  /**
   * Creates a context. Rejects `InvalidInput` for malformed options (a missing `import`, a preload that is
   * not exactly one of `source`/`module`) and `ModuleError` when a preload fails.
   */
  create(options: ContextOptions): Promise<Context>;
}
