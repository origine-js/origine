//! Pure-Rust in-memory fake of the `oio_*` C API, compiled only under Miri (which cannot call
//! the Zig library). Semantics follow `src/io/include/origine_io.h`:
//!
//! * ops are caller-owned; callbacks run only from `oio_loop_run` / `oio_loop_destroy`;
//! * file ops run (via `std::fs`) when the loop is driven, not at submit time;
//! * timeouts fire on real elapsed time and complete with 0;
//! * `oio_cancel` completes a pending op with `-ECANCELED` (deferred to the next run);
//! * destroy cancels outstanding ops, runs their callbacks and the pending posts;
//! * `oio_loop_wake` / `oio_loop_post` are thread-safe (a `Mutex`'d queue plus a `Condvar`).
//!
//! Threading model: the shared part of a loop (`Shared`) is behind a mutex. Everything else
//! (`Local`) is touched only by the loop-driving thread, per the C API contract.
//!
//! CONTRACT (docs/contracts.md, surface A): this file is a hand-written mirror of the C API. The
//! list of functions comes from the header (generated `for_each_oio_fn!`): a function missing here
//! fails to compile under Miri, and every function here must have exactly the generated signature
//! (`signatures_match_the_header` below). Constants and structs come from `sys`, never from here.

use crate::sys::{self, oio_cb, oio_fd, oio_loop, oio_op, oio_options, oio_stat};
use std::cell::{Cell, UnsafeCell};
use std::collections::{BTreeMap, VecDeque};
use std::ffi::{CStr, c_char, c_int, c_void};
use std::fs::{DirBuilder, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, FileExt, MetadataExt, OpenOptionsExt};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

const EIO: i64 = 5;
const EBADF: i64 = 9;
const ENOTDIR: i64 = 20;
const EINVAL: i64 = 22;
const ERANGE: i64 = 34; // same on Linux and macOS
#[cfg(target_os = "macos")]
mod errno_consts {
    pub const ECANCELED: i64 = 89;
    pub const ENOSYS: i64 = 78;
    pub const EAGAIN: i64 = 35;
    pub const ETIMEDOUT: i64 = 60;
}
#[cfg(not(target_os = "macos"))]
mod errno_consts {
    pub const ECANCELED: i64 = 125;
    pub const ENOSYS: i64 = 38;
    pub const EAGAIN: i64 = 11;
    pub const ETIMEDOUT: i64 = 110;
}
use errno_consts::{EAGAIN, ECANCELED, ENOSYS, ETIMEDOUT};

// ---------------------------------------------------------------------------------------------
// Loop state

struct Post {
    f: unsafe extern "C" fn(*mut c_void),
    ud: *mut c_void,
}

struct Shared {
    posts: VecDeque<Post>,
    woken: bool,
}

struct Entry {
    op: *mut oio_op,
    /// `None` (and no futex): a plain op, executed on the next run.
    deadline: Option<Instant>,
    /// Result when `deadline` passes (0 for timeouts, `-ETIMEDOUT` for futex waits).
    timeout_result: i64,
    /// Futex word this op waits on; completes only via wake, timeout or cancel.
    futex: Option<*const u32>,
}

/// How a submitted op is scheduled.
enum Sched {
    /// Execute on the next run.
    Now,
    /// Complete with 0 at the deadline.
    At(Instant),
    /// Wait on a futex word, with an optional deadline completing with `-ETIMEDOUT`.
    Futex(*const u32, Option<Instant>),
    /// Already decided: complete with this result on the next run.
    Done(i64),
}

struct Local {
    pending: Vec<Entry>,
    /// Completed or cancelled ops whose callbacks have not run yet.
    ready: VecDeque<(*mut oio_op, i64)>,
}

struct MockLoop {
    shared: Mutex<Shared>,
    cv: Condvar,
    local: UnsafeCell<Local>,
    /// Re-entrancy guard for `with_local`.
    busy: Cell<bool>,
}

enum Wait {
    Spin,
    Until(Instant),
    Forever,
}

impl MockLoop {
    fn new() -> MockLoop {
        MockLoop {
            shared: Mutex::new(Shared { posts: VecDeque::new(), woken: false }),
            cv: Condvar::new(),
            local: UnsafeCell::new(Local { pending: Vec::new(), ready: VecDeque::new() }),
            busy: Cell::new(false),
        }
    }

    /// Run `f` with exclusive access to the loop-thread-only state. `f` must not call back into
    /// the loop (it never runs user code).
    fn with_local<R>(&self, f: impl FnOnce(&mut Local) -> R) -> R {
        assert!(!self.busy.replace(true), "mock loop: re-entrant access to local state");
        // SAFETY: `local` is only accessed from the loop-driving thread (C API contract:
        // submit/cancel/run/destroy are loop-thread only; wake/post only touch `shared`), and
        // the `busy` guard above rules out an overlapping `&mut` from re-entrancy.
        let local = unsafe { &mut *self.local.get() };
        let r = f(local);
        self.busy.set(false);
        r
    }

    fn active(&self) -> u32 {
        self.with_local(|l| (l.pending.len() + l.ready.len()) as u32)
    }

    fn take_posts(&self) -> (VecDeque<Post>, bool) {
        let mut g = self.shared.lock().unwrap();
        (std::mem::take(&mut g.posts), std::mem::replace(&mut g.woken, false))
    }

