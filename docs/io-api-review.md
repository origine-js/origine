# origine I/O: event loop and Rust runtime, API for review

A review-oriented tour of the public APIs. The maintained references are [src/io/docs](../src/io/docs/README.md) for the Zig loop and the [origine_io docs](../rust/crates/origine_io/docs/README.md) for the Rust crate; where this page and those differ, they win.

Three layers, each on top of the one before:

1. **`src/io` (Zig)**: the event loop / reactor. Completion-based (io_uring, IOCP-shaped), caller-owned ops, backends for io_uring, kqueue+GCD and a portable thread pool. Exposed to Zig (`io.Loop`) and as a C ABI (`origine_io.h`).
2. **`origine_io` (Rust)**: safe op futures over the C ABI, plus `origine_io::rt` (single-threaded async runtime) and `origine_io::fs` (std/tokio-style capability fs).
3. **`origine_api` (Rust, V8 natives)**: the guest-facing `api.io` / `api.fs.requestAsync` (not part of this review; contract in `docs/async-host-contract.md`).

---

## 1. Zig event loop (`src/io/`)

### Model
- **Completion-based.** You submit an `Op`; the loop calls your callback with `result` (>= 0 value, or `-errno`; `-ECANCELED` when cancelled).
- **Ops are caller-owned** (libuv style): no per-op allocation, but the `Op` must stay alive and unmoved from submit until its callback ran. Ops hold plain data only (never engine handles).
- **Thread rules.** A loop is driven by one thread (whoever calls `run`). `submit`, `cancel`, `run`, `destroy` are loop-thread only. `wake` and `post` are thread-safe. Callbacks always run on the thread inside `run`. Several loops may coexist.
- **Backends** never call callbacks; they only report completions to `Loop`, which dispatches. Selection: `.auto` (uring on Linux, kqueue+GCD on macOS, else threaded), or explicit. IOCP (Windows) is a reserved slot.

### `io.Loop` (`src/io/loop.zig`)
```zig
pub const Loop = struct {
    pub fn create(allocator: std.mem.Allocator, options: Options) !*Loop
    pub fn destroy(loop: *Loop) void                  // cancels outstanding ops, runs their callbacks (-ECANCELED) and pending posts, frees
    pub fn submit(loop: *Loop, op: *Op) !void
    pub fn cancel(loop: *Loop, op: *Op) bool          // true if the op will still complete (usually with -ECANCELED); callback always runs
    pub fn run(loop: *Loop, mode: Mode) u32           // returns ops still active. .once blocks for >= 1 event; .nowait polls; .until_idle runs until active == 0
    pub fn wake(loop: *Loop) void                     // any thread: makes a blocked run(.once) return
    pub fn post(loop: *Loop, func: PostFn, ud: ?*anyopaque) !void   // any thread: runs func(ud) on the loop thread during run
    pub fn pollable(loop: *Loop) isize                // fd readable when run(.nowait) would progress; -1 if none
    pub fn caps(loop: *Loop) u64                      // Caps bits
    // typed submit helpers: fill `op` from the arguments and submit
    pub fn start(loop, op, fields: Op, cb, user) !void             // generic
    nop, open, close, read, write, readv, writev, fstat, stat, fsync, fallocate, ftruncate,
    sendfile, send, recv, sendmsg, recvmsg, connect, accept, link, unlink, rename, readdir,
    futexWait, futexWake, timeout
};
pub const Options = extern struct { backend: u32 = 0 /*0 auto,1 uring,2 kqueue_gcd,3 iocp,4 threaded*/, entries: u32 = 0 };
pub const Mode = enum(c_int) { once, nowait, until_idle };
pub const PostFn = *const fn (ud: ?*anyopaque) callconv(.c) void;
```
Helper signature shape: `loop.read(op, fd, buf: []u8, offset: i64, cb, user) !void` (offset -1 = current position, else pread).

