//! Async, `std::fs` / `tokio::fs`-shaped file system access on the [`Loop`], designed for
//! capability-style sandboxing: **there is no ambient current directory**. Every path is
//! resolved against a [`Dir`] handle (`openat` and friends) and is validated by [`sanitize`]
//! first: NUL bytes, absolute paths and `..` components are rejected with
//! [`io::ErrorKind::InvalidInput`]. (Only [`Dir::open_ambient`] takes an arbitrary path, to
//! obtain the root capability.) The check is lexical: symlinks inside a `Dir` that point
//! outside of it are still followed by the OS.
//!
//! No call blocks and no thread is spawned: every `.await` is a loop op. Errors are plain
//! [`io::Error`]s; match on [`io::ErrorKind`] (`AlreadyExists`, `NotFound`, `DirectoryNotEmpty`,
//! ...), never on errno numbers.
//!
//! # Owned buffers
//! [`File`] reads and writes take a buffer by value and hand it back together with the
//! result (`(io::Result<usize>, B)`, see [`BufResult`]). The buffer is any [`IoBuf`] /
//! [`IoBufMut`]: usually a `Vec<u8>`, but also a `Box<[u8]>` or a [`crate::RawRegion`] over
//! caller-pinned memory (a V8 backing store). The loop completes ops
//! asynchronously, possibly after the future that started them was dropped, so the memory an op
//! reads or writes must stay at a stable address until the completion callback ran. A borrowed
//! `&mut [u8]` cannot promise that (it could be freed on cancellation); an owned buffer can,
//! because the op keeps it alive. `read` fills the buffer's existing `len()` bytes, so pass
//! `vec![0; n]`; the first `n` returned bytes (the result) are the data.
//!
//! # Concurrency
//! Everything here is `!Send` (handles share an `Rc`) and meant for tasks on the single-threaded
//! [`crate::rt::Runtime`]. Run independent operations concurrently by spawning tasks, a
//! [`crate::rt::JoinSet`] or [`crate::rt::join`]. [`Dir::remove_dir_all`] fans out with
//! `JoinSet::bounded(16)` per directory level, so it must run inside the runtime
//! (`Runtime::block_on` or a spawned task).
//!
//! # Closing
//! Close explicitly with [`Dir::close`] / [`File::close`] to observe errors. A handle that is
//! simply dropped (last clone for a `Dir`) submits a *detached* close op: its memory is kept
//! alive until the completion callback, nothing is cancelled and nothing blocks. If the loop is
//! destroyed first, its destroy runs the callback.
//!
//! Dropping a future that is waiting on a loop op cancels the op (see the crate docs). A
//! cancelled *close* may leak the descriptor; a [`ReadDir::next_entry`] dropped mid-refill may
//! skip entries.

mod at;
mod path;

pub use path::sanitize;

use crate::rt::JoinSet;
use crate::{BufResult, Fd, FileKind, IoBuf, IoBufMut, Loop, Stat, flags};
use std::cell::Cell;
use std::collections::VecDeque;
use std::ffi::OsString;
use std::future::Future;
use std::io;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::rc::Rc;

/// Descriptor value meaning "already closed / handed off".
const CLOSED: Fd = Fd::MIN;
/// `EBADF` on Linux and macOS.
const EBADF: i32 = 9;
const COPY_CHUNK: usize = 64 * 1024;
const READ_CHUNK: usize = 32 * 1024;
const READDIR_BUF: usize = 8192;
const REMOVE_CONCURRENCY: usize = 16;

type LocalBoxFuture<T> = Pin<Box<dyn Future<Output = T>>>;

fn closed_error() -> io::Error {
    io::Error::from_raw_os_error(EBADF)
}

// ---------------------------------------------------------------------------------------------
// Types

/// The kind of a file system entry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FileType {
    kind: FileKind,
}

impl FileType {
    pub fn is_file(&self) -> bool {
        self.kind == FileKind::File
    }
    pub fn is_dir(&self) -> bool {
        self.kind == FileKind::Directory
    }
    pub fn is_symlink(&self) -> bool {
        self.kind == FileKind::Symlink
    }
    /// Anything that is not a regular file, directory or symlink (or whose kind is unknown).
    pub fn is_other(&self) -> bool {
        self.kind == FileKind::Other
    }
}

/// File metadata, like [`std::fs::Metadata`] (the fields the loop reports).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Metadata {
    len: u64,
    file_type: FileType,
    mode: u32,
}

