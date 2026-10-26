//! Pinned guest buffers: lending a guest `ArrayBuffer` to the I/O loop without copying it.
//!
//! # The protocol
//! A guest buffer (an `ArrayBuffer`, or a view over one: [`ArrayBufferArg`]) is either
//!
//! * **pinned**: when [`origine_api_core::pin::StoreTraits::pinnable`] holds (not shared, not
//!   resizable, detachable) and the region is not empty, the buffer is *detached* (the guest's
//!   `ArrayBuffer` and every view over it become length 0, exactly like
//!   `ArrayBuffer.prototype.transfer()`), and the store's `SharedRef<BackingStore>` becomes the
//!   owner of an [`origine_io::RawRegion`] over the captured `(byte_offset, byte_length)` window.
//!   The kernel or a worker then reads or writes the guest's bytes in place; or
//! * **copied**: reads fall back to a host `Vec<u8>` that is copied out into the guest's buffer at
//!   completion by the native's [`crate::native::Wrap`] when the buffer is not pinnable. Writes
//!   choose explicitly: the plain ones always copy the window at call time ([`copy_for_write`]) and
//!   never touch the guest's buffer; the `*Move` ones pin it ([`pin_for_move`]) and fail
//!   `Unsupported` instead of copying when they cannot.
//!
//! A region with no bytes is [`Plan::Empty`]: nothing is detached, nothing is copied, no I/O.
//!
//! # Why this is sound
//! * *Exclusive access.* After a verified detach no guest handle reaches the store (the V8 sandbox
//!   keeps the store inside the sandbox; the guest has no other wrapper for it), and the store is
//!   not shared, so no other thread has it either. The loop is the only accessor until the
//!   region is dropped.
//! * *Lifetime.* The `SharedRef` keeps the store alive for as long as the region (an owner field)
//!   lives. A region is owned by the op future; a dropped future leaves it in the loop's op state
//!   until the completion callback has run (`origine_io` cancel-on-drop), so `io.close()`,
//!   a runtime's teardown and `origine_api_detach_isolate` (cancel, then drain the loop, then
//!   drop) never free memory a worker may still write into. The promise of such an op is
//!   rejected `Canceled`; nothing is resurrected.
//! * *Threads.* Everything with a V8 handle stays on the isolate thread. The region is `!Send`;
//!   only its address reaches the kernel. The final `SharedRef` drop happens on the loop thread,
//!   which is the isolate thread (the loop is driven from `origine_api_poll`); the reference
//!   count is atomic anyway.
//! * *Length.* The window is captured from the view *before* detaching (afterwards views report
//!   0) and re-checked against the store's length before a pointer is formed.
//!
//! On a rejected operation a pinned buffer is not returned: the guest has handed it over and the
//! error value carries no buffer. (Argument and handle errors are detected before anything is
//! detached, so those leave the buffer intact.)

use std::any::Any;
use std::ffi::c_void;

use origine_api_core::pin::{self, Plan, StoreTraits};
use origine_api_core::{NativeError, errno};
use origine_io::{IoBuf, IoBufMut, RawRegion};

use crate::decode::ArrayBufferArg;

/// The owner of a pinned [`RawRegion`]: keeps the V8 store alive and gives it back for
/// re-wrapping into a new `ArrayBuffer` on the isolate thread.
pub struct PinnedStore(pub v8::SharedRef<v8::BackingStore>);

/// The buffer of a guest-buffer operation: a pinned region, or an ordinary host `Vec<u8>` (the
/// copy fallback, an empty region, or host memory).
pub enum GuestBuf {
    Pinned(RawRegion),
    Copied(Vec<u8>),
}

impl GuestBuf {
    /// The store of a pinned region (consuming the buffer); `None` for a `Copied` one.
    pub fn into_store(self) -> Option<v8::SharedRef<v8::BackingStore>> {
        match self {
            GuestBuf::Pinned(region) => region.into_owner().downcast::<PinnedStore>().ok().map(|store| store.0),
            GuestBuf::Copied(_) => None,
        }
    }
}

// SAFETY: each arm forwards to an `IoBuf` implementation that upholds the contract; the variant
// never changes while the value lives, so the pointer and lengths stay those of that arm.
unsafe impl IoBuf for GuestBuf {
    fn stable_ptr(&self) -> *const u8 {
        match self {
            GuestBuf::Pinned(region) => region.stable_ptr(),
            GuestBuf::Copied(vec) => vec.stable_ptr(),
        }
    }
    fn bytes_init(&self) -> usize {
        match self {
            GuestBuf::Pinned(region) => region.bytes_init(),
            GuestBuf::Copied(vec) => vec.bytes_init(),
        }
    }
    fn bytes_total(&self) -> usize {
        match self {
            GuestBuf::Pinned(region) => region.bytes_total(),
            GuestBuf::Copied(vec) => vec.bytes_total(),
        }
    }
}