    fn run_posts(posts: VecDeque<Post>) {
        for p in posts {
            // SAFETY: `f`/`ud` were supplied together by the caller of `oio_loop_post`, whose
            // contract makes `f(ud)` valid to call once on the loop thread.
            unsafe { (p.f)(p.ud) };
        }
    }

    /// One pass: posted functions, then every op that is ready (cancelled, immediate or an
    /// expired timer). Returns how many events ran and whether a wake was consumed.
    fn pass(&self) -> (usize, bool) {
        let (posts, woken) = self.take_posts();
        let mut ran = posts.len();
        Self::run_posts(posts);

        let now = Instant::now();
        let batch = self.with_local(|l| {
            let mut out: Vec<(*mut oio_op, Option<i64>)> = l.ready.drain(..).map(|(op, r)| (op, Some(r))).collect();
            let mut keep = Vec::new();
            for e in l.pending.drain(..) {
                match (e.deadline, e.futex) {
                    (Some(d), _) if d > now => keep.push(e),
                    (Some(_), _) => out.push((e.op, Some(e.timeout_result))),
                    (None, Some(_)) => keep.push(e),
                    (None, None) => out.push((e.op, None)),
                }
            }
            l.pending = keep;
            out
        });
        ran += batch.len();
        for (op, res) in batch {
            let r = res.unwrap_or_else(|| {
                let req = snapshot(op);
                if req.kind == sys::OIO_READDIR {
                    let (r, next) = readdir(&req);
                    // SAFETY: `op` is alive until its callback runs (below); no reference to it
                    // is held here, and the write goes through the raw pointer.
                    unsafe { (*op).aux = next };
                    r
                } else {
                    execute(&req)
                }
            });
            complete(op, r);
        }
        (ran, woken)
    }

    fn wait_kind(&self) -> Wait {
        self.with_local(|l| {
            if !l.ready.is_empty() || l.pending.iter().any(|e| e.deadline.is_none() && e.futex.is_none()) {
                Wait::Spin
            } else if let Some(t) = l.pending.iter().filter_map(|e| e.deadline).min() {
                Wait::Until(t)
            } else {
                Wait::Forever
            }
        })
    }

    /// Block until a post/wake arrives or the earliest timer expires.
    fn wait(&self) {
        let kind = self.wait_kind();
        if matches!(kind, Wait::Spin) {
            return;
        }
        let mut g = self.shared.lock().unwrap();
        loop {
            if !g.posts.is_empty() || g.woken {
                return;
            }
            match kind {
                Wait::Spin => return,
                Wait::Forever => g = self.cv.wait(g).unwrap(),
                Wait::Until(t) => {
                    let now = Instant::now();
                    if now >= t {
                        return;
                    }
                    g = self.cv.wait_timeout(g, t - now).unwrap().0;
                }
            }
        }
    }

    fn run(&self, mode: c_int) -> c_int {
        if !(sys::OIO_RUN_ONCE..=sys::OIO_RUN_UNTIL_IDLE).contains(&mode) {
            return -(EINVAL as c_int);
        }
        let mut woke = false;
        loop {
            let (ran, w) = self.pass();
            woke |= w;
            let active = self.active() as c_int;
            match mode {
                sys::OIO_RUN_NOWAIT => return active,
                sys::OIO_RUN_ONCE => {
                    if ran > 0 || woke {
                        return active;
                    }
                }
                _ => {
                    if active == 0 {
                        if ran == 0 {
                            return 0;
                        }
                        continue;
                    }
                }
            }
            self.wait();
        }
    }

    /// Wake up to `count` waiters on `addr` (FIFO); returns how many.
    fn wake_futex(&self, addr: *const u32, count: u32) -> i64 {
        self.with_local(|l| {
            let mut woken = 0;
            let mut i = 0;
            while i < l.pending.len() && woken < i64::from(count) {
                if l.pending[i].futex == Some(addr) {
                    let e = l.pending.remove(i);
                    l.ready.push_back((e.op, 0));
                    woken += 1;
                } else {
                    i += 1;
                }
            }
            woken
        })
    }

    fn cancel(&self, op: *mut oio_op) -> c_int {
        self.with_local(|l| match l.pending.iter().position(|e| e.op == op) {
            Some(i) => {
                l.pending.remove(i);
                l.ready.push_back((op, -ECANCELED));
                1
            }
            None => 0,
        })
    }

    /// Cancel everything, run callbacks and posts until quiescent.
    fn drain_for_destroy(&self) {
        loop {
            let (posts, _) = self.take_posts();
            let had_posts = !posts.is_empty();
            Self::run_posts(posts);
            let batch: Vec<_> = self.with_local(|l| {
                for e in l.pending.drain(..) {
                    l.ready.push_back((e.op, -ECANCELED));
                }
                l.ready.drain(..).collect()
            });
            let had_ops = !batch.is_empty();
            for (op, r) in batch {
                complete(op, r);
            }
            if !had_posts && !had_ops {
                return;
            }
        }
    }
}

/// Borrow the loop behind a C pointer.
///
/// # Safety
/// `l` must come from `oio_loop_create` and not yet be destroyed.
unsafe fn lp<'a>(l: *mut oio_loop) -> &'a MockLoop {
    // SAFETY: guaranteed by the caller; only shared references are created, and the only
    // cross-thread entry points (`wake`/`post`) use the `Mutex`-protected part.
    unsafe { &*l.cast::<MockLoop>() }
}

// ---------------------------------------------------------------------------------------------
// Ops

struct Req {
    kind: i32,
    fd: oio_fd,
    fd2: oio_fd,
    offset: i64,
    buf: *mut c_void,
    len: usize,
    path: *const c_char,
    path2: *const c_char,
    aux: u64,
}

