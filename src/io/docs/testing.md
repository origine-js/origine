# Testing

## Layout

| where | what | how it runs |
|---|---|---|
| `backend/uring.zig` (21 tests) | Drive the io_uring vtable directly: file ops, cancel, post/wake, pollable, fsync, fallocate, readv/writev, stat/link/rename, TCP and sendmsg, futex, sendfile, ftruncate, readdir (including 2000 entries through a 4096-byte buffer, concurrent dirs, cancel, destroy) | Linux only; every test returns `SkipZigTest` where `supported` is false or the ring cannot be created |
| `backend/tests/kqueue.zig` (19 tests) | Same surface for kqueue+GCD, plus non-blocking socket waits (cancel, destroy), futex wake counting for tracked waiters | Darwin only (skipped elsewhere); imported by `backend/kqueue.zig` |
| `backend/threaded.zig` (18 tests) | Same surface for the pool; also cancel of a queued op, pool growth with blocked futex waiters, the pollable self-pipe | Any POSIX OS |
| `tests.zig` (7 tests) | Loop-level behavior through `io.Loop` against `.auto` and `.threaded`: write/read round trip, `-ENOENT`, timeout ordering, cancel, cross-thread `post` waking a blocked `run`, `destroy` with ops in flight, independent loops | Everywhere |
| `io.zig` `test {}` block | Pulls in `c_api.zig` and `tests.zig`; the backend files are compiled in through `Loop`'s lazy imports | |

Backend tests exercise the `VTable` directly with a small harness (`TestEnv`, `collect`/`waitDone`, `runOne`): submit an `Op`, `poll(true, &drained)` until the op is reported, assert `op.result` and side effects, then `destroy`. They never touch `Loop`, so they test the backend contract in isolation. `tests.zig` tests the contract as seen by users (`Loop`, callbacks via `@fieldParentPtr`, `run` modes, destroy semantics). `c_api.zig` has no tests of its own; it is exercised from Rust.

Counts above are from the current sources (66 test entries in total, counting the `io.zig` `test {}` block); on macOS a full run reports `45 passed; 21 skipped; 0 failed` (the 21 skipped are the io_uring tests).

## Running

```sh
zig build test-io            # from the repo root: builds src/io/io.zig as a test, no V8 needed
zig test src/io/io.zig -lc   # same without the build system
```

`test-io` is defined in `build.zig` (a test module rooted at `src/io/io.zig` with `link_libc = true`). It runs on the host only.

### Linux in the Apple container

io_uring is Linux-only, so run the Linux tests in a container from macOS:

```sh
container run --rm -v "$PWD":/work \
  -e ZIG_LOCAL_CACHE_DIR=/tmp/zc -e ZIG_GLOBAL_CACHE_DIR=/tmp/zg \
  -w /work devc-neo:latest /opt/zig/zig test src/io/io.zig -lc
```

Notes:

- The caches go to `/tmp` inside the container so the bind-mounted checkout stays clean (and a macOS-built cache is never reused for Linux).
- If the container's kernel or sandbox does not allow io_uring, `uring.create` fails; the uring tests then skip and `Loop` with `.auto` falls back to the threaded backend, so a green run does not prove the io_uring path ran. Check the summary line for skipped counts.
- Futex (kernel >= 6.7) and ftruncate (>= 6.9) tests skip when the kernel probe says the op is unsupported; the `fallocate` test skips on filesystems without fallocate; the TCP tests skip if loopback bind fails.

## Rust tests against the Zig library

The Rust crates `origine_io` and `origine_api_fs` have `build.rs` scripts that link a static archive `liborigine_io.a` only when the environment variable `ORIGINE_IO_LIB` names the directory containing it:

```sh
cd rust && ORIGINE_IO_LIB=/path/to/dir cargo test -p origine_io
```

- The archive must contain the `oio_*` exports of `src/io/c_api.zig`, built for the host target, with libc. `build.zig` links its own copy (`ioLibrary`) into the shell and the tests but declares no install step, so build one by hand from the repository root:

  ```sh
  mkdir -p /tmp/oio && cd /tmp/oio
  R=/path/to/origine
  zig build-lib -static -lc -OReleaseFast --name origine_io \
    --dep @io -Mroot=$R/src/io/lib.zig --dep @safe -M@io=$R/src/io/io.zig -M@safe=$R/src/safe.zig
  ```

  Then use `ORIGINE_IO_LIB=/tmp/oio`.
- Without `ORIGINE_IO_LIB` the crates build normally (the final Zig link resolves the symbols), and tests that need the real library cannot link.
- Under Miri (`cargo miri test`, see the `check-rust` recipe in the `justfile`) the crate uses its pure-Rust fake of the C API (`src/mock.rs`, `cfg(miri)`); Miri cannot call the Zig library.
- Rust-side test documentation: [`origine_io` testing](../../../rust/crates/origine_io/docs/testing.md).

## Pitfalls found so far

- **Op lifetime in tests.** `Op` and everything it points to must outlive the callback. Tests keep ops in a stack struct and finish with `run(.until_idle)` before the scope ends; leaving one outstanding then freeing the memory (or letting `destroy` run after the frame is gone) corrupts memory. `destroy`-with-ops tests declare the probe before the loop.
- **Use `std.testing.allocator` for loops** (as `tests.zig` does) so a leaked ring/state or pool is reported. Post nodes always use `std.heap.c_allocator` and are freed by `Loop`; a test that drives a backend directly must free them itself (`std.heap.c_allocator.destroy(node)` after running `node.func`).
- **Scratch paths are fixed under `/tmp`** (some tests use fixed names such as `/tmp/loop-roundtrip.txt`; the uring tests include the pid). Do not run two copies of the suite on the same machine at once.
- **A `run(.once)` with nothing active blocks forever** unless something wakes it; tests that rely on `post` or `wake` start the poster thread first.
- **`pollable()` is not uniform**: the threaded self-pipe is level-triggered and cleared by `poll`; kqueue's fd does not signal inline completions; io_uring needs a `poll` call to submit queued SQEs. Test assertions about readability are backend specific (see the threaded pollable test).
- **Blocked syscalls hang `destroy`** on kqueue and threaded: tests that submit blocking `read`/`accept`/`futex_wait` must unblock them (write to the pipe, close the peer, or `wake`) before destroying, as the threaded cancel test does.
- **Results differ by backend** for `Stat.mode` (kqueue masks to permission bits), `mkdir` mode 0, futex wake counts on macOS, and cancelled running ops. Write assertions against the portable contract in [ops.md](ops.md).
- **Zig/OS gating.** Anything OS-specific in a shared file must be inside `if (supported)` or lazily analysed, as `uring.zig` does with `Impl`, otherwise the file fails to compile on other targets. Check cross-platform compilation (`zig test src/io/io.zig -lc` on macOS and in the container) after touching backends.
- **macOS futex tests** need macOS 14.4 or newer for the `os_sync_*` symbols; on older systems the futex cap is absent.
