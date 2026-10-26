//! The async fs behind `native.fsAsync.*`: a [`Grant`] is a capability-rooted directory plus the
//! handle tables of the files and directories opened through it. The operations mirror the sync
//! natives of `src/api/fs.zig` (same arguments, same results, same errors), but run on the
//! `origine_io` runtime: each returns a future that owns everything it needs, so it can be spawned
//! and outlive the call.
//!
//! This crate has no V8 dependency; `origine_api` binds the operations to JS promises.
//!
//! # Handles
//! A directory or file handle is an id in the grant's table (`{fs, id}` on the JS side; the caller
//! finds the grant by `fs`). Directory id 0 names the grant root. An operation takes a
//! [`Guard`] on its handles when it is *started* (synchronously, so a `close` issued right after
//! sees it): while any guard lives `close` waits, and the id is not reused. New operations on a
//! closing handle fail with `StaleHandle`, on a closed or unknown one with `BadHandle`.
//!
//! # Order of checks
//! Like Zig: paths are validated first (`InvalidInput`, `PermissionDenied`), then the grant's access
//! (`PermissionDenied`), then the handles (`BadHandle`/`StaleHandle`), then the OS.

use std::cell::RefCell;
use std::future::Future;
use std::ops::Deref;
use std::path::Path;
use std::rc::Rc;

use origine_api_core::table::{Guard, Table};
use origine_api_core::{NativeError, errno};
use origine_io::fs::{Dir, File, FileType, OpenOptions, sanitize};
use origine_io::{IoBuf, IoBufMut};

/// Largest file `read_all` returns, regardless of the requested limit.
pub const MAX_READ_BYTES: usize = 256 << 20;
/// Largest integer a JS number holds exactly (2^53 - 1).
const MAX_EXACT: u64 = (1 << 53) - 1;
const READ_CHUNK: usize = 64 * 1024;

/// `[kind, size]` of `stat` / `fileStat`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Stat {
    /// 1 file, 2 directory, 3 symlink, 4 other.
    pub kind: u32,
    pub size: f64,
}

/// `[name0, kind0, name1, kind1, ...]` of `readDir`, as pairs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DirListing(pub Vec<(String, u32)>);

/// The kind code the guest sees (`kindCode` in `src/api/fs.zig`).
pub fn kind_code(kind: FileType) -> u32 {
    if kind.is_file() {
        1
    } else if kind.is_dir() {
        2
    } else if kind.is_symlink() {
        3
    } else {
        4
    }
}

fn invalid_input() -> NativeError {
    NativeError::Errno(errno::INVALID_INPUT)
}

fn denied() -> NativeError {
    NativeError::Errno(errno::PERMISSION_DENIED)
}

/// The engine's snapshot / code-cache directory (`init_cache.dir_name` in Zig): V8 trusts what it
/// finds there, so a guest must not be able to plant it.
const CACHE_DIR: &str = "__oricache__";

/// Rejects NUL (`InvalidInput`: a malformed path) and, as policy denials (`PermissionDenied`, like
/// the OS's own), absolute paths, `..` components and `__oricache__` components. Lexical only:
/// symlinks are not resolved here, so following one can leave the grant's root. The Zig twin is
/// `cleanPath` in `src/api/fs.zig`.
fn clean(path: &str) -> Result<(), NativeError> {
    if path.contains('\0') {
        return Err(invalid_input());
    }
    if path.starts_with('/') || path.split('/').any(|part| part == ".." || part == CACHE_DIR) {
        return Err(denied());
    }
    // The rest of `sanitize` (non-Unix prefixes) is a policy denial too.
    sanitize(Path::new(path)).map(|_| ()).map_err(|_| denied())
}

/// Validates the `root` of a grant request like any other path (lexical policy, see `clean`).
pub fn check_root(root: &str) -> Result<(), NativeError> {
    clean(root)
}

/// True when `path` names the grant root itself (empty or only `.` components).
fn names_root(path: &str) -> bool {
    path.split('/').all(|part| part.is_empty() || part == ".")
}

