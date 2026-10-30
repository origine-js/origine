// `origine:@std/transformer/oxc`: host transformers for the module graph (`ModuleSource#withTransformer`,
// `Transform.byExtension`, the maker of an `ImportHandler`).
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

  /** An immutable JS class descriptor the host runs natively on module source: no JS is entered to transform. */
  export interface OxcTransformer {
    readonly host: "oxc";
    readonly kind: "transformer";
    readonly transform: "ts" | "tsx" | "jsx";
    readonly options: OxcOptions;
  }

  /**
   * A TypeScript transformer: types are stripped, nothing is type-checked and no type-directed
   * emit happens. A source it rejects fails the import with `file:line:col: error: message` diagnostics.
   * Throws a `TypeError` for an option of the wrong type.
   */
  export function ts(options?: OxcOptions): OxcTransformer;
  /** The same factory, named for `.tsx`. */
  export function tsx(options?: OxcOptions): OxcTransformer;
  /** The same factory, named for `.jsx`. */
  export function jsx(options?: OxcOptions): OxcTransformer;
}
