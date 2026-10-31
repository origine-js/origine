# `origine:@std/errno`

Source: generated at compile time from `IoErrno` and `HostErrno` ([errno_codes.zig](../../api/errno_codes.zig),
via [errno.zig](../../api/errno.zig) `module_source`). Never edit a table by hand; add a member to an
enum and its generated module, `IoError`/`HostError` and glue helpers all follow.

```js
import { ERRNO } from 'origine:@std/errno';
ERRNO.io.NotFound    // 10
ERRNO.host.BadHandle // 2
```

`ERRNO` is a frozen `{ io, host }`: two tables, one per error domain, each a frozen `{ Name: code }`
for every member (without `ok`, which is 0). Use them through
[`IoError` and `HostError`](io.md#values). Both enums live in
[errno_codes.zig](../../api/errno_codes.zig); `ERRNO`, the Rust table and the
TypeScript types are generated from them.

- **`io`**: everything Rust's [`std::io::ErrorKind`](https://doc.rust-lang.org/std/io/enum.ErrorKind.html)
  has a name for, with Rust's names (so the same failure has the same name from the sync Zig `std.Io`
  and the async Rust fs), plus the two OS errors Rust leaves uncategorized (`TooManyOpenFiles`, `Io`).
  Raised by fs and net.
- **`host`**: origine's own runtime concepts, which Rust has no name for. Any native can raise them.

A rule for a new code: if Rust's `ErrorKind` has a name for it, it is an `io` code with that name; if
it exists only because of the runtime, it is a `host` code.

## Numbering

The domain and category are readable from the number, in disjoint blocks with room to grow. **Look codes up by name**
(`ERRNO.io.NotFound`, `IoError.NotFound`), never hard-code or persist a number: the names are the
contract (they are Rust's `ErrorKind` names, which Rust does not rename), while the numbers are not
guaranteed stable until a few stable versions have shipped (the layout was already renumbered once, at
the draft stage). `0` is "no error" and is never a member.

| Block | Domain | Category |
| --- | --- | --- |
| 1-9 | host | runtime |
| 10-19 | io | path and file system objects |
| 20-29 | io | permission and state |
| 30-39 | io | arguments and data |
| 40-49 | io | resources |
| 50-59 | io | network and timing |

### `ERRNO.host`

| Name | Code | Notes |
| --- | --- | --- |
| `Unexpected` | 1 | anything else (Rust's `Other`; also the name of an unknown code) |
| `BadHandle` | 2 | never issued, closed, or from another grant, scope or runtime |
| `StaleHandle` | 3 | a handle that is closing, or a buffer already detached |
| `Canceled` | 4 | an async operation was canceled: its io runtime closed |

### `ERRNO.io`

| Name | Code | Notes |
| --- | --- | --- |
| `NotFound` | 10 | |
| `AlreadyExists` | 11 | |
| `NotADirectory` | 12 | |
| `IsADirectory` | 13 | |
| `DirectoryNotEmpty` | 14 | removing (or renaming over) a non-empty directory |
| `FilesystemLoop` | 15 | `ELOOP`: too many symlinks |
| `InvalidFilename` | 16 | `ENAMETOOLONG` or a name the file system cannot encode |
| `CrossesDevices` | 17 | `EXDEV`: a rename across file systems |
| `PermissionDenied` | 20 | every denial: the grant's (`..`, an absolute path, a `__codecache__` component, a write on a read-only grant, a read on a write-only one, a request above the host ceiling) and the OS's (`EACCES`, `EPERM`) |
| `ReadOnlyFilesystem` | 21 | `EROFS` |
| `ResourceBusy` | 22 | `EBUSY`, `ETXTBSY` |
| `Unsupported` | 23 | |
| `InvalidInput` | 30 | a bad argument: a NUL in a path, an empty entry name, a missing or unknown `access`, a bad open mode (also a missing or mistyped native argument) |
| `InvalidData` | 31 | also a scope source that does not compile |
| `StorageFull` | 40 | |
| `FileTooLarge` | 41 | |
| `QuotaExceeded` | 42 | `EDQUOT` |
| `TooManyOpenFiles` | 43 | `EMFILE`, `ENFILE` (no Rust kind) |
| `Io` | 44 | `EIO` (no Rust kind) |
| `TimedOut` | 50 | |
| `WouldBlock` | 51 | |
| `ConnectionRefused` | 52 | |
| `ConnectionReset` | 53 | |
| `BrokenPipe` | 54 | |
| `AddressInUse` | 55 | |
| `NotConnected` | 56 | |

`JavaScriptException` is not a code: a JS exception pending in V8 is Zig-internal. A native that fails
with it writes no errno and the exception propagates to the caller; no guest code sees a number for it.

Old names (before the Rust-name rename): `FileNotFound` → `NotFound`, `AccessDenied` →
`PermissionDenied`, `NotDir` → `NotADirectory`, `IsDir` → `IsADirectory`, `PathAlreadyExists` →
`AlreadyExists`, `InvalidPath` → `InvalidInput`, `NoSpaceLeft` → `StorageFull`, `FileTooBig` →
`FileTooLarge`, `DirNotEmpty` → `DirectoryNotEmpty`. The numbers before the draft-stage renumbering are gone.

## What a failure was about

An errno is a kind. What the failure was about travels beside it, as an `ErrorDetail` (`detail_fields` in
[errno_codes.zig](../../api/errno_codes.zig), the Rust table has the same list): a plain object of a fixed shape, every
field always present and `undefined` when unset.

| Field | Meaning |
|---|---|
| `subject` | What the failure was about, as the caller named it (a path, a module specifier). Set only where a native names it, never an absolute host path. |
| `os` | The raw OS error code, when the failure came from the OS and the backend has it. Async fs (Rust) does; sync fs (Zig) does not. |

The errors the glue throws and rejects with get the set fields as own properties (`e.subject`, `e.os`), and
`message` is the subject (`NotFound: nope.txt`). There is no stack beyond the one `Error` captures where it is made, and the
detail object itself is not part of the API.

A failed import, evaluated source or preload is a `ModuleError` (`origine:@std/errors`): its `errno` is the kind of the cause
(`Import.reject(ImportError.PermissionDenied)` is `PermissionDenied`, a missing file is `NotFound`, a module that threw is
`Unexpected`), `subject` the module it was for, and `cause` an error rebuilt in the importing realm. Nothing of the failing
realm's objects crosses.

Natives name their subject in the `func` options of the binding table (`.subject = <JS argument index>`, `src/api/binding.zig`),
or by calling `Call.failAt`. The fast call path reports only the kind.
