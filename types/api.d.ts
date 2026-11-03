import type { HostCap } from "./host.d.ts";
import type { FsCap } from "./fs.d.ts";
import type { IoCap } from "./io.d.ts";
import type { NetCap } from "./net.d.ts";
import type { TlsCap } from "./tls.d.ts";
import type { HttpCap } from "./http.d.ts";
import type { DnsCap } from "./dns.d.ts";
import type { ContextCap } from "./context.d.ts";
import type { GraphCap } from "./graph.d.ts";
import type { IsolateCap } from "./isolate.d.ts";

/**
 * The host API handed to `main`: every permission a program has. Frozen. `api.io.narrow` restricts backend choices and shared runtime quotas;
 * filesystem authority is selected explicitly through grants.
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
  /** TLS over `api.net` stream sockets (needs an `io`; absent when built with `-Dtls=false`: accessing it throws `PermissionDenied`). */
  readonly tls: TlsCap;
  /** HTTP/2 sessions over `api.net` or `api.tls` sockets (needs an `io`; absent when built with `-Dhttp=false`: accessing it throws `PermissionDenied`). */
  readonly http: HttpCap;
  /** Address lookups over UDP, TCP and TLS (needs an `io`; absent when built with `-Ddns=false`: accessing it throws `PermissionDenied`). */
  readonly dns: DnsCap;
  /** The machine and process: arguments and environment variables. */
  readonly host: HostCap;
  /** Module graph: sources, code caches and the authority modules are produced with. */
  readonly graph: GraphCap;
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
