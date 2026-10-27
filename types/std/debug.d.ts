// `origine:@std/debug`: the program's only output without a capability.
declare module "origine:@std/debug" {
  /**
   * Writes its arguments, converted with `String()` and separated by spaces, as one line to the
   * process's standard error. It never throws and reports no write error.
   *
   * It is a debugging hook of the host (the engine's source marks it as temporary). V8's own
   * `console` object exists in the context but is not connected to the terminal, so it is not declared.
   */
  export function eprintln(...values: unknown[]): void;
}
