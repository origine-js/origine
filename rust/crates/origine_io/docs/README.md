# origine_io

Safe Rust over the Zig event loop in `src/io` (completion based; io_uring, kqueue+GCD, threaded
pool). Three layers, all `std` only (no tokio, no threads spawned by Rust, nothing blocks):

| Layer | Module | What it is |
|---|---|---|
| op futures | crate root (`Loop`, `OpFuture`, `LoopHandle`) | one future per loop op, owned buffers (`IoBuf`/`IoBufMut`: `Vec<u8>`, `Box<[u8]>`, pinned `RawRegion`), cancel-on-drop. See [futures.md](futures.md). |
| runtime | `origine_io::rt` | single-threaded `!Send` task runtime driven by the loop (the loop is the reactor, like mio under tokio). See [rt.md](rt.md). |
| fs | `origine_io::fs` | capability-rooted, `std::fs`/`tokio::fs`-shaped API (`Dir`, `File`, ...). See [fs.md](fs.md). |

Testing and the Miri mock: [testing.md](testing.md).

The Zig side (loop, `Op`, backends, C ABI) is documented in
[`src/io/docs/README.md`](../../../../src/io/docs/README.md),
[ops.md](../../../../src/io/docs/ops.md), [backends.md](../../../../src/io/docs/backends.md) and
[c-api.md](../../../../src/io/docs/c-api.md). The raw FFI declarations live in `src/sys.rs` and
mirror `src/io/include/origine_io.h`.

## Crate map

```
src/buf.rs        IoBuf, IoBufMut, RawRegion (buffer traits and pinned-memory buffer)
src/lib.rs        Loop, LoopHandle, OpFuture, op methods, readdir helpers, block_on, join
src/sys.rs        extern "C" oio_* declarations, constants, #[repr(C)] oio_op/oio_stat (layout test)
src/rt.rs         Runtime, Handle, JoinHandle, AbortHandle, JoinSet, select/timeout/sleep/yield_now
src/fs/mod.rs     Dir, File, OpenOptions, ReadDir, DirEntry, Metadata, FileType
src/fs/path.rs    sanitize (lexical path check)
src/fs/at.rs      crate-private dirfd-relative ops (open_at, mkdir_at, ...) and close_detached
src/mock.rs       cfg(miri) pure-Rust fake of the oio_* C API
tests/io.rs rt.rs fs.rs
build.rs          links liborigine_io.a when ORIGINE_IO_LIB is set
```

Used by [`origine_api_fs`](../../origine_api_fs/src/lib.rs) (grants over `fs::Dir`) and
[`origine_api`](../../origine_api/docs/README.md) (one `Loop` + `Runtime` per guest `api.io`).

## Quick start

```rust
use origine_io::fs::{Dir, OpenOptions};
use origine_io::rt::Runtime;
use origine_io::{Loop, Options, block_on, flags};
use std::rc::Rc;

// 1. A bare loop: op futures + block_on.
let lp = Loop::new(Options::default())?;           // Backend::Auto, entries = 0 (default)
let fd = block_on(&lp, lp.open("/tmp/x.txt", flags::RDWR | flags::CREAT, 0o644))?;
let (res, buf) = block_on(&lp, lp.write(fd, b"hello".to_vec(), Some(0)));
assert_eq!(res?, 5);
block_on(&lp, lp.close(fd))?;

// 2. A runtime on the loop: tasks, JoinSet, fs.
let lp = Rc::new(lp);
let rt = Runtime::new(lp.clone());
rt.block_on(async {
    let root = Dir::open_ambient(&lp, "/tmp").await?;             // the only unchecked path
    root.create_dir_all("a/b").await?;
    root.write("a/b/f.txt", "data").await?;
    let bytes = root.read("a/b/f.txt").await?;
    root.remove_dir_all("a").await?;                              // needs a running Runtime
    std::io::Result::Ok(())
})?;
```

`Loop` is cheap to clone (it is an `Rc`), but still `!Send`: keep it on the thread that drives it.
`Runtime::new` takes an `Rc<Loop>`.

## Drive modes

A loop is driven by exactly one thread, whoever calls `Loop::run`.

1. **Own thread.** The owning thread calls `run(Mode::Once)` (blocks for at least one event) in a
   loop. `block_on` (crate root) and `Runtime::block_on` do this. Other threads interrupt it with
   `LoopHandle::wake` / `LoopHandle::post`; a `Waker` fired from another thread does it for you
   (see [rt.md](rt.md)).
2. **Foreign loop.** Register `Loop::pollable()` (an fd; `None` if the backend has none) in
   another event loop (tokio `AsyncFd`, the V8 platform loop, a GUI loop, `poll(2)`), and call
   `run(Mode::NoWait)` when it becomes readable. Futures wake whatever `Waker` the foreign
   executor supplies. `origine_api` does this with `poll(2)` over every runtime's fd plus a wake
   channel ([../../origine_api/docs/README.md](../../origine_api/docs/README.md)).
3. **Host-embedded runtime.** With a `Runtime`, the host calls `Runtime::tick(mode)` instead of
   `Loop::run` so ready tasks are polled around each loop turn ([rt.md](rt.md)).

`Mode`: `Once` blocks until >= 1 event, `NoWait` polls, `UntilIdle` runs until no op is active.
`run` returns the number of ops still active.

## Building and linking

The crate calls the `oio_*` C ABI implemented by `src/io/c_api.zig`. Rust itself needs no link
flags in the shipped executable: the final Zig link compiles `c_api.zig` into the program (a
`comptime` reference to `@import("@io").c_api` keeps the `export fn`s; see
[../../../../docs/async-host-contract.md](../../../../docs/async-host-contract.md) "Linking").

For `cargo test`/dev builds of this crate, `build.rs` links the Zig-built static library only if
`ORIGINE_IO_LIB` is set to a directory containing `liborigine_io.a`:

```sh
mkdir -p /tmp/oio && cd /tmp/oio
zig build-lib -static -lc -OReleaseSafe --name origine_io /path/to/origine/src/io/c_api.zig
cd /path/to/origine/rust
ORIGINE_IO_LIB=/tmp/oio cargo test -p origine_io
```

(There is no `zig build` step that emits `liborigine_io.a` at the time of writing; the command above
was verified by hand.) Without `ORIGINE_IO_LIB` and outside Miri, tests fail to link. Under Miri
(`cfg(miri)`), `sys.rs` re-exports the in-process mock from `src/mock.rs` instead of the
`extern "C"` block, so no library is needed. `origine_api_fs` has the same `ORIGINE_IO_LIB`
`build.rs`.

## Safety and lints

Every `unsafe` block carries a `// SAFETY:` comment and does one unsafe operation (workspace clippy
lints, see [../../../docs/README.md](../../../docs/README.md)). The op memory model that makes the
FFI sound is described in [futures.md](futures.md).