// SAFETY: as for `IoBuf`; each arm's `stable_mut_ptr` is the same address as its `stable_ptr`.
unsafe impl IoBufMut for GuestBuf {
    fn stable_mut_ptr(&mut self) -> *mut u8 {
        match self {
            GuestBuf::Pinned(region) => region.stable_mut_ptr(),
            GuestBuf::Copied(vec) => vec.stable_mut_ptr(),
        }
    }
    unsafe fn set_init(&mut self, pos: usize) {
        match self {
            // SAFETY: the caller's contract (`pos` initialized bytes, `pos <= bytes_total()`) is forwarded.
            GuestBuf::Pinned(region) => unsafe { region.set_init(pos) },
            // SAFETY: as above.
            GuestBuf::Copied(vec) => unsafe { vec.set_init(pos) },
        }
    }
}

/// What [`take`] decided.
enum Taken {
    Region(RawRegion),
    Empty,
    Copy,
}

/// Decides and, for [`Plan::Pin`], performs the pin of `arg`'s window. `init` says whether the
/// bytes are meaningful (a write source) or only room to fill (a read sink).
/// Borrows arg through return; a returned region owns its backing-store reference.
/// Shared buffers stay attached and select the copy path; failure retains no resources.
fn take(arg: &ArrayBufferArg<'_>, init: bool) -> Result<Taken, NativeError> {
    let Ok(buffer) = v8::Local::<v8::ArrayBuffer>::try_from(arg.buffer()) else {
        return Ok(Taken::Copy);
    };
    if buffer.was_detached() {
        return Err(NativeError::Errno(errno::STALE_HANDLE));
    }
    // Capture the window before anything can detach the buffer (views report 0 afterwards).
    let (offset, len) = (arg.offset(), arg.len());
    if len == 0 {
        return Ok(Taken::Empty);
    }
    let store = buffer.get_backing_store();
    let traits =
        StoreTraits { shared: store.is_shared(), resizable: store.is_resizable_by_user_javascript(), detachable: buffer.is_detachable() };
    if pin::plan(traits, len) != Plan::Pin {
        return Ok(Taken::Copy);
    }
    if !pin::window_fits(offset, len, store.byte_length()) {
        return Err(NativeError::Errno(errno::INVALID_DATA));
    }
    let Some(base) = store.data() else {
        return Ok(Taken::Copy);
    };
    // `detach` reports `Some(true)` for a buffer it did not detach, so verify the effect. A buffer
    // that could not be detached (a detach key we do not hold) is still intact: copy it.
    if buffer.detach(None) != Some(true) || !buffer.was_detached() {
        return Ok(Taken::Copy);
    }
    // SAFETY: `window_fits` established `offset <= store.byte_length()`, and `base` is the start
    // of a live allocation of that length, so the result stays inside (or one past) it.
    let start = unsafe { base.cast::<u8>().add(offset) };
    let owner: Box<dyn Any> = Box::new(PinnedStore(store));
    let region = if init {
        // SAFETY: `start..start + len` lies inside the store (checked above); the store is kept
        // alive by `owner`, which the region owns; its address is stable (V8 never moves a
        // backing store); the buffer was detached and the store is not shared, so nothing but the
        // loop accesses the bytes until the region is dropped (see the module docs).
        unsafe { RawRegion::new(start, len, owner) }
    } else {
        // SAFETY: as above (the bytes happen to be initialized, which `new_uninit` does not need).
        unsafe { RawRegion::new_uninit(start, len, owner) }
    };
    Ok(Taken::Region(region))
}

/// The source buffer of a *copying* write of `arg`'s bytes: a copy made now, so the guest's buffer
/// stays attached and usable (the default of every `write`, `writeAll`, ... in `api.fs`).
/// `StaleHandle` if the buffer is already detached.
pub fn copy_for_write(arg: &ArrayBufferArg<'_>) -> Result<GuestBuf, NativeError> {
    if let Ok(buffer) = v8::Local::<v8::ArrayBuffer>::try_from(arg.buffer())
        && buffer.was_detached()
    {
        return Err(NativeError::Errno(errno::STALE_HANDLE));
    }
    Ok(GuestBuf::Copied(arg.to_vec()))
}

/// The source buffer of a *moving* write (`writeMove`, ...): the pinned window, the guest's
/// `ArrayBuffer` is detached (the whole buffer, not only the view's window) and the loop writes
/// from its store in place. Never copies: a buffer that cannot be detached (shared, resizable,
/// WebAssembly memory) fails `Unsupported` with the buffer untouched, and so does a detached
/// one with `StaleHandle`. A region with no bytes completes without I/O and detaches nothing.
pub fn pin_for_move(arg: &ArrayBufferArg<'_>) -> Result<GuestBuf, NativeError> {
    match take(arg, true)? {
        Taken::Region(region) => Ok(GuestBuf::Pinned(region)),
        Taken::Empty => Ok(GuestBuf::Copied(Vec::new())),
        Taken::Copy => Err(NativeError::Errno(errno::UNSUPPORTED)),
    }
}

