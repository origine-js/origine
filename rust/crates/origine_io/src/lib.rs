//! Safe, std-only wrapper over the `origine_io` completion-based I/O C ABI.
//!
//! A [`Loop`] owns one `oio_loop`. Operations ([`Loop::read`], [`Loop::write`], [`Loop::open`],
//! ...) submit immediately and return a [`Future`] that resolves once the loop has run the
//! completion callback. Buffers are passed by value and handed back with the result
//! (completion style, like tokio-uring), so memory stays valid for the whole operation.
//!
//! # Threading
//! A loop is driven by one thread. `Loop` is `!Send`: submitting, polling the futures and
//! calling [`Loop::run`] all happen on that thread. Only [`LoopHandle`] (from
//! [`Loop::handle`]) is `Send + Sync`; it offers [`LoopHandle::wake`] and [`LoopHandle::post`].
//!
//! # Drive modes
//! 1. **Own thread**: the thread that owns the loop calls `run(Mode::Once)` in a loop (this is
//!    what [`block_on`] does); other threads use the handle's `wake`/`post` to interrupt it.
//! 2. **Foreign loop**: poll [`Loop::pollable`] in a foreign event loop (tokio `AsyncFd`, the V8
//!    platform loop, a GUI loop, ...) and call `run(Mode::NoWait)` when it becomes readable.
//!    Futures wake whatever `Waker` the foreign executor supplied.
//!
//! # Cancellation
//! Dropping a pending future cancels the op. Its heap-allocated op and buffer are intentionally
//! kept alive until the C callback runs (the callback then frees them), so an in-flight op is
//! never freed. Dropping the `Loop` runs `oio_loop_destroy`, which fires the remaining
//! callbacks.

mod buf;
#[macro_use]
mod sys;

pub mod fs;
pub mod rt;

#[cfg(miri)]
mod mock;

pub use buf::{IoBuf, IoBufMut, RawRegion};

use std::any::Any;
use std::ffi::{CString, c_void};
use std::future::Future;
use std::io;
use std::pin::Pin;
use std::ptr;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Wake, Waker};
use std::time::Duration;

pub use sys::{
    OIO_CAP_CANCEL as CAP_CANCEL, OIO_CAP_FALLOCATE as CAP_FALLOCATE, OIO_CAP_FILE_IO as CAP_FILE_IO, OIO_CAP_FTRUNCATE as CAP_FTRUNCATE,
    OIO_CAP_FUTEX as CAP_FUTEX, OIO_CAP_LINK as CAP_LINK, OIO_CAP_NOP as CAP_NOP, OIO_CAP_POLLABLE as CAP_POLLABLE,
    OIO_CAP_READDIR as CAP_READDIR, OIO_CAP_SENDFILE as CAP_SENDFILE, OIO_CAP_SOCKETS as CAP_SOCKETS, OIO_CAP_SYNC as CAP_SYNC,
    OIO_CAP_TIMEOUT as CAP_TIMEOUT, OIO_CAP_VECTORED as CAP_VECTORED,
};

/// Open flags (low two bits are the access mode).
pub mod flags {
    pub use crate::sys::{
        OIO_O_APPEND as APPEND, OIO_O_CREAT as CREAT, OIO_O_DIRECTORY as DIRECTORY, OIO_O_EXCL as EXCL, OIO_O_RDONLY as RDONLY,
        OIO_O_RDWR as RDWR, OIO_O_TRUNC as TRUNC, OIO_O_WRONLY as WRONLY,
    };
}

/// Backend selection.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Backend {
    #[default]
    Auto,
    Uring,
    KqueueGcd,
    Iocp,
    Threaded,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Options {
    pub backend: Backend,
    /// Queue depth / worker count hint, 0 = default.
    pub entries: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// Block until at least one event.
    Once,
    NoWait,
    UntilIdle,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileKind {
    Other,
    File,
    Directory,
    Symlink,
}

#[derive(Clone, Copy, Debug)]
pub struct Stat {
    pub size: u64,
    pub mode: u32,
    pub kind: FileKind,
}

/// Raw file descriptor / handle as used by the C API.
pub type Fd = isize;

/// An I/O result together with the buffer that was lent to the op (a `Vec<u8>` unless another
/// [`IoBuf`] type is used).
pub type BufResult<T, B = Vec<u8>> = (io::Result<T>, B);

fn os_err(neg: i64) -> io::Error {
    io::Error::from_raw_os_error((-neg) as i32)
}

fn check(r: i64) -> io::Result<i64> {
    if r < 0 { Err(os_err(r)) } else { Ok(r) }
}

// ---------------------------------------------------------------------------------------------
// Loop

/// A raw loop pointer that may be sent to other threads.
#[derive(Clone, Copy)]
struct LoopPtr(*mut sys::oio_loop);

// SAFETY: the only operations performed through a `LoopPtr` on another thread are
// `oio_loop_wake` and `oio_loop_post`, which the C API documents as thread-safe. Every such use
// happens while holding `Shared::ptr`'s mutex, and `Inner::drop` clears the pointer under that
// same mutex before destroying the loop, so the pointee is alive for the whole call.
unsafe impl Send for LoopPtr {}

struct Shared {
    /// Raw loop pointer; `None` once destroyed. Guards wake/post against destroy.
    ptr: Mutex<Option<LoopPtr>>,
}

struct Inner {
    ptr: *mut sys::oio_loop,
    shared: Arc<Shared>,
}

impl Drop for Inner {
    fn drop(&mut self) {
        // Make handles inert first, then destroy (fires remaining callbacks).
        *self.shared.ptr.lock().unwrap() = None;
        // SAFETY: `self.ptr` came from a successful `oio_loop_create` and is destroyed exactly
        // once, here (`Inner` is only reachable through `Rc`, dropped last). Handles can no longer
        // reach it (cleared above), and every `OpFuture` holds an `Rc<Inner>`, so no future
        // outlives this call. All ops are released by their callbacks, which run inside destroy.
        unsafe { sys::oio_loop_destroy(self.ptr) };
    }
}

/// An I/O loop. `!Send`: keep it on the thread that drives it.
#[derive(Clone)]
pub struct Loop {
    inner: Rc<Inner>,
}

/// Thread-safe handle to a loop. Does nothing once the loop is gone.
#[derive(Clone)]
pub struct LoopHandle {
    shared: Arc<Shared>,
}

impl LoopHandle {
    /// Interrupt a blocking `run(Once)`.
    pub fn wake(&self) {
        let g = self.shared.ptr.lock().unwrap();
        if let Some(LoopPtr(p)) = *g {
            // SAFETY: `p` is alive because destroy clears it under this mutex, which we hold;
            // `oio_loop_wake` is thread-safe.
            unsafe { sys::oio_loop_wake(p) };
        }
    }

    /// Run `f` on the loop thread (inside `run`). Not run if the loop is destroyed first.
    pub fn post<F: FnOnce() + Send + 'static>(&self, f: F) -> io::Result<()> {
        unsafe extern "C" fn tramp(ud: *mut c_void) {
            // SAFETY: `ud` is the pointer produced by `Box::into_raw` below, handed to the loop
            // exactly once, and the loop calls `tramp` at most once per post.
            let f = unsafe { Box::from_raw(ud.cast::<Box<dyn FnOnce() + Send>>()) };
            f();
        }
        let g = self.shared.ptr.lock().unwrap();
        let Some(LoopPtr(p)) = *g else {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "loop destroyed"));
        };
        let raw = Box::into_raw(Box::new(Box::new(f) as Box<dyn FnOnce() + Send>)).cast::<c_void>();
        // SAFETY: `p` is alive (we hold the mutex that destroy needs); `oio_loop_post` is
        // thread-safe; `tramp` matches the boxed type behind `raw` and takes ownership of it.
        let rc = unsafe { sys::oio_loop_post(p, Some(tramp), raw) };
        if rc < 0 {
            // SAFETY: the post was rejected, so `tramp` will never run and `raw` is still ours.
            drop(unsafe { Box::from_raw(raw.cast::<Box<dyn FnOnce() + Send>>()) });
            return Err(os_err(i64::from(rc)));
        }
        Ok(())
    }
}

