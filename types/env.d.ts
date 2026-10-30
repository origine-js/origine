/** `api.host.env`: command-line arguments and environment variables configured by the host. */
export interface EnvCap {
  /** The arguments the program was started with. Allocates a frozen array. */
  args(): readonly string[];
  /** The value of the variable `name`, or `undefined` when it is unset. */
  get(name: string): string | undefined;
  /** The environment variable names. Allocates a frozen array. */
  list(): readonly string[];
}