/// The sink buffer for a read into `arg`'s window, and whether it is a host copy (`true`: the
/// caller must copy the result out into the guest's buffer at completion; the guest's buffer was
/// not detached). `StaleHandle` if the buffer is already detached.
pub fn pin_for_read(arg: &ArrayBufferArg<'_>) -> Result<(GuestBuf, bool), NativeError> {
    Ok(match take(arg, false)? {
        Taken::Region(region) => (GuestBuf::Pinned(region), false),
        Taken::Empty => (GuestBuf::Copied(Vec::new()), true),
        Taken::Copy => (GuestBuf::Copied(vec![0; arg.len()]), true),
    })
}

/// A fresh V8-allocated store of `len` bytes (`len > 0`) as a sink: the buffer for a
/// host-provided read. Nothing is detached (no guest object exists yet).
pub fn alloc_for_read(isolate: &mut v8::Isolate, len: usize) -> Result<GuestBuf, NativeError> {
    if len == 0 {
        return Ok(GuestBuf::Copied(Vec::new()));
    }
    let store = v8::ArrayBuffer::new_backing_store(isolate, len).make_shared();
    let (Some(base), true) = (store.data(), store.byte_length() == len) else {
        return Err(NativeError::Errno(errno::INVALID_DATA));
    };
    let owner: Box<dyn Any> = Box::new(PinnedStore(store));
    // SAFETY: `base` is the start of the store's `len` writable bytes, kept alive by `owner`; the
    // store is fresh, so nothing else references it; its address is stable.
    let region = unsafe { RawRegion::new_uninit(base.cast::<u8>(), len, owner) };
    Ok(GuestBuf::Pinned(region))
}

/// The owner of a receive window inside a slab: keeps the slab alive and remembers where the
/// window starts.
struct SlabWindow {
    slab: v8::SharedRef<v8::BackingStore>,
    offset: usize,
}

/// A sink over `len` bytes at `offset` of `slab`, a V8 store (inside the V8 sandbox when there is
/// one) that no `ArrayBuffer` wraps over that window: the loop is the only accessor until the
/// region is dropped. [`GuestBuf::into_window`] gives the slab and offset back.
pub fn region_over_slab(slab: v8::SharedRef<v8::BackingStore>, offset: usize, len: usize) -> Result<GuestBuf, NativeError> {
    let fits = offset.checked_add(len).is_some_and(|end| end <= slab.byte_length());
    let base = slab.data().filter(|_| fits && len > 0).ok_or(NativeError::Errno(errno::INVALID_DATA))?;
    // SAFETY: `offset <= slab.byte_length()`, so the result stays inside (or one past) the allocation.
    let start = unsafe { base.cast::<u8>().add(offset) };
    let owner: Box<dyn Any> = Box::new(SlabWindow { slab, offset });
    // SAFETY: `start..start + len` lies inside the slab (checked above), which `owner` keeps alive;
    // its address is stable; the window is handed to the loop only once (the pump advances past
    // what a chunk keeps), and no `ArrayBuffer` wraps it until `carve` runs after the receive.
    let region = unsafe { RawRegion::new_uninit(start, len, owner) };
    Ok(GuestBuf::Pinned(region))
}

impl GuestBuf {
    /// The slab and offset of a [`region_over_slab`] buffer (consuming it).
    pub fn into_window(self) -> Option<(v8::SharedRef<v8::BackingStore>, usize)> {
        match self {
            GuestBuf::Pinned(region) => region.into_owner().downcast::<SlabWindow>().ok().map(|window| (window.slab, window.offset)),
            GuestBuf::Copied(_) => None,
        }
    }
}

unsafe extern "C" fn release_slab(_data: *mut c_void, _length: usize, slab: *mut c_void) {
    // SAFETY: `slab` is the `Box<SharedRef<BackingStore>>` that `carve` leaked for this store; V8
    // calls the deleter exactly once, on whatever thread frees the store (the reference count is atomic).
    drop(unsafe { Box::from_raw(slab.cast::<v8::SharedRef<v8::BackingStore>>()) });
}

/// A backing store of exactly `len` bytes at `offset` of `slab`: no copy, and nothing outside the
/// window is reachable through it. The store holds a reference on `slab`, which goes back to the
/// allocator when the last window is released (the `ArrayBuffer` over it detached or collected).
/// The slab must be a V8-allocated store, so the window is inside the sandbox when there is one.
pub fn carve(slab: &v8::SharedRef<v8::BackingStore>, offset: usize, len: usize) -> Result<v8::SharedRef<v8::BackingStore>, NativeError> {
    let fits = offset.checked_add(len).is_some_and(|end| end <= slab.byte_length());
    let base = slab.data().filter(|_| fits && len > 0).ok_or(NativeError::Errno(errno::INVALID_DATA))?;
    // SAFETY: the window lies inside the slab (checked above).
    let start = unsafe { base.cast::<u8>().add(offset) };
    let keep = Box::into_raw(Box::new(slab.clone()));
    // SAFETY: `start..start + len` stays valid while the leaked reference lives, which is until V8
    // runs `release_slab` with it; the receive into the window finished before the carve.
    let store = unsafe { v8::ArrayBuffer::new_backing_store_from_ptr(start.as_ptr().cast(), len, release_slab, keep.cast()) };
    Ok(store.make_shared())
}
