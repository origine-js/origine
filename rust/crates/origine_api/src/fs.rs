//! `native.fsAsync.*`: the async twins of the sync fs natives (`src/api/fs.zig`), taking the same
//! arguments (handles flattened as `fs, id`) and resolving with the same results. The grant is
//! found by the `fs` of the handle; all logic is in `origine_api_fs`.
//!
//! Each native is `native.fsAsync.<camelCase>` in JS (its `path`) and is listed in `registry.rs`.

use std::cell::{Cell, RefCell};
use std::future::Future;
use std::rc::Rc;

use origine_api_core::{NativeError, errno};
use origine_api_fs::{DirListing, Grant, Stat};

use crate::decode::{DirRef, FileRef, Limit};
use crate::native;
use crate::native::{Op, ScopeKey, host_mut};
use crate::pinned::{self, GuestBuf};
use crate::{ArrayBufferArg, HostState, IntoJs};
use origine_api_core::pin;

/// The result of `request`: `{ id }`.
#[derive(crate::IntoJs)]
pub struct GrantOpened {
    id: u32,
}

/// `native.fsAsync.request(ioId, root, write)`: opens `root` (relative to the embedder's fs root)
/// as a grant bound to runtime `ioId`. Rejects `BadHandle` (runtime unknown/closed/foreign),
/// `AccessDenied` (no async fs configured), `InvalidPath`, or the OS error of opening the root.
#[native(side_effect = "any", path = "fsAsync.request", needs = "async_fs", promise)]
fn fs_async_request<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    key: ScopeKey,
    io: u32,
    root: String,
    write: bool,
) -> Result<Op<'s, impl Future<Output = Result<GrantOpened, NativeError>> + use<>>, NativeError> {
    let (runtime, id, write, base, root) = host_mut(scope)?.prepare_grant(key, io, &root, write)?;
    let slot: Rc<RefCell<Option<Rc<Grant>>>> = Rc::default();
    let filled = Rc::clone(&slot);
    let future = async move {
        let opened = base.open_dir(&root).await;
        let _ = base.close().await;
        *filled.borrow_mut() = Some(Grant::new(id, write, opened?));
        Ok(GrantOpened { id })
    };
    let hook = Box::new(move |scope: &mut v8::PinScope<'_, '_>| {
        let grant = slot.borrow_mut().take().ok_or(NativeError::Errno(errno::CANCELED))?;
        host_mut(scope)?.register_grant(key, runtime, grant)
    });
    Ok(Op::new(runtime, future).with_hook(hook))
}

#[native(side_effect = "any", path = "fsAsync.openFile", needs = "async_fs", promise)]
fn fs_async_open_file(
    host: &mut HostState,
    key: ScopeKey,
    dir: DirRef,
    path: String,
    bits: u32,
) -> Result<Op<'static, impl Future<Output = Result<u32, NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, dir.fs)?;
    Ok(Op::new(runtime, g.open_file(dir.id, &path, bits)?))
}

#[native(side_effect = "any", path = "fsAsync.openDir", needs = "async_fs", promise)]
fn fs_async_open_dir(
    host: &mut HostState,
    key: ScopeKey,
    dir: DirRef,
    path: String,
) -> Result<Op<'static, impl Future<Output = Result<u32, NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, dir.fs)?;
    Ok(Op::new(runtime, g.open_dir(dir.id, &path)?))
}

#[native(side_effect = "any", path = "fsAsync.stat", needs = "async_fs", promise)]
fn fs_async_stat(
    host: &mut HostState,
    key: ScopeKey,
    dir: DirRef,
    path: String,
) -> Result<Op<'static, impl Future<Output = Result<Stat, NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, dir.fs)?;
    Ok(Op::new(runtime, g.stat(dir.id, &path)?))
}

#[native(side_effect = "any", path = "fsAsync.createDir", needs = "async_fs", promise)]
fn fs_async_create_dir(
    host: &mut HostState,
    key: ScopeKey,
    dir: DirRef,
    path: String,
) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, dir.fs)?;
    Ok(Op::new(runtime, g.create_dir(dir.id, &path)?))
}