### `Op` (`src/io/op.zig`, `extern struct`, ABI)
```zig
pub const Callback = *const fn (op: *Op, result: i64) callconv(.c) void;
pub const Op = extern struct {
    cb: ?Callback, user: ?*anyopaque,
    kind: Kind, flags: u32,
    fd: Fd,            // subject fd; for path ops the directory fd (fd_cwd = -1)
    fd2: Fd,           // sendfile input; new dir for rename/link
    offset: i64,       // -1 = current position
    buf: ?*anyopaque, len: usize,
    path: ?[*:0]const u8, path2: ?[*:0]const u8,   // UTF-8, must outlive the op
    aux: u64,          // open: flags | mode << 32; mkdir: mode; timeout: ns; accept/readdir out values
    result: i64,
    priv: [8]?*anyopaque,                           // backend scratch
};
pub const Fd = isize;  pub const fd_cwd: Fd = -1;
```
| Kind | Conventions |
|---|---|
| nop | completes 0 |
| open | `fd`=dir, `path`, `aux`=O flags (`RDONLY/WRONLY/RDWR/CREAT/TRUNC/APPEND/EXCL/DIRECTORY`) \| mode<<32; result = new fd |
| close | `fd` |
| read / write | `fd`, `buf`, `len`, `offset` (-1 current, else pread/pwrite) |
| readv / writev | `buf` = `Iovec[len]`, `offset` as above |
| fstat / stat | writes `Stat{size,mode,kind}` to `buf`; stat: `fd`=dir, `path`, `flags`&1 = nofollow |
| fsync | `flags`&1 = data only |
| fallocate | `offset`,`len`, `aux`&1 = KEEP_SIZE |
| ftruncate | `fd`, `offset` = new length |
| mkdir / unlink / rename / link | `fd`/`path` (+ `fd2`/`path2`), unlink `flags`&1 = rmdir, mkdir mode in `aux` |
| readdir | `fd`=dir, `buf`/`len` out, `offset`=cookie in, next cookie -> `aux`; packed `{kind u8, name_len u16 LE, name}`; 0 = end; -ERANGE if first entry doesn't fit |
| send / recv / sendmsg / recvmsg | native MSG_* in `flags`; msg ops: `buf` = `struct msghdr *` |
| connect / accept | `buf` = native sockaddr; accept: `len` = capacity, peer size -> `aux`, result = new fd |
| sendfile | `fd`=out, `fd2`=in, `offset`=in offset (-1 current), `len`=count |
| futex_wait / futex_wake | `buf`=`*u32`; wait: `aux`=expected, `offset`=timeout ns (<0 forever) -> 0 / -EAGAIN / -ETIMEDOUT; wake: `aux`=count, result = woken |
| timeout | `aux` = ns; fires with result 0 |

### Backend interface (`src/io/backend.zig`)
```zig
pub const VTable = struct {
    submit:   *const fn (ctx, op: *Op) anyerror!void,
    cancel:   *const fn (ctx, op: *Op) bool,
    poll:     *const fn (ctx, block: bool, out: *Drained) void,   // collects done ops + posted fns; never runs callbacks
    wake:     *const fn (ctx) void,
    post:     *const fn (ctx, func: PostFn, ud) anyerror!void,
    pollable: *const fn (ctx) isize,
    caps: u64,                                                    // Caps.{nop,file_io,timeout,cancel,pollable,vectored,sockets,futex,sendfile,fallocate,link,sync,readdir,ftruncate}
    destroy:  *const fn (ctx, out: *Drained) void,                // cancels everything outstanding into `out`, frees
};
```
Post nodes are allocated by the backend from `std.heap.c_allocator` and freed by `Loop` after running.

### C ABI (`src/io/include/origine_io.h`, implemented in `src/io/c_api.zig`)
Loop: `oio_loop_create/destroy/run/wake/post/pollable/active/caps`. Ops: `oio_nop/open/close/read/write/readv/writev/fstat/stat_at/fsync/fallocate/ftruncate/sendfile/send/recv/sendmsg/recvmsg/connect/accept/link/unlink/rename/mkdir/readdir/futex_wait/futex_wake/timeout`, plus `oio_cancel`. Every call returns 0 / value or `-errno`; same thread rules.

---

## 2. Rust: `origine_io`