fn snapshot(op: *mut oio_op) -> Req {
    // SAFETY: `op` was accepted by a submit call and stays alive and unmoved until its callback
    // runs (C API contract), which has not happened yet; nobody else holds a reference.
    let o = unsafe { &*op };
    Req { kind: o.kind, fd: o.fd, fd2: o.fd2, offset: o.offset, buf: o.buf, len: o.len, path: o.path, path2: o.path2, aux: o.aux }
}

/// Store the result in the op and run its callback.
fn complete(op: *mut oio_op, result: i64) {
    // SAFETY: `op` is alive until its callback returns (C API contract); the reference is
    // dropped before the callback runs.
    let o = unsafe { &mut *op };
    o.result = result;
    let cb = o.cb;
    if let Some(cb) = cb {
        // SAFETY: `cb` was supplied with the op by the submitter, who guarantees it is valid to
        // call with this op. The op may be freed by the callback; we never touch it afterwards.
        unsafe { cb(op, result) };
    }
}

fn errno(e: &io::Error) -> i64 {
    -i64::from(e.raw_os_error().unwrap_or(EIO as i32))
}

fn io_result(r: io::Result<usize>) -> i64 {
    match r {
        Ok(n) => n as i64,
        Err(e) => errno(&e),
    }
}

fn path_of(p: *const c_char) -> PathBuf {
    // SAFETY: the submitter guarantees `p` is a valid NUL-terminated string that outlives the
    // op (it points into the op's owner, kept alive until the callback).
    let c = unsafe { CStr::from_ptr(p) };
    PathBuf::from(std::ffi::OsStr::from_bytes(c.to_bytes()))
}

struct Fds {
    next: isize,
    files: BTreeMap<isize, File>,
    /// Paths of the fds opened on directories (for `oio_readdir`).
    dirs: BTreeMap<isize, PathBuf>,
}

static FDS: Mutex<Fds> = Mutex::new(Fds { next: 3, files: BTreeMap::new(), dirs: BTreeMap::new() });

/// Resolve `p` against `dirfd` (`OIO_FDCWD` = the process cwd, otherwise a directory opened
/// through this mock; its path is recorded in `dirs`). Mock-only: the real backends use `*at`.
fn resolve(dirfd: oio_fd, p: *const c_char) -> Result<PathBuf, i64> {
    let rel = path_of(p);
    if dirfd == sys::OIO_FDCWD {
        return Ok(rel);
    }
    let t = FDS.lock().unwrap();
    match t.dirs.get(&dirfd) {
        Some(base) => Ok(base.join(rel)),
        None if t.files.contains_key(&dirfd) => Err(-ENOTDIR),
        None => Err(-EBADF),
    }
}

fn open_file(r: &Req) -> i64 {
    let path = match resolve(r.fd, r.path) {
        Ok(p) => p,
        Err(e) => return e,
    };
    let flags = r.aux & 0xffff_ffff;
    let mode = (r.aux >> 32) as u32;
    let mut o = OpenOptions::new();
    match flags & 3 {
        0 => {
            o.read(true);
        }
        1 => {
            o.write(true);
        }
        _ => {
            o.read(true).write(true);
        }
    }
    if flags & sys::OIO_O_CREAT != 0 {
        if flags & sys::OIO_O_EXCL != 0 {
            o.create_new(true);
        } else {
            o.create(true);
        }
    }
    if flags & sys::OIO_O_TRUNC != 0 {
        o.truncate(true);
    }
    if flags & sys::OIO_O_APPEND != 0 {
        o.append(true);
    }
    o.mode(mode);
    let f = match o.open(&path) {
        Ok(f) => f,
        Err(e) => return errno(&e),
    };
    let is_dir = f.metadata().is_ok_and(|m| m.is_dir());
    if flags & sys::OIO_O_DIRECTORY != 0 && !is_dir {
        return -ENOTDIR;
    }
    let mut t = FDS.lock().unwrap();
    let fd = t.next;
    t.next += 1;
    t.files.insert(fd, f);
    if is_dir {
        t.dirs.insert(fd, path);
    }
    fd as i64
}

/// Fill `buf` unless EOF comes first (Miri's `pread`/`pwrite` shims may transfer less).
fn read_full(f: &File, buf: &mut [u8], offset: i64) -> io::Result<usize> {
    let mut done = 0;
    while done < buf.len() {
        let n = if offset < 0 { (&*f).read(&mut buf[done..])? } else { f.read_at(&mut buf[done..], offset as u64 + done as u64)? };
        if n == 0 {
            break;
        }
        done += n;
    }
    Ok(done)
}

fn write_full(f: &File, buf: &[u8], offset: i64) -> io::Result<usize> {
    if offset < 0 {
        (&*f).write_all(buf)?;
    } else {
        f.write_all_at(buf, offset as u64)?;
    }
    Ok(buf.len())
}

fn write_stat(out: *mut c_void, m: &std::fs::Metadata) -> i64 {
    let kind = if m.is_file() {
        1
    } else if m.is_dir() {
        2
    } else if m.file_type().is_symlink() {
        3
    } else {
        0
    };
    let st = oio_stat { size: m.len(), mode: m.mode(), kind };
    // SAFETY: the stat submit functions store the caller's out pointer in `buf`; the submitter
    // keeps it valid and unaliased until the callback.
    unsafe { out.cast::<oio_stat>().write(st) };
    0
}

