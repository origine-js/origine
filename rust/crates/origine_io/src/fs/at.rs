//! Directory-relative variants of the path ops (`openat`, `mkdirat`, ...), plus the detached
//! `close` used by `Drop`. The public [`Loop`] ops in the crate root are cwd-relative; the
//! capability-style [`super::Dir`] needs a dirfd.
//!
//! Every submit closure makes exactly one C call; the SAFETY argument is the one documented on
//! "ops" in the crate root (`OpState` owns the op, paths and out-parameters at stable addresses
//! until the completion callback ran).

use crate::{Fd, Loop, OpFuture, OpState, Stat, check, cpath, sys, to_stat, trampoline};
use std::io;
use std::path::Path;

impl Loop {
    pub(crate) fn open_at(&self, dirfd: Fd, path: &Path, flags: u64, mode: u32) -> OpFuture<io::Result<Fd>> {
        let mut st = OpState::new();
        match cpath(path) {
            Ok(p) => st.path = Some(p),
            Err(e) => return self.failed(st, e),
        }
        let p = st.path_ptr();
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see module docs; `p` is the NUL-terminated path in `OpState::path`.
                unsafe { sys::oio_open(l, op, dirfd, p, flags, mode, cb) }
            },
            |_, r| check(r).map(|fd| fd as Fd),
        )
    }

    pub(crate) fn mkdir_at(&self, dirfd: Fd, path: &Path, mode: u32) -> OpFuture<io::Result<()>> {
        let mut st = OpState::new();
        match cpath(path) {
            Ok(p) => st.path = Some(p),
            Err(e) => return self.failed(st, e),
        }
        let p = st.path_ptr();
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see module docs; `p` is the NUL-terminated path in `OpState::path`.
                unsafe { sys::oio_mkdir(l, op, dirfd, p, mode, cb) }
            },
            |_, r| check(r).map(|_| ()),
        )
    }

    pub(crate) fn unlink_at(&self, dirfd: Fd, path: &Path, rmdir: bool) -> OpFuture<io::Result<()>> {
        let mut st = OpState::new();
        match cpath(path) {
            Ok(p) => st.path = Some(p),
            Err(e) => return self.failed(st, e),
        }
        let p = st.path_ptr();
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see module docs; `p` is the NUL-terminated path in `OpState::path`.
                unsafe { sys::oio_unlink(l, op, dirfd, p, u32::from(rmdir), cb) }
            },
            |_, r| check(r).map(|_| ()),
        )
    }

    pub(crate) fn rename_at(&self, from_dir: Fd, from: &Path, to_dir: Fd, to: &Path) -> OpFuture<io::Result<()>> {
        let mut st = OpState::new();
        match (cpath(from), cpath(to)) {
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
                // SAFETY: see module docs; `a`/`b` are the NUL-terminated paths in `OpState`.
                unsafe { sys::oio_rename(l, op, from_dir, a, to_dir, b, cb) }
            },
            |_, r| check(r).map(|_| ()),
        )
    }

    pub(crate) fn stat_at_dir(&self, dirfd: Fd, path: &Path, nofollow: bool) -> OpFuture<io::Result<Stat>> {
        let mut st = OpState::new();
        match cpath(path) {
            Ok(p) => st.path = Some(p),
            Err(e) => return self.failed(st, e),
        }
        let p = st.path_ptr();
        let out = st.stat;
        self.submit(
            st,
            move |l, op, cb| {
                // SAFETY: see module docs; `p` is the path in `OpState::path`, `out` the
                // `oio_stat` owned by the state.
                unsafe { sys::oio_stat_at(l, op, dirfd, p, u32::from(nofollow), out, cb) }
            },
            |st, r| {
                check(r)?;
                Ok(to_stat(st.stat_value()))
            },
        )
    }

    /// Submit a `close` that nobody awaits. The op state is born "abandoned", so the completion
    /// callback frees it; nothing is cancelled and nothing blocks. Used by `Drop`. If the loop
    /// is destroyed first, its destroy fires the callback.
    pub(crate) fn close_detached(&self, fd: Fd) {
        let mut st = OpState::new();
        st.abandoned = true;
        let op = st.op;
        let p = Box::into_raw(st);
        // SAFETY: `op` is the live allocation owned by the state at `p`; nothing else can reach
        // it before submit.
        unsafe { (*op).user = p.cast() };
        // SAFETY: the loop is alive (`self`); `op` stays at a fixed address until the callback,
        // which (state is abandoned) frees `p` and does not touch the op afterwards.
        let rc = unsafe { sys::oio_close(self.raw(), op, fd, Some(trampoline)) };
        if rc < 0 {
            // SAFETY: the submit was rejected, so the callback will never run and `p` is still
            // exclusively ours.
            drop(unsafe { Box::from_raw(p) });
        }
    }
}