/// A path that may be empty (the directory itself).
fn any_path(path: &str) -> Result<String, NativeError> {
    clean(path)?;
    Ok(path.to_owned())
}

/// A path that must name an entry: non-empty after cleaning (`.` alone is allowed).
fn entry_path(path: &str) -> Result<String, NativeError> {
    clean(path)?;
    if path.is_empty() {
        return Err(invalid_input());
    }
    Ok(path.to_owned())
}

/// A path that must not name the grant root, for operations that could destroy it.
fn sub_path(path: &str) -> Result<String, NativeError> {
    clean(path)?;
    if names_root(path) {
        return Err(invalid_input());
    }
    Ok(path.to_owned())
}

/// Converts a size to the f64 JS sees, failing with `FileTooLarge` instead of rounding.
fn exact_size(size: u64) -> Result<f64, NativeError> {
    if size > MAX_EXACT { Err(NativeError::Errno(errno::FILE_TOO_LARGE)) } else { Ok(size as f64) }
}

/// A directory an operation works on: the grant root, or a guarded table entry.
pub enum DirHandle {
    Root(Dir),
    Entry(Guard<Dir>),
}

impl Deref for DirHandle {
    type Target = Dir;

    fn deref(&self) -> &Dir {
        match self {
            DirHandle::Root(dir) => dir,
            DirHandle::Entry(guard) => guard,
        }
    }
}

/// Open bits: 1 write, 2 create, 4 truncate, 8 exclusive (`OPEN_MODES` in `src/js/glue/fs.js`).
/// Like Zig, truncate and exclusive only apply together with create, and a handle that is
/// created is readable too.
fn open_options(bits: u32) -> OpenOptions {
    let mut options = OpenOptions::new();
    if bits & 2 != 0 {
        options.read(true).write(true).create(true).truncate(bits & 4 != 0).create_new(bits & 8 != 0);
    } else {
        options.read(true).write(bits & 1 != 0);
    }
    options
}

/// What a grant may do: `READ`, `WRITE` or both (`access: 'r' | 'w' | 'rw'` in `api.fs`). Native
/// handles are readable whenever they are writable, so a write-only grant is enforced here: it
/// denies (`PermissionDenied`) everything that observes what exists, namely reads, `stat`,
/// `readDir` and opening a file read-only.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Access {
    pub read: bool,
    pub write: bool,
}

impl Access {
    pub const READ: Access = Access { read: true, write: false };
    pub const WRITE: Access = Access { read: false, write: true };
    pub const READ_WRITE: Access = Access { read: true, write: true };

    /// The bits of `native.fsAsync.request`: 1 read, 2 write; `None` for anything else.
    pub fn from_bits(bits: u32) -> Option<Access> {
        match bits {
            1 => Some(Access::READ),
            2 => Some(Access::WRITE),
            3 => Some(Access::READ_WRITE),
            _ => None,
        }
    }
}

/// A capability over one directory. See the crate docs.
pub struct Grant {
    id: u32,
    access: Access,
    root: Dir,
    files: RefCell<Table<File>>,
    dirs: RefCell<Table<Dir>>,
}

impl Grant {
    /// A grant named `id` over `root` with `access`: without write every mutating operation is
    /// rejected, without read every observing one.
    pub fn new(id: u32, access: Access, root: Dir) -> Rc<Grant> {
        Rc::new(Grant { id, access, root, files: RefCell::default(), dirs: RefCell::default() })
    }

    /// The grant's id (`fs` of its handles).
    pub fn id(&self) -> u32 {
        self.id
    }

    /// Whether mutating operations are allowed.
    pub fn is_writable(&self) -> bool {
        self.access.write
    }

    /// Whether observing operations (reads, `stat`, `readDir`) are allowed.
    pub fn is_readable(&self) -> bool {
        self.access.read
    }

    /// Open files plus open (non-root) directories.
    pub fn open_handles(&self) -> usize {
        self.files.borrow().live() + self.dirs.borrow().live()
    }