/// Miri on macOS has no `linkat`, so a "hard link" is a copy that fails if the target exists
/// (same observable content, size and EEXIST behaviour; no shared inode).
fn emulated_link(old: &std::path::Path, new: &std::path::Path) -> io::Result<usize> {
    let data = std::fs::read(old)?;
    let mut f = OpenOptions::new().write(true).create_new(true).open(new)?;
    f.write_all(&data)?;
    Ok(0)
}

/// Mock of `oio_readdir`: entries sorted by name, cookie = index of the next entry. Returns the
/// result and the next cookie (`op->aux`).
fn readdir(r: &Req) -> (i64, u64) {
    let path = {
        let t = FDS.lock().unwrap();
        match t.dirs.get(&r.fd) {
            Some(p) => p.clone(),
            None if t.files.contains_key(&r.fd) => return (-ENOTDIR, r.aux),
            None => return (-EBADF, r.aux),
        }
    };
    let mut ents: Vec<(Vec<u8>, u8)> = Vec::new();
    let rd = match std::fs::read_dir(path) {
        Ok(rd) => rd,
        Err(e) => return (errno(&e), r.aux),
    };
    for e in rd {
        let Ok(e) = e else { return (-EIO, r.aux) };
        let kind = match e.file_type() {
            Ok(t) if t.is_file() => 1,
            Ok(t) if t.is_dir() => 2,
            Ok(t) if t.is_symlink() => 3,
            _ => 0,
        };
        ents.push((e.file_name().as_bytes().to_vec(), kind));
    }
    ents.sort();
    let start = usize::try_from(r.aux).unwrap_or(usize::MAX);
    // SAFETY: the submitter guarantees `buf..buf+len` is writable memory, exclusively lent to
    // the op until its callback (non-null and aligned: `u8`, `Vec` pointer).
    let buf = unsafe { std::slice::from_raw_parts_mut(r.buf.cast::<u8>(), r.len) };
    let mut pos = 0;
    let mut idx = start;
    while let Some((name, kind)) = ents.get(idx) {
        let need = 3 + name.len();
        if pos + need > buf.len() {
            break;
        }
        buf[pos] = *kind;
        buf[pos + 1..pos + 3].copy_from_slice(&(name.len() as u16).to_le_bytes());
        buf[pos + 3..pos + need].copy_from_slice(name);
        pos += need;
        idx += 1;
    }
    if pos == 0 && idx < ents.len() {
        return (-ERANGE, r.aux);
    }
    (pos as i64, idx as u64)
}

