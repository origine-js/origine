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

`src/api/errno.zig` is the single source of truth; this file is a **hand-kept duplicate** that must
match it (there is no generator or cross-check yet). `14..=21` are fixed by
[`docs/async-host-contract.md`](../../../../docs/async-host-contract.md).

| Code | Constant | Name (`native.errors` / `origine:@std/errno`) |
|---:|---|---|
| 1 | `FILE_NOT_FOUND` | `FileNotFound` |
| 2 | `ACCESS_DENIED` | `AccessDenied` |
| 3 | `NOT_DIR` | `NotDir` |
| 4 | `IS_DIR` | `IsDir` |
| 5 | `PATH_ALREADY_EXISTS` | `PathAlreadyExists` |
| 6 | `BAD_HANDLE` | `BadHandle` |
| 7 | `STALE_HANDLE` | `StaleHandle` |
| 8 | `INVALID_PATH` | `InvalidPath` |
| 9 | `NO_SPACE_LEFT` | `NoSpaceLeft` |
| 10 | `UNSUPPORTED` | `Unsupported` |
| 11 | `FILE_TOO_BIG` | `FileTooBig` |
| 12 | `INVALID_DATA` | `InvalidData` |
| 13 | `JAVA_SCRIPT_EXCEPTION` | `JavaScriptException` |
| 14 | `CANCELED` | `Canceled` |
| 15 | `TIMED_OUT` | `TimedOut` |
| 16 | `WOULD_BLOCK` | `WouldBlock` |
| 17 | `CONNECTION_REFUSED` | `ConnectionRefused` |
| 18 | `CONNECTION_RESET` | `ConnectionReset` |
| 19 | `BROKEN_PIPE` | `BrokenPipe` |
| 20 | `ADDRESS_IN_USE` | `AddressInUse` |
| 21 | `NOT_CONNECTED` | `NotConnected` |
| 255 | `UNEXPECTED` | `Unexpected` (also the name of any unknown code) |

`name_of(code) -> &'static str` gives the names above.

### `errno_of(&io::Error) -> u32`

Classifies by `io::ErrorKind` first:

| `io::ErrorKind` | Errno |
|---|---|
| `NotFound` | 1 `FileNotFound` |
| `PermissionDenied` | 2 `AccessDenied` |
| `NotADirectory` | 3 `NotDir` |
| `IsADirectory` | 4 `IsDir` |
| `AlreadyExists` | 5 `PathAlreadyExists` |
| `InvalidInput` | 8 `InvalidPath` |
| `StorageFull` | 9 `NoSpaceLeft` |
| `Unsupported` | 10 `Unsupported` |
| `FileTooLarge` | 11 `FileTooBig` |
| `InvalidData` | 12 `InvalidData` |
| `TimedOut` | 15 `TimedOut` |
| `WouldBlock` | 16 `WouldBlock` |
| `ConnectionRefused` | 17 |
| `ConnectionReset` | 18 |
| `BrokenPipe` | 19 |
| `AddrInUse` | 20 `AddressInUse` |
| `NotConnected` | 21 |
| anything else (`Other`, `Interrupted`, `DirectoryNotEmpty`, ...) | fall through to the raw OS error |

For uncategorized kinds with a raw OS error (`errno_of_raw`):

| Raw errno | Errno |
|---|---|
| `ECANCELED` (125 Linux, 89 macOS) | 14 `Canceled` |
| 1, 13 (`EPERM`, `EACCES`) | 2 `AccessDenied` |
| 2 | 1 `FileNotFound` |
| 17 | 5 `PathAlreadyExists` |
| 20 | 3 `NotDir` |
| 21 | 4 `IsDir` |
| 22 | 8 `InvalidPath` |
| 27 | 11 `FileTooBig` |
| 28 | 9 `NoSpaceLeft` |
| other / no OS error | 255 `Unexpected` |

Note `DirectoryNotEmpty` and `Interrupted` become `Unexpected` (255) today. The readdir `ERANGE`
error from `origine_io` has kind `InvalidInput`, so it maps to `InvalidPath`. Tests in the file
assert the table.

## `NativeError` (`error.rs`)

How a native fails: sync natives throw it, async natives reject with it.

| Variant | JS value |
|---|---|
| `Arg(ArgError)` | `TypeError("argument N: expected X")` |
| `Errno(u32)` | frozen `{ errno, name }` (same shape as `failure(code)` in `src/js/glue/util.js`) |
| `Type(String)` / `Range(String)` / `Error(String)` | `TypeError` / `RangeError` / `Error` |

Constructors `type_error`, `range_error`, `error`; `From<ArgError>`; `From<io::Error>` goes through
`errno_of`. Implements `Display` (`errno 1 (FileNotFound)`) and `std::error::Error`. The JS
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
