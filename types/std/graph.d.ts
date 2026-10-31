// `origine:@std/graph/*`: the data side of the module graph. Frozen descriptions of modules, import
// pipelines and caches. Nothing consumes them yet: `api.graph` and `api.context` are designed in
// docs/graph-api.md and not implemented, so there is no way to load or evaluate a recipe today.

declare module "origine:@std/graph/module" {
  type NativeIdentity = import("origine:@std/graph/module").Descriptor;
  const descriptorBrand: unique symbol;
  /** Opaque identity supplied by the runtime's factories. */
  export interface Descriptor { readonly [descriptorBrand]: true; }

  /** An IoError thrown by builders for a malformed argument, with errno InvalidInput and a message. */
  type BuildError = { readonly errno: number; readonly name: "InvalidInput"; readonly message: string };

  /** Which phase an import asks for. Only `Evaluation` is implemented by the engine. */
  export const ModuleImportPhase: {
    readonly Evaluation: "evaluation";
    readonly Source: "source";
    readonly Defer: "defer";
  };
  export type ModuleImportPhase = (typeof ModuleImportPhase)[keyof typeof ModuleImportPhase];

  /** Where the source map of a module comes from. */
  export type SourceMap = (| { readonly kind: "none" }
    | { readonly kind: "url"; readonly value: string }
    | { readonly kind: "text"; readonly value: string }) & import("origine:@std/graph/module").Descriptor;
  export const SourceMap: {
    /** No map. The default. */
    readonly None: SourceMap;
    /** A map served from `url`. It is carried for tools; the engine does not fetch it. */
    url(url: string): SourceMap;
    /** A map given as JSON text. */
    text(json: string): SourceMap;
  };

  /**
   * A function `(source, id) => string | { source, map } | Promise<...>` that runs in the creating
   * realm, or a transformer descriptor (`Transform.byExtension(...)`) that the host runs.
   */
  export type Transformer =
    | ((source: string, id: string) => string | { readonly source: string; readonly map?: SourceMap } | Promise<string | { readonly source: string; readonly map?: SourceMap }>)
    | { readonly host: string; readonly kind: "transformer"; readonly native?: boolean };

  /** Source text: a file the graph reads with its fs grant, or text given directly. Immutable. */
  export interface ModuleSource extends NativeIdentity {
    readonly kind: "file" | "text";
    /** `kind: 'file'`: the path, relative to the graph's fs root. */
    readonly path?: string;
    /** `kind: 'text'`: the text. */
    readonly text?: string;
    readonly map: SourceMap;
    /** Applied in order, the last one last. */
    readonly transformers: readonly Transformer[];
    /** True when no transformer needs the JS realm. */
    readonly native: boolean;
    /** A new source with `transformer` chained after the existing ones; the receiver is unchanged. Throws `InvalidInput` for a non-transformer. */
    withTransformer(transformer: Transformer): ModuleSource;
  }
  export const ModuleSource: {
    /** A file at `path` (non-empty, no NUL), read by the graph's fs grant. Throws `InvalidInput`. */
    file(path: string, map?: SourceMap): ModuleSource;
    /** In-memory text. A recipe made from it needs a `name`. */
    text(text: string, map?: SourceMap): ModuleSource;
    is(value: unknown): value is ModuleSource;
  };

  /** What `ModuleRecipe` takes. */
  export interface ModuleRecipeOptions {
    readonly source: ModuleSource;
    /** Answers this module's imports. Required: it decides what the module can load. */
    readonly import: import("origine:@std/graph/import").ImportHandler;
    /** The V8 resource name. Defaults to the path of a file source; required for a text source. */
    readonly name?: string;
    /** Overrides the graph's code cache for this module. */
    readonly codeCache?: import("origine:@std/graph/cache").CodeCache;
  }

  /** An immutable description of a module. Describing is free; a graph loads and compiles it. */
  export interface ModuleRecipe extends NativeIdentity {
    readonly source: ModuleSource;
    readonly import: import("origine:@std/graph/import").ImportHandler;
    readonly name: string;
    /** `null`: use the graph's. */
    readonly codeCache: import("origine:@std/graph/cache").CodeCache | null;
    /** True when neither the source's transformers nor the import handler need the JS realm: the recipe is then plain data. */
    readonly native: boolean;
  }
  export const ModuleRecipe: {
    /** Throws `InvalidInput` for a missing or mistyped option. Options are read as own data properties (a getter counts as missing). */
    (options: ModuleRecipeOptions): ModuleRecipe;
    is(value: unknown): value is ModuleRecipe;
  };
}

