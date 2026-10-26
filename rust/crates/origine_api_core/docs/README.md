# origine_api_core

The pure-Rust, V8-free core of the guest API natives: error codes and mappings, argument range
rules, the error type, handle tables and the runtime ceiling. It exists as a separate crate so that
`just check-rust` can run all of it under **Miri**, which `origine_api` cannot (it links V8 and
cannot run without the Zig/V8 build). `origine_api` binds this logic to V8 values;
[`origine_api_fs`](../../origine_api_fs/src/lib.rs) and [`origine_api_macros`](../../origine_api_macros/docs/README.md)
depend on it. No external dependencies.

```
src/lib.rs    Backend, Ceiling
src/errno.rs  Errno numbers, names, io::Error -> Errno
src/error.rs  NativeError
src/arg.rs    ArgError, number range checks, camel_case
src/table.rs  Table / Entry / Guard / Drained (handle tables with in-flight accounting)
```

There is no task-spawn trait in this crate: tasks are spawned directly on `origine_io::rt` by
`origine_api` (`HostState::start`), and the async-fs operations are plain `impl Future` values from
`origine_api_fs` that are spawned there. What `table.rs` offers for async work is the in-flight
accounting below, with `Drained` as the future that waits for it.

## Errno mapping (`errno.rs`)

`src/api/errno_codes.zig` (`IoErrno` and `HostErrno`) is the single source of truth; `errno_table.rs` (the constants, `HOST_CODES`, `IO_CODES`, `ALL`,
`is_host`, `name_of`) is generated from it by `rust/scripts/contracts.sh gen` and checked by
`contracts.sh check`. Names follow Rust's `std::io::ErrorKind` wherever the kind exists. Only the
`ErrorKind` / raw-errno policy below is hand-written; the Zig half of the same table is the std-name
alias list in `src/api/errno.zig` (`aliases`), and `src/tests/managed/api.zig` provokes the same
failures through the sync (Zig) and async (Rust) fs and asserts the same errno. `14..=21` are fixed by
[`docs/async-host-contract.md`](../../../../docs/async-host-contract.md).

| Code | Constant | Name (`native.errors` / `origine:@std/errno`) |
|---:|---|---|
| 1 | `UNEXPECTED` | `Unexpected` |
| 2 | `BAD_HANDLE` | `BadHandle` |
| 3 | `STALE_HANDLE` | `StaleHandle` |
| 4 | `CANCELED` | `Canceled` |
| 10 | `NOT_FOUND` | `NotFound` |
| 11 | `ALREADY_EXISTS` | `AlreadyExists` |
| 12 | `NOT_A_DIRECTORY` | `NotADirectory` |
| 13 | `IS_A_DIRECTORY` | `IsADirectory` |
| 14 | `DIRECTORY_NOT_EMPTY` | `DirectoryNotEmpty` |
| 15 | `FILESYSTEM_LOOP` | `FilesystemLoop` |
| 16 | `INVALID_FILENAME` | `InvalidFilename` |
| 17 | `CROSSES_DEVICES` | `CrossesDevices` |
| 20 | `PERMISSION_DENIED` | `PermissionDenied` |
| 21 | `READ_ONLY_FILESYSTEM` | `ReadOnlyFilesystem` |
| 22 | `RESOURCE_BUSY` | `ResourceBusy` |
| 23 | `UNSUPPORTED` | `Unsupported` |
| 30 | `INVALID_INPUT` | `InvalidInput` |
| 31 | `INVALID_DATA` | `InvalidData` |
| 40 | `STORAGE_FULL` | `StorageFull` |
| 41 | `FILE_TOO_LARGE` | `FileTooLarge` |
| 42 | `QUOTA_EXCEEDED` | `QuotaExceeded` |
| 43 | `TOO_MANY_OPEN_FILES` | `TooManyOpenFiles` |
| 44 | `IO` | `Io` |
| 50 | `TIMED_OUT` | `TimedOut` |
| 51 | `WOULD_BLOCK` | `WouldBlock` |
| 52 | `CONNECTION_REFUSED` | `ConnectionRefused` |
| 53 | `CONNECTION_RESET` | `ConnectionReset` |
| 54 | `BROKEN_PIPE` | `BrokenPipe` |
| 55 | `ADDRESS_IN_USE` | `AddressInUse` |
| 56 | `NOT_CONNECTED` | `NotConnected` |