impl Loop {
    pub fn new(options: Options) -> io::Result<Loop> {
        let o = sys::oio_options {
            backend: match options.backend {
                Backend::Auto => sys::OIO_BACKEND_AUTO,
                Backend::Uring => sys::OIO_BACKEND_URING,
                Backend::KqueueGcd => sys::OIO_BACKEND_KQUEUE_GCD,
                Backend::Iocp => sys::OIO_BACKEND_IOCP,
                Backend::Threaded => sys::OIO_BACKEND_THREADED,
            },
            entries: options.entries,
        };
        let mut p: *mut sys::oio_loop = ptr::null_mut();
        // SAFETY: `&o` and `&mut p` are valid for the duration of the call.
        let rc = unsafe { sys::oio_loop_create(&o, &mut p) };
        if rc < 0 {
            return Err(os_err(i64::from(rc)));
        }
        let shared = Arc::new(Shared { ptr: Mutex::new(Some(LoopPtr(p))) });
        Ok(Loop { inner: Rc::new(Inner { ptr: p, shared }) })
    }

    fn raw(&self) -> *mut sys::oio_loop {
        self.inner.ptr
    }

    pub fn handle(&self) -> LoopHandle {
        LoopHandle { shared: self.inner.shared.clone() }
    }

    /// Drive the loop; returns the number of active ops.
    pub fn run(&self, mode: Mode) -> io::Result<u32> {
        let m = match mode {
            Mode::Once => sys::OIO_RUN_ONCE,
            Mode::NoWait => sys::OIO_RUN_NOWAIT,
            Mode::UntilIdle => sys::OIO_RUN_UNTIL_IDLE,
        };
        // SAFETY: `self.raw()` is alive while `self.inner` is; `Loop` is `!Send`, so this is the
        // loop's driving thread.
        let rc = unsafe { sys::oio_loop_run(self.raw(), m) };
        if rc < 0 { Err(os_err(i64::from(rc))) } else { Ok(rc as u32) }
    }

    /// Convenience for [`LoopHandle::wake`] on this thread.
    pub fn wake(&self) {
        // SAFETY: the loop is alive while `self.inner` is; `oio_loop_wake` is thread-safe.
        unsafe { sys::oio_loop_wake(self.raw()) }
    }