declare module "origine:@std/graph/resolve" {
  type NativeIdentity = import("origine:@std/graph/module").Descriptor;
  /** What a resolver layer receives. */
  export interface ResolveRequest {
    readonly specifier: string;
    /** The id of the importing module. */
    readonly referrer: string;
    readonly attributes: Readonly<Record<string, string>>;
    readonly phase: import("origine:@std/graph/module").ModuleImportPhase;
  }
  /** What a layer returns to settle a specifier. */
  export interface Resolved {
    readonly id: string;
    readonly attributes?: Readonly<Record<string, string>>;
  }
  /** A host layer descriptor (see `origine:@std/graph/resolve/layers`) or a function run in the creating realm. `undefined` passes to the next layer. */
  export type ResolverLayer =
    | (import("origine:@std/graph/module").Descriptor & { readonly host: string; readonly kind: "layer" })
    | ((request: ResolveRequest) => Resolved | undefined | Promise<Resolved | undefined>);

  /** An ordered list of layers; the first answer wins and none means `NotFound`. Immutable. */
  export interface ImportResolver extends NativeIdentity {
    readonly layers: readonly ResolverLayer[];
    /** A new resolver with `layer` appended; the receiver is unchanged. Throws `InvalidInput` for a non-layer. */
    layer(layer: ResolverLayer): ImportResolver;
  }
  export const ImportResolver: {
    /** No layers yet. */
    layered(): ImportResolver;
    is(value: unknown): value is ImportResolver;
  };
}

declare module "origine:@std/graph/resolve/layers" {
  type NativeIdentity = import("origine:@std/graph/module").Descriptor;
  type Layer = (import("origine:@std/graph/module").Descriptor & { readonly host: string; readonly kind: "layer" });
  /** `./x` and `../x` against the importer's id. */
  export function relative(): Layer;
  /** Recognises `origine:` ids; serving them is `origineProvider`'s job. */
  export function origine(): Layer;
  export interface ImportMapData {
    readonly imports?: Readonly<Record<string, string>>;
    readonly scopes?: Readonly<Record<string, Readonly<Record<string, string>>>>;
  }
  /** Import map data as on the web, copied and frozen. Throws `InvalidInput` for a malformed map. */
  export function importMap(data: ImportMapData): Layer & {
    readonly imports: Readonly<Record<string, string>>;
    readonly scopes: Readonly<Record<string, Readonly<Record<string, string>>>>;
  };
}

declare module "origine:@std/graph/import" {
  type NativeIdentity = import("origine:@std/graph/module").Descriptor;
  type ModuleSource = import("origine:@std/graph/module").ModuleSource;
  type ModuleRecipe = import("origine:@std/graph/module").ModuleRecipe;
  type Transformer = import("origine:@std/graph/module").Transformer;
  type ImportResolver = import("origine:@std/graph/resolve").ImportResolver;
  type ImportCache = import("origine:@std/graph/cache").ImportCache;

  /** The kinds of failure an import can have: the `io` codes of `IoError` that apply, by name. */
  export const ImportError: {
    new (code: number, message?: string): import("origine:@std/errors").OrigineError;
    readonly prototype: import("origine:@std/errors").OrigineError;
    name(code: number): string;
    nameOf(code: number): string;
    of(code: number, message?: string): import("origine:@std/errors").OrigineError;
    readonly NotFound: 10;
    readonly PermissionDenied: 20;
    readonly Unsupported: 23;
    readonly InvalidInput: 30;
    readonly InvalidData: 31;
    /** The open case. `message` stays in the creating realm; a child sees a `ModuleError`. */
    other(message: string): import("origine:@std/errors").OrigineError & { readonly name: "Unexpected" };
    /** Whether `value` (a code or any `{ errno }`) is `code`. */
    is(value: number | { readonly errno?: number } | null | undefined, code: number): boolean;
  };
  export type ImportErrorCode = 10 | 20 | 23 | 30 | 31;

