import type { EnvCap } from "./env.d.ts";
import type { FsCap } from "./fs.d.ts";
import type { IoCap } from "./io.d.ts";
import type { NetCap } from "./net.d.ts";
import type { ScopeCap } from "./scope.d.ts";

/**
 * The host API handed to `main`: every permission a program has. Frozen. Narrow a capability
 * (`api.env.narrow`, `api.io.narrow`) to hand a slice to a child scope; nothing widens one.
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
  /** Arguments and environment variables. */
  readonly env: EnvCap;
  /** Child scopes. */
  readonly scope: ScopeCap;
}

/** The part of {@link Api} every embedder provides. */
export type BasicApi = Pick<Api, "fs" | "env" | "scope">;

/**
 * The entry point: an init module exports `main`. It may be `async`; the program runs until the
 * returned promise settles, and a rejection fails it. Returning ends it, dropping unawaited work
 * and event handlers: `await io.run()` to keep serving.
 *
 * ```ts
 * import type { Main } from '@origine/types';
 * export const main: Main = async api => { ... };
 * ```
 */
export type Main = (api: Api) => void | Promise<void>;