    pub fn post<F: FnOnce() + Send + 'static>(&self, f: F) -> io::Result<()> {
        self.handle().post(f)
    }

    /// OS handle to poll from a foreign loop, then call `run(Mode::NoWait)`.
    pub fn pollable(&self) -> Option<isize> {
        // SAFETY: the loop is alive while `self.inner` is.
        let fd = unsafe { sys::oio_loop_pollable(self.raw()) };
        (fd >= 0).then_some(fd)
    }

    pub fn active(&self) -> u32 {
        // SAFETY: the loop is alive while `self.inner` is.
        unsafe { sys::oio_loop_active(self.raw()) }
    }

    pub fn caps(&self) -> u64 {
        // SAFETY: the loop is alive while `self.inner` is.
        unsafe { sys::oio_loop_caps(self.raw()) }
    }

    // ---- ops ----
    //
    // Every submit closure below makes exactly one C call. Its SAFETY argument is always the
    // same: `l` is the live loop; `op` points to the `oio_op` owned by the op's `OpState`, which
    // stays at a fixed address until the completion callback has run (the `OpFuture` keeps the
    // state alive, or on drop hands it to the callback); any buffer / path / stat pointers were
    // taken from heap memory owned by that same `OpState` and are not touched by Rust until
    // completion.

    pub fn nop(&self) -> OpFuture<io::Result<()>> {
        let st = OpState::new();
        self.submit(
            st,
            |l, op, cb| {
                // SAFETY: see "ops" above.
                unsafe { sys::oio_nop(l, op, cb) }
            },
            |_, r| check(r).map(|_| ()),
        )
    }

    /// Read into `buf`'s whole window (`bytes_total()` bytes; for `Vec<u8>` its `len()`).
    /// `offset` None = current position. The result is the byte count; the buffer comes back
    /// with [`IoBufMut::set_init`] applied for the bytes that were read.
    pub fn read<B: IoBufMut>(&self, fd: Fd, buf: B, offset: Option<u64>) -> OpFuture<BufResult<usize, B>> {
        self.read_range(fd, buf, 0, offset)
    }

    /// Like [`Loop::read`], but into `buf[start..bytes_total()]` (a sub-range, no copy). On
    /// success `set_init(start + n)` is called. `start > bytes_total()` fails with `EINVAL`.
    pub fn read_range<B: IoBufMut>(&self, fd: Fd, buf: B, start: usize, offset: Option<u64>) -> OpFuture<BufResult<usize, B>> {
        let mut st = OpState::new();
        let total = buf.bytes_total();
        if start > total {
            st.set_owned(buf);
            return self.failed_with(st, EINVAL, |st, r| (Err(os_err(r)), st.take_owned::<B>()));
        }
        st.rw_start = start;
        let p = st.set_owned(buf).stable_mut_ptr().wrapping_add(start);
        let n = total - start;
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `p`/`n` lie inside the `IoBufMut` owned by
                // `OpState::owned`, whose pointer is stable until the buffer is dropped.
                unsafe { sys::oio_read(l, op, fd, p.cast::<c_void>(), n, off(offset), cb) }
            },
            |st, r| {
                let mut b = st.take_owned::<B>();
                let res = check(r).map(|n| n as usize);
                if let Ok(n) = res {
                    let end = st.rw_start.saturating_add(n).min(b.bytes_total());
                    // SAFETY: the op reported `n` bytes written at `start..`, so `0..end` is
                    // initialized (bytes below `start` were initialized before, or the caller
                    // chose a `start` past uninitialized bytes and accepts that), `end <= total`.
                    unsafe { b.set_init(end) };
                }
                (res, b)
            },
        )
    }

    /// Write `buf`'s initialized bytes (`bytes_init()`; for `Vec<u8>` its `len()`). `offset`
    /// None = current position.
    pub fn write<B: IoBuf>(&self, fd: Fd, buf: B, offset: Option<u64>) -> OpFuture<BufResult<usize, B>> {
        self.write_range(fd, buf, 0, offset)
    }

    /// Like [`Loop::write`], but writes `buf[start..bytes_init()]` (a sub-range, no copy). This
    /// is what `write_all` loops on for partial writes. `start > bytes_init()` fails with
    /// `EINVAL`.
    pub fn write_range<B: IoBuf>(&self, fd: Fd, buf: B, start: usize, offset: Option<u64>) -> OpFuture<BufResult<usize, B>> {
        let mut st = OpState::new();
        let init = buf.bytes_init();
        if start > init {
            st.set_owned(buf);
            return self.failed_with(st, EINVAL, |st, r| (Err(os_err(r)), st.take_owned::<B>()));
        }
        let p = st.set_owned(buf).stable_ptr().wrapping_add(start);
        let n = init - start;
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `p`/`n` lie inside the `IoBuf` owned by
                // `OpState::owned`, whose pointer is stable until the buffer is dropped.
                unsafe { sys::oio_write(l, op, fd, p.cast::<c_void>(), n, off(offset), cb) }
            },
            |st, r| (check(r).map(|n| n as usize), st.take_owned::<B>()),
        )
    }

    /// Open relative to the current directory (or absolute). Resolves to the new fd.
    pub fn open(&self, path: impl AsRef<std::path::Path>, flags: u64, mode: u32) -> OpFuture<io::Result<Fd>> {
        let mut st = OpState::new();
        match cpath(path.as_ref()) {
            Ok(p) => st.path = Some(p),
            Err(e) => return self.failed(st, e),
        }
        let p = st.path_ptr();
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `p` is the NUL-terminated path in `OpState::path`.
                unsafe { sys::oio_open(l, op, sys::OIO_FDCWD, p, flags, mode, cb) }
            },
            |_, r| check(r).map(|fd| fd as Fd),
        )
    }

    pub fn close(&self, fd: Fd) -> OpFuture<io::Result<()>> {
        self.submit(
            OpState::new(),
            move |l, op, cb| {
                // SAFETY: see "ops" above.
                unsafe { sys::oio_close(l, op, fd, cb) }
            },
            |_, r| check(r).map(|_| ()),
        )
    }

    pub fn fstat(&self, fd: Fd) -> OpFuture<io::Result<Stat>> {
        let st = OpState::new();
        let out = st.stat;
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `out` is the separately allocated `oio_stat` owned by
                // the `OpState`, written only by C until completion.
                unsafe { sys::oio_fstat(l, op, fd, out, cb) }
            },
            |st, r| {
                check(r)?;
                Ok(to_stat(st.stat_value()))
            },
        )
    }

    pub fn mkdir(&self, path: impl AsRef<std::path::Path>, mode: u32) -> OpFuture<io::Result<()>> {
        let mut st = OpState::new();
        match cpath(path.as_ref()) {
            Ok(p) => st.path = Some(p),
            Err(e) => return self.failed(st, e),
        }
        let p = st.path_ptr();
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `p` is the NUL-terminated path in `OpState::path`.
                unsafe { sys::oio_mkdir(l, op, sys::OIO_FDCWD, p, mode, cb) }
            },
            |_, r| check(r).map(|_| ()),
        )
    }

    /// Remove a file, or an (empty) directory when `rmdir` is set.
    pub fn unlink(&self, path: impl AsRef<std::path::Path>, rmdir: bool) -> OpFuture<io::Result<()>> {
        let mut st = OpState::new();
        match cpath(path.as_ref()) {
            Ok(p) => st.path = Some(p),
            Err(e) => return self.failed(st, e),
        }
        let p = st.path_ptr();
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `p` is the NUL-terminated path in `OpState::path`.
                unsafe { sys::oio_unlink(l, op, sys::OIO_FDCWD, p, u32::from(rmdir), cb) }
            },
            |_, r| check(r).map(|_| ()),
        )
    }

    pub fn rename(&self, from: impl AsRef<std::path::Path>, to: impl AsRef<std::path::Path>) -> OpFuture<io::Result<()>> {
        let mut st = OpState::new();
        match (cpath(from.as_ref()), cpath(to.as_ref())) {
            (Ok(a), Ok(b)) => {
                st.path = Some(a);
                st.path2 = Some(b);
            }
            (Err(e), _) | (_, Err(e)) => return self.failed(st, e),
        }
        let a = st.path_ptr();
        let b = st.path2_ptr();
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `a`/`b` are the NUL-terminated paths in `OpState`.
                unsafe { sys::oio_rename(l, op, sys::OIO_FDCWD, a, sys::OIO_FDCWD, b, cb) }
            },
            |_, r| check(r).map(|_| ()),
        )
    }

    /// Resolves after `d`. Expiry (reported as `-ETIME` by some backends) is success;
    /// cancellation is not applicable to a live future.
    pub fn timeout(&self, d: Duration) -> OpFuture<io::Result<()>> {
        let ns = d.as_nanos().min(u128::from(u64::MAX)) as u64;
        self.submit(
            OpState::new(),
            move |l, op, cb| {
                // SAFETY: see "ops" above.
                unsafe { sys::oio_timeout(l, op, ns, cb) }
            },
            |_, r| {
                if r == -i64::from(ETIME) {
                    return Ok(());
                }
                check(r).map(|_| ())
            },
        )
    }

    /// Flush a file to disk (`datasync`: data only, not metadata).
    pub fn fsync(&self, fd: Fd, datasync: bool) -> OpFuture<io::Result<()>> {
        self.submit(
            OpState::new(),
            move |l, op, cb| {
                // SAFETY: see "ops" above.
                unsafe { sys::oio_fsync(l, op, fd, u32::from(datasync), cb) }
            },
            |_, r| check(r).map(|_| ()),
        )
    }

    /// Stat a path relative to the current directory; `nofollow` does not follow a final symlink.
    pub fn stat_at(&self, path: impl AsRef<std::path::Path>, nofollow: bool) -> OpFuture<io::Result<Stat>> {
        let mut st = OpState::new();
        match cpath(path.as_ref()) {
            Ok(p) => st.path = Some(p),
            Err(e) => return self.failed(st, e),
        }
        let p = st.path_ptr();
        let out = st.stat;
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `p` is the NUL-terminated path in `OpState::path` and
                // `out` the `oio_stat` owned by the state.
                unsafe { sys::oio_stat_at(l, op, sys::OIO_FDCWD, p, u32::from(nofollow), out, cb) }
            },
            |st, r| {
                check(r)?;
                Ok(to_stat(st.stat_value()))
            },
        )
    }

    /// Hard link `new_path` to `old`.
    pub fn link(&self, old: impl AsRef<std::path::Path>, new_path: impl AsRef<std::path::Path>) -> OpFuture<io::Result<()>> {
        let mut st = OpState::new();
        match (cpath(old.as_ref()), cpath(new_path.as_ref())) {
            (Ok(a), Ok(b)) => {
                st.path = Some(a);
                st.path2 = Some(b);
            }
            (Err(e), _) | (_, Err(e)) => return self.failed(st, e),
        }
        let a = st.path_ptr();
        let b = st.path2_ptr();
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `a`/`b` are the NUL-terminated paths in `OpState`.
                unsafe { sys::oio_link(l, op, sys::OIO_FDCWD, a, sys::OIO_FDCWD, b, cb) }
            },
            |_, r| check(r).map(|_| ()),
        )
    }

    /// Scatter read into `bufs` (each buffer's `bytes_total()`, for `Vec<u8>` its `len()`); they
    /// come back with the result, `set_init` applied in order for the bytes that were read.
    pub fn readv<B: IoBufMut>(&self, fd: Fd, bufs: Vec<B>, offset: Option<u64>) -> OpFuture<(io::Result<usize>, Vec<B>)> {
        let mut st = OpState::new();
        let iov = st
            .set_owned(bufs)
            .iter_mut()
            .map(|b| sys::oio_iovec { base: b.stable_mut_ptr().cast::<c_void>(), len: b.bytes_total() })
            .collect();
        st.iov = iov;
        let (iov, n) = st.iov_raw();
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `iov`/`n` describe the array in `OpState::iov`, which
                // points into the buffers in `OpState::owned`; both stay put until completion.
                unsafe { sys::oio_readv(l, op, fd, iov, n, off(offset), cb) }
            },
            |st, r| {
                let mut bufs = st.take_owned::<Vec<B>>();
                let res = check(r).map(|n| n as usize);
                if let Ok(mut left) = res {
                    for b in &mut bufs {
                        let k = left.min(b.bytes_total());
                        // SAFETY: the op filled the buffers in order; the first `k` bytes of this
                        // one were written (or this is a partial read with `k == 0`).
                        unsafe { b.set_init(k) };
                        left -= k;
                    }
                }
                (res, bufs)
            },
        )
    }

    /// Gather write of `bufs` (each buffer's `bytes_init()`); they come back with the result.
    pub fn writev<B: IoBuf>(&self, fd: Fd, bufs: Vec<B>, offset: Option<u64>) -> OpFuture<(io::Result<usize>, Vec<B>)> {
        let mut st = OpState::new();
        let iov = st
            .set_owned(bufs)
            .iter()
            .map(|b| sys::oio_iovec { base: b.stable_ptr().cast_mut().cast::<c_void>(), len: b.bytes_init() })
            .collect();
        st.iov = iov;
        let (iov, n) = st.iov_raw();
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `iov`/`n` describe the array in `OpState::iov`, which
                // points into the buffers in `OpState::owned`; both stay put until completion.
                unsafe { sys::oio_writev(l, op, fd, iov, n, off(offset), cb) }
            },
            |st, r| (check(r).map(|n| n as usize), st.take_owned::<Vec<B>>()),
        )
    }

    /// Copy up to `count` bytes from `in_fd` (at `in_offset`, None = current) to `out_fd`.
    pub fn sendfile(&self, out_fd: Fd, in_fd: Fd, in_offset: Option<u64>, count: usize) -> OpFuture<io::Result<usize>> {
        self.submit(
            OpState::new(),
            move |l, op, cb| {
                // SAFETY: see "ops" above.
                unsafe { sys::oio_sendfile(l, op, out_fd, in_fd, off(in_offset), count, cb) }
            },
            |_, r| check(r).map(|n| n as usize),
        )
    }

    /// Preallocate `len` bytes at `offset`; `keep_size` does not extend the file size.
    pub fn fallocate(&self, fd: Fd, offset: u64, len: usize, keep_size: bool) -> OpFuture<io::Result<()>> {
        let flags = if keep_size { sys::OIO_FALLOC_KEEP_SIZE } else { 0 };
        self.submit(
            OpState::new(),
            move |l, op, cb| {
                // SAFETY: see "ops" above.
                unsafe { sys::oio_fallocate(l, op, fd, off(Some(offset)), len, flags, cb) }
            },
            |_, r| check(r).map(|_| ()),
        )
    }

    /// Send `buf`'s initialized bytes on a connected socket (`msg_flags` are the platform's
    /// `MSG_*` values).
    pub fn send<B: IoBuf>(&self, fd: Fd, buf: B, msg_flags: u32) -> OpFuture<BufResult<usize, B>> {
        let mut st = OpState::new();
        let n = buf.bytes_init();
        let p = st.set_owned(buf).stable_ptr();
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `p`/`n` describe the buffer held in `OpState::owned`.
                unsafe { sys::oio_send(l, op, fd, p.cast::<c_void>(), n, msg_flags, cb) }
            },
            |st, r| (check(r).map(|n| n as usize), st.take_owned::<B>()),
        )
    }

    /// Receive into `buf`'s whole window (`bytes_total()`; for `Vec<u8>` its `len()`).
    pub fn recv<B: IoBufMut>(&self, fd: Fd, buf: B, msg_flags: u32) -> OpFuture<BufResult<usize, B>> {
        let mut st = OpState::new();
        let n = buf.bytes_total();
        let p = st.set_owned(buf).stable_mut_ptr();
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `p`/`n` describe the buffer held in `OpState::owned`.
                unsafe { sys::oio_recv(l, op, fd, p.cast::<c_void>(), n, msg_flags, cb) }
            },
            |st, r| {
                let mut b = st.take_owned::<B>();
                let res = check(r).map(|n| n as usize);
                if let Ok(n) = res {
                    // SAFETY: the op wrote `n <= total` bytes from the start.
                    unsafe { b.set_init(n.min(b.bytes_total())) };
                }
                (res, b)
            },
        )
    }

    /// Connect a socket to `sockaddr` (the platform's native `sockaddr` bytes).
    pub fn connect(&self, fd: Fd, sockaddr: Vec<u8>) -> OpFuture<io::Result<()>> {
        let mut st = OpState::new();
        st.buf = sockaddr;
        let (p, n) = st.buf_raw();
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `p`/`n` describe the address bytes in `OpState::buf`.
                unsafe { sys::oio_connect(l, op, fd, p.cast::<c_void>().cast_const(), n, cb) }
            },
            |_, r| check(r).map(|_| ()),
        )
    }

    /// Accept a connection; resolves to the new fd and the peer's native `sockaddr` bytes
    /// (at most `addr_cap` of them).
    pub fn accept(&self, fd: Fd, addr_cap: usize) -> OpFuture<io::Result<(Fd, Vec<u8>)>> {
        let mut st = OpState::new();
        st.buf = vec![0; addr_cap];
        let (p, n) = st.buf_raw();
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `p`/`n` describe the address buffer in `OpState::buf`.
                unsafe { sys::oio_accept(l, op, fd, p.cast::<c_void>(), n, cb) }
            },
            |st, r| {
                let newfd = check(r)? as Fd;
                let mut addr = std::mem::take(&mut st.buf);
                addr.truncate(usize::try_from(st.op_aux()).unwrap_or(usize::MAX));
                Ok((newfd, addr))
            },
        )
    }

    /// Wait until `word` is woken (`futex_wake`) while it still equals `expected`. Fails with
    /// `EAGAIN` if it already differs, `ETIMEDOUT` after `timeout`. The word is kept alive for
    /// the op's lifetime.
    pub fn futex_wait(&self, word: Arc<AtomicU32>, expected: u32, timeout: Option<Duration>) -> OpFuture<io::Result<()>> {
        let ns = timeout.map_or(-1, |d| i64::try_from(d.as_nanos()).unwrap_or(i64::MAX));
        let mut st = OpState::new();
        let addr = word.as_ptr().cast_const();
        st.word = Some(word);
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `addr` points into the `AtomicU32` kept alive by
                // `OpState::word`.
                unsafe { sys::oio_futex_wait(l, op, addr, expected, ns, cb) }
            },
            |_, r| check(r).map(|_| ()),
        )
    }

    /// Wake up to `count` waiters on `word`; resolves to how many were woken.
    pub fn futex_wake(&self, word: Arc<AtomicU32>, count: u32) -> OpFuture<io::Result<u32>> {
        let mut st = OpState::new();
        let addr = word.as_ptr().cast_const();
        st.word = Some(word);
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `addr` points into the `AtomicU32` kept alive by
                // `OpState::word`.
                unsafe { sys::oio_futex_wake(l, op, addr, count, cb) }
            },
            |_, r| check(r).map(|n| n as u32),
        )
    }

    /// Truncate or extend the file behind `fd` to exactly `len` bytes.
    pub fn ftruncate(&self, fd: Fd, len: u64) -> OpFuture<io::Result<()>> {
        self.submit(
            OpState::new(),
            move |l, op, cb| {
                // SAFETY: see "ops" above.
                unsafe { sys::oio_ftruncate(l, op, fd, len, cb) }
            },
            |_, r| check(r).map(|_| ()),
        )
    }

    /// List the directory open on `dirfd` into `buf` (its current `len()` bytes). Pass cookie 0
    /// first, then the returned [`DirRead::cookie`]. Decode the first `n` bytes with
    /// [`parse_dir_entries`]; `n == 0` means end of directory. Do not run two readdirs on one
    /// fd at once. A first entry that does not fit in `buf` fails with [`erange_error`]
    /// (`is_erange`); use at least 4096 bytes. The buffer comes back with the result.
    pub fn readdir(&self, dirfd: Fd, buf: Vec<u8>, cookie: u64) -> OpFuture<DirRead> {
        let mut st = OpState::new();
        st.buf = buf;
        st.cookie_in = cookie;
        let (p, n) = st.buf_raw();
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see "ops" above; `p`/`n` describe the buffer held in `OpState::buf`.
                unsafe { sys::oio_readdir(l, op, dirfd, p.cast::<c_void>(), n, cookie, cb) }
            },
            |st, r| {
                let result = check(r).map(|n| n as usize).map_err(|e| if e.raw_os_error() == Some(ERANGE) { erange_error() } else { e });
                // On failure the cookie did not advance; the C side leaves `aux` untouched or
                // unspecified, so only trust it on success.
                let cookie = if result.is_ok() { st.op_aux() } else { st.cookie_in };
                DirRead { result, buf: std::mem::take(&mut st.buf), cookie }
            },
        )
    }

    // ---- plumbing ----

    fn failed<T>(&self, st: Box<OpState>, e: io::Error) -> OpFuture<io::Result<T>> {
        self.failed_with(st, e.raw_os_error().unwrap_or(EINVAL), |_, r| Err(os_err(r)))
    }

    /// A future that is already complete with `-errno` (nothing was submitted).
    fn failed_with<T>(&self, mut st: Box<OpState>, errno: i32, map: fn(&mut OpState, i64) -> T) -> OpFuture<T> {
        st.completed = true;
        st.result = Some(-i64::from(errno));
        OpFuture { st: Box::into_raw(st), lp: self.inner.clone(), map }
    }

    fn submit<T>(
        &self,
        st: Box<OpState>,
        f: impl FnOnce(*mut sys::oio_loop, *mut sys::oio_op, sys::oio_cb) -> i32,
        map: fn(&mut OpState, i64) -> T,
    ) -> OpFuture<T> {
        let op = st.op;
        let p = Box::into_raw(st);
        // SAFETY: `op` is the live allocation owned by the state at `p`; nothing else has
        // access to it yet (not submitted).
        unsafe { (*op).user = p.cast::<c_void>() };
        let rc = f(self.raw(), op, Some(trampoline));
        if rc < 0 {
            // SAFETY: `p` is live (owned by the future we return). No other reference exists:
            // the callback, if it already ran, has finished.
            let st = unsafe { state(p) };
            if !st.completed {
                st.completed = true;
                st.result = Some(i64::from(rc));
            }
        }
        OpFuture { st: p, lp: self.inner.clone(), map }
    }
}

