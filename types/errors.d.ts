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

/** The error value of one I/O name, e.g. `IoErrorOf<'NotFound'>` is `{ errno: 10; name: 'NotFound' }`. */
export type IoErrorOf<N extends IoErrnoName = IoErrnoName> = N extends IoErrnoName
  ? { readonly errno: IoErrnoTable[N]; readonly name: N }
  : never;

/** The error value of one host name, e.g. `HostErrorOf<'BadHandle'>` is `{ errno: 2; name: 'BadHandle' }`. */
export type HostErrorOf<N extends HostErrnoName = HostErrnoName> = N extends HostErrnoName
  ? { readonly errno: HostErrnoTable[N]; readonly name: N }
  : never;

/** The error value of one I/O code, e.g. `IoErrorByCode<10>` is `{ errno: 10; name: 'NotFound' }`. */
export type IoErrorByCode<C extends IoErrnoCode> = Extract<IoError, { readonly errno: C }>;

/** The error value of one host code, e.g. `HostErrorByCode<2>` is `{ errno: 2; name: 'BadHandle' }`. */
export type HostErrorByCode<C extends HostErrnoCode> = Extract<HostError, { readonly errno: C }>;

/**
 * What the runtime throws (sync calls) or rejects with (async calls) when an operation fails: a
 * frozen **plain object**, not an `Error` (it has no `message` or `stack`). There are two domains,
 * told apart by `name` (and by number: host codes are 1-9, I/O codes 10 and up):
 *
 * - `IoError`: what Rust's `std::io::ErrorKind` names (`NotFound`, `PermissionDenied`, ...), raised by fs and net;
 * - `HostError`: origine's own runtime concepts (`BadHandle`, `StaleHandle`, `Canceled`, `Unexpected`), raised by any native.
 *
 * Each operation says which it can fail with. Narrow on `name`:
 *
 * ```ts
 * try { fs.read_to_string('a.txt'); }
 * catch (e) { if (IoError.is(e, IoError.NotFound)) { ... } else throw e; }
 * ```
 *
 * A bad argument, a denial, an absent file and a broken connection are different names (see `IoErrnoTable`): a
 * missing or malformed option is `InvalidInput`, a grant that does not allow the call is `PermissionDenied`.
 * A call can also throw a `TypeError` (or `RangeError`) for an argument of the wrong type or range,
 * e.g. a missing `mode` of `api.net.listen`; those are programming errors, not `IoError`s.
 */
export type IoError = IoErrorOf<IoErrnoName>;

/** A runtime failure that has no Rust `ErrorKind` name (`BadHandle`, `StaleHandle`, `Canceled`, `Unexpected`). See {@link IoError}. */
export type HostError = HostErrorOf<HostErrnoName>;
