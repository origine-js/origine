# `origine_io::fs`

Source: `src/fs/mod.rs`, `src/fs/path.rs`, `src/fs/at.rs`. Async, `std::fs` / `tokio::fs` shaped file
system access on a [`Loop`](futures.md), built for capability style sandboxing: **there is no
ambient current directory**. Every path is resolved against a `Dir` with `openat`-family ops.

No call blocks and no thread is spawned: each `.await` is a loop op. Everything is `!Send` (handles
share an `Rc`) and meant for tasks of the single-threaded [`Runtime`](rt.md).

## Path rules (`sanitize`)

Every method that takes a path first runs `sanitize(&Path) -> io::Result<&Path>` (returns the
input unchanged). It rejects, with `ErrorKind::InvalidInput`:

* a NUL byte,
* an absolute path (leading `/`; on non-unix also a root or drive prefix),
* any `..` component.

Accepted: the empty path, `.`, `./a`, `a//b`, `a/`, names like `..a` or `a..`, non-UTF-8 bytes on
unix. What an empty path or `.` *means* is up to the operation (`open_dir("")` fails with
`NotFound`, `open_dir(".")` opens the directory itself).

**The check is lexical only.** A symlink inside a `Dir` that points outside it is still followed by
the OS. A sandbox that must also stop symlink escapes needs more (for example
`O_NOFOLLOW`/`RESOLVE_BENEATH` style resolution in the backend); this crate does not provide it.
`remove_dir_all` never follows symlinks (it unlinks them). The only unchecked entry point is
`Dir::open_ambient`, used to obtain the root capability; hand out sub-`Dir`s from it. The rules
mirror `cleanPath` in `src/api/fs.zig`.

## Types

| Type | Notes |
|---|---|
| `Dir` | `Clone` (an `Rc<Owned>`); all clones share one descriptor. |
| `File` | not `Clone`; owns a descriptor. |
| `OpenOptions` | `new()`, `read`, `write`, `append`, `truncate`, `create`, `create_new`, `mode` (default `0o666`, before umask). |
| `ReadDir` / `DirEntry` | async iterator over a directory. |
| `Metadata`, `FileType` | `len`, `is_empty`, `file_type`, `is_file/is_dir/is_symlink`, `mode` (st_mode), `permissions_mode` (`mode & 0o7777`); `FileType::is_other()` for everything else or unknown. |
| `sanitize` | see above. |

### `Dir`

```rust
Dir::from_fd(&Loop, Fd) -> Dir                  // takes ownership of an open directory fd
Dir::open_ambient(&Loop, path).await -> io::Result<Dir>   // unchecked path
dir.raw_fd() -> Option<Fd>; dir.event_loop() -> &Loop
dir.close().await                                // closes for all clones; later ops fail with EBADF
dir.open_dir(p) / open_file(p, &OpenOptions) -> File
dir.create_dir(p)        // mode 0o777 before umask
dir.create_dir_all(p)
dir.remove_file(p)       // file or symlink, not a directory
dir.remove_dir(p)        // empty directory
dir.remove_dir_all(p)
dir.rename(from, &to_dir, to)
dir.metadata(p) / symlink_metadata(p) / try_exists(p)
dir.read_dir(p) -> ReadDir
dir.read(p) -> Vec<u8>; dir.write(p, impl Into<Vec<u8>>); dir.copy(from, to) -> u64; dir.copy_to(from, &to_dir, to) -> u64
```

* `try_exists`: `Ok(false)` only for `NotFound`; permission errors and invalid paths are returned.
* `read`: opens, sizes the buffer from `fstat` as a hint, reads to EOF with no limit, always
  closes; the read error wins over the close error.
* `write`: create + truncate, `write_all`, close.
* `copy_to`: opens the source, `fstat`s it, creates/truncates the destination with the source's
  permission bits, copies in 64 KiB chunks. Returns bytes copied.
* `rename`: both sides are sanitized; `to_dir` may be `self`.

### `File`

Reads and writes use **owned buffers** (any `IoBuf`/`IoBufMut`, usually `Vec<u8>`, in;
`(io::Result<_>, B)` out, i.e. `BufResult<T, B>` with `B = Vec<u8>` by default; the reasoning and
the `Box<[u8]>` / `RawRegion` (pinned, e.g. V8 backing store) buffers are in
[futures.md](futures.md)):

```rust
file.read(buf).await        -> (io::Result<usize>, B)   // fills buf's window (Vec: len()); 0 = EOF; uses/moves the position
file.read_at(buf, off).await                              // no position
file.write(buf).await / write_at(buf, off).await         // one write of bytes_init() bytes, may be partial
file.write_all(buf).await   -> (io::Result<()>, B)       // loops over partial writes; buffer returned UNCHANGED
file.write_all_at(buf, off).await                         // (no draining; on Err some prefix may have been written)
file.read_to_end(limit).await -> io::Result<Vec<u8>>           // from the current position
file.set_len(n) / sync_all() / sync_data() / metadata() / close()
File::from_fd(&Loop, Fd); file.raw_fd() -> Option<Fd>
```

