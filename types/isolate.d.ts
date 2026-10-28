import type { Receiver, Sender } from "./host.d.ts";

/** Options of {@link IsolateCap.create} and {@link IsolateCap.CreateConfig}. */
export interface CreateOptions {
  /** Module specifier of the new isolate's init module; its exported `main(api)` runs there. */
  readonly init: string;
  /** Capacity of each of the two channels between the creator and the new isolate (1 to 2^32 - 1). */
  readonly capacity: number;
  /** Arguments of the new isolate: `api.host.env.args()` there is `[init, ...args]`. Default `[]`. */
  readonly args?: readonly string[];
  /** Environment of the new isolate, as given: nothing is inherited. Default `{}`. */
  readonly env?: Readonly<Record<string, string>>;
  /** Structured-cloned for the new isolate (`SharedArrayBuffer`s are shared): its `api.isolate.parent.data`. */
  readonly data?: unknown;
  /** `ArrayBuffer`s of `data` to move rather than copy; they are detached when the isolate is created. */
  readonly transfer?: readonly ArrayBuffer[];
}

/** The validated, frozen options of one `create`. */
export type CreateConfig = Readonly<Required<Pick<CreateOptions, "init" | "capacity" | "args" | "env">>> &
  Readonly<Pick<CreateOptions, "data" | "transfer">>;

/** How an isolate ended. */
export interface IsolateExit {
  readonly status: "completed" | "failed" | "terminated";
  /** The error name of a failed isolate (`InitFailed`, `MainFailed`, ...). */
  readonly error?: string;
}

/** An isolate running on another thread, and the channels to it. */
export interface Isolate {
  /** Numbers the isolates this isolate created, from 1. */
  readonly id: number;
  /** Sends to the new isolate (its `parent.rx`). */
  readonly tx: Sender;
  /** Receives from the new isolate (its `parent.tx`); ends when the isolate ends. */
  readonly rx: Receiver;
  /** Asks the isolate to stop; running JavaScript is interrupted. Idempotent. */
  terminate(): void;
  /** Resolves once the isolate has ended, always with the same object. */
  join(): Promise<IsolateExit>;
}

/** What an isolate made by `create` knows of its creator. */
export interface Parent {
  /** Sends to the creator (its `Isolate.rx`). */
  readonly tx: Sender;
  /** Receives from the creator (its `Isolate.tx`). */
  readonly rx: Receiver;
  /** The `data` option, cloned for this isolate. */
  readonly data: unknown;
}

/**
 * `api.isolate`: isolates on other threads. A created isolate is not narrowed by its creator: its init
 * module decides what it does, within the embedder's ceiling. Every isolate it created is stopped when
 * this isolate's host is destroyed.
 */
export interface IsolateCap {
  /** Validates `options` once; `create` accepts the result as it is. Throws `TypeError` for a bad option. */
  CreateConfig(options: CreateOptions | CreateConfig): CreateConfig;
  /** Starts an isolate. Rejects `QuotaExceeded` past the host's limit; throws `TypeError` for bad options. */
  create(options: CreateOptions | CreateConfig): Isolate;
  /** In an isolate made by `create`: its creator. `null` in the first isolate. */
  readonly parent: Parent | null;
}