const ERANGE: i32 = 34; // same on Linux and macOS

/// Error of [`Loop::readdir`] when the first pending entry does not fit in the buffer. Its kind is
/// [`io::ErrorKind::InvalidInput`] (`ERANGE` has no stable kind); test with [`is_erange`].
pub fn erange_error() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, "readdir buffer too small for the next entry (ERANGE)")
}

/// True for the error [`erange_error`] builds (matched by its message, kind `InvalidInput`).
pub fn is_erange(e: &io::Error) -> bool {
    e.kind() == io::ErrorKind::InvalidInput && e.to_string().contains("(ERANGE)")
}

/// Outcome of [`Loop::readdir`].
#[derive(Debug)]
pub struct DirRead {
    /// Bytes written into `buf` (0 = end of directory).
    pub result: io::Result<usize>,
    /// The buffer that was lent to the op.
    pub buf: Vec<u8>,
    /// Cookie for the next call (on error, the cookie that was passed in).
    pub cookie: u64,
}

/// One directory entry decoded by [`parse_dir_entries`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DirEntryRaw<'a> {
    pub kind: FileKind,
    /// Raw name bytes (not NUL-terminated, not necessarily UTF-8).
    pub name: &'a [u8],
}

/// Decode entries packed as `{kind u8, name_len u16 LE, name}`. Never panics: on a truncated
/// trailing entry the iterator ends (it yields nothing more).
pub fn parse_dir_entries(buf: &[u8]) -> impl Iterator<Item = DirEntryRaw<'_>> {
    let mut rest = buf;
    std::iter::from_fn(move || {
        let (&kind, tail) = rest.split_first()?;
        let (len, tail) = tail.split_first_chunk::<2>()?;
        let len = usize::from(u16::from_le_bytes(*len));
        let (name, tail) = tail.split_at_checked(len)?;
        rest = tail;
        Some(DirEntryRaw {
            kind: match kind {
                1 => FileKind::File,
                2 => FileKind::Directory,
                3 => FileKind::Symlink,
                _ => FileKind::Other,
            },
            name,
        })
    })
    .fuse()
}

