import type {
  ErrnoTable,
  HostErrnoCode,
  HostErrnoName,
  HostErrnoTable,
  IoErrnoCode,
  IoErrnoName,
  IoErrnoTable,
} from "./generated/errno.d.ts";

export type { ErrnoTable, HostErrnoCode, HostErrnoName, HostErrnoTable, IoErrnoCode, IoErrnoName, IoErrnoTable };

/** The error value of one I/O name, e.g. `IoErrorOf<'NotFound'>` is an Error instance with `{ errno: 10; name: 'NotFound' }`. */
export type IoErrorOf<N extends IoErrnoName = IoErrnoName> = N extends IoErrnoName
  ? Error & { readonly errno: IoErrnoTable[N]; readonly name: N }
  : never;

/** The error value of one host name, e.g. `HostErrorOf<'BadHandle'>` is an Error instance with `{ errno: 2; name: 'BadHandle' }`. */
export type HostErrorOf<N extends HostErrnoName = HostErrnoName> = N extends HostErrnoName
  ? Error & { readonly errno: HostErrnoTable[N]; readonly name: N }
  : never;

/** The error value of one I/O code, e.g. `IoErrorByCode<10>` is an Error instance with `{ errno: 10; name: 'NotFound' }`. */
export type IoErrorByCode<C extends IoErrnoCode> = Extract<IoError, { readonly errno: C }>;

/** The error value of one host code, e.g. `HostErrorByCode<2>` is an Error instance with `{ errno: 2; name: 'BadHandle' }`. */
export type HostErrorByCode<C extends HostErrnoCode> = Extract<HostError, { readonly errno: C }>;

/** Runtime failures extend OrigineError and Error, with errno, name, message and stack.
 * IoError covers filesystem/network failures; HostError covers runtime lifecycle failures.
 * Codes and narrowing through `.is(error, code)` retain their existing meanings.
 */
export type IoError = IoErrorOf<IoErrnoName>;

/** A runtime failure that has no Rust `ErrorKind` name (`BadHandle`, `StaleHandle`, `Canceled`, `Unexpected`). See {@link IoError}. */
export type HostError = HostErrorOf<HostErrnoName>;