impl Metadata {
    fn new(s: Stat) -> Metadata {
        Metadata { len: s.size, file_type: FileType { kind: s.kind }, mode: s.mode }
    }
    pub fn len(&self) -> u64 {
        self.len
    }
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }
    pub fn file_type(&self) -> FileType {
        self.file_type
    }
    pub fn is_file(&self) -> bool {
        self.file_type.is_file()
    }
    pub fn is_dir(&self) -> bool {
        self.file_type.is_dir()
    }
    pub fn is_symlink(&self) -> bool {
        self.file_type.is_symlink()
    }
    /// Unix mode bits (`st_mode`, permissions in the low 12 bits).
    pub fn mode(&self) -> u32 {
        self.mode
    }
    /// Just the permission bits (`mode & 0o7777`).
    pub fn permissions_mode(&self) -> u32 {
        self.mode & 0o7777
    }
}

/// Options for [`Dir::open_file`], like [`std::fs::OpenOptions`].
#[derive(Clone, Debug)]
pub struct OpenOptions {
    read: bool,
    write: bool,
    append: bool,
    truncate: bool,
    create: bool,
    create_new: bool,
    mode: u32,
}

impl Default for OpenOptions {
    fn default() -> Self {
        Self::new()
    }
}

impl OpenOptions {
    pub fn new() -> OpenOptions {
        OpenOptions { read: false, write: false, append: false, truncate: false, create: false, create_new: false, mode: 0o666 }
    }
    pub fn read(&mut self, v: bool) -> &mut Self {
        self.read = v;
        self
    }
    pub fn write(&mut self, v: bool) -> &mut Self {
        self.write = v;
        self
    }
    pub fn append(&mut self, v: bool) -> &mut Self {
        self.append = v;
        self
    }
    pub fn truncate(&mut self, v: bool) -> &mut Self {
        self.truncate = v;
        self
    }
    pub fn create(&mut self, v: bool) -> &mut Self {
        self.create = v;
        self
    }
    /// Fail with `AlreadyExists` if the file exists (implies `create`).
    pub fn create_new(&mut self, v: bool) -> &mut Self {
        self.create_new = v;
        self
    }
    /// Permission bits for a newly created file (default `0o666`, before the umask).
    pub fn mode(&mut self, mode: u32) -> &mut Self {
        self.mode = mode;
        self
    }

    /// Map to the C ABI open flags, with the same validity rules as `std`.
    fn flags(&self) -> io::Result<u64> {
        let write = self.write || self.append;
        let access = match (self.read, write) {
            (true, false) => flags::RDONLY,
            (false, true) => flags::WRONLY,
            (true, true) => flags::RDWR,
            (false, false) => return Err(io::Error::new(io::ErrorKind::InvalidInput, "open needs read, write or append access")),
        };
        if !write && (self.create || self.create_new || self.truncate) {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "create/truncate need write or append access"));
        }
        if self.append && self.truncate && !self.create_new {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "append and truncate are mutually exclusive"));
        }
        let mut f = access;
        if self.append {
            f |= flags::APPEND;
        }
        if self.create || self.create_new {
            f |= flags::CREAT;
        }
        if self.create_new {
            f |= flags::EXCL;
        }
        if self.truncate {
            f |= flags::TRUNC;
        }
        Ok(f)
    }
}

/// An owned descriptor; drop submits a detached close.
struct Owned {
    lp: Loop,
    fd: Cell<Fd>,
}

