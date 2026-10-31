declare module "origine:@std/errors" {
  /** Base runtime error. Construction allocates an Error and captures its stack. */
  export class OrigineError extends Error {
    constructor(errno: number, message?: string);
    readonly errno: number;
    /** What the failure was about, as the caller named it (a path, a module specifier); set only where the host knows it. Never an absolute host path. */
    readonly subject?: string;
    /** The raw OS error code, when the failure came from the OS and the backend has it (async fs does; the sync fs does not). */
    readonly os?: number;
    static nameOf(code: number): string;
    static is(value: unknown, code: number): boolean;
    /**
     * Whether the condition behind an error (or an errno) may pass by itself, so the same request can succeed later:
     * `WouldBlock`, `TimedOut`, `ResourceBusy`, `ConnectionRefused`, `ConnectionReset`, `TooManyOpenFiles`. A hint, not a
     * promise that repeating the request is safe; that depends on the operation.
     */
    static transient(value: unknown): boolean;
    static of(code: number, message?: string): OrigineError;
  }
  export { IoError, HostError } from "origine:@std/io";
  export { ImportError } from "origine:@std/graph/import";
  /**
   * An import, an evaluated source or a preload that failed. `errno` is the kind of the cause (a hook's
   * `Import.reject(ImportError.PermissionDenied)`, a missing file `NotFound`; `Unexpected` when the module itself threw),
   * `subject` the module that failed (the id the resolver gave; what the call named when none was reached), `referrer` the module that imported it, and `cause` an error rebuilt in the importing realm (nothing of the failing
   * realm's objects crosses).
   */
  export class ModuleError extends OrigineError {
    constructor(errno: number, message?: string, subject?: string, cause?: unknown, referrer?: string);
    readonly name: "ModuleError";
    /** The module that imported the one that failed, when it failed as a static import of another module. */
    readonly referrer?: string;
    cause?: unknown;
  }
}