    /// Fails with `PermissionDenied` on a read-only grant.
    fn writable(&self) -> Result<(), NativeError> {
        if self.access.write { Ok(()) } else { Err(denied()) }
    }

    /// Fails with `PermissionDenied` on a write-only grant.
    fn readable(&self) -> Result<(), NativeError> {
        if self.access.read { Ok(()) } else { Err(denied()) }
    }

    fn dir(&self, id: u32) -> Result<DirHandle, NativeError> {
        if id == 0 {
            return Ok(DirHandle::Root(self.root.clone()));
        }
        let entry = self.dirs.borrow().get(id)?.clone();
        Ok(DirHandle::Entry(entry.begin()?))
    }

    fn file(&self, id: u32) -> Result<Guard<File>, NativeError> {
        let entry = self.files.borrow().get(id)?.clone();
        Ok(entry.begin()?)
    }

    // ---- directories -------------------------------------------------------------------

    /// `openFile(dir, path, bits)`: the new file's id.
    pub fn open_file(
        self: &Rc<Self>,
        dir: u32,
        path: &str,
        bits: u32,
    ) -> Result<impl Future<Output = Result<u32, NativeError>> + use<>, NativeError> {
        let path = entry_path(path)?;
        if bits & 0b1111 != 0 {
            self.writable()?;
        } else {
            self.readable()?;
        }
        let parent = self.dir(dir)?;
        let options = open_options(bits);
        let grant = Rc::clone(self);
        Ok(async move {
            let file = parent.open_file(&path, &options).await?;
            if bits & 0b11 == 0 {
                // Read-only without create: like Zig's `allow_directory = false`, a directory is `IsADirectory`.
                let is_dir = match file.metadata().await {
                    Ok(meta) => meta.is_dir(),
                    Err(err) => {
                        let _ = file.close().await;
                        return Err(err.into());
                    }
                };
                if is_dir {
                    let _ = file.close().await;
                    return Err(NativeError::Errno(errno::IS_A_DIRECTORY));
                }
            }
            Ok(grant.files.borrow_mut().insert(file))
        })
    }

    /// `openDir(dir, path)`: the new directory's id.
    pub fn open_dir(self: &Rc<Self>, dir: u32, path: &str) -> Result<impl Future<Output = Result<u32, NativeError>> + use<>, NativeError> {
        let path = any_path(path)?;
        let parent = self.dir(dir)?;
        let grant = Rc::clone(self);
        Ok(async move {
            let opened = parent.open_dir(if path.is_empty() { "." } else { &path }).await?;
            Ok(grant.dirs.borrow_mut().insert(opened))
        })
    }

    /// `stat(dir, path)`: `std::fs::metadata`, a final symlink is followed (a dangling one is
    /// `NotFound`); an empty path is the directory itself.
    pub fn stat(&self, dir: u32, path: &str) -> Result<impl Future<Output = Result<Stat, NativeError>> + use<>, NativeError> {
        self.stat_of(dir, path, true)
    }

    /// `symlinkStat(dir, path)`: `std::fs::symlink_metadata`, the entry itself.
    pub fn symlink_stat(&self, dir: u32, path: &str) -> Result<impl Future<Output = Result<Stat, NativeError>> + use<>, NativeError> {
        self.stat_of(dir, path, false)
    }

    fn stat_of(&self, dir: u32, path: &str, follow: bool) -> Result<impl Future<Output = Result<Stat, NativeError>> + use<>, NativeError> {
        let path = any_path(path)?;
        self.readable()?;
        let parent = self.dir(dir)?;
        Ok(async move {
            let meta = if path.is_empty() {
                parent.metadata(".").await?
            } else if follow {
                parent.metadata(&path).await?
            } else {
                parent.symlink_metadata(&path).await?
            };
            Ok(Stat { kind: kind_code(meta.file_type()), size: exact_size(meta.len())? })
        })
    }