#[cfg(target_os = "macos")]
const ETIME: i32 = 101;
#[cfg(not(target_os = "macos"))]
const ETIME: i32 = 62;
const EINVAL: i32 = 22;

fn to_stat(stat: sys::oio_stat) -> Stat {
    Stat {
        size: stat.size,
        mode: stat.mode,
        kind: match stat.kind {
            1 => FileKind::File,
            2 => FileKind::Directory,
            3 => FileKind::Symlink,
            _ => FileKind::Other,
        },
    }
}

/// `None` is -1 ("current position"). An offset above `i64::MAX` would wrap to a negative value
/// (`u64::MAX` to -1, silently meaning "current position"), so it maps to `i64::MIN`, which every
/// backend rejects with EINVAL.
fn off(o: Option<u64>) -> i64 {
    o.map_or(-1, |v| i64::try_from(v).unwrap_or(i64::MIN))
}

/// NUL-terminated copy of `p`.
fn cpath(p: &std::path::Path) -> io::Result<Vec<u8>> {
    #[cfg(unix)]
    let bytes = std::os::unix::ffi::OsStrExt::as_bytes(p.as_os_str()).to_vec();
    #[cfg(not(unix))]
    let bytes = p.to_str().ok_or_else(|| io::Error::from_raw_os_error(EINVAL))?.as_bytes().to_vec();
    CString::new(bytes).map(CString::into_bytes_with_nul).map_err(|_| io::Error::from_raw_os_error(EINVAL))
}