fn execute(r: &Req) -> i64 {
    match r.kind {
        sys::OIO_NOP => 0,
        sys::OIO_OPEN => open_file(r),
        sys::OIO_CLOSE => {
            let mut t = FDS.lock().unwrap();
            t.dirs.remove(&r.fd);
            match t.files.remove(&r.fd) {
                Some(_) => 0,
                None => -EBADF,
            }
        }
        sys::OIO_FTRUNCATE => {
            let t = FDS.lock().unwrap();
            let Some(f) = t.files.get(&r.fd) else { return -EBADF };
            io_result(f.set_len(r.aux).map(|()| 0))
        }
        sys::OIO_READ => {
            let t = FDS.lock().unwrap();
            let Some(f) = t.files.get(&r.fd) else { return -EBADF };
            // SAFETY: the submitter guarantees `buf..buf+len` is writable memory, exclusively
            // lent to the op until its callback (non-null and aligned: `u8`, `Vec` pointer).
            let buf = unsafe { std::slice::from_raw_parts_mut(r.buf.cast::<u8>(), r.len) };
            io_result(read_full(f, buf, r.offset))
        }
        sys::OIO_WRITE => {
            let t = FDS.lock().unwrap();
            let Some(f) = t.files.get(&r.fd) else { return -EBADF };
            // SAFETY: the submitter guarantees `buf..buf+len` is readable memory that is not
            // mutated until the op's callback.
            let buf = unsafe { std::slice::from_raw_parts(r.buf.cast::<u8>().cast_const(), r.len) };
            io_result(write_full(f, buf, r.offset))
        }
        sys::OIO_FSTAT => {
            let t = FDS.lock().unwrap();
            let Some(f) = t.files.get(&r.fd) else { return -EBADF };
            let m = match f.metadata() {
                Ok(m) => m,
                Err(e) => return errno(&e),
            };
            write_stat(r.buf, &m)
        }
        sys::OIO_STAT => {
            let p = match resolve(r.fd, r.path) {
                Ok(p) => p,
                Err(e) => return e,
            };
            let m = if r.aux & 1 != 0 { std::fs::symlink_metadata(p) } else { std::fs::metadata(p) };
            match m {
                Ok(m) => write_stat(r.buf, &m),
                Err(e) => errno(&e),
            }
        }
        sys::OIO_FSYNC => {
            let t = FDS.lock().unwrap();
            let Some(f) = t.files.get(&r.fd) else { return -EBADF };
            io_result(if r.aux & 1 != 0 { f.sync_data() } else { f.sync_all() }.map(|()| 0))
        }
        sys::OIO_LINK => match (resolve(r.fd, r.path), resolve(r.fd2, r.path2)) {
            (Ok(a), Ok(b)) => io_result(emulated_link(&a, &b)),
            (Err(e), _) | (_, Err(e)) => e,
        },
        sys::OIO_READV | sys::OIO_WRITEV => {
            let t = FDS.lock().unwrap();
            let Some(f) = t.files.get(&r.fd) else { return -EBADF };
            // SAFETY: the submitter guarantees `buf` points to `len` valid `oio_iovec`s that stay
            // alive and unchanged until the callback.
            let iov = unsafe { std::slice::from_raw_parts(r.buf.cast::<sys::oio_iovec>().cast_const(), r.len) };
            let mut total = 0usize;
            for v in iov {
                let pos = if r.offset < 0 { -1 } else { r.offset + total as i64 };
                let n = if r.kind == sys::OIO_READV {
                    // SAFETY: each iovec describes writable memory exclusively lent to the op.
                    let b = unsafe { std::slice::from_raw_parts_mut(v.base.cast::<u8>(), v.len) };
                    read_full(f, b, pos)
                } else {
                    // SAFETY: each iovec describes readable memory unchanged until the callback.
                    let b = unsafe { std::slice::from_raw_parts(v.base.cast::<u8>().cast_const(), v.len) };
                    write_full(f, b, pos)
                };
                match n {
                    Ok(n) => {
                        total += n;
                        if n < v.len {
                            break;
                        }
                    }
                    Err(e) if total == 0 => return errno(&e),
                    Err(_) => break,
                }
            }
            total as i64
        }
        sys::OIO_SENDFILE => {
            let t = FDS.lock().unwrap();
            let (Some(inf), Some(outf)) = (t.files.get(&r.fd2), t.files.get(&r.fd)) else {
                return -EBADF;
            };
            let mut tmp = vec![0u8; r.len];
            io_result(read_full(inf, &mut tmp, r.offset).and_then(|n| write_full(outf, &tmp[..n], -1)))
        }
        sys::OIO_FALLOCATE => {
            let t = FDS.lock().unwrap();
            let Some(f) = t.files.get(&r.fd) else { return -EBADF };
            let end = r.offset.saturating_add(r.len as i64);
            if r.offset < 0 || end < 0 {
                return -EINVAL;
            }
            if r.aux & sys::OIO_FALLOC_KEEP_SIZE != 0 {
                return 0;
            }
            match f.metadata() {
                Ok(m) if m.len() >= end as u64 => 0,
                Ok(_) => io_result(f.set_len(end as u64).map(|()| 0)),
                Err(e) => errno(&e),
            }
        }
        sys::OIO_SEND | sys::OIO_RECV | sys::OIO_SENDMSG | sys::OIO_RECVMSG | sys::OIO_CONNECT | sys::OIO_ACCEPT => -ENOSYS,
        sys::OIO_MKDIR => {
            let p = match resolve(r.fd, r.path) {
                Ok(p) => p,
                Err(e) => return e,
            };
            let mut b = DirBuilder::new();
            b.mode(r.aux as u32);
            io_result(b.create(p).map(|()| 0))
        }
        sys::OIO_UNLINK => {
            let p = match resolve(r.fd, r.path) {
                Ok(p) => p,
                Err(e) => return e,
            };
            io_result(if r.aux & 1 != 0 { std::fs::remove_dir(p) } else { std::fs::remove_file(p) }.map(|()| 0))
        }
        sys::OIO_RENAME => match (resolve(r.fd, r.path), resolve(r.fd2, r.path2)) {
            (Ok(a), Ok(b)) => io_result(std::fs::rename(a, b).map(|()| 0)),
            (Err(e), _) | (_, Err(e)) => e,
        },
        _ => -EINVAL,
    }
}

/// Fill the op, queue it, and return 0 (or `-EINVAL` for a missing callback).
///
/// # Safety
/// `l` is a live loop, `op` a valid op that stays alive and unmoved until its callback ran.
unsafe fn submit(l: *mut oio_loop, op: *mut oio_op, cb: oio_cb, sched: Sched, fill: impl FnOnce(&mut oio_op)) -> c_int {
    if cb.is_none() {
        return -(EINVAL as c_int);
    }
    // SAFETY: the caller guarantees `op` is valid and exclusively ours until the callback.
    let o = unsafe { &mut *op };
    o.cb = cb;
    o.flags = 0;
    o.result = 0;
    o.fd = 0;
    o.fd2 = 0;
    o.offset = -1;
    o.buf = std::ptr::null_mut();
    o.len = 0;
    o.path = std::ptr::null();
    o.path2 = std::ptr::null();
    o.aux = 0;
    fill(o);
    // SAFETY: `l` is live (caller contract).
    let l = unsafe { lp(l) };
    l.with_local(|loc| match sched {
        Sched::Done(r) => loc.ready.push_back((op, r)),
        Sched::Now => loc.pending.push(Entry { op, deadline: None, timeout_result: 0, futex: None }),
        Sched::At(t) => {
            loc.pending.push(Entry { op, deadline: Some(t), timeout_result: 0, futex: None });
        }
        Sched::Futex(a, t) => {
            loc.pending.push(Entry { op, deadline: t, timeout_result: -ETIMEDOUT, futex: Some(a) });
        }
    });
    0
}

// ---------------------------------------------------------------------------------------------
// The C API

/// # Safety
/// C API contract (`origine_io.h`): `out` must be valid for a pointer write; `options` may be null
/// or point to a valid `oio_options`.
pub unsafe extern "C" fn oio_loop_create(options: *const oio_options, out: *mut *mut oio_loop) -> c_int {
    if !options.is_null() {
        // SAFETY: non-null and valid per the contract above.
        let o = unsafe { *options };
        if o.backend > sys::OIO_BACKEND_THREADED {
            return -(EINVAL as c_int);
        }
    }
    let p = Box::into_raw(Box::new(MockLoop::new())).cast::<oio_loop>();
    // SAFETY: `out` is valid for writes per the contract.
    unsafe { *out = p };
    0
}