  /** What a hook receives for a resolved import. */
  export interface ResolvedImport {
    readonly id: string;
    readonly attributes: Readonly<Record<string, string>>;
    readonly specifier: string;
    readonly referrer: string;
    readonly phase: import("origine:@std/graph/module").ModuleImportPhase;
  }

  /** A hook's answer. All verdicts are immutable JS class instances. */
  export type Verdict = (| { readonly kind: "next" }
    | { readonly kind: "accept" }
    | { readonly kind: "provide"; readonly source: ModuleSource; readonly recipe?: never }
    | { readonly kind: "provide"; readonly recipe: ModuleRecipe; readonly source?: never }
    | { readonly kind: "link"; readonly reference: object }
    | { readonly kind: "exports"; readonly values: Readonly<Record<string, unknown>> }
    | { readonly kind: "reject"; readonly error: { readonly errno: number; readonly name: string; readonly message?: string } }) & import("origine:@std/graph/module").Descriptor;

  export const Import: {
    /** Not mine: continue with the next hook. */
    next(): Verdict;
    /** Stop the chain and use the default `maker`. */
    accept(): Verdict;
    /** Stop the chain with a source (the `maker` makes it a recipe) or a recipe (final; the maker is skipped). The importer gets its own module. */
    provide(target: ModuleSource | ModuleRecipe): Verdict;
    /**
     * Stop the chain and use a module already evaluated in some context: the importer links the module
     * itself, with live bindings and the other realm's objects (an alias when it is the importer's own
     * context). Nothing is copied or frozen, so this crosses the realm boundary on purpose: a function or
     * object exported that way runs in, and reaches, the exporting realm. To hand data over instead, build
     * a module of copies with `Import.exports`.
     */
    link(reference: object): Verdict;
    /**
     * Stop the chain with a module whose namespace is `values`: its own enumerable string-keyed data
     * properties, `default` included (an accessor is `InvalidInput`). The importer gets one synthetic module
     * with those bindings. Nothing is copied or frozen: each value is the caller's own object or function, shared as it
     * is, so the importer reaches whatever the values reach. Build them with `snapshot` and `seal` to hand data over.
     * An `origine:` id is never served this way (`PermissionDenied`).
     */
    exports(values: Readonly<Record<string, unknown>>): Verdict;
    /** Stop the chain with an error. Throws `InvalidInput` for any other code. */
    reject(error: ImportErrorCode | ReturnType<typeof ImportError.other>): Verdict;
  };

  /** A provider descriptor from `origine:@std/graph/providers`, or a function run in the creating realm. */
  export type Hook = (import("origine:@std/graph/module").Descriptor & { readonly host: string; readonly kind: "provider" }) | ((resolved: ResolvedImport) => Verdict | Promise<Verdict>);

  /** What a maker returns (or `MakeRecipe.inherit` is given): recipe options, never a recipe. */
  export interface MakerOptions {
    /** The handler for the made module's own imports. Defaults to the handler being made. */
    readonly import?: ImportHandler;
    readonly transformer?: Transformer;
  }
  export type Maker = (| ({ readonly host: "maker"; readonly kind: "maker" } & MakerOptions)
    | { readonly kind: "maker"; readonly native: false; readonly fn: (supplied: { readonly id: string; readonly source: ModuleSource }) => MakerOptions | Promise<MakerOptions> }) & import("origine:@std/graph/module").Descriptor;
  export const MakeRecipe: {
    /** Native: inherit this handler (or `options.import`) and apply `options.transformer` to every supplied source. */
    inherit(options?: MakerOptions): Maker;
    /** Your own, run in the creating realm for every supplied source. */
    fn(fn: (supplied: { readonly id: string; readonly source: ModuleSource }) => MakerOptions | Promise<MakerOptions>): Maker;
  };

  export const Transform: {
    /**
     * Picks a transformer by the extension of the module id (`'.ts'`; the longest suffix wins, so `.d.ts`
     * beats `.ts`). At most 64 extensions. Throws `InvalidInput` for a bad extension or value.
     */
    byExtension(map: Readonly<Record<string, Transformer>>): {
      readonly host: "byExtension";
      readonly kind: "transformer";
      /** False when any entry is a function. */
      readonly native: boolean;
      readonly entries: readonly (readonly [extension: string, transformer: Transformer])[];
    };
  };

