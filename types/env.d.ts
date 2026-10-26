/** Options of {@link EnvCap.narrow}. */
export interface EnvNarrow {
  /** The only variable names the narrowed capability shows. Names this capability already hides stay hidden. */
  readonly allow: readonly string[];
}

/** `api.env`: command-line arguments and environment variables. */
export interface EnvCap {
  /** The arguments the program was started with. */
  args(): readonly string[];
  /** The value of the variable `name`, or `undefined` when it is unset or not visible. */
  get(name: string): string | undefined;
  /** The names of the visible variables. */
  list(): readonly string[];
  /** A capability that shows only the names in `allow` (that this one shows too). Throws `TypeError` without an `allow` array. */
  narrow(options: EnvNarrow): EnvCap;
}