impl Owned {
    fn new(lp: &Loop, fd: Fd) -> Owned {
        Owned { lp: lp.clone(), fd: Cell::new(fd) }
    }
    fn get(&self) -> io::Result<Fd> {
        match self.fd.get() {
            CLOSED => Err(closed_error()),
            fd => Ok(fd),
        }
    }
    async fn close(&self) -> io::Result<()> {
        match self.fd.replace(CLOSED) {
            CLOSED => Err(closed_error()),
            fd => self.lp.close(fd).await,
        }
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        let fd = self.fd.replace(CLOSED);
        if fd != CLOSED {
            self.lp.close_detached(fd);
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Dir

/// A directory capability: every operation is relative to it. Cheap to clone (all clones share
/// one descriptor, closed when the last clone is dropped or by [`Dir::close`]).
#[derive(Clone)]
pub struct Dir {
    h: Rc<Owned>,
}

impl std::fmt::Debug for Dir {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Dir").field("fd", &self.h.fd.get()).finish()
    }
}

impl Dir {
    /// Take ownership of an already open directory descriptor.
    pub fn from_fd(lp: &Loop, fd: Fd) -> Dir {
        Dir { h: Rc::new(Owned::new(lp, fd)) }
    }

    /// Open a directory by an ambient (cwd-relative or absolute) path, *without* the path
    /// checks of the other methods: this is how the root capability is obtained. Hand out
    /// sub-`Dir`s from here, never this function.
    pub async fn open_ambient(lp: &Loop, path: impl AsRef<Path>) -> io::Result<Dir> {
        let fd = lp.open(path, flags::RDONLY | flags::DIRECTORY, 0).await?;
        Ok(Dir::from_fd(lp, fd))
    }

    /// The raw descriptor, or `None` after `close`. The `Dir` keeps ownership.
    pub fn raw_fd(&self) -> Option<Fd> {
        self.h.get().ok()
    }

    /// The loop this directory's ops run on.
    pub fn event_loop(&self) -> &Loop {
        &self.h.lp
    }

    /// Close the descriptor for all clones; later operations fail (`EBADF`). Closing twice is an
    /// error.
    pub async fn close(&self) -> io::Result<()> {
        self.h.close().await
    }

    fn lp(&self) -> &Loop {
        &self.h.lp
    }

    pub async fn open_dir(&self, path: impl AsRef<Path>) -> io::Result<Dir> {
        let path = sanitize(path.as_ref())?;
        let fd = self.lp().open_at(self.h.get()?, path, flags::RDONLY | flags::DIRECTORY, 0).await?;
        Ok(Dir::from_fd(self.lp(), fd))
    }

    pub async fn open_file(&self, path: impl AsRef<Path>, opts: &OpenOptions) -> io::Result<File> {
        let path = sanitize(path.as_ref())?;
        let flags = opts.flags()?;
        let fd = self.lp().open_at(self.h.get()?, path, flags, opts.mode).await?;
        Ok(File { h: Owned::new(self.lp(), fd) })
    }

    pub async fn create_dir(&self, path: impl AsRef<Path>) -> io::Result<()> {
        let path = sanitize(path.as_ref())?;
        self.lp().mkdir_at(self.h.get()?, path, 0o777).await
    }

    /// Create `path` and all missing parents; succeeds if it already is a directory. Safe to run
    /// concurrently with itself.
    pub async fn create_dir_all(&self, path: impl AsRef<Path>) -> io::Result<()> {
        let path = sanitize(path.as_ref())?;
        let mut prefix = PathBuf::new();
        let mut parts = path.components().filter(|c| !matches!(c, std::path::Component::CurDir)).peekable();
        while let Some(part) = parts.next() {
            prefix.push(part);
            match self.create_dir(&prefix).await {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                    // An existing *file* is only an error for the last component (for the others
                    // the next mkdir reports `NotADirectory`).
                    if parts.peek().is_none() && !self.metadata(&prefix).await?.is_dir() {
                        return Err(e);
                    }
                }
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }

    /// Unlink a file or symlink (not a directory).
    pub async fn remove_file(&self, path: impl AsRef<Path>) -> io::Result<()> {
        let path = sanitize(path.as_ref())?;
        self.lp().unlink_at(self.h.get()?, path, false).await
    }

    /// Remove an empty directory.
    pub async fn remove_dir(&self, path: impl AsRef<Path>) -> io::Result<()> {
        let path = sanitize(path.as_ref())?;
        self.lp().unlink_at(self.h.get()?, path, true).await
    }

    /// Remove a directory and everything below it. Symlinks are unlinked, never followed. The
    /// entries of each directory are removed concurrently (at most 16 at a time per level).
    /// Needs a running [`crate::rt::Runtime`] (it uses a bounded `JoinSet`). The first error
    /// aborts the remaining work and is returned.
    pub async fn remove_dir_all(&self, path: impl AsRef<Path>) -> io::Result<()> {
        let path = sanitize(path.as_ref())?.to_path_buf();
        remove_tree(self.clone(), path).await
    }

    /// Rename `from` (relative to `self`) to `to` (relative to `to_dir`, which may be `self`).
    pub async fn rename(&self, from: impl AsRef<Path>, to_dir: &Dir, to: impl AsRef<Path>) -> io::Result<()> {
        let from = sanitize(from.as_ref())?;
        let to = sanitize(to.as_ref())?;
        self.lp().rename_at(self.h.get()?, from, to_dir.h.get()?, to).await
    }

    /// Metadata, following a final symlink.
    pub async fn metadata(&self, path: impl AsRef<Path>) -> io::Result<Metadata> {
        let path = sanitize(path.as_ref())?;
        self.lp().stat_at_dir(self.h.get()?, path, false).await.map(Metadata::new)
    }

    /// Metadata of the entry itself (does not follow a final symlink).
    pub async fn symlink_metadata(&self, path: impl AsRef<Path>) -> io::Result<Metadata> {
        let path = sanitize(path.as_ref())?;
        self.lp().stat_at_dir(self.h.get()?, path, true).await.map(Metadata::new)
    }

    /// `Ok(false)` only for `NotFound`; other errors (permissions, invalid path) are returned.
    pub async fn try_exists(&self, path: impl AsRef<Path>) -> io::Result<bool> {
        match self.metadata(path).await {
            Ok(_) => Ok(true),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e),
        }
    }

    /// List a directory (without `.` and `..`, in OS order).
    pub async fn read_dir(&self, path: impl AsRef<Path>) -> io::Result<ReadDir> {
        let dir = self.open_dir(path).await?;
        Ok(ReadDir { dir, storage: None, cookie: 0, entries: VecDeque::new(), done: false })
    }

    /// Read a whole file.
    pub async fn read(&self, path: impl AsRef<Path>) -> io::Result<Vec<u8>> {
        let file = self.open_file(path, OpenOptions::new().read(true)).await?;
        let r = async {
            let hint = file.metadata().await.map_or(0, |m| usize::try_from(m.len()).unwrap_or(0));
            file.read_to_end_hint(usize::MAX, hint).await
        }
        .await;
        let c = file.close().await;
        let data = r?;
        c?;
        Ok(data)
    }

    /// Create or truncate a file and write `contents` to it.
    pub async fn write(&self, path: impl AsRef<Path>, contents: impl Into<Vec<u8>>) -> io::Result<()> {
        let file = self.open_file(path, OpenOptions::new().write(true).create(true).truncate(true)).await?;
        let (r, _) = file.write_all(contents.into()).await;
        let c = file.close().await;
        r?;
        c
    }

    /// Copy a file within this directory; returns the bytes copied.
    pub async fn copy(&self, from: impl AsRef<Path>, to: impl AsRef<Path>) -> io::Result<u64> {
        self.copy_to(from, self, to).await
    }

    /// Copy `from` (relative to `self`) to `to` (relative to `to_dir`). A new file gets the
    /// source's permission bits; an existing destination is truncated.
    pub async fn copy_to(&self, from: impl AsRef<Path>, to_dir: &Dir, to: impl AsRef<Path>) -> io::Result<u64> {
        let (from, to) = (sanitize(from.as_ref())?, sanitize(to.as_ref())?);
        let src = self.open_file(from, OpenOptions::new().read(true)).await?;
        let r: io::Result<u64> = async {
            let meta = src.metadata().await?;
            let dst =
                to_dir.open_file(to, OpenOptions::new().write(true).create(true).truncate(true).mode(meta.permissions_mode())).await?;
            let r = copy_loop(&src, &dst).await;
            let c = dst.close().await;
            let n = r?;
            c?;
            Ok(n)
        }
        .await;
        let c = src.close().await;
        let n = r?;
        c?;
        Ok(n)
    }
}

async fn copy_loop(src: &File, dst: &File) -> io::Result<u64> {
    let mut buf = vec![0; COPY_CHUNK];
    let mut total = 0u64;
    loop {
        let (r, mut b) = src.read(buf).await;
        let n = r?;
        if n == 0 {
            return Ok(total);
        }
        b.truncate(n);
        let (r, mut b) = dst.write_all(b).await;
        r?;
        b.resize(COPY_CHUNK, 0);
        buf = b;
        total += n as u64;
    }
}

fn remove_children(dir: Dir) -> LocalBoxFuture<io::Result<()>> {
    Box::pin(async move {
        // List first, delete afterwards: unlinking while paging through a directory may make
        // the OS skip entries.
        let mut entries = Vec::new();
        let mut rd = dir.read_dir(".").await?;
        while let Some(e) = rd.next_entry().await? {
            entries.push((e.file_name(), e.file_type()));
        }
        drop(rd);
        let mut set = JoinSet::bounded(REMOVE_CONCURRENCY);
        for (name, ty) in entries {
            let dir = dir.clone();
            set.spawn(async move { if ty.is_dir() { remove_tree(dir, PathBuf::from(name)).await } else { dir.remove_file(name).await } });
        }
        while let Some(r) = set.join_next().await {
            let err = match r {
                Ok(Ok(())) => continue,
                Ok(Err(e)) => e,
                Err(e) => io::Error::other(format!("remove_dir_all task failed: {e:?}")),
            };
            set.abort_all();
            return Err(err);
        }
        Ok(())
    })
}

fn remove_tree(parent: Dir, name: PathBuf) -> LocalBoxFuture<io::Result<()>> {
    Box::pin(async move {
        let sub = parent.open_dir(&name).await?;
        let r = remove_children(sub.clone()).await;
        let c = sub.close().await;
        r?;
        c?;
        parent.remove_dir(&name).await
    })
}

// ---------------------------------------------------------------------------------------------
// ReadDir

/// One entry of a [`ReadDir`]. The kind comes with the listing: no extra `stat`.
#[derive(Clone, Debug)]
pub struct DirEntry {
    name: Vec<u8>,
    file_type: FileType,
}

impl DirEntry {
    /// The entry's name (a single path component).
    pub fn file_name(&self) -> OsString {
        #[cfg(unix)]
        {
            std::os::unix::ffi::OsStringExt::from_vec(self.name.clone())
        }
        #[cfg(not(unix))]
        {
            OsString::from(String::from_utf8_lossy(&self.name).into_owned())
        }
    }
    /// The raw name bytes (not necessarily UTF-8).
    pub fn file_name_bytes(&self) -> &[u8] {
        &self.name
    }
    /// Kind as reported by the directory listing; `is_other()` when the file system did not say.
    pub fn file_type(&self) -> FileType {
        self.file_type
    }
}

/// Async directory iterator; owns its own descriptor (closed on drop, detached).
pub struct ReadDir {
    dir: Dir,
    storage: Option<Vec<u8>>,
    cookie: u64,
    entries: VecDeque<DirEntry>,
    done: bool,
}

impl ReadDir {
    /// The next entry, `None` at the end. Refills from the loop's `readdir` op when the
    /// current batch is used up.
    pub async fn next_entry(&mut self) -> io::Result<Option<DirEntry>> {
        loop {
            if let Some(e) = self.entries.pop_front() {
                return Ok(Some(e));
            }
            if self.done {
                return Ok(None);
            }
            let buf = self.storage.take().unwrap_or_else(|| vec![0; READDIR_BUF]);
            let r = self.dir.lp().readdir(self.dir.h.get()?, buf, self.cookie).await;
            self.storage = Some(r.buf);
            let n = r.result?;
            if n == 0 {
                self.done = true;
                return Ok(None);
            }
            self.cookie = r.cookie;
            let storage = self.storage.as_deref().unwrap_or_default();
            for raw in crate::parse_dir_entries(&storage[..n.min(storage.len())]) {
                self.entries.push_back(DirEntry { name: raw.name.to_vec(), file_type: FileType { kind: raw.kind } });
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// File

/// An open file. Not `Clone`; reads and writes use owned buffers (see the module docs).
/// Operations without an explicit offset use (and move) the descriptor's file position.
pub struct File {
    h: Owned,
}

impl std::fmt::Debug for File {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("File").field("fd", &self.h.fd.get()).finish()
    }
}

impl File {
    /// Take ownership of an open file descriptor.
    pub fn from_fd(lp: &Loop, fd: Fd) -> File {
        File { h: Owned::new(lp, fd) }
    }

    pub fn raw_fd(&self) -> Option<Fd> {
        self.h.get().ok()
    }

    /// Close explicitly to observe the error; a plain drop closes detached.
    pub async fn close(&self) -> io::Result<()> {
        self.h.close().await
    }

    /// Read into `buf` (its whole window: `bytes_total()` bytes, for a `Vec<u8>` its `len()`).
    /// Returns the byte count (0 = EOF) and the buffer back, with [`IoBufMut::set_init`] applied
    /// for the bytes that were read.
    pub async fn read<B: IoBufMut>(&self, buf: B) -> BufResult<usize, B> {
        match self.h.get() {
            Ok(fd) => self.h.lp.read(fd, buf, None).await,
            Err(e) => (Err(e), buf),
        }
    }

    /// Like [`File::read`] at `offset`, without using the file position.
    pub async fn read_at<B: IoBufMut>(&self, buf: B, offset: u64) -> BufResult<usize, B> {
        match self.h.get() {
            Ok(fd) => self.h.lp.read(fd, buf, Some(offset)).await,
            Err(e) => (Err(e), buf),
        }
    }

    /// Write `buf`'s initialized bytes once; may write less than all of it. Returns the count
    /// and the buffer back.
    pub async fn write<B: IoBuf>(&self, buf: B) -> BufResult<usize, B> {
        match self.h.get() {
            Ok(fd) => self.h.lp.write(fd, buf, None).await,
            Err(e) => (Err(e), buf),
        }
    }

    pub async fn write_at<B: IoBuf>(&self, buf: B, offset: u64) -> BufResult<usize, B> {
        match self.h.get() {
            Ok(fd) => self.h.lp.write(fd, buf, Some(offset)).await,
            Err(e) => (Err(e), buf),
        }
    }

    /// Write all of `buf`'s initialized bytes, looping over partial writes (each retry writes the
    /// not yet written tail of the same buffer, no copy). The buffer is always returned
    /// **unchanged**, on success and on error alike.
    pub async fn write_all<B: IoBuf>(&self, buf: B) -> BufResult<(), B> {
        self.write_all_impl(buf, None).await
    }

    /// [`File::write_all`] at `offset` (the file position is not used).
    pub async fn write_all_at<B: IoBuf>(&self, buf: B, offset: u64) -> BufResult<(), B> {
        self.write_all_impl(buf, Some(offset)).await
    }

    async fn write_all_impl<B: IoBuf>(&self, mut buf: B, mut offset: Option<u64>) -> BufResult<(), B> {
        let fd = match self.h.get() {
            Ok(fd) => fd,
            Err(e) => return (Err(e), buf),
        };
        let total = buf.bytes_init();
        let mut done = 0;
        while done < total {
            let (r, b) = self.h.lp.write_range(fd, buf, done, offset).await;
            buf = b;
            match r {
                Ok(0) => return (Err(io::ErrorKind::WriteZero.into()), buf),
                Ok(n) => {
                    let n = n.min(total - done);
                    done += n;
                    if let Some(o) = &mut offset {
                        *o += n as u64;
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) => return (Err(e), buf),
            }
        }
        (Ok(()), buf)
    }

    /// Read from the current position to EOF. Fails with [`io::ErrorKind::FileTooLarge`] when
    /// more than `limit` bytes are available.
    pub async fn read_to_end(&self, limit: usize) -> io::Result<Vec<u8>> {
        self.read_to_end_hint(limit, 0).await
    }

    async fn read_to_end_hint(&self, limit: usize, hint: usize) -> io::Result<Vec<u8>> {
        let mut out = Vec::with_capacity(hint.min(limit).min(1 << 30));
        let mut buf = vec![0; READ_CHUNK];
        loop {
            // Ask for at most one byte beyond the limit, so "exactly limit" still succeeds.
            let remaining = limit - out.len();
            buf.resize(READ_CHUNK.min(remaining.saturating_add(1)), 0);
            let (r, b) = self.read(buf).await;
            buf = b;
            match r {
                Ok(0) => return Ok(out),
                Ok(n) => {
                    if n > remaining {
                        return Err(io::Error::new(io::ErrorKind::FileTooLarge, "file exceeds the read limit"));
                    }
                    out.extend_from_slice(&buf[..n]);
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) => return Err(e),
            }
        }
    }

    /// Truncate or extend to exactly `len` bytes.
    pub async fn set_len(&self, len: u64) -> io::Result<()> {
        self.h.lp.ftruncate(self.h.get()?, len).await
    }

    /// Flush data and metadata to disk.
    pub async fn sync_all(&self) -> io::Result<()> {
        self.h.lp.fsync(self.h.get()?, false).await
    }

    /// Flush data (not necessarily metadata) to disk.
    pub async fn sync_data(&self) -> io::Result<()> {
        self.h.lp.fsync(self.h.get()?, true).await
    }

    pub async fn metadata(&self) -> io::Result<Metadata> {
        self.h.lp.fstat(self.h.get()?).await.map(Metadata::new)
    }
}
