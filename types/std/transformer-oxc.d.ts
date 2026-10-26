// `origine:@std/transformer/oxc`: host transformers for `api.scope.create({ transformers })`.
declare module "origine:@std/transformer/oxc" {
  /** Options of the oxc transformers (all optional). */
  export interface OxcOptions {
    /** JSX runtime: `'automatic'` needs the runtime module importable (see `importSource`); `'classic'` uses `pragma`. */
    readonly jsx?: "automatic" | "classic";
    /** Module the automatic runtime imports from. */
    readonly importSource?: string;
    /** Classic runtime element factory. */
    readonly pragma?: string;
    /** Classic runtime fragment factory. */
    readonly pragmaFrag?: string;
    /** Use the development JSX runtime. */
    readonly development?: boolean;
    /** Keep imports that only name types. */
    readonly verbatimImports?: boolean;
    /** Append an inline source map. */
    readonly inlineSourceMap?: boolean;
  }

  type HostTransformer = import("../scope.d.ts").HostTransformer;

  /**
   * A TypeScript transformer: types are stripped, nothing is type-checked and no type-directed
   * emit happens. Throws a `SyntaxError` with `file:line:col: error: message` diagnostics.
   */
  export function ts(options?: OxcOptions): HostTransformer;
  /** The same factory, named for `.tsx`. */
  export function tsx(options?: OxcOptions): HostTransformer;
  /** The same factory, named for `.jsx`. */
  export function jsx(options?: OxcOptions): HostTransformer;
}