#[native(side_effect = "any", path = "fsAsync.deleteFile", needs = "async_fs", promise)]
fn fs_async_delete_file(
    host: &mut HostState,
    key: ScopeKey,
    dir: DirRef,
    path: String,
) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, dir.fs)?;
    Ok(Op::new(runtime, g.delete_file(dir.id, &path)?))
}

#[native(side_effect = "any", path = "fsAsync.readDir", needs = "async_fs", promise)]
fn fs_async_read_dir(
    host: &mut HostState,
    key: ScopeKey,
    dir: DirRef,
) -> Result<Op<'static, impl Future<Output = Result<DirListing, NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, dir.fs)?;
    Ok(Op::new(runtime, g.read_dir(dir.id)?))
}

#[native(side_effect = "any", path = "fsAsync.readAll", needs = "async_fs", promise)]
fn fs_async_read_all(
    host: &mut HostState,
    key: ScopeKey,
    file: FileRef,
    limit: Limit,
) -> Result<Op<'static, impl Future<Output = Result<Vec<u8>, NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, file.fs)?;
    Ok(Op::new(runtime, g.read_all(file.id, limit.0)?))
}

#[native(side_effect = "any", path = "fsAsync.writeAll", needs = "async_fs", promise)]
fn fs_async_write_all(
    host: &mut HostState,
    key: ScopeKey,
    file: FileRef,
    data: ArrayBufferArg<'_>,
) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, file.fs)?;
    Ok(Op::new(runtime, g.write_all_with(file.id, Box::new(|| pinned::pin_for_write(&data)))?))
}

#[native(side_effect = "any", path = "fsAsync.close", needs = "async_fs", promise)]
fn fs_async_close(
    host: &mut HostState,
    key: ScopeKey,
    file: FileRef,
) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, file.fs)?;
    Ok(Op::new(runtime, g.close(file.id)?))
}

#[native(side_effect = "any", path = "fsAsync.closeDir", needs = "async_fs", promise)]
fn fs_async_close_dir(
    host: &mut HostState,
    key: ScopeKey,
    dir: DirRef,
) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, dir.fs)?;
    Ok(Op::new(runtime, g.close_dir(dir.id)?))
}

#[native(side_effect = "any", path = "fsAsync.createDirPath", needs = "async_fs", promise)]
fn fs_async_create_dir_path(
    host: &mut HostState,
    key: ScopeKey,
    dir: DirRef,
    path: String,
) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, dir.fs)?;
    Ok(Op::new(runtime, g.create_dir_path(dir.id, &path)?))
}

#[native(side_effect = "any", path = "fsAsync.deleteDir", needs = "async_fs", promise)]
fn fs_async_delete_dir(
    host: &mut HostState,
    key: ScopeKey,
    dir: DirRef,
    path: String,
) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, dir.fs)?;
    Ok(Op::new(runtime, g.delete_dir(dir.id, &path)?))
}

#[native(side_effect = "any", path = "fsAsync.deleteTree", needs = "async_fs", promise)]
fn fs_async_delete_tree(
    host: &mut HostState,
    key: ScopeKey,
    dir: DirRef,
    path: String,
) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, dir.fs)?;
    Ok(Op::new(runtime, g.delete_tree(dir.id, &path)?))
}

#[native(side_effect = "any", path = "fsAsync.rename", needs = "async_fs", promise)]
fn fs_async_rename(
    host: &mut HostState,
    key: ScopeKey,
    dir: DirRef,
    old_path: String,
    new_dir: DirRef,
    new_path: String,
) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, dir.fs)?;
    if new_dir.fs != dir.fs {
        return Err(NativeError::Errno(errno::BAD_HANDLE));
    }
    Ok(Op::new(runtime, g.rename(dir.id, &old_path, new_dir.id, &new_path)?))
}

