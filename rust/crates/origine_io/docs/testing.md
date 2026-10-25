# Testing `origine_io`

## Layout

| File | Covers | Runs on |
|---|---|---|
| `src/lib.rs` `mod tests` | `parse_dir_entries` (well formed, every truncation, garbage never panics), `erange_error`/`is_erange` | pure Rust, no library |
| `src/sys.rs` `mod tests` | `#[repr(C)]` layout of `oio_op`, `oio_stat`, `oio_options`, `oio_iovec` (160-byte `oio_op`, field offsets) | pure Rust |
| `src/fs/path.rs` `mod tests` | `sanitize` accept/reject tables | pure Rust |
| `tests/io.rs` | raw op futures: roundtrip, errors (`ENOENT`), out-of-order completion, cancel-on-drop, drop of a loop with pending ops, `post` from a thread, abandoned ops are released, new file ops (link, fsync, fallocate, sendfile, readv/writev), futex, sockets, `ftruncate`, `readdir` (full listing, tiny-buffer continuation, `ERANGE`) | real library or mock |
| `tests/buf.rs` | generic buffers: `Vec` semantics unchanged (read fills `len()`), `Box<[u8]>`/`&'static [u8]`/`String`, `RawRegion` over a heap block (read/write/`write_all_at`, `set_init`, `read_range`/`write_range` incl. `EINVAL`), generic `readv`/`writev`, dropped pending read keeps the region alive until the callback (owner `Drop` flag; on a real pipe when not under Miri), `write_all` of 4 MiB into a pipe (partial writes, not under Miri), `RawRegion: !Send` | real library or mock |
| `tests/rt.rs` | spawn/join order, nested spawn, detach, `sleep`/`timeout`/`select`/`join`, `JoinSet` (bounded, unbounded, drop aborts), abort cancels an in-flight read, dropping the runtime, panics, wake from another thread, budget fairness, `yield_now`, `tick` | real library or mock |
| `tests/fs.rs` | `fs`: roundtrip, large `write_all`/`read_to_end` limit, `OpenOptions` validity, `create_dir_all`, `remove_dir_all`, `read_dir` with many entries, metadata/symlinks, rename across dirs and copy, path rejection never touches the fs, dropped pending futures, detached close on drop, explicit close and use-after-close, concurrent tasks sharing a `Dir` | real library or mock |

Integration tests are `cfg`-free: the same source runs against Zig's library or the mock. Sizes and
timer spacing scale with `cfg!(miri)` (fewer entries/bytes; timers x40) so ordering assertions
stay meaningful under Miri.

## Real library

See "Building and linking" in [README.md](README.md): build `liborigine_io.a` with Zig (the command is there) and set
`ORIGINE_IO_LIB`:

```sh
ORIGINE_IO_LIB=/path/to/dir cargo test -p origine_io      # from rust/
```

This exercises the real backend selected by `Backend::Auto` (kqueue+GCD on macOS, io_uring on
Linux). The Zig-side tests (`zig build test-io`) are separate; see
[`src/io/docs`](../../../../src/io/docs/README.md).

Tests that need capabilities the platform backend lacks return early (for example
`socket_buffers_come_back` returns when `CAP_SOCKETS` is set, since it only checks the "no sockets"
behaviour of the mock).

### Serialized fs tests

`tests/fs.rs` takes a process-wide `static SERIAL: Mutex<()>` in `Env::new` and holds the guard for
the whole test. The tests share descriptor numbers (a process-wide fd table) and the leak checks
reason about "fd N is closed now", so parallel tests would make those assertions race. Each test
uses its own temp directory (`origine_fs_<name>_<pid>`).

## Miri and the mock (`src/mock.rs`)

Miri cannot call foreign functions, so under `cfg(miri)` `sys.rs` re-exports `crate::mock::oio_*`
(an in-process fake of the C API) instead of the `extern "C"` block. Semantics follow
`src/io/include/origine_io.h`:

* ops are caller-owned; callbacks run only from `oio_loop_run` / `oio_loop_destroy`;
* file ops execute (via `std::fs`) when the loop is *driven*, not at submit time; they run
  synchronously on the driving thread;
* timeouts fire on real elapsed time and complete with 0; futex waits complete by wake, timeout
  (`-ETIMEDOUT`) or cancel;
* `oio_cancel` completes a pending op with `-ECANCELED`, deferred to the next run;
* destroy cancels outstanding ops, runs their callbacks and pending posts;
* `oio_loop_wake` / `oio_loop_post` are thread-safe (a `Mutex`ed queue plus a `Condvar`); the rest
  of the loop state is touched only by the driving thread (a `busy` flag asserts no re-entrancy).

### Fidelity limits

* **No sockets**: `send`, `recv`, `sendmsg`, `recvmsg`, `connect`, `accept` complete with
  `-ENOSYS`; `caps()` lacks `CAP_SOCKETS` and `CAP_POLLABLE`.
* **`pollable()` is always `None`** (-1) and the `backend`/`entries` options are ignored; there is
  one behaviour regardless of `Backend`.
* **`link` is a copy**: `emulated_link` reads the old file and writes a new one with `create_new`;
  there is no shared inode, so link counts and later writes to one name are not visible through
  the other.
* **`sendfile`** is read-into-buffer plus write; **`fallocate`** only extends the length (and is a
  no-op with `KEEP_SIZE`).
* **Descriptors are virtual**: a process-wide table (`FDS`) numbers fds from 3 and maps them to
  `std::fs::File`s; directory fds are remembered as *paths*, and "dirfd-relative" ops are
  resolved by joining paths. There is no real `openat`, so symlink/TOCTOU behaviour of the real
  backends is not modelled. Raw OS descriptors from outside are not valid.
* **`readdir`** sorts entries by name; the cookie is the index of the next entry.
* **Timing**: no kernel, so ordering that depends on real I/O latency is only approximated
  (timers use wall-clock time).
* Cancellation is deterministic (deferred to the next run); real backends may complete an op
  before the cancel lands.

Use the mock for memory-safety and protocol checks (ownership of `OpState`, cancel-on-drop,
abandon paths, task and `JoinSet` state machines), the real library for behaviour.

## Commands

From the repo root:

| Command | What |
|---|---|
| `just check` | `check-rust` + `check-format` |
| `just check-rust` | `zig build clippy -Dcargo-offline=true` (clippy `-D warnings` over the workspace with the V8 env) and Miri over `origine_io`, `origine_oxc`, `origine_api_core`, `origine_api_macros` |
| `zig build clippy` | clippy only (see [../../origine_api/docs/README.md](../../origine_api/docs/README.md) for why it goes through Zig) |

Miri by hand, from `rust/`:

```sh
MIRIFLAGS="-Zmiri-disable-isolation" cargo miri test --offline --locked -p origine_io
```

`-Zmiri-disable-isolation` is required: the tests create temp directories and files, and use the
wall clock and `std::thread::sleep`. The `miri` component is part of the pinned toolchain
(`rust/rust-toolchain.toml`). `origine_api_fs` is Miri-capable on the same mock but is not in the
`justfile` Miri list (its non-Miri tests need `ORIGINE_IO_LIB`).

Single test with the real library:

```sh
ORIGINE_IO_LIB=/path/to/dir cargo test -p origine_io --test fs remove_dir_all_nested_tree
```
