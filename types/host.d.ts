import type { EnvCap } from "./env.d.ts";

/** Options of {@link Sender.send}. */
export interface SendOptions {
  /** `ArrayBuffer`s to move with the message: they are detached here once it is queued. */
  readonly transfer?: readonly ArrayBuffer[];
}

/**
 * The sending end of a channel. Values are copied with the structured clone algorithm
 * (`SharedArrayBuffer`s are shared, not copied), so functions and symbols cannot be sent.
 */
export interface Sender {
  /** A number that names this end; pass it to another isolate and rebuild the end with {@link ThreadingCap.sender}. */
  readonly handle: number;
  /**
   * Queues a copy of `value`, waiting while the channel is full. Throws `TypeError` for a value that
   * cannot be cloned (nothing is queued or detached). Rejects `BrokenPipe` once the receiver is closed.
   */
  send(value: unknown, options?: SendOptions): Promise<void>;
  /** Another sender of the same channel. The channel ends for receivers only when every sender is closed. */
  clone(): Sender;
  /** Closes this sender (`BadHandle` when it is already closed). */
  close(): void;
}

/** The receiving end of a channel; iterating it yields messages until every sender is closed and the queue is drained. */
export interface Receiver extends AsyncIterable<unknown> {
  /** A number that names this end; see {@link Sender.handle}. */
  readonly handle: number;
  /** The oldest message, waiting while the channel is empty. Rejects `NotConnected` once it is drained and every sender is closed. */
  recv(): Promise<unknown>;
  /** Closes the receiver: queued messages are dropped and senders get `BrokenPipe`. */
  close(): void;
}

/** Options of {@link ThreadingCap.channel}. */
export interface ChannelOptions {
  /** The most messages the channel holds before `send` waits (an integer from 1 to 2^32 - 1). */
  readonly capacity: number;
}

/** `api.host.threading`: what the host offers for running work on several threads. */
export interface ThreadingCap {
  /** Logical CPUs this process may run threads on (at least 1). */
  readonly parallelism: number;
  /** A new bounded channel between isolates. Throws `TypeError` for a bad `capacity`. */
  channel(options: ChannelOptions): { readonly tx: Sender; readonly rx: Receiver };
  /** The sender behind a {@link Sender.handle} received from another isolate. */
  sender(handle: number): Sender;
  /** The receiver behind a {@link Receiver.handle} received from another isolate. */
  receiver(handle: number): Receiver;
}

/** `api.host`: the machine and process the program runs on. */
export interface HostCap {
  /** Arguments and environment variables. */
  readonly env: EnvCap;
  /** Threads: how many the host can run at once. */
  readonly threading: ThreadingCap;
}