#[native(side_effect = "any", path = "fsAsync.fileStat", needs = "async_fs", promise)]
fn fs_async_file_stat(
    host: &mut HostState,
    key: ScopeKey,
    file: FileRef,
) -> Result<Op<'static, impl Future<Output = Result<Stat, NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, file.fs)?;
    Ok(Op::new(runtime, g.file_stat(file.id)?))
}

#[native(side_effect = "any", path = "fsAsync.fileWrite", needs = "async_fs", promise)]
fn fs_async_file_write(
    host: &mut HostState,
    key: ScopeKey,
    file: FileRef,
    data: ArrayBufferArg<'_>,
) -> Result<Op<'static, impl Future<Output = Result<usize, NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, file.fs)?;
    Ok(Op::new(runtime, g.file_write_with(file.id, Box::new(|| pinned::pin_for_write(&data)))?))
}

#[native(side_effect = "any", path = "fsAsync.filePwriteAll", needs = "async_fs", promise)]
fn fs_async_file_pwrite_all(
    host: &mut HostState,
    key: ScopeKey,
    file: FileRef,
    data: ArrayBufferArg<'_>,
    offset: u64,
) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, file.fs)?;
    Ok(Op::new(runtime, g.file_pwrite_all_with(file.id, offset, Box::new(|| pinned::pin_for_write(&data)))?))
}

#[native(side_effect = "any", path = "fsAsync.fileSetLength", needs = "async_fs", promise)]
fn fs_async_file_set_length(
    host: &mut HostState,
    key: ScopeKey,
    file: FileRef,
    length: u64,
) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, file.fs)?;
    Ok(Op::new(runtime, g.file_set_length(file.id, length)?))
}

#[native(side_effect = "any", path = "fsAsync.fileSync", needs = "async_fs", promise)]
fn fs_async_file_sync(
    host: &mut HostState,
    key: ScopeKey,
    file: FileRef,
) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, file.fs)?;
    Ok(Op::new(runtime, g.file_sync(file.id)?))
}

/// Reads into the guest buffer at completion (it must still be attached); resolves the count.
#[native(side_effect = "any", path = "fsAsync.fileRead", needs = "async_fs", promise)]
fn fs_async_file_read<'s>(
    host: &mut HostState,
    key: ScopeKey,
    file: FileRef,
    buffer: ArrayBufferArg<'s>,
) -> Result<Op<'s, impl Future<Output = Result<usize, NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, file.fs)?;
    Ok(Op::reading(runtime, g.file_read(file.id, buffer.len(), None)?, buffer))
}

/// Reads into the guest buffer at completion (it must still be attached); resolves the count.
#[native(side_effect = "any", path = "fsAsync.filePread", needs = "async_fs", promise)]
fn fs_async_file_pread<'s>(
    host: &mut HostState,
    key: ScopeKey,
    file: FileRef,
    buffer: ArrayBufferArg<'s>,
    offset: u64,
) -> Result<Op<'s, impl Future<Output = Result<usize, NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host.grant(key, file.fs)?;
    Ok(Op::reading(runtime, g.file_read(file.id, buffer.len(), Some(offset))?, buffer))
}

// ---- zero-copy reads -------------------------------------------------------------------------

/// The resolution of `fileReadInto` / `filePreadInto` before the glue wraps it: `{ bytes, buffer }`.
pub enum ReadInto {
    /// The guest buffer was pinned: `buffer` is a NEW `ArrayBuffer` over the same store (the
    /// guest's original `ArrayBuffer` stays detached).
    Pinned { bytes: usize, store: v8::SharedRef<v8::BackingStore> },
    /// The copy fallback: the bytes sit in the shared cell and the [`native::Wrap`] copies them
    /// into the guest's own buffer and resolves `{ bytes, buffer: <that buffer> }`. Encoded as
    /// the bare count until then.
    Copied { bytes: usize },
}