    /// `createDir(dir, path)`.
    pub fn create_dir(&self, dir: u32, path: &str) -> Result<impl Future<Output = Result<(), NativeError>> + use<>, NativeError> {
        let path = entry_path(path)?;
        self.writable()?;
        let parent = self.dir(dir)?;
        Ok(async move { Ok(parent.create_dir(&path).await?) })
    }

    /// `deleteFile(dir, path)`.
    pub fn delete_file(&self, dir: u32, path: &str) -> Result<impl Future<Output = Result<(), NativeError>> + use<>, NativeError> {
        let path = entry_path(path)?;
        self.writable()?;
        let parent = self.dir(dir)?;
        Ok(async move { Ok(parent.remove_file(&path).await?) })
    }

    /// `readDir(dir)`: every entry of the directory (no `.`/`..`), in OS order.
    pub fn read_dir(&self, dir: u32) -> Result<impl Future<Output = Result<DirListing, NativeError>> + use<>, NativeError> {
        self.readable()?;
        let parent = self.dir(dir)?;
        Ok(async move {
            let mut entries = parent.read_dir(".").await?;
            let mut listing = Vec::new();
            while let Some(entry) = entries.next_entry().await? {
                listing.push((String::from_utf8_lossy(entry.file_name_bytes()).into_owned(), kind_code(entry.file_type())));
            }
            Ok(DirListing(listing))
        })
    }

    /// `closeDir(dir)`: waits for the operations on the directory, then closes it. The root stays open.
    pub fn close_dir(&self, dir: u32) -> Result<impl Future<Output = Result<(), NativeError>> + use<>, NativeError> {
        if dir == 0 {
            return Err(NativeError::Errno(errno::BAD_HANDLE)); // the root stays open for the grant's lifetime
        }
        let entry = Rc::clone(self.dirs.borrow().get(dir)?);
        entry.begin_close()?;
        Ok(async move {
            entry.drained().await;
            let closed = entry.value().close().await;
            entry.finish_close();
            Ok(closed?)
        })
    }

    /// `createDirPath(dir, path)`: `mkdir -p`.
    pub fn create_dir_path(&self, dir: u32, path: &str) -> Result<impl Future<Output = Result<(), NativeError>> + use<>, NativeError> {
        let path = sub_path(path)?;
        self.writable()?;
        let parent = self.dir(dir)?;
        Ok(async move { Ok(parent.create_dir_all(&path).await?) })
    }

    /// `deleteDir(dir, path)`: an empty directory.
    pub fn delete_dir(&self, dir: u32, path: &str) -> Result<impl Future<Output = Result<(), NativeError>> + use<>, NativeError> {
        let path = sub_path(path)?;
        self.writable()?;
        let parent = self.dir(dir)?;
        Ok(async move { Ok(parent.remove_dir(&path).await?) })
    }

    /// `deleteTree(dir, path)`: like Zig's `deleteTree`, a missing path is not an error, a file or
    /// symlink is unlinked, and a directory is removed with everything below it.
    pub fn delete_tree(&self, dir: u32, path: &str) -> Result<impl Future<Output = Result<(), NativeError>> + use<>, NativeError> {
        let path = sub_path(path)?;
        self.writable()?;
        let parent = self.dir(dir)?;
        Ok(async move {
            let meta = match parent.symlink_metadata(&path).await {
                Ok(meta) => meta,
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(()),
                Err(err) => return Err(err.into()),
            };
            let removed = if meta.is_dir() { parent.remove_dir_all(&path).await } else { parent.remove_file(&path).await };
            match removed {
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
                other => Ok(other?),
            }
        })
    }

    /// `rename(dir, old, new_dir, new)`.
    pub fn rename(
        &self,
        dir: u32,
        old_path: &str,
        new_dir: u32,
        new_path: &str,
    ) -> Result<impl Future<Output = Result<(), NativeError>> + use<>, NativeError> {
        let (old_path, new_path) = (sub_path(old_path)?, sub_path(new_path)?);
        self.writable()?;
        let from = self.dir(dir)?;
        let to = self.dir(new_dir)?;
        Ok(async move { Ok(from.rename(&old_path, &to, &new_path).await?) })
    }