  /** One element of the pipeline, in order. */
  export interface PlanEntry {
    readonly stage: "resolver" | "hooks" | "maker" | "transformer" | "cache" | "meta";
    /** `'native'`: run by the host with no JS; `'js'`: run in the creating realm. */
    readonly kind: "native" | "js";
    /** The host name of a native element. */
    readonly name?: string;
  }

  export interface ImportHandlerOptions {
    /** At least one layer. */
    readonly resolver: ImportResolver;
    /** A hook or an array of them, in order. Required; an empty array resolves nothing. */
    readonly hooks: Hook | readonly Hook[];
    /** Default `MakeRecipe.inherit()`. */
    readonly maker?: Maker;
    /**
     * Default `ImportCache.native({ retain: 'all' })`, made once per handler. Contexts that use the same
     * `ImportCache` object share its modules, so two contexts created from one handler object share module
     * instances (live bindings, the same objects) unless you give each its own handler or cache. Sharing
     * leaks the realm boundary: objects of the home context (the first to import a module) reach the others.
     */
    readonly cache?: ImportCache;
    /** `({ id }) => data`, called when a module is made; the plain-data result becomes its `import.meta`. */
    readonly meta?: (info: { readonly id: string }) => Readonly<Record<string, unknown>>;
  }

  /** A module's import pipeline: resolver -> hooks -> maker, plus a cache. Immutable. */
  export interface ImportHandler extends NativeIdentity {
    readonly resolver: ImportResolver;
    readonly hooks: readonly Hook[];
    readonly maker: Maker;
    readonly cache: ImportCache;
    readonly meta: ImportHandlerOptions["meta"] | null;
    /** Every element in pipeline order, so the cost is visible. */
    readonly plan: readonly PlanEntry[];
    /** True when no import of this handler enters the JS realm. */
    readonly native: boolean;
  }
  export const ImportHandler: {
    /** Throws `InvalidInput` for a missing or mistyped option, a resolver with no layers, or a hook that is not a function or provider. */
    make(options: ImportHandlerOptions): ImportHandler;
    is(value: unknown): value is ImportHandler;
  };
}

declare module "origine:@std/graph/providers" {
  type NativeIdentity = import("origine:@std/graph/module").Descriptor;
  type Verdict = import("origine:@std/graph/import").Verdict;
  type ResolvedImport = import("origine:@std/graph/import").ResolvedImport;
  type Provider = (import("origine:@std/graph/module").Descriptor & { readonly host: string; readonly kind: "provider" });

  /**
   * Serves `origine:@std/*` modules from the host, with their natives bound to the importing context.
   * With no options, or `std: true`, it serves every one the creating context itself may import. `std`
   * can name fewer, without the `origine:@std/` prefix (`'text'`, `'transformer/oxc'`): exactly one of
   * `include` and `exclude`. Whatever it asks for, it can only narrow what the creating context may
   * import: a hook that names more is `PermissionDenied`, and the default is that context's own set.
   */
  export function origineProvider(options?: {
    readonly std?: true | { readonly include: readonly string[]; readonly exclude?: never } | { readonly exclude: readonly string[]; readonly include?: never };
  }): Provider & { readonly std: { readonly all: true } | { readonly include?: readonly string[]; readonly exclude?: readonly string[] } };
  /** Reads source files with the graph's fs grant. `read` is required: `'mmap'` avoids a copy for ASCII/Latin-1 text, but a file changed while mapped changes under V8. */
  export function fsProvider(options: { readonly read: "copy" | "mmap" }): Provider & { readonly read: "copy" | "mmap" };
  /** Serves `type: 'json'` imports as a module whose default export is the parsed value. */
  export function json(): Provider;
  /** Adapts a loader function to a hook: `loader(id, attributes)` returns source text, `{ source }`, or a promise of either. */
  export function fromLoader(
    loader: (id: string, attributes: Readonly<Record<string, string>>) => string | { readonly source: string } | Promise<string | { readonly source: string }>,
  ): (resolved: ResolvedImport) => Promise<Verdict>;
}