// ---------------------------------------------------------------------------------------------
// Op state and futures

/// Heap state of one op, owned through a raw `*mut OpState` (`Box::into_raw`).
///
/// The C-visible `oio_op` and `oio_stat` live in their *own* allocations (raw pointers below),
/// not inline: Rust creates `&mut OpState` in `poll`/`trampoline`, and a `&mut` covering the
/// `oio_op` would invalidate the pointer C holds. Fields C does not see are plain Rust fields.
struct OpState {
    /// Owned (`Box::into_raw`); freed in `Drop`. Stable address until the callback has run.
    op: *mut sys::oio_op,
    /// Owned (`Box::into_raw`); freed in `Drop`. Out-parameter of `oio_fstat`.
    stat: *mut sys::oio_stat,
    buf: Vec<u8>,
    /// Caller-supplied buffer(s) of read/write/send/recv/readv/writev, type-erased (`B` or
    /// `Vec<B>`); `take_owned` gives it back typed. Dropped with the state, i.e. after the
    /// completion callback when the future was abandoned.
    owned: Option<Box<dyn Any>>,
    /// Start offset inside the owned buffer of a `read_range`.
    rw_start: usize,
    /// Cookie passed to `readdir`.
    cookie_in: u64,
    /// NUL-terminated.
    path: Option<Vec<u8>>,
    path2: Option<Vec<u8>>,
    /// The `oio_iovec` array handed to C (its heap block is never reallocated after submit).
    iov: Vec<sys::oio_iovec>,
    /// Futex word, kept alive for as long as C may touch it.
    word: Option<Arc<AtomicU32>>,
    waker: Option<Waker>,
    result: Option<i64>,
    /// Callback ran (or the submit failed): nothing is in flight any more.
    completed: bool,
    /// Future was dropped while in flight: the callback frees the state.
    abandoned: bool,
}

