/** What a scope `loader` returns for a module: its source text, or `{ source }`. */
export type LoaderResult = string | { readonly source: string };

/**
 * Supplies module source for a child scope. Called with the module id in the **creating** scope;
 * may be async. A throw or rejection fails the import. It must not create scopes (`Unsupported`).
 */
export type Loader = (moduleId: string) => LoaderResult | Promise<LoaderResult>;

/** A JavaScript source transform for one file extension: `(source, id) => string | { source }`. Promises are not supported. */
export type SourceTransform = (source: string, id: string) => string | { readonly source: string };

/**
 * A host transformer made by `ts()`, `tsx()` or `jsx()` of `origine:@std/transformer/oxc`. It is a
 * function `(source, id) => string` that the host runs natively when a child scope uses it.
 */
export interface HostTransformer {
  (source: string, id: string): string;
}

/** Import map data (parsed natively): `imports` and `scopes`, as in the web's import maps. */
export interface ImportMap {
  readonly imports?: Readonly<Record<string, string>>;
  readonly scopes?: Readonly<Record<string, Readonly<Record<string, string>>>>;
}

/** A script (`source`, a function expression called with `values`) or an ES module (`module`, whose default export is called with `values` when it is a function) run in the child before `main`. */
export type Preload =
  | { readonly source: string; readonly module?: never; readonly values?: unknown }
  | { readonly module: string; readonly source?: never; readonly values?: unknown };

/** Extension (`'.ts'`, starting with a dot; the longest suffix wins) to its transformer. */
export type Transformers = Readonly<Record<string, HostTransformer | SourceTransform>>;

interface ScopeOptionsBase {
  /** The specifier of the main module. */
  readonly main: string;
  /** Import map data. */
  readonly importMap?: ImportMap;
  /** Scripts and modules evaluated in order before `main`; `values` is deep-frozen plain data and functions only. */
  readonly preload?: readonly Preload[];
  /**
   * Lets the child import the host's `origine:` modules. It is the parent's to give: a parent
   * scope without it gets `Unsupported`, so a child cannot widen its authority.
   */
  readonly origineNamespace?: boolean;
}

/**
 * Options of {@link ScopeCap.create}. `transformers` need a `loader` (`InvalidInput` otherwise), and
 * the type says so: a scope has either neither or a loader with optional transformers.
 */
export type ScopeOptions = ScopeOptionsBase &
  (
    | { readonly loader?: never; readonly transformers?: never }
    | { readonly loader: Loader; readonly transformers?: Transformers }
  );

/** A child scope. `using scope = await api.scope.create(...)` closes it. */
export interface ScopeHandle extends Disposable {
  /** Evaluates the child's `main` module. Rejects with the child's failure. */
  run(): Promise<void>;
  /** Destroys the scope and everything it owns, revoking its grants. Throws a `HostError` (`BadHandle`, `StaleHandle`) when the handle is not live. */
  close(): void;
}

/** `api.scope`: child scopes. A child gets no capability unless the parent hands it a slice through `preload` values. */
export interface ScopeCap {
  /** Creates a child scope. Rejects `InvalidInput` for malformed options (a missing `main`, `transformers` without a `loader`, a preload that is not exactly one of `source`/`module`). */
  create(options: ScopeOptions): Promise<ScopeHandle>;
}