/// # Safety
/// `l` must come from `oio_loop_create`, be used by the loop thread only, and no other thread may
/// call `wake`/`post` concurrently; the loop must not be used afterwards.
pub unsafe extern "C" fn oio_loop_destroy(l: *mut oio_loop) {
    // SAFETY: live loop per the contract; the reference is dropped before the `Box` is freed.
    let lp_ref = unsafe { lp(l) };
    lp_ref.drain_for_destroy();
    // SAFETY: `l` came from `Box::into_raw` in `oio_loop_create`, is destroyed exactly once, and
    // no reference to it remains (all callbacks have returned).
    drop(unsafe { Box::from_raw(l.cast::<MockLoop>()) });
}

/// # Safety
/// `l` must be a live loop, driven by the calling (loop) thread only.
pub unsafe extern "C" fn oio_loop_run(l: *mut oio_loop, mode: c_int) -> c_int {
    // SAFETY: live loop per the contract.
    unsafe { lp(l) }.run(mode)
}

/// # Safety
/// `l` must be a live loop (may be called from any thread while it is alive).
pub unsafe extern "C" fn oio_loop_wake(l: *mut oio_loop) {
    // SAFETY: live loop per the contract; `wake` only touches the mutex-protected part.
    let l = unsafe { lp(l) };
    l.shared.lock().unwrap().woken = true;
    l.cv.notify_all();
}

/// # Safety
/// `l` must be a live loop (any thread); `f(ud)` must be valid to call once on the loop thread.
pub unsafe extern "C" fn oio_loop_post(l: *mut oio_loop, f: Option<unsafe extern "C" fn(*mut c_void)>, ud: *mut c_void) -> c_int {
    let Some(f) = f else { return -(EINVAL as c_int) };
    // SAFETY: live loop per the contract; `post` only touches the mutex-protected part.
    let l = unsafe { lp(l) };
    l.shared.lock().unwrap().posts.push_back(Post { f, ud });
    l.cv.notify_all();
    0
}

/// # Safety
/// `l` must be a live loop.
pub unsafe extern "C" fn oio_loop_pollable(_l: *mut oio_loop) -> isize {
    -1
}

/// # Safety
/// `l` must be a live loop, used from the loop thread.
pub unsafe extern "C" fn oio_loop_active(l: *mut oio_loop) -> u32 {
    // SAFETY: live loop per the contract.
    unsafe { lp(l) }.active()
}

/// # Safety
/// `l` must be a live loop.
pub unsafe extern "C" fn oio_loop_caps(_l: *mut oio_loop) -> u64 {
    sys::OIO_CAP_NOP
        | sys::OIO_CAP_FILE_IO
        | sys::OIO_CAP_TIMEOUT
        | sys::OIO_CAP_CANCEL
        | sys::OIO_CAP_VECTORED
        | sys::OIO_CAP_FUTEX
        | sys::OIO_CAP_SENDFILE
        | sys::OIO_CAP_FALLOCATE
        | sys::OIO_CAP_LINK
        | sys::OIO_CAP_SYNC
        | sys::OIO_CAP_READDIR
        | sys::OIO_CAP_FTRUNCATE
}

/// # Safety
/// `l` live, `op` valid and kept alive/unmoved until its callback ran (loop thread only).
pub unsafe extern "C" fn oio_nop(l: *mut oio_loop, op: *mut oio_op, cb: oio_cb) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_NOP;
        })
    }
}

/// # Safety
/// As [`oio_nop`]; `path` must be a NUL-terminated string valid until the callback.
pub unsafe extern "C" fn oio_open(
    l: *mut oio_loop,
    op: *mut oio_op,
    dirfd: oio_fd,
    path: *const c_char,
    flags: u64,
    mode: u32,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_OPEN;
            o.fd = dirfd;
            o.path = path;
            o.aux = flags | (u64::from(mode) << 32);
        })
    }
}

/// # Safety
/// As [`oio_nop`].
pub unsafe extern "C" fn oio_close(l: *mut oio_loop, op: *mut oio_op, fd: oio_fd, cb: oio_cb) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_CLOSE;
            o.fd = fd;
        })
    }
}

/// # Safety
/// As [`oio_nop`]; `buf..buf+len` must be writable and exclusively lent until the callback.
pub unsafe extern "C" fn oio_read(
    l: *mut oio_loop,
    op: *mut oio_op,
    fd: oio_fd,
    buf: *mut c_void,
    len: usize,
    offset: i64,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_READ;
            o.fd = fd;
            o.buf = buf;
            o.len = len;
            o.offset = offset;
        })
    }
}

/// # Safety
/// As [`oio_nop`]; `buf..buf+len` must be readable and unmodified until the callback.
pub unsafe extern "C" fn oio_write(
    l: *mut oio_loop,
    op: *mut oio_op,
    fd: oio_fd,
    buf: *const c_void,
    len: usize,
    offset: i64,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_WRITE;
            o.fd = fd;
            o.buf = buf.cast_mut();
            o.len = len;
            o.offset = offset;
        })
    }
}

/// # Safety
/// As [`oio_nop`]; `out` must be valid for an `oio_stat` write until the callback.
pub unsafe extern "C" fn oio_fstat(l: *mut oio_loop, op: *mut oio_op, fd: oio_fd, out: *mut oio_stat, cb: oio_cb) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_FSTAT;
            o.fd = fd;
            o.buf = out.cast::<c_void>();
        })
    }
}

