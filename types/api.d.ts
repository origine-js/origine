import type { HostCap } from "./host.d.ts";
import type { FsCap } from "./fs.d.ts";
import type { IoCap } from "./io.d.ts";
import type { NetCap } from "./net.d.ts";
import type { ContextCap } from "./context.d.ts";
import type { ModuleGraph } from "./graph.d.ts";
import type { IsolateCap } from "./isolate.d.ts";

/**
 * The host API handed to `main`: every permission a program has. Frozen. Narrow a capability
 * (`api.host.env.narrow`, `api.io.narrow`) to hand a slice to a context; nothing widens one.
 * `api.io` and `api.net` exist where the embedder gave the program a runtime ceiling (the
 * `origine` shell does); see {@link BasicApi} for code that must also run without it.
 */
export interface Api {
  /** File system grants (`requestSync`, `requestAsync`). */
  readonly fs: FsCap;
  /** Async runtimes and timers. */
  readonly io: IoCap;
  /** Loopback TCP (needs an `io`). */
  readonly net: NetCap;
  /** The machine and process: arguments and environment variables. */
  readonly host: HostCap;
  /** Module graph: sources, code caches and the authority modules are produced with. */
  readonly graph: ModuleGraph;
  /** Realms whose imports run through an import handler. */
  readonly context: ContextCap;
  /** Isolates on other threads (where the embedder allows them). */
  readonly isolate: IsolateCap;
}

/** The part of {@link Api} every embedder provides. */
export type BasicApi = Pick<Api, "fs" | "host" | "graph" | "context">;

/**
 * The entry point: an init module exports `main`. It may be `async`; the program runs until the
 * returned promise settles, and a rejection fails it. Returning ends it, dropping unawaited work
 * and event handlers: `await io.run()` to keep serving.
 *
 * ```ts
 * import type { Main } from '@origine/types';
 * export const main: Main = async (api, data) => { ... };  // `data`: what `api.isolate.create` passed
 * ```
 */
export type Main<Data = unknown> = (api: Api, data: Data) => void | Promise<void>;
