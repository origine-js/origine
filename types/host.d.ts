import type { EnvCap } from "./env.d.ts";

/** `api.host`: the machine and process the program runs on. */
export interface HostCap {
  /** Arguments and environment variables. */
  readonly env: EnvCap;
}
