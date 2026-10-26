// `origine:@std/quansync`: write an operation once, run it synchronously or asynchronously.
declare module "origine:@std/quansync" {
  /** `'sync'` or `'async'`: what `io.kind` of a grant is. */
  export type Mode = "sync" | "async";

  /**
   * A suspended quansync call: a generator-like value (so `yield*` works inside a composite) and a
   * thenable (so `await` runs it asynchronously). **Single use.**
   */
  export interface Task<T> extends PromiseLike<T> {
    next(value?: unknown): IteratorResult<unknown, T>;
    throw(error: unknown): IteratorResult<unknown, T>;
    return(value: T): IteratorResult<unknown, T>;
    [Symbol.iterator](): Task<T>;
  }

  /**
   * A function that runs in both modes. The leaves' `sync` and `async` *are* the given
   * implementations (no wrapper, no allocation); `f[mode]` indexes them by mode name.
   */
  export interface Quansync<A extends unknown[], R> {
    /** A task: `yield*` it inside a composite, or `await` it (runs asynchronously). */
    (...args: A): Task<R>;
    /** Runs synchronously; returns the result or throws. */
    readonly sync: (...args: A) => R;
    /** Runs asynchronously; returns a promise. */
    readonly async: (...args: A) => Promise<R>;
  }

  /** The two hand-written implementations of a leaf. */
  export interface LeafDefinition<A extends unknown[], R> {
    sync(...args: A): R;
    async(...args: A): Promise<R>;
  }

  /** Optional hand-written fast paths of a composite: a composite costs one generator per call. */
  export interface Overrides<A extends unknown[], R> {
    sync?: (...args: A) => R;
    async?: (...args: A) => Promise<R>;
  }

  /**
   * Defines a quansync function. `{ sync, async }` is a leaf; a generator function is a composite
   * that may `yield*` other quansync calls (or `yield` a leaf effect or task: anything else throws
   * `TypeError`), with optional fast-path `overrides`.
   */
  export interface QuansyncFactory {
    <A extends unknown[], R>(definition: LeafDefinition<A, R>): Quansync<A, R>;
    <A extends unknown[], R>(
      definition: (...args: A) => Generator<unknown, R, any>,
      overrides?: Overrides<A, R>,
    ): Quansync<A, R>;
    /** Runs `task` in `mode`: its result, or a promise of it. `TypeError` for another mode. */
    run: typeof run;
    /** Whether `value` is a task. */
    isTask(value: unknown): value is Task<unknown>;
    /** `['sync', 'async']`. */
    readonly MODES: readonly ["sync", "async"];
  }

  export const quansync: QuansyncFactory;

  /** Runs `task` in `mode`: its result (`'sync'`), or a promise of it (`'async'`). */
  export function run<R>(mode: "sync", task: Task<R>): R;
  export function run<R>(mode: "async", task: Task<R>): Promise<R>;
  export function run<R>(mode: Mode, task: Task<R>): R | Promise<R>;
}
