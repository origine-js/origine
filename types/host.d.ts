import type { EnvCap } from "./env.d.ts";

/** `api.host.threading`: what the host offers for running work on several threads. */
export interface ThreadingCap {
  /** Logical CPUs this process may run threads on (at least 1). */
  readonly parallelism: number;
}

/** `api.host`: the machine and process the program runs on. */
export interface HostCap {
  /** Arguments and environment variables. */
  readonly env: EnvCap;
  /** Threads: how many the host can run at once. */
  readonly threading: ThreadingCap;
}
