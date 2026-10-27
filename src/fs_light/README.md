# fs_light

The file-system primitives of Zig **0.15.2** (`lib/std/posix.zig`, `fs/Dir.zig`, `fs/File.zig`,
`os/windows.zig` and `os/windows/*.zig`), vendored so the Zig side of origine can use files, directories
and the terminal without `std.Io` (whose `Threaded` backend drags in every operation, sockets and a
thread pool). They take no `io` parameter and keep no state. `src/managed/sys.zig` wraps them in the
Zig 0.17 `std.Io.Dir` / `std.Io.File` shape (same names, options and error names, minus `io`), and
`src/managed/stderr.zig` writes diagnostics through them.

`std.Io` is banned from the shipped binary (see `AGENTS.md`); this is the file-system layer to use instead, and `std.Io.Reader`/`Writer` (plus `Limit` and `Timestamp`, plain data) are the only `std.Io` names allowed.

License: MIT (Zig contributors), as the Zig standard library.

## Patches against 0.15.2

Mechanical, to compile with Zig 0.17 (`std` imports became `@import("std")`, siblings are local):

- `fs.zig` is new: what `Dir`/`File`/`posix` expect to find in `std.fs` (`cwd`, `path`, the limits).
- Removed: `File.Reader`/`Writer`/`Deprecated*`, `Dir.copyFile`/`updateFile`/`atomicFile` and
  `AtomicFile.zig` (they sit on the old `std.io`), all `test` blocks, `.solaris`.
- Added: `File.readToEndAllocOptions` (the old one went through `deprecatedReader`),
  `Dir.statFileFollowing(sub_path, follow)` (`lstat`).
- API drift: `linux.E.init` is `linux.errno`, `STATX_*` constants are the `STATX` packed struct,
  `Thread.sleep` is `kernel32.Sleep`, `mmap` takes `PROT` as a struct, `componentIterator` no longer
  returns an error, `std.fs.path.isAbsoluteWindowsWTF16` lives on in `windows.zig`.
- Behavior: `toPosixPath` panics on an embedded NUL in every build mode (0.15 only asserted it with
  runtime safety, so a release build would truncate the path); `renameat` reports `ENOTEMPTY` as `DirNotEmpty` (0.17 and Rust do; 0.15 said
  `PathAlreadyExists`). `unexpected_error_tracing` is off (it would link `std.debug`).

Windows is vendored along (`windows.zig`, `windows/`) and compiles; it has not been run.