impl<'s> IntoJs<'s> for ReadInto {
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        match self {
            ReadInto::Pinned { bytes, store } => {
                // Re-attaches the store the guest's buffer was detached from (see `pinned`).
                let buffer = v8::ArrayBuffer::with_backing_store(scope, &store);
                read_result(scope, bytes, buffer)
            }
            ReadInto::Copied { bytes } => bytes.into_js(scope),
        }
    }
}

fn read_result<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    bytes: usize,
    buffer: v8::Local<'s, v8::ArrayBuffer>,
) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let object = crate::encode::new_object(scope);
    crate::encode::set(scope, object, "bytes", bytes)?;
    crate::encode::set(scope, object, "buffer", buffer)?;
    Ok(object.into())
}

/// The resolution of `fileReadAlloc` / `filePreadAlloc`: a `Uint8Array` of the bytes read.
pub struct AllocRead {
    bytes: usize,
    /// The store the read filled (`None` for a zero-length read).
    store: Option<v8::SharedRef<v8::BackingStore>>,
}

impl<'s> IntoJs<'s> for AllocRead {
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        let buffer = match &self.store {
            Some(store) if pin::should_compact(self.bytes, store.byte_length()) => compact(scope, store, self.bytes),
            Some(store) => v8::ArrayBuffer::with_backing_store(scope, store),
            None => v8::ArrayBuffer::new(scope, 0),
        };
        v8::Uint8Array::new(scope, buffer, 0, self.bytes).map(Into::into).ok_or_else(|| NativeError::range_error("buffer too large"))
    }
}

/// A new `ArrayBuffer` holding the first `bytes` bytes of `store` (the rest of a short read is
/// dropped with the store).
fn compact<'s>(scope: &mut v8::PinScope<'s, '_>, store: &v8::SharedRef<v8::BackingStore>, bytes: usize) -> v8::Local<'s, v8::ArrayBuffer> {
    let buffer = v8::ArrayBuffer::new(scope, bytes);
    if let (Some(dst), Some(src)) = (buffer.data().filter(|_| bytes > 0), store.data()) {
        // SAFETY: `bytes <= store.byte_length() / 2` (see `should_compact`), so `src` has `bytes`
        // readable bytes, all initialized by the completed read or zeroed by V8; `dst` is the
        // fresh buffer's `bytes` writable bytes. They are separate allocations.
        unsafe { std::ptr::copy_nonoverlapping(src.as_ptr().cast::<u8>(), dst.as_ptr().cast::<u8>(), bytes) };
    }
    buffer
}

/// Starts a read into the guest buffer `buffer` (`offset` `None` = the file position).
fn read_into<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    key: ScopeKey,
    file: FileRef,
    buffer: ArrayBufferArg<'s>,
    offset: Option<u64>,
) -> Result<Op<'s, impl Future<Output = Result<ReadInto, NativeError>> + use<>>, NativeError> {
    let (g, runtime) = host_mut(scope)?.grant(key, file.fs)?;
    let copied = Cell::new(false);
    let started = g.file_read_into_with(
        file.id,
        offset,
        Box::new(|| {
            let (buf, copy) = pinned::pin_for_read(&buffer)?;
            copied.set(copy);
            Ok(buf)
        }),
    )?;
    let cell: Rc<RefCell<Vec<u8>>> = Rc::default();
    let out = Rc::clone(&cell);
    let future = async move {
        let (bytes, buf) = started.await?;
        match buf {
            GuestBuf::Copied(mut data) => {
                data.truncate(bytes);
                *out.borrow_mut() = data;
                Ok(ReadInto::Copied { bytes })
            }
            pinned @ GuestBuf::Pinned(_) => {
                let store = pinned.into_store().ok_or(NativeError::Errno(errno::UNEXPECTED))?;
                Ok(ReadInto::Pinned { bytes, store })
            }
        }
    };
    let op = Op::new(runtime, future);
    if !copied.get() {
        return Ok(op);
    }
    // The copy fallback: fill the guest's own buffer at completion and resolve with it.
    let target = v8::Global::new(scope, buffer.buffer());
    let (start, len) = (buffer.offset(), buffer.len());
    Ok(op.with_wrap(Box::new(move |scope, _count| {
        let guest = v8::Local::new(scope, &target);
        let data = cell.borrow();
        native::copy_into(guest, start, len, &data)?;
        read_result(scope, data.len(), guest)
    })))
}

