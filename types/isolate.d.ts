import type { Port, Snapshot } from "./host.d.ts";

/** Options of {@link IsolateCap.create} and {@link IsolateCap.CreateConfig}. */
export interface CreateOptions {
  /** Module specifier of the new isolate's init module; its exported `main(api, data)` runs there. */
  readonly init: string;
  /** Arguments of the new isolate: `api.host.env.args()` there is `[init, ...args]`. Default `[]`. */
  readonly args?: readonly string[];
  /** Environment of the new isolate, as given: nothing is inherited. Default `{}`. */
  readonly env?: Readonly<Record<string, string>>;
  /**
   * The second argument of the new isolate's `main`: structured-cloned (`SharedArrayBuffer`s are
   * shared). Ports in it must be listed in `transfer`; that is how the two isolates talk.
   */
  readonly data?: unknown;
  /** The `ArrayBuffer`s and ports of `data` to move rather than copy; they stop working here. */
  readonly transfer?: readonly (ArrayBuffer | Port)[];
  /**
   * Starts the isolate from this snapshot (made for the same `init`, else `InvalidInput`): its init module
   * graph is already evaluated and its source is not read again. The isolate keeps its own hold on it.
   */
  readonly snapshot?: Snapshot;
}

/** The validated, frozen options of one `create`. */
export type CreateConfig = Readonly<Required<Pick<CreateOptions, "init" | "args" | "env">>> & Readonly<Pick<CreateOptions, "data" | "transfer" | "snapshot">>;

/** How an isolate ended. */
export interface IsolateExit {
  readonly status: "completed" | "failed" | "terminated";
  /** The error name of a failed isolate (`InitFailed`, `MainFailed`, ...). */
  readonly error?: string;
}

/** An isolate running on another thread. */
export interface Isolate {
  /** Its identity: the `identity` of the messages it sends. Unique in the process, never 0. */
  readonly id: number;
  /** Asks the isolate to stop; running JavaScript is interrupted. Idempotent. */
  terminate(): void;
  /** Resolves once the isolate has ended, always with the same object. */
  join(): Promise<IsolateExit>;
}

/**
 * `api.isolate`: isolates on other threads. A created isolate is not narrowed by its creator: its init
 * module decides what it does, within the embedder's ceiling. The ports it was given are closed when it
 * ends, however it ends. Every isolate a host created is stopped when the host is destroyed.
 */
export interface IsolateCap {
  /** Validates `options` once; `create` accepts the result as it is. Throws `TypeError` for a bad option. */
  CreateConfig(options: CreateOptions | CreateConfig): CreateConfig;
  /** Starts an isolate. Rejects `QuotaExceeded` past the host's limit; throws `TypeError` for bad options. */
  create(options: CreateOptions | CreateConfig): Isolate;
}