impl OpState {
    fn new() -> Box<OpState> {
        let op = sys::oio_op {
            cb: None,
            user: ptr::null_mut(),
            kind: 0,
            flags: 0,
            fd: 0,
            fd2: 0,
            offset: 0,
            buf: ptr::null_mut(),
            len: 0,
            path: ptr::null(),
            path2: ptr::null(),
            aux: 0,
            result: 0,
            priv_: [ptr::null_mut(); 8],
        };
        Box::new(OpState {
            op: Box::into_raw(Box::new(op)),
            stat: Box::into_raw(Box::new(sys::oio_stat::default())),
            buf: Vec::new(),
            owned: None,
            rw_start: 0,
            cookie_in: 0,
            iov: Vec::new(),
            word: None,
            path: None,
            path2: None,
            waker: None,
            result: None,
            completed: false,
            abandoned: false,
        })
    }

    fn buf_raw(&mut self) -> (*mut u8, usize) {
        (self.buf.as_mut_ptr(), self.buf.len())
    }

    fn path_ptr(&self) -> *const std::ffi::c_char {
        self.path.as_ref().map_or(ptr::null(), |p| p.as_ptr().cast())
    }

    fn path2_ptr(&self) -> *const std::ffi::c_char {
        self.path2.as_ref().map_or(ptr::null(), |p| p.as_ptr().cast())
    }

    /// The iovec array handed to C (build `iov` first; never modified after).
    fn iov_raw(&self) -> (*const sys::oio_iovec, usize) {
        (self.iov.as_ptr(), self.iov.len())
    }

    /// Store the buffer and return a reference to it, so callers take its stable pointer from
    /// the value in its final home (under Stacked Borrows, moving a `Box<[u8]>` after the pointer
    /// was taken would invalidate that pointer).
    fn set_owned<B: Any>(&mut self, b: B) -> &mut B {
        self.owned = Some(Box::new(b));
        self.owned.as_mut().and_then(|b| b.downcast_mut::<B>()).expect("just stored")
    }

    /// Take the owned buffer back as the type it was stored with.
    fn take_owned<B: Any>(&mut self) -> B {
        let b = self.owned.take().expect("op state has no owned buffer");
        *b.downcast::<B>().expect("op state buffer type mismatch")
    }

    /// `op.aux` as written by C (accept: size of the peer address).
    fn op_aux(&self) -> u64 {
        // SAFETY: `self.op` is a live allocation owned by `self`; called only after completion,
        // when C no longer writes to it.
        unsafe { (*self.op).aux }
    }

    /// The out-parameter value. Only meaningful after a successful `oio_fstat` completion.
    fn stat_value(&self) -> sys::oio_stat {
        // SAFETY: `self.stat` is a live allocation owned by `self`; this is called only once the
        // op completed (from `poll`), so C no longer writes to it.
        unsafe { *self.stat }
    }
}

impl Drop for OpState {
    fn drop(&mut self) {
        // SAFETY: `op` was created by `Box::into_raw` in `new` and is freed only here. The state
        // is dropped only when nothing is in flight: after completion, or from inside the
        // completion callback of an abandoned op (C does not touch the op afterwards).
        drop(unsafe { Box::from_raw(self.op) });
        // SAFETY: as above for the `stat` allocation.
        drop(unsafe { Box::from_raw(self.stat) });
    }
}

/// Reborrow the state behind `p`.
///
/// # Safety
/// `p` must point to a live `OpState` (not yet freed), and no other reference to it may exist
/// while the returned one is used.
unsafe fn state<'a>(p: *mut OpState) -> &'a mut OpState {
    // SAFETY: guaranteed by the caller.
    unsafe { &mut *p }
}

unsafe extern "C" fn trampoline(op: *mut sys::oio_op, result: i64) {
    // SAFETY: C passes back the op we submitted; it is alive (owned by the `OpState`) until this
    // callback returns, and `submit` stored the owning state's address in `user`.
    let p = unsafe { (*op).user }.cast::<OpState>();
    // SAFETY: the state is freed only by the abandoned branch below or by the future after
    // `completed` is set here, so it is live. Callbacks run on the loop thread, never while the
    // future is being polled or dropped (single-threaded, `!Send`), so no other reference exists.
    let st = unsafe { state(p) };
    if st.abandoned {
        // SAFETY: the future was dropped and left ownership of the state to this callback.
        // `st` is not used afterwards.
        drop(unsafe { Box::from_raw(p) });
        return;
    }
    st.completed = true;
    st.result = Some(result);
    let waker = st.waker.take();
    // `st` is dead here; waking may run arbitrary executor code (even polling the future).
    if let Some(w) = waker {
        w.wake();
    }
}