/// # Safety
/// As [`oio_open`].
pub unsafe extern "C" fn oio_mkdir(l: *mut oio_loop, op: *mut oio_op, dirfd: oio_fd, path: *const c_char, mode: u32, cb: oio_cb) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_MKDIR;
            o.fd = dirfd;
            o.path = path;
            o.aux = u64::from(mode);
        })
    }
}

/// # Safety
/// As [`oio_open`].
pub unsafe extern "C" fn oio_unlink(
    l: *mut oio_loop,
    op: *mut oio_op,
    dirfd: oio_fd,
    path: *const c_char,
    flags: u32,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_UNLINK;
            o.fd = dirfd;
            o.path = path;
            o.aux = u64::from(flags);
        })
    }
}

/// # Safety
/// As [`oio_open`]; both paths must be valid until the callback.
pub unsafe extern "C" fn oio_rename(
    l: *mut oio_loop,
    op: *mut oio_op,
    old_dirfd: oio_fd,
    from: *const c_char,
    new_dirfd: oio_fd,
    to: *const c_char,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_RENAME;
            o.fd = old_dirfd;
            o.fd2 = new_dirfd;
            o.path = from;
            o.path2 = to;
        })
    }
}

/// # Safety
/// As [`oio_rename`].
pub unsafe extern "C" fn oio_link(
    l: *mut oio_loop,
    op: *mut oio_op,
    old_dirfd: oio_fd,
    old: *const c_char,
    new_dirfd: oio_fd,
    new_path: *const c_char,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_LINK;
            o.fd = old_dirfd;
            o.fd2 = new_dirfd;
            o.path = old;
            o.path2 = new_path;
        })
    }
}

/// # Safety
/// As [`oio_open`]; `out` must be valid for an `oio_stat` write until the callback.
pub unsafe extern "C" fn oio_stat_at(
    l: *mut oio_loop,
    op: *mut oio_op,
    dirfd: oio_fd,
    path: *const c_char,
    nofollow: u32,
    out: *mut oio_stat,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_STAT;
            o.fd = dirfd;
            o.path = path;
            o.buf = out.cast::<c_void>();
            o.aux = u64::from(nofollow != 0);
        })
    }
}

/// # Safety
/// As [`oio_nop`].
pub unsafe extern "C" fn oio_fsync(l: *mut oio_loop, op: *mut oio_op, fd: oio_fd, datasync: u32, cb: oio_cb) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_FSYNC;
            o.fd = fd;
            o.aux = u64::from(datasync != 0);
        })
    }
}

/// # Safety
/// As [`oio_nop`].
pub unsafe extern "C" fn oio_sendfile(
    l: *mut oio_loop,
    op: *mut oio_op,
    out_fd: oio_fd,
    in_fd: oio_fd,
    in_offset: i64,
    count: usize,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_SENDFILE;
            o.fd = out_fd;
            o.fd2 = in_fd;
            o.offset = in_offset;
            o.len = count;
        })
    }
}

/// # Safety
/// As [`oio_nop`].
pub unsafe extern "C" fn oio_fallocate(
    l: *mut oio_loop,
    op: *mut oio_op,
    fd: oio_fd,
    offset: i64,
    len: usize,
    flags: u64,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_FALLOCATE;
            o.fd = fd;
            o.offset = offset;
            o.len = len;
            o.aux = flags;
        })
    }
}

/// # Safety
/// As [`oio_nop`]; `buf..buf+len` must stay valid (and writable) until the callback.
pub unsafe extern "C" fn oio_readdir(
    l: *mut oio_loop,
    op: *mut oio_op,
    dirfd: oio_fd,
    buf: *mut c_void,
    len: usize,
    cookie: u64,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_READDIR;
            o.fd = dirfd;
            o.buf = buf;
            o.len = len;
            o.aux = cookie;
        })
    }
}

/// # Safety
/// As [`oio_nop`].
pub unsafe extern "C" fn oio_ftruncate(l: *mut oio_loop, op: *mut oio_op, fd: oio_fd, len: u64, cb: oio_cb) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_FTRUNCATE;
            o.fd = fd;
            o.aux = len;
        })
    }
}

/// # Safety
/// As [`oio_nop`]; `buf..buf+len` must stay valid until the callback. Sockets are not modelled:
/// the op completes with `-ENOSYS`.
pub unsafe extern "C" fn oio_send(
    l: *mut oio_loop,
    op: *mut oio_op,
    fd: oio_fd,
    buf: *const c_void,
    len: usize,
    msg_flags: u32,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_SEND;
            o.fd = fd;
            o.buf = buf.cast_mut();
            o.len = len;
            o.aux = u64::from(msg_flags);
        })
    }
}

/// # Safety
/// As [`oio_send`], with writable memory.
pub unsafe extern "C" fn oio_recv(
    l: *mut oio_loop,
    op: *mut oio_op,
    fd: oio_fd,
    buf: *mut c_void,
    len: usize,
    msg_flags: u32,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_RECV;
            o.fd = fd;
            o.buf = buf;
            o.len = len;
            o.aux = u64::from(msg_flags);
        })
    }
}