/// `fileReadInto(fs, id, buffer)`: one read at the file position straight into the guest buffer
/// (pinned and detached when eligible). Resolves `{ bytes, buffer: ArrayBuffer }`, see
/// [`ReadInto`]; `buffer` is the guest's buffer again (copy fallback) or a new one over the same
/// store (pinned).
#[native(side_effect = "any", path = "fsAsync.fileReadInto", needs = "async_fs", promise)]
fn fs_async_file_read_into<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    key: ScopeKey,
    file: FileRef,
    buffer: ArrayBufferArg<'s>,
) -> Result<Op<'s, impl Future<Output = Result<ReadInto, NativeError>> + use<>>, NativeError> {
    read_into(scope, key, file, buffer, None)
}

/// `filePreadInto(fs, id, buffer, offset)`: [`fs_async_file_read_into`] at `offset`.
#[native(side_effect = "any", path = "fsAsync.filePreadInto", needs = "async_fs", promise)]
fn fs_async_file_pread_into<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    key: ScopeKey,
    file: FileRef,
    buffer: ArrayBufferArg<'s>,
    offset: u64,
) -> Result<Op<'s, impl Future<Output = Result<ReadInto, NativeError>> + use<>>, NativeError> {
    read_into(scope, key, file, buffer, Some(offset))
}

/// Starts a read into a store of `len` bytes allocated by V8 (no guest object exists yet).
fn read_alloc(
    scope: &mut v8::PinScope<'_, '_>,
    key: ScopeKey,
    file: FileRef,
    len: u64,
    offset: Option<u64>,
) -> Result<Op<'static, impl Future<Output = Result<AllocRead, NativeError>> + use<>>, NativeError> {
    let len = usize::try_from(len).map_err(|_| NativeError::Errno(errno::FILE_TOO_BIG)).and_then(pin::check_alloc_len)?;
    let (g, runtime) = host_mut(scope)?.grant(key, file.fs)?;
    let isolate: &mut v8::Isolate = scope;
    let started = g.file_read_into_with(file.id, offset, Box::new(|| pinned::alloc_for_read(isolate, len)))?;
    Ok(Op::new(runtime, async move {
        let (bytes, buf) = started.await?;
        Ok(AllocRead { bytes, store: buf.into_store() })
    }))
}

/// `fileReadAlloc(fs, id, len)`: allocates a V8 `ArrayBuffer` of `len` bytes (at most 256 MiB,
/// else `FileTooBig`), reads once at the file position into it and resolves a `Uint8Array`
/// over the first `bytes` bytes of that buffer (empty at end of file).
#[native(side_effect = "any", path = "fsAsync.fileReadAlloc", needs = "async_fs", promise)]
fn fs_async_file_read_alloc(
    scope: &mut v8::PinScope<'_, '_>,
    key: ScopeKey,
    file: FileRef,
    len: u64,
) -> Result<Op<'static, impl Future<Output = Result<AllocRead, NativeError>> + use<>>, NativeError> {
    read_alloc(scope, key, file, len, None)
}

/// `filePreadAlloc(fs, id, len, offset)`: [`fs_async_file_read_alloc`] at `offset`.
#[native(side_effect = "any", path = "fsAsync.filePreadAlloc", needs = "async_fs", promise)]
fn fs_async_file_pread_alloc(
    scope: &mut v8::PinScope<'_, '_>,
    key: ScopeKey,
    file: FileRef,
    len: u64,
    offset: u64,
) -> Result<Op<'static, impl Future<Output = Result<AllocRead, NativeError>> + use<>>, NativeError> {
    read_alloc(scope, key, file, len, Some(offset))
}