Host codes are 1-9 (`UNEXPECTED` is Rust's `Other`; also the name of any unknown code), I/O codes 10 and up in blocks of ten by category; `is_host(code)` tells them apart. See [errno.md](../../../../src/js/docs/errno.md).

`name_of(code) -> &'static str` gives the names above. `AddressInUse` is the one name that is not
Rust's (`AddrInUse`): it is a sockets name, left for that module.

Policy: `InvalidInput` is a malformed argument or path (a NUL byte, an empty entry name, a bad open
mode); `PermissionDenied` is every denial, the grant's own (`..`, absolute paths, `__oricache__`
components, a request or operation the grant's access or the embedder's ceiling does not allow) and
the OS's (`EACCES` and `EPERM` alike). `TooManyOpenFiles` and `Io` have no Rust kind (Rust reports
`EMFILE`/`ENFILE`/`EIO` as uncategorized); `Interrupted` and the rest stay `Unexpected`.

### `errno_of(&io::Error) -> u32`

Classifies by `io::ErrorKind` first:

| `io::ErrorKind` | Errno |
|---|---|
| `NotFound` | `NotFound` |
| `PermissionDenied` | `PermissionDenied` |
| `NotADirectory` | `NotADirectory` |
| `IsADirectory` | `IsADirectory` |
| `AlreadyExists` | `AlreadyExists` |
| `InvalidInput` | `InvalidInput` |
| `StorageFull` | `StorageFull` |
| `Unsupported` | `Unsupported` |
| `FileTooLarge` | `FileTooLarge` |
| `InvalidData` | `InvalidData` |
| `TimedOut` | `TimedOut` |
| `WouldBlock` | `WouldBlock` |
| `ConnectionRefused` | `ConnectionRefused` |
| `ConnectionReset` | `ConnectionReset` |
| `BrokenPipe` | `BrokenPipe` |
| `AddrInUse` | `AddressInUse` |
| `NotConnected` | `NotConnected` |
| `DirectoryNotEmpty` | `DirectoryNotEmpty` |
| `ReadOnlyFilesystem` | `ReadOnlyFilesystem` |
| `ResourceBusy`, `ExecutableFileBusy` | `ResourceBusy` |
| `CrossesDevices` | `CrossesDevices` |
| `QuotaExceeded` | `QuotaExceeded` |
| `InvalidFilename` | `InvalidFilename` |
| anything else (`Other`, `Interrupted`, the unstable `FilesystemLoop`, ...) | fall through to the raw OS error |

For uncategorized kinds with a raw OS error (`errno_of_raw`; `ELOOP` is 40 on Linux, 62 on macOS):

| Raw errno | Errno |
|---|---|
| `ECANCELED` (125 Linux, 89 macOS) | `Canceled` |
| `ELOOP` | `FilesystemLoop` |
| 1, 13 (`EPERM`, `EACCES`) | `PermissionDenied` |
| 2 | `NotFound` |
| 5 (`EIO`) | `Io` |
| 16, 26 (`EBUSY`, `ETXTBSY`) | `ResourceBusy` |
| 17 | `AlreadyExists` |
| 20 | `NotADirectory` |
| 21 | `IsADirectory` |
| 22 | `InvalidInput` |
| 23, 24 (`ENFILE`, `EMFILE`) | `TooManyOpenFiles` |
| 27 | `FileTooLarge` |
| 28 | `StorageFull` |
| 30 (`EROFS`) | `ReadOnlyFilesystem` |
| other / no OS error | `Unexpected` |