/// Future of one submitted op. `!Send` (holds the loop). Dropping it while pending cancels the
/// op; its memory is released by the completion callback.
pub struct OpFuture<T> {
    /// Owned `Box::into_raw` pointer, live until this future is dropped or hands it to the
    /// callback (`abandoned`).
    st: *mut OpState,
    lp: Rc<Inner>,
    map: fn(&mut OpState, i64) -> T,
}

impl<T> Future for OpFuture<T> {
    type Output = T;
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<T> {
        let this = self.get_mut();
        // SAFETY: `this.st` is live while the future exists (see field docs). The loop only
        // runs callbacks from `run`, never during this poll, so no other reference exists.
        let st = unsafe { state(this.st) };
        match st.result.take() {
            Some(r) => Poll::Ready((this.map)(st, r)),
            None => {
                assert!(!st.completed, "OpFuture polled after completion");
                match &st.waker {
                    Some(w) if w.will_wake(cx.waker()) => {}
                    _ => st.waker = Some(cx.waker().clone()),
                }
                Poll::Pending
            }
        }
    }
}

impl<T> Drop for OpFuture<T> {
    fn drop(&mut self) {
        // SAFETY: `self.st` is live (see field docs); no other reference exists (callbacks do
        // not run during drop except from `oio_cancel` below, after our last use of `st`).
        let st = unsafe { state(self.st) };
        if st.completed {
            // SAFETY: nothing is in flight; we own the allocation and free it exactly once.
            drop(unsafe { Box::from_raw(self.st) });
        } else {
            // In flight: hand ownership to the callback. Do not touch `st` after cancel,
            // the callback may run (and free it) synchronously.
            st.abandoned = true;
            st.waker = None;
            let op = st.op;
            // SAFETY: the loop is alive (`self.lp`), `op` is the submitted, still in-flight op.
            // The callback eventually frees the state; `st` is not used after this call.
            unsafe { sys::oio_cancel(self.lp.ptr, op) };
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Minimal executor helpers

struct BlockWaker {
    woken: AtomicBool,
    handle: LoopHandle,
}

impl Wake for BlockWaker {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }
    fn wake_by_ref(self: &Arc<Self>) {
        self.woken.store(true, Ordering::SeqCst);
        self.handle.wake();
    }
}

/// Poll `fut` to completion, driving `lp` between polls. Only for tests/examples and simple
/// programs; real applications integrate with their own executor (see module docs).
pub fn block_on<F: Future>(lp: &Loop, fut: F) -> F::Output {
    let mut fut = std::pin::pin!(fut);
    let bw = Arc::new(BlockWaker { woken: AtomicBool::new(false), handle: lp.handle() });
    let waker = Waker::from(bw.clone());
    let mut cx = Context::from_waker(&waker);
    loop {
        if let Poll::Ready(v) = fut.as_mut().poll(&mut cx) {
            return v;
        }
        let mode = if bw.woken.swap(false, Ordering::SeqCst) { Mode::NoWait } else { Mode::Once };
        lp.run(mode).expect("loop run failed");
    }
}

/// Poll two futures concurrently and return both outputs.
pub fn join<A: Future, B: Future>(a: A, b: B) -> impl Future<Output = (A::Output, B::Output)> {
    let mut a = Box::pin(a);
    let mut b = Box::pin(b);
    let (mut ra, mut rb) = (None, None);
    std::future::poll_fn(move |cx| {
        if ra.is_none()
            && let Poll::Ready(v) = a.as_mut().poll(cx)
        {
            ra = Some(v);
        }
        if rb.is_none()
            && let Poll::Ready(v) = b.as_mut().poll(cx)
        {
            rb = Some(v);
        }
        if ra.is_some() && rb.is_some() { Poll::Ready((ra.take().unwrap(), rb.take().unwrap())) } else { Poll::Pending }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pack(kind: u8, name: &[u8]) -> Vec<u8> {
        let mut v = vec![kind];
        v.extend_from_slice(&(name.len() as u16).to_le_bytes());
        v.extend_from_slice(name);
        v
    }

    #[test]
    fn parse_entries() {
        let mut b = pack(1, b"a.txt");
        b.extend(pack(2, b"dir"));
        b.extend(pack(3, b""));
        b.extend(pack(9, b"\xff\xfe"));
        let v: Vec<_> = parse_dir_entries(&b).collect();
        assert_eq!(
            v,
            [
                DirEntryRaw { kind: FileKind::File, name: b"a.txt" },
                DirEntryRaw { kind: FileKind::Directory, name: b"dir" },
                DirEntryRaw { kind: FileKind::Symlink, name: b"" },
                DirEntryRaw { kind: FileKind::Other, name: b"\xff\xfe" },
            ]
        );
        assert_eq!(parse_dir_entries(&[]).count(), 0);
    }

    #[test]
    fn parse_malformed_never_panics() {
        let mut b = pack(1, b"abc");
        b.extend(pack(2, b"defgh"));
        // Every truncation yields a prefix of the complete entries and stops cleanly.
        for cut in 0..b.len() {
            let n = parse_dir_entries(&b[..cut]).count();
            assert_eq!(n, usize::from(cut >= 6), "cut {cut}");
        }
        // Name length larger than the remaining bytes.
        assert_eq!(parse_dir_entries(&[1, 0xff, 0xff, b'x']).count(), 0);
        // Header cut after kind / after one length byte.
        assert_eq!(parse_dir_entries(&[1]).count(), 0);
        assert_eq!(parse_dir_entries(&[1, 5]).count(), 0);
        // Garbage: terminates without panicking for any byte pattern.
        for seed in 0u32..200 {
            let g: Vec<u8> = (0..64u32).map(|i| (seed.wrapping_mul(2654435761).wrapping_add(i.wrapping_mul(40503)) >> 7) as u8).collect();
            let _ = parse_dir_entries(&g).count();
        }
    }

    #[test]
    fn erange_roundtrip() {
        let e = erange_error();
        assert_eq!(e.kind(), io::ErrorKind::InvalidInput);
        assert!(is_erange(&e));
        assert!(!is_erange(&io::Error::from(io::ErrorKind::InvalidInput)));
    }
}