### `Loop`, `LoopHandle`, op futures (`rust/crates/origine_io/src/lib.rs`)
```rust
pub struct Loop;                       // !Send; owns the oio_loop
impl Loop {
    pub fn new(options: Options) -> io::Result<Loop>;
    pub fn handle(&self) -> LoopHandle;                     // Send + Sync
    pub fn run(&self, mode: Mode) -> io::Result<u32>;       // Mode::{Once, NoWait, UntilIdle}
    pub fn wake(&self);  pub fn post<F: FnOnce() + Send + 'static>(&self, f: F) -> io::Result<()>;
    pub fn pollable(&self) -> Option<isize>;  pub fn active(&self) -> u32;  pub fn caps(&self) -> u64;
}
impl LoopHandle { pub fn wake(&self); pub fn post<F: FnOnce() + Send + 'static>(&self, f: F) -> io::Result<()>; }

// every op returns an OpFuture<T>; dropping a pending one cancels it and keeps the op's memory alive until the callback
pub type BufResult<T> = (io::Result<T>, Vec<u8>);          // buffers are passed by value and come back with the result
Loop::read(fd, Vec<u8>, Option<u64>) -> OpFuture<BufResult<usize>>        write(..) likewise
Loop::readv / writev(fd, Vec<Vec<u8>>, Option<u64>) -> OpFuture<(io::Result<usize>, Vec<Vec<u8>>)>
Loop::open(path, flags, mode) -> OpFuture<io::Result<Fd>>   close(fd)   fstat(fd) -> Stat   stat_at(path, nofollow) -> Stat
Loop::mkdir(path, mode)  unlink(path, rmdir)  rename(from, to)  link(old, new)
Loop::fsync(fd, datasync)  fallocate(fd, offset, len, keep_size)  ftruncate(fd, len)  sendfile(out, in, Option<u64>, count)
Loop::send / recv(fd, Vec<u8>, msg_flags)  (no safe sendmsg/recvmsg wrapper; they exist in the C ABI and Zig only)  connect(fd, sockaddr: Vec<u8>)  accept(fd, addr_cap) -> (Fd, Vec<u8>)
Loop::futex_wait(Arc<AtomicU32>, expected, Option<Duration>)  futex_wake(Arc<AtomicU32>, count) -> u32
Loop::timeout(Duration)   Loop::nop()
Loop::readdir(dirfd, Vec<u8>, cookie) -> OpFuture<DirRead { result, buf, cookie }>     parse_dir_entries(&[u8]) -> impl Iterator<Item = DirEntryRaw>
pub fn block_on<F: Future>(lp: &Loop, fut: F) -> F::Output;  pub fn join(a, b)
```
Errors are plain `io::Error` (`from_raw_os_error`); `-ERANGE` from readdir is `erange_error()` / `is_erange(&e)`.

### `origine_io::rt` (custom single-threaded runtime on the loop; `src/rt.rs`)
```rust
pub struct Runtime;   // !Send, bound to Rc<Loop>
impl Runtime {
    pub fn new(lp: Rc<Loop>) -> Runtime;                   // drop: cancels all tasks, runs loop.run(NoWait) once
    pub fn spawn<F: Future + 'static>(&self, f: F) -> JoinHandle<F::Output>;   // !Send futures are fine
    pub fn handle(&self) -> Handle;  pub fn event_loop(&self) -> &Rc<Loop>;
    pub fn sleep(&self, d: Duration) -> Sleep;  pub fn timeout<F: Future>(&self, d, fut: F) -> impl Future<Output = Result<F::Output, Elapsed>>;
    pub fn task_count(&self) -> usize;  pub fn has_work(&self) -> bool;     // tasks alive or ops active
    pub fn run_until_idle(&self) -> usize;                                   // poll ready tasks; does not run the loop
    pub fn tick(&self, mode: Mode) -> usize;                                 // drain ready, loop.run(mode), drain ready; returns #polls
    pub fn block_on<F: Future>(&self, fut: F) -> F::Output;
}
pub struct Handle;    // Clone, weak: try_current(), current(), spawn, sleep, timeout, is_closed
pub struct JoinHandle<T>;   // Future<Output = Result<T, JoinError>>; abort(), abort_handle(), is_finished(); dropping detaches
pub struct AbortHandle;     // Clone: abort(), is_finished()
pub enum JoinError { Cancelled, Panicked(Box<dyn Any + Send>) }   // is_cancelled / is_panic / into_panic
pub struct JoinSet<T>;      // new(), bounded(n), new_in(&Handle), bounded_in(&Handle, n); spawn, join_next, join_all, abort_all, len, is_empty
pub fn spawn / sleep / timeout / yield_now / consume_budget;  pub fn join(a, b);  pub fn select(a, b) -> Either<A, B>;  pub enum Either<A, B>;  pub struct Elapsed;
```
Semantics: wakers are `Arc<Task>` (atomic queued flag + mutexed ready queue; a wake from another thread also calls `LoopHandle::wake`); a task has a 128-unit cooperative budget per poll, spent only by `JoinHandle`, `JoinSet::join_next` and `consume_budget`; task panics are caught (`JoinError::Panicked`); `select` drops the loser before returning (cancels its ops); aborting/dropping a task drops its future, which cancels in-flight loop ops.