`Interrupted` becomes `Unexpected` today. The readdir `ERANGE` error from `origine_io` has
kind `InvalidInput`, so it maps to `InvalidInput`. Tests in the file assert the table.

## `NativeError` (`error.rs`)

How a native fails: sync natives throw it, async natives reject with it.

| Variant | JS value |
|---|---|
| `Arg(ArgError)` | `TypeError("argument N: expected X")` |
| `Errno(u32)` | frozen `{ errno, name }` (same shape as `failure(code)` in `src/js/glue/util.js`) |
| `Type(String)` / `Range(String)` / `Error(String)` | `TypeError` / `RangeError` / `Error` |

Constructors `type_error`, `range_error`, `error`; `From<ArgError>`; `From<io::Error>` goes through
`errno_of`. Implements `Display` (`errno 1 (NotFound)`) and `std::error::Error`. The JS
conversion lives in `origine_api::native::error_value`.

## Argument rules (`arg.rs`)

Mirrors `decode` in `src/api/binding.zig`.

* `MAX_SAFE_INTEGER = 2^53 - 1`.
* `f64_to_u32`: integer in `0..=u32::MAX` (rejects NaN, infinities, fractions, negatives).
* `f64_to_u64`: integer in `0..=2^53-1`.
* `f64_to_limit`: `std.Io.Limit` semantics: `+Infinity` = `usize::MAX`; NaN, negatives and
  `-Infinity` rejected; otherwise truncated and clamped to `usize::MAX / 2`.
* `u64_to_f64`: `None` above `2^53-1` (results that JS cannot hold exactly).
* `camel_case`: `max_runtimes` -> `maxRuntimes`, `r#type` -> `type` (used by the derives).
* `ArgError { index, expected }`: displays `argument N: expected X`; `in_property(name)` rewrites
  to ``expected property `name` to be X`` and nests as ``property `a.b` ...``.

## Runtime ceiling (`lib.rs`)

* `Backend::{Auto, Uring, Kqueue, Threaded}`: `parse`/`name` (`"auto"`, `"uring"`, `"kqueue"`,
  `"threaded"`), `mask_bit()` = `1 << kind` (uring 1<<1, kqueue 1<<2, threaded 1<<4; `Auto` has
  no bit).
* `Ceiling { max_runtimes, backends_mask, default_entries }`, `Ceiling::NONE`,
  `check_create(live, backend) -> Result<(), errno>`: `Unsupported` if the backend is excluded
  (`Auto` needs a non-empty mask) -- checked first -- then `AccessDenied` if `live >= max_runtimes`.

## Handle tables (`table.rs`)

Per-grant tables of file/dir handles, single-threaded (`Rc`, `Cell`) because async operations of
one runtime and the natives that start them all run on the isolate thread.

* `Table<T>`: ids are 1-based slot indexes; `insert` reuses only **closed** slots; `get` fails
  `Bad` for unknown/closed ids; `live()` counts non-closed entries.
* `Entry<T>` state: `Open` -> `Closing` (`begin_close`) -> `Closed` (`finish_close`).
  `begin()` returns a `Guard<T>` (derefs to the value, counts `in_flight`) only while `Open`;
  `Closing` -> `HandleError::Stale` (`StaleHandle`), `Closed` -> `Bad` (`BadHandle`).
* `Guard` drop decrements `in_flight` and wakes waiters at zero; `entry.drained()` is a future
  that completes when `in_flight == 0`. Close = `begin_close()`, `drained().await`, close the
  value, `finish_close()`. An id therefore never changes meaning while an operation on it runs.

## Testing

```sh
cd rust && MIRIFLAGS="-Zmiri-disable-isolation" cargo miri test --offline --locked -p origine_api_core
cd rust && cargo test -p origine_api_core            # plain cargo works: no V8
```