/// # Safety
/// As [`oio_send`]; `msghdr` must stay valid until the callback.
pub unsafe extern "C" fn oio_sendmsg(
    l: *mut oio_loop,
    op: *mut oio_op,
    fd: oio_fd,
    msghdr: *mut c_void,
    msg_flags: u32,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_SENDMSG;
            o.fd = fd;
            o.buf = msghdr;
            o.aux = u64::from(msg_flags);
        })
    }
}

/// # Safety
/// As [`oio_sendmsg`].
pub unsafe extern "C" fn oio_recvmsg(
    l: *mut oio_loop,
    op: *mut oio_op,
    fd: oio_fd,
    msghdr: *mut c_void,
    msg_flags: u32,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_RECVMSG;
            o.fd = fd;
            o.buf = msghdr;
            o.aux = u64::from(msg_flags);
        })
    }
}

/// # Safety
/// As [`oio_nop`]; `addr` must point to a live `u32` until the callback.
pub unsafe extern "C" fn oio_futex_wait(
    l: *mut oio_loop,
    op: *mut oio_op,
    addr: *const u32,
    expected: u32,
    timeout_ns: i64,
    cb: oio_cb,
) -> c_int {
    // SAFETY: `addr` is a live, aligned `u32` per the contract; accessed atomically only.
    let cur = unsafe { AtomicU32::from_ptr(addr.cast_mut()) }.load(Ordering::SeqCst);
    let sched = if cur != expected {
        Sched::Done(-EAGAIN)
    } else {
        let deadline = u64::try_from(timeout_ns).ok().map(|ns| Instant::now() + Duration::from_nanos(ns));
        Sched::Futex(addr, deadline)
    };
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, sched, |o| {
            o.kind = sys::OIO_FUTEX_WAIT;
            o.buf = addr.cast_mut().cast::<c_void>();
            o.aux = u64::from(expected);
        })
    }
}

/// # Safety
/// As [`oio_futex_wait`].
pub unsafe extern "C" fn oio_futex_wake(l: *mut oio_loop, op: *mut oio_op, addr: *const u32, count: u32, cb: oio_cb) -> c_int {
    // SAFETY: live loop per the contract.
    let woken = unsafe { lp(l) }.wake_futex(addr, count);
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Done(woken), |o| {
            o.kind = sys::OIO_FUTEX_WAKE;
            o.buf = addr.cast_mut().cast::<c_void>();
            o.aux = u64::from(count);
        })
    }
}

/// # Safety
/// As [`oio_send`]; `sockaddr..+addr_len` must stay valid until the callback.
pub unsafe extern "C" fn oio_connect(
    l: *mut oio_loop,
    op: *mut oio_op,
    fd: oio_fd,
    sockaddr: *const c_void,
    addr_len: usize,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_CONNECT;
            o.fd = fd;
            o.buf = sockaddr.cast_mut();
            o.len = addr_len;
        })
    }
}

/// # Safety
/// As [`oio_recv`]: `addr..+addr_cap` must be writable until the callback (may be null).
pub unsafe extern "C" fn oio_accept(
    l: *mut oio_loop,
    op: *mut oio_op,
    fd: oio_fd,
    addr: *mut c_void,
    addr_cap: usize,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_ACCEPT;
            o.fd = fd;
            o.buf = addr;
            o.len = addr_cap;
        })
    }
}

/// # Safety
/// As [`oio_nop`]; `iov..+iov_count` and every buffer it describes must stay valid (and, for
/// reads, exclusively lent) until the callback.
pub unsafe extern "C" fn oio_readv(
    l: *mut oio_loop,
    op: *mut oio_op,
    fd: oio_fd,
    iov: *const sys::oio_iovec,
    iov_count: usize,
    offset: i64,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_READV;
            o.fd = fd;
            o.buf = iov.cast_mut().cast::<c_void>();
            o.len = iov_count;
            o.offset = offset;
        })
    }
}

/// # Safety
/// As [`oio_readv`].
pub unsafe extern "C" fn oio_writev(
    l: *mut oio_loop,
    op: *mut oio_op,
    fd: oio_fd,
    iov: *const sys::oio_iovec,
    iov_count: usize,
    offset: i64,
    cb: oio_cb,
) -> c_int {
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::Now, |o| {
            o.kind = sys::OIO_WRITEV;
            o.fd = fd;
            o.buf = iov.cast_mut().cast::<c_void>();
            o.len = iov_count;
            o.offset = offset;
        })
    }
}

/// # Safety
/// As [`oio_nop`].
pub unsafe extern "C" fn oio_timeout(l: *mut oio_loop, op: *mut oio_op, ns: u64, cb: oio_cb) -> c_int {
    let deadline = Instant::now() + Duration::from_nanos(ns);
    // SAFETY: forwarded contract.
    unsafe {
        submit(l, op, cb, Sched::At(deadline), |o| {
            o.kind = sys::OIO_TIMEOUT;
            o.aux = ns;
        })
    }
}

/// # Safety
/// `l` live (loop thread); `op` an op previously submitted to it, still alive.
pub unsafe extern "C" fn oio_cancel(l: *mut oio_loop, op: *mut oio_op) -> c_int {
    // SAFETY: live loop per the contract.
    unsafe { lp(l) }.cancel(op)
}

/// Compile-time check that every fake has the exact signature of the extern declaration
/// generated from the header: the array only type-checks when both fn items coerce to one fn
/// pointer type.
macro_rules! check_signatures {
    ($($f:ident),* $(,)?) => {
        #[allow(dead_code)]
        fn signatures_match_the_header() {
            $( let _ = [sys::generated::$f, $f]; )*
        }
    };
}
for_each_oio_fn!(check_signatures);
