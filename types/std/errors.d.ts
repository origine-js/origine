declare module "origine:@std/errors" {
  /** Base runtime error. Construction allocates an Error and captures its stack. */
  export class OrigineError extends Error {
    constructor(errno: number, message?: string);
    readonly errno: number;
    static nameOf(code: number): string;
    static is(value: unknown, code: number): boolean;
    static of(code: number, message?: string): OrigineError;
  }
  export { IoError, HostError } from "origine:@std/io";
  export { ImportError } from "origine:@std/graph/import";
}
