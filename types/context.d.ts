import type { ModuleGraph, ModuleReference } from "./graph.d.ts";

/** A script (`source`, a function expression called with `values`) or an ES module (`module`, whose default export is called with `values` when it is a function) run in the context before it imports anything. */
export type Preload =
  | { readonly source: string; readonly module?: never; readonly values?: unknown }
  | { readonly module: string; readonly source?: never; readonly values?: unknown };

/** The realm-hardening switches of {@link ContextOptions.security}. Every one is off unless set. */
export interface ContextSecurity {
  /**
   * Whether code in the realm may compile strings: `eval`, `new Function` and the `AsyncFunction`,
   * `GeneratorFunction` and `AsyncGeneratorFunction` constructors (reached through `fn.constructor`). Default
   * `false`: they throw `EvalError: Code generation from strings disallowed for this context`.
   *
   * CAUTION: enabling it lets code in the realm compile strings (`eval`, `new Function`, `fn.constructor('...')`).
   * Functions are shared across realms (by `Import.link`, `graph.exports(ref)`, `Import.exports` values and
   * preload `values`), and V8 checks the realm the constructor belongs to, not the caller's. So any function
   * exported from a context with this enabled lets its importers run arbitrary code in that realm
   * (`Promise.resolve('return globalThis.secret').then(fn.constructor)` from another realm builds and returns a
   * function that runs in this one): it effectively gives up the realm boundary. Do not enable it for a context
   * whose functions reach less trusted code. Do not rely on V8 refusing a direct `fn.constructor(...)` call from
   * another realm (a `TypeError: no access`, from the security tokens): a microtask gets around it. With the
   * default every such call is an `EvalError`, in any realm. `WebAssembly` is not affected: it compiles bytes, and
   * wasm code cannot reach the realm's globals.
   */
  readonly codeGeneration?: boolean;
}

/** Options of {@link ContextCap.create}. */
export interface ContextOptions {
  /**
   * The handler that answers `import()` in code that has no module around it (scripts, preloads,
   * `context.import`). Required: it decides what the realm can load.
   */
  readonly import: import("origine:@std/graph/import").ImportHandler;
  /**
   * The graph the realm's modules are produced with: `api.graph` or a graph derived from it. Required, no
   * default: it decides what authority sources are read with and where code caches live. Missing, not a
   * graph the host made, or closed is `InvalidInput`.
   */
  readonly graph: ModuleGraph;
  /**
   * Switches that weaken the realm's hardening, all off by default (`codeGeneration`). An unknown key, a
   * non-object or a non-boolean value is `InvalidInput`. Cost visible in the name: this is the place for switches
   * a parent turns on knowingly.
   */
  readonly security?: ContextSecurity;
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
   * Creates a context. Contexts whose `import` handlers use the same `ImportCache` object (a handler makes
   * its default one once, so contexts made from one handler object use the same) share that cache's modules:
   * the first to import an id evaluates it and the others link that module (live bindings, same objects),
   * which leaks the realm boundary; give each context its own handler or cache to keep them apart.
   * Rejects `InvalidInput` for malformed options (a missing `import`, a missing, forged or closed `graph`, a preload that is
   * not exactly one of `source`/`module`) and `ModuleError` when a preload fails.
   */
  create(options: ContextOptions): Promise<Context>;
}