### `origine_io::fs` (capability-rooted, std/tokio-shaped; `src/fs/`)
```rust
Dir (Clone, Rc):  from_fd(&Loop, Fd), open_ambient(&Loop, path) (the only unchecked path), raw_fd, event_loop, close()
  open_dir, open_file(path, &OpenOptions) -> File, create_dir, create_dir_all, remove_file, remove_dir, remove_dir_all (JoinSet::bounded(16), needs a Runtime),
  rename(from, &to_dir, to), metadata, symlink_metadata, try_exists, read_dir -> ReadDir, read, write, copy, copy_to(from, &to_dir, to)
ReadDir::next_entry() -> io::Result<Option<DirEntry>>   DirEntry { file_name() -> OsString, file_name_bytes(), file_type() }
File:  read / read_at / write / write_at / write_all / write_all_at (Vec<u8> in, (io::Result<_>, Vec<u8>) out),
       read_to_end(limit) (ErrorKind::FileTooLarge), set_len, sync_all, sync_data, metadata, close, from_fd, raw_fd
OpenOptions { read, write, append, truncate, create, create_new, mode }   Metadata { len, file_type, mode, .. }   FileType { is_file, is_dir, is_symlink, is_other }
sanitize(&Path) -> io::Result<&Path>   // InvalidInput for NUL, leading '/', any '..' (lexical only; symlinks are not checked)
```
Dropping a `Dir`/`File` without `close()` submits a detached close (never blocks).

---

## 3. Things I would like your opinion on
1. **Owned buffers (`Vec<u8>` in, `(Result, Vec<u8>)` out) vs borrowed buffers.** Needed because a dropped future must not leave the kernel writing into freed memory; costs ergonomics (tokio-uring does the same).
2. **`Op` is a flat `extern struct` with overloaded fields** (`aux`, `flags`, `buf`) instead of a tagged union. Keeps the C ABI trivial; the per-kind table above is the contract.
3. **Path ops are cwd-relative on `Loop` and dirfd-relative only inside `fs::at`** (not public). Should `Loop::open/mkdir/...` take a `dirfd` publicly?
4. **`readdir` as a loop op with a resumable cookie = fd position**: one reader per directory fd; dropping `next_entry()` mid-refill can skip entries.
5. **`futex_wake` count is exact only for waiters submitted through the same backend instance on macOS** (os_sync_* cannot report counts).
6. **Blocking inside backends**: kqueue and io_uring (readdir, sendfile fallbacks) use internal worker threads for syscalls without an async form; Rust never blocks.
7. **`Loop` is `!Send` and `Runtime` is single-threaded**; cross-thread use is only `LoopHandle::{wake, post}`. Is a work-stealing/multi-loop runtime ever needed?
8. **`oio_rename` takes (old_dirfd, from, new_dirfd, to)** and `oio_stat_at` is named so (the struct is already `oio_stat`).
9. **Cancellation:** `cancel` is advisory; the callback always runs exactly once. Blocked syscalls (accept/recv/futex_wait on the threaded backend) cannot be interrupted, so `Loop::destroy` waits for them.