    // ---- files -------------------------------------------------------------------------

    /// `close(file)`: waits for the operations on the file, then closes it.
    pub fn close(&self, file: u32) -> Result<impl Future<Output = Result<(), NativeError>> + use<>, NativeError> {
        let entry = Rc::clone(self.files.borrow().get(file)?);
        entry.begin_close()?;
        Ok(async move {
            entry.drained().await;
            let closed = entry.value().close().await;
            entry.finish_close();
            Ok(closed?)
        })
    }

    /// `fileStat(file)`.
    pub fn file_stat(&self, file: u32) -> Result<impl Future<Output = Result<Stat, NativeError>> + use<>, NativeError> {
        self.readable()?;
        let file = self.file(file)?;
        Ok(async move {
            let meta = file.metadata().await?;
            Ok(Stat { kind: kind_code(meta.file_type()), size: exact_size(meta.len())? })
        })
    }

    /// `readAll(file, limit)`: from the current position to the end or until `limit` bytes. Fails
    /// with `FileTooLarge` beyond [`MAX_READ_BYTES`].
    pub fn read_all(&self, file: u32, limit: usize) -> Result<impl Future<Output = Result<Vec<u8>, NativeError>> + use<>, NativeError> {
        self.readable()?;
        let file = self.file(file)?;
        Ok(async move {
            let mut out: Vec<u8> = Vec::new();
            let mut chunk = vec![0; READ_CHUNK];
            while out.len() < limit {
                chunk.resize(READ_CHUNK.min(limit - out.len()), 0);
                let (read, back) = file.read(chunk).await;
                chunk = back;
                match read {
                    Ok(0) => break,
                    Ok(count) => {
                        if out.len() + count > MAX_READ_BYTES {
                            return Err(NativeError::Errno(errno::FILE_TOO_LARGE));
                        }
                        out.extend_from_slice(&chunk[..count]);
                    }
                    Err(err) if err.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(err) => return Err(err.into()),
                }
            }
            Ok(out)
        })
    }

    /// `writeAll(file, data)`: at the current position. `data` is any [`IoBuf`] (a `Vec<u8>`, or
    /// pinned guest memory); the buffer is dropped when the write is done.
    pub fn write_all<B: IoBuf>(&self, file: u32, data: B) -> Result<impl Future<Output = Result<(), NativeError>> + use<B>, NativeError> {
        self.write_all_with(file, Box::new(|| Ok(data)))
    }

    /// [`Grant::write_all`] with the buffer made by `make` *after* the write ceiling and the
    /// handle were checked (so a rejected call has not consumed or detached anything). `make`
    /// runs synchronously, before this returns.
    pub fn write_all_with<B: IoBuf>(
        &self,
        file: u32,
        make: Box<dyn FnOnce() -> Result<B, NativeError> + '_>,
    ) -> Result<impl Future<Output = Result<(), NativeError>> + use<B>, NativeError> {
        self.writable()?;
        let file = self.file(file)?;
        let data = make()?;
        Ok(async move {
            if data.bytes_init() == 0 {
                return Ok(());
            }
            let (written, _) = file.write_all(data).await;
            Ok(written?)
        })
    }

    /// `fileRead(file, len)` / `filePread(file, len, offset)`: up to `len` bytes (empty at the end).
    /// The caller copies them into the guest buffer.
    pub fn file_read(
        &self,
        file: u32,
        len: usize,
        offset: Option<u64>,
    ) -> Result<impl Future<Output = Result<Vec<u8>, NativeError>> + use<>, NativeError> {
        self.readable()?;
        let file = self.file(file)?;
        Ok(async move {
            if len == 0 {
                return Ok(Vec::new());
            }
            let buf = vec![0; len];
            let (read, mut buf) = match offset {
                Some(offset) => file.read_at(buf, offset).await,
                None => file.read(buf).await,
            };
            buf.truncate(read?);
            Ok(buf)
        })
    }