* `read` into a `Vec<u8>` expects `vec![0; n]` (the length is the window, the capacity is never
  used); the first `result` bytes of the returned buffer are the data. For `RawRegion::new_uninit`
  the buffer's `bytes_init()` covers them afterwards.
* `write_all*` slices the buffer by pointer offset between retries: no copy, no `drain`.
* `write_all*` retries `Interrupted`, returns `WriteZero` if a write makes no progress.
* `read_to_end(limit)`: fails with `ErrorKind::FileTooLarge` if more than `limit` bytes exist
  (a file of exactly `limit` bytes succeeds). Retries `Interrupted`.
* Operations without an offset use and move the descriptor's position.
* After `close`, every method fails with `EBADF` (the buffer is returned unchanged).

### `ReadDir`

`next_entry().await -> io::Result<Option<DirEntry>>`. `read_dir(p)` opens `p` as its own `Dir`
(closed on drop, detached). It refills from the `readdir` op with an 8 KiB buffer, decoding with
`parse_dir_entries`; `.` and `..` are not listed, order is the OS order. `DirEntry`:
`file_name() -> OsString`, `file_name_bytes()`, `file_type()` (kind comes with the listing, no
`stat`; `is_other()` when the file system did not say).

Caveats: the cookie is the directory fd position, so one reader per `ReadDir`; a `next_entry`
future dropped mid-refill can skip entries; `ERANGE` cannot happen with the 8 KiB buffer unless a
single name exceeds it.

## Close and drop semantics

* Explicit `close()` returns the error. It replaces the stored descriptor with a sentinel first,
  so a second `close` fails with `EBADF` and nothing is double-closed.
* **Dropping** a `File` or the last clone of a `Dir` without closing submits a *detached* `close`
  op: its memory is released by the completion callback, nothing is awaited, cancelled or blocked
  on. If the loop is destroyed first, destroy runs the callback.
* Dropping a future that waits on a loop op cancels the op ([futures.md](futures.md)). Consequences:
  a cancelled `close` may leak the descriptor; a `next_entry` dropped mid-refill may skip entries;
  a cancelled write may or may not have landed.
* A `Dir` obtained by `from_fd`/`open_ambient` is owned: closing the fd elsewhere is a bug.

## Composites

* **`create_dir_all(p)`**: creates each prefix with `mkdir`; `AlreadyExists` on a prefix is fine,
  except that the *last* component must actually be a directory (checked with `metadata`); an
  existing file in the middle surfaces as `NotADirectory` from the next `mkdir`. Safe to run
  concurrently with itself. `.` components are skipped.
* **`remove_dir_all(p)`**: `open_dir`, list all entries first (unlinking while paging may make the
  OS skip entries), then remove them concurrently with a `JoinSet::bounded(16)` per directory
  level (sub-directories recurse, everything else is `remove_file`; symlinks are unlinked, never
  followed), close the sub-dir, `remove_dir` it. The first error aborts the remaining tasks of
  that level and is returned (a panicked/cancelled child becomes `ErrorKind::Other`).
  **Requirements**: it must run inside a [`Runtime`](rt.md) (`Runtime::block_on` or a spawned
  task), because `JoinSet::bounded` needs the current runtime; outside one it panics. Fan-out
  is `<= 16` per level, so the total concurrency grows with tree depth.
* **`copy`/`copy_to`**: see `Dir` above.

## Error conventions

Plain `io::Error`; match on `io::ErrorKind`: `NotFound`, `AlreadyExists`, `NotADirectory`,
`IsADirectory`, `DirectoryNotEmpty`, `PermissionDenied`, `InvalidInput` (path rules, bad
`OpenOptions`), `FileTooLarge`, `WriteZero`, `Interrupted`. Closed handles are `EBADF` (raw os error
9). `OpenOptions` follow std's validity rules and fail with `InvalidInput` for: no access mode,
`create`/`truncate` without write or append, `append` together with `truncate` (unless
`create_new`). `create_new` implies `create` and `O_EXCL`. `origine_api_core::errno` maps these
kinds to the guest-visible `Errno` ([../../origine_api_core/docs/README.md](../../origine_api_core/docs/README.md)).

## Example

```rust
rt.block_on(async {
    let root = Dir::open_ambient(&lp, "data").await?;
    root.create_dir_all("logs/2026").await?;

    let f = root.open_file("logs/2026/a.log", OpenOptions::new().write(true).create(true).append(true)).await?;
    let (r, _buf) = f.write_all(b"line\n".to_vec()).await;
    r?;
    f.sync_data().await?;
    f.close().await?;

    let mut rd = root.read_dir("logs").await?;
    while let Some(e) = rd.next_entry().await? {
        println!("{:?} dir={}", e.file_name(), e.file_type().is_dir());
    }

    assert_eq!(root.open_dir("../x").await.unwrap_err().kind(), std::io::ErrorKind::InvalidInput);
    root.remove_dir_all("logs").await?;
    root.close().await
})?;
```