declare module "origine:@std/graph/cache" {
  type NativeIdentity = import("origine:@std/graph/module").Descriptor;
  /**
   * A table of modules: (id, attributes) -> module. The object is the table's name: handlers made with the
   * same object keep their modules in the same table, handlers made with two objects keep two modules for
   * one id, also inside one context. Keep one object per table you want to inspect.
   */
  export type ImportCache = ({
    readonly host: "importCache";
    readonly kind: "cache";
    /** How many modules the table holds, in the contexts this realm created. Needs `api.graph` or `api.context`. */
    readonly size: number;
    /**
     * Forgets the module `id` (and what imported it) in every context this realm created, so the next import
     * makes and evaluates a new one while the old one keeps working. Returns how many modules it dropped.
     */
    delete(id: string): number;
    /** Forgets every module of the table, in every context this realm created. Returns how many it dropped. */
    clear(): number;
    /** `'all'`: entries live as long as the context. `'used'`: dropped once nothing holds them, so a later import evaluates the module again. Per table. */
    readonly retain: "all" | "used";
  }) & import("origine:@std/graph/module").Descriptor;
  export const ImportCache: {
    /**
     * `retain` is required because it changes what re-importing does. There is no `entries` cap: an identity
     * table never evicts one module while others stay, so its only bounds are `retain: "used"`, `delete` and
     * `clear`. Passing `entries` is `InvalidInput`. Throws `InvalidInput`.
     */
    native(options: { readonly retain: "all" | "used" }): ImportCache;
  };

  /** The native memo of resolver results. */
  export type ResolveCache = ({ readonly host: "resolveCache"; readonly kind: "cache"; readonly entries?: number }) & import("origine:@std/graph/module").Descriptor;
  export const ResolveCache: {
    native(options?: { readonly entries?: number }): ResolveCache;
  };

  /** (id, source hash) -> V8 code-cache bytes. */
  export type CodeCache = (| { readonly host: "codeCacheNone" | "codeCacheMemory" | "codeCacheDir"; readonly kind: "codeCache"; readonly bytes?: number; readonly fs?: object }
    | {
        readonly kind: "codeCache";
        readonly native: false;
        readonly load: (key: CodeCacheKey, source: string) => Uint8Array | undefined | Promise<Uint8Array | undefined>;
        readonly store: (key: CodeCacheKey, blob: Uint8Array) => void | Promise<void>;
      }) & import("origine:@std/graph/module").Descriptor;
  export interface CodeCacheKey {
    /** The module id (the `name` of a root module). */
    readonly id: string;
    /** Lowercase hex BLAKE3 digest of the exact text V8 compiles (after every transformer). */
    readonly hash: string;
  }
  export const CodeCache: {
    /** Every compile parses. */
    readonly none: CodeCache;
    /** Kept in the graph's memory and shared by its contexts; `bytes` caps it. */
    memory(options?: { readonly bytes?: number }): CodeCache;
    /**
     * Files in the directory an `api.fs` grant allows (it needs write access), one per distinct source text
     * at `__codecache__/<32 hex digits of BLAKE3(runtime, module kind, source text)>.v8-code-cache`. The
     * module id is not in the name, so a virtual id (`app:/x.js`, `https://...`) or one with `..` cannot land
     * outside `__codecache__` or depend on the working directory, and identical sources share a file; each file
     * holds the hash of the source it was made from and is ignored for any other text. Touches the disk;
     * written at `graph.flush()`.
     */
    dir(fs: object, options?: { readonly bytes?: number }): CodeCache;
    /**
     * Your own store; both functions may be async and run in the creating realm. `store(key, blob)` runs at
     * `graph.flush()` with an opaque blob to keep whole; `load(key, source)` runs once a module's source is
     * final, before it compiles, and returns the blob kept under that key or `undefined`. A blob made for
     * another source text or V8 build, or a rejected `load`, is a miss, never an error.
     */
    custom(options: {
      readonly load: (key: CodeCacheKey, source: string) => Uint8Array | undefined | Promise<Uint8Array | undefined>;
      readonly store: (key: CodeCacheKey, blob: Uint8Array) => void | Promise<void>;
    }): CodeCache;
  };
}
