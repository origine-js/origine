import type { EnvCap } from "./env.d.ts";

/** How a port is read, chosen when the channel is made (there is no default), like the handles of `api.net`. */
export type PortMode = "pull" | "event";

/** Options of {@link PortBase.send}. */
export interface SendOptions {
  /**
   * What moves with the message: `ArrayBuffer`s (detached here once it is queued) and ports. A port
   * that is in the message must be listed; a listed port stops working here and its peer talks to the
   * receiver. A port with a read in flight or a started flow cannot move (`WouldBlock`).
   */
  readonly transfer?: readonly (ArrayBuffer | Port)[];
}

/** What a port delivers, as `recv()` resolves it and as `message` handlers get it. */
export interface MessageEvent {
  /** The identity of the isolate that sent it (0 for the first isolate, `Isolate.id` for one made by `create`). */
  readonly identity: number;
  /** The structured clone of the value sent (`SharedArrayBuffer`s are shared). */
  readonly data: unknown;
  /** The objects that moved with it, in the order of the sender's `transfer` list. */
  readonly transfer: readonly (ArrayBuffer | Port)[];
}

/** The part of a port both modes share. Values are cloned with the structured clone algorithm. */
export interface PortBase {
  readonly mode: PortMode;
  /**
   * Queues a copy of `data`, waiting while the channel is full. Throws `TypeError` for a value that
   * cannot be cloned (a function, a symbol, an unlisted port) and nothing is queued or moved. Rejects
   * `BrokenPipe` once the peer closed its port.
   */
  send(data: unknown, options?: SendOptions): Promise<void>;
  /** Closes this port: the peer's pending and later reads end once what was sent is read, and its sends reject `BrokenPipe`. `BadHandle` when already closed or moved. */
  close(): void;
}

/** A port read with promises: `recv`, `for await`. */
export interface PullPort extends PortBase {
  readonly mode: "pull";
  /** The oldest message, waiting while there is none. Rejects `NotConnected` once the peer closed and everything was read. */
  recv(): Promise<MessageEvent>;
  /** The messages until the peer closes its port. */
  [Symbol.asyncIterator](): AsyncIterableIterator<MessageEvent>;
  /** A new event port over the same channel; consumes this one (`BadHandle` afterwards). `WouldBlock` while a `recv` is pending. */
  toEvent(): EventPort;
}

/** The events of an {@link EventPort}. */
export interface PortEvents {
  message: MessageEvent;
  /** Fires once: the peer closed (after the messages it sent were delivered) or this port was closed. */
  close: undefined;
  /** A failed read, or a `message` handler that threw. */
  error: unknown;
}

/** A port that pushes: `register('message', fn)`. */
export interface EventPort extends PortBase {
  readonly mode: "event";
  /**
   * Subscribes `fn`; returns `{ unregister() }`. The first `message` handler starts the flow. While a
   * handler is registered the port keeps the isolate's event loop busy; close the port to let it end.
   */
  register<E extends keyof PortEvents>(event: E, fn: (event: PortEvents[E]) => void): { unregister(): boolean };
  pause(): void;
  resume(): void;
  readonly paused: boolean;
  /** A new pull port over the same channel; consumes this one. `Unsupported` once a `message` handler started the flow. */
  toPull(): PullPort;
}

export type Port = PullPort | EventPort;

/** Options of {@link ChannelConstructor}. */
export interface ChannelOptions {
  /** Required: how both ports are read. */
  readonly mode: PortMode;
  /** The most messages waiting in each direction before `send` waits (an integer from 1 to 2^32 - 1). Default 16. */
  readonly capacity?: number;
}

/** `new Channel({ mode })`: `[port, remotePort]`, two connected ports. What one sends the other receives, in order. */
export interface ChannelConstructor {
  new (options: ChannelOptions & { mode: "pull" }): readonly [PullPort, PullPort];
  new (options: ChannelOptions & { mode: "event" }): readonly [EventPort, EventPort];
  new (options: ChannelOptions): readonly [Port, Port];
}

/** `api.host.threading`: what the host offers for running work on several threads. */
export interface ThreadingCap {
  /** Logical CPUs this process may run threads on (at least 1). */
  readonly parallelism: number;
  readonly Channel: ChannelConstructor;
}

/** Options of {@link SnapshotConstructor.create}. */
export interface SnapshotCreateOptions {
  /** Module specifier of the init module whose graph is evaluated, resolved as the process's own init is. */
  readonly init: string;
}

/** Options of {@link SnapshotConstructor.fromOrigineDataBlob}. */
export interface SnapshotLoadOptions {
  /** The specifier the file was made for. */
  readonly init: string;
}

/** Options of {@link Snapshot.origineDataBlob}. */
export interface DataBlobOptions {
  /** Pack the file with LZ4 (default `false`); needs a build with LZ4 snapshots, else `Unsupported`. */
  readonly compress?: boolean;
}

/**
 * A heap snapshot held in memory. Start isolates from one with `api.isolate.create({ snapshot })`:
 * they begin with the init module graph already evaluated.
 */
export interface Snapshot {
  /** The specifier this snapshot was made for; `undefined` for one from `fromRaw`. */
  readonly init: string | undefined;
  /** A copy of the raw V8 blob. */
  blob(): Uint8Array;
  /**
   * A copy of the snapshot in the file format of `__oricache__`: it carries the table that restores the
   * modules, and fits only this build, this `init` and these sources. `Unsupported` for a snapshot
   * from `fromRaw`, which has no table.
   */
  origineDataBlob(options?: DataBlobOptions): Uint8Array;
  /** Releases the memory; isolates already started from it keep their own hold. `BadHandle` when already closed. */
  close(): void;
}

/** `api.host.Snapshot`. Cannot be called or constructed: use the static methods. */
export interface SnapshotConstructor {
  readonly prototype: Snapshot;
  /**
   * Evaluates the module graph of `options.init` (not its `main`) in a throwaway isolate **on this
   * thread, which stays blocked until it is done**, and snapshots the heap. Throws `InvalidData` for
   * an init that throws or needs I/O to finish, `Unsupported` for a graph a snapshot cannot carry,
   * `PermissionDenied` where the embedder allows no isolates.
   */
  create(options: SnapshotCreateOptions): Snapshot;
  /** A snapshot over a copy of a bare V8 blob, as `blob()` returns it. `InvalidData` for bytes V8 refuses. */
  fromRaw(bytes: Uint8Array): Snapshot;
  /**
   * A snapshot from the bytes `origineDataBlob()` made. `InvalidData` for a damaged file, one made by
   * another build or for another `init`, or whose source files changed since.
   */
  fromOrigineDataBlob(bytes: Uint8Array, options: SnapshotLoadOptions): Snapshot;
}

/** `api.host`: the machine and process the program runs on. */
export interface HostCap {
  /** Arguments and environment variables. */
  readonly env: EnvCap;
  readonly Snapshot: SnapshotConstructor;
  /** Threads: how many the host can run at once. */
  readonly threading: ThreadingCap;
}