    /// `fileWrite(file, data)`: one write that may be partial; the byte count (0 for no data).
    pub fn file_write<B: IoBuf>(
        &self,
        file: u32,
        data: B,
    ) -> Result<impl Future<Output = Result<usize, NativeError>> + use<B>, NativeError> {
        self.file_write_with(file, Box::new(|| Ok(data)))
    }

    /// [`Grant::file_write`] with the buffer made by `make` after the checks (see [`Grant::write_all_with`]).
    pub fn file_write_with<B: IoBuf>(
        &self,
        file: u32,
        make: Box<dyn FnOnce() -> Result<B, NativeError> + '_>,
    ) -> Result<impl Future<Output = Result<usize, NativeError>> + use<B>, NativeError> {
        self.writable()?;
        let file = self.file(file)?;
        let data = make()?;
        Ok(async move {
            if data.bytes_init() == 0 {
                return Ok(0);
            }
            let (written, _) = file.write(data).await;
            Ok(written?)
        })
    }

    /// `filePwriteAll(file, data, offset)`.
    pub fn file_pwrite_all<B: IoBuf>(
        &self,
        file: u32,
        data: B,
        offset: u64,
    ) -> Result<impl Future<Output = Result<(), NativeError>> + use<B>, NativeError> {
        self.file_pwrite_all_with(file, offset, Box::new(|| Ok(data)))
    }

    /// [`Grant::file_pwrite_all`] with the buffer made by `make` after the checks (see [`Grant::write_all_with`]).
    pub fn file_pwrite_all_with<B: IoBuf>(
        &self,
        file: u32,
        offset: u64,
        make: Box<dyn FnOnce() -> Result<B, NativeError> + '_>,
    ) -> Result<impl Future<Output = Result<(), NativeError>> + use<B>, NativeError> {
        self.writable()?;
        let file = self.file(file)?;
        let data = make()?;
        Ok(async move {
            if data.bytes_init() == 0 {
                return Ok(());
            }
            let (written, _) = file.write_all_at(data, offset).await;
            Ok(written?)
        })
    }

    /// `fileReadInto` / `filePreadInto`: one read (at `offset`, or the current position) of up to
    /// `buf.bytes_total()` bytes straight into `buf`; resolves the byte count (0 = end of file)
    /// and hands the buffer back. A zero-length buffer completes with 0 without I/O. On an error
    /// the buffer is dropped.
    pub fn file_read_into<B: IoBufMut>(
        &self,
        file: u32,
        buf: B,
        offset: Option<u64>,
    ) -> Result<impl Future<Output = Result<(usize, B), NativeError>> + use<B>, NativeError> {
        self.file_read_into_with(file, offset, Box::new(|| Ok(buf)))
    }

    /// [`Grant::file_read_into`] with the buffer made by `make` after the handle was checked (see
    /// [`Grant::write_all_with`]).
    pub fn file_read_into_with<B: IoBufMut>(
        &self,
        file: u32,
        offset: Option<u64>,
        make: Box<dyn FnOnce() -> Result<B, NativeError> + '_>,
    ) -> Result<impl Future<Output = Result<(usize, B), NativeError>> + use<B>, NativeError> {
        self.readable()?;
        let file = self.file(file)?;
        let buf = make()?;
        Ok(async move {
            if buf.bytes_total() == 0 {
                return Ok((0, buf));
            }
            let (read, buf) = match offset {
                Some(offset) => file.read_at(buf, offset).await,
                None => file.read(buf).await,
            };
            Ok((read?, buf))
        })
    }

    /// `fileSetLength(file, length)`.
    pub fn file_set_length(&self, file: u32, length: u64) -> Result<impl Future<Output = Result<(), NativeError>> + use<>, NativeError> {
        self.writable()?;
        let file = self.file(file)?;
        Ok(async move { Ok(file.set_len(length).await?) })
    }

    /// `fileSync(file)`.
    pub fn file_sync(&self, file: u32) -> Result<impl Future<Output = Result<(), NativeError>> + use<>, NativeError> {
        let file = self.file(file)?;
        Ok(async move { Ok(file.sync_all().await?) })
    }
}
