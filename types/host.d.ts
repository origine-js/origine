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

/** `api.host`: the machine and process the program runs on. */
export interface HostCap {
  /** Arguments and environment variables. */
  readonly env: EnvCap;
  /** Threads: how many the host can run at once. */
  readonly threading: ThreadingCap;
}
