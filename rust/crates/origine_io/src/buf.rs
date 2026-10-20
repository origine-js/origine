//! Buffer traits for completion-based ops ([`IoBuf`], [`IoBufMut`]) and [`RawRegion`], a buffer
//! over caller-pinned memory that is not a `Vec<u8>` (for example a V8 `BackingStore`).

use std::any::Any;
use std::fmt;
use std::ptr::NonNull;

/// A buffer whose bytes an in-flight op may read (a *source*).
///
/// # Safety
/// Implementors guarantee, for as long as the value is neither dropped nor moved out of its
/// allocation (moving the *handle*, e.g. a `Vec` struct, is fine; the bytes must not move):
///
/// * [`stable_ptr`](IoBuf::stable_ptr) returns the same address on every call;
/// * that address is valid for reads of [`bytes_init`](IoBuf::bytes_init) bytes, and
///   `bytes_init() <= bytes_total()`;
/// * the memory may be accessed (read, and for [`IoBufMut`] written) by another thread such as
///   the kernel or an I/O worker through the raw pointer while the op is in flight, so the
///   value must not hand the same bytes to anything that expects exclusive access meanwhile
///   (the op owns the value, and nothing else touches the bytes until it is returned).
///
/// `'static` and `Unpin`: a pending op that is dropped must be able to keep the buffer alive
/// until the completion callback (it leaks it into the op state, which owns it as
/// `Box<dyn Any>`), and the op state may move the value around freely.
pub unsafe trait IoBuf: Unpin + 'static {
    /// Start of the buffer. Stable, see the trait contract.
    fn stable_ptr(&self) -> *const u8;
    /// Number of leading bytes that are initialized (what a write op sends).
    fn bytes_init(&self) -> usize;
    /// Total capacity in bytes (what a read op may fill). `>= bytes_init()`.
    fn bytes_total(&self) -> usize;
}

/// A buffer an in-flight op may write into (a *sink*).
///
/// # Safety
/// In addition to [`IoBuf`]: [`stable_mut_ptr`](IoBufMut::stable_mut_ptr) returns the same
/// address as `stable_ptr` and is valid for writes of [`bytes_total`](IoBuf::bytes_total)
/// bytes; [`set_init`](IoBufMut::set_init) is sound when its contract holds.
pub unsafe trait IoBufMut: IoBuf {
    /// Start of the buffer, for writing. Same address as [`IoBuf::stable_ptr`].
    fn stable_mut_ptr(&mut self) -> *mut u8;

    /// Record that the first `pos` bytes are now initialized: afterwards
    /// `bytes_init() >= pos` (it never shrinks). Called by read ops with `start + n` after a
    /// successful completion.
    ///
    /// # Safety
    /// The first `pos` bytes must really be initialized and `pos <= bytes_total()`.
    unsafe fn set_init(&mut self, pos: usize);
}

// SAFETY: a `Vec`'s heap block does not move while the Vec is alive and is not reallocated
// (nothing here grows it); `len <= capacity`. The window is the *length* (not the capacity): ops
// read into / write from `0..len`, so `vec![0; n]` reads up to `n` bytes.
unsafe impl IoBuf for Vec<u8> {
    fn stable_ptr(&self) -> *const u8 {
        self.as_ptr()
    }
    fn bytes_init(&self) -> usize {
        self.len()
    }
    fn bytes_total(&self) -> usize {
        self.len()
    }
}

// SAFETY: as for `IoBuf`; `stable_mut_ptr` is the same address, valid for `len()` bytes, and
// `set_init` only ever lengthens within the stated contract.
unsafe impl IoBufMut for Vec<u8> {
    fn stable_mut_ptr(&mut self) -> *mut u8 {
        self.as_mut_ptr()
    }
    unsafe fn set_init(&mut self, pos: usize) {
        if pos > self.len() {
            debug_assert!(pos <= self.capacity());
            // SAFETY: the caller guarantees `pos <= bytes_total()` (the length, so this branch is
            // unreachable for a conforming caller, but is sound anyway if the capacity is
            // larger) and that the first `pos` bytes are initialized.
            unsafe { self.set_len(pos) };
        }
    }
}

// SAFETY: the boxed slice's allocation does not move or change size.
unsafe impl IoBuf for Box<[u8]> {
    fn stable_ptr(&self) -> *const u8 {
        self.as_ptr()
    }
    fn bytes_init(&self) -> usize {
        self.len()
    }
    fn bytes_total(&self) -> usize {
        self.len()
    }
}

// SAFETY: as above; always fully initialized, so `set_init` has nothing to do.
unsafe impl IoBufMut for Box<[u8]> {
    fn stable_mut_ptr(&mut self) -> *mut u8 {
        self.as_mut_ptr()
    }
    unsafe fn set_init(&mut self, _pos: usize) {}
}

// SAFETY: static data never moves and lives forever.
unsafe impl IoBuf for &'static [u8] {
    fn stable_ptr(&self) -> *const u8 {
        self.as_ptr()
    }
    fn bytes_init(&self) -> usize {
        self.len()
    }
    fn bytes_total(&self) -> usize {
        self.len()
    }
}

// SAFETY: a `String`'s heap block does not move while it is alive (never grown here).
unsafe impl IoBuf for String {
    fn stable_ptr(&self) -> *const u8 {
        self.as_ptr()
    }
    fn bytes_init(&self) -> usize {
        self.len()
    }
    fn bytes_total(&self) -> usize {
        self.len()
    }
}

/// A buffer over memory the caller has pinned: `(ptr, len)` plus an `owner` that keeps the
/// memory alive (for example a `v8::SharedRef<BackingStore>`, or a `Box<[u8]>` that was leaked
/// into a raw pointer and is reclaimed by the owner's `Drop`).
///
/// The op future holds the region on the loop thread; the kernel or a worker accesses the bytes
/// only through the raw pointer. So `RawRegion` is `!Send` (it holds a `NonNull` and a
/// `Box<dyn Any>`), exactly like the op futures: it never crosses threads, only the address does.
/// Dropping the region (from the completion callback of an abandoned op, or when the buffer is
/// returned and dropped by the caller) drops `owner`, which is what frees the memory.
pub struct RawRegion {
    ptr: NonNull<u8>,
    len: usize,
    init: usize,
    owner: Box<dyn Any>,
}

impl RawRegion {
    /// Describe `len` bytes at `ptr`, all of them initialized (`bytes_init == len`), kept alive
    /// by `owner`.
    ///
    /// # Safety
    /// * `ptr..ptr+len` is valid for reads and writes, initialized, and stays valid until
    ///   `owner` is dropped (the memory must outlive the owner object being alive; the owner's
    ///   `Drop` may free it);
    /// * while this `RawRegion` exists (the op's whole duration, including after the future was
    ///   dropped and until the completion callback), nothing else reads or writes the bytes: the
    ///   caller has pinned the region exclusively (for V8: the guest `ArrayBuffer` is detached,
    ///   no `Uint8Array` view can reach it);
    /// * the address does not change (a V8 backing store does not move).
    pub unsafe fn new(ptr: NonNull<u8>, len: usize, owner: Box<dyn Any>) -> RawRegion {
        RawRegion { ptr, len, init: len, owner }
    }

    /// Like [`RawRegion::new`] but the bytes are *not* initialized (`bytes_init == 0`); read ops
    /// raise it through [`IoBufMut::set_init`]. The `ptr..ptr+len` writability requirement and the
    /// rest of the contract are the same, except that the bytes need not be initialized.
    ///
    /// # Safety
    /// See [`RawRegion::new`], minus the initialization requirement.
    pub unsafe fn new_uninit(ptr: NonNull<u8>, len: usize, owner: Box<dyn Any>) -> RawRegion {
        RawRegion { ptr, len, init: 0, owner }
    }

    /// Length of the region in bytes.
    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Raw start of the region.
    pub fn as_ptr(&self) -> *mut u8 {
        self.ptr.as_ptr()
    }

    /// Give up the region and return the owner (dropping it releases the memory).
    pub fn into_owner(self) -> Box<dyn Any> {
        self.owner
    }
}

impl fmt::Debug for RawRegion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("RawRegion").field("ptr", &self.ptr).field("len", &self.len).field("init", &self.init).finish_non_exhaustive()
    }
}

// SAFETY: `RawRegion::new` guarantees the address is stable and valid for `len` bytes while
// `owner` (a field of `self`) lives, and that nothing else accesses it, which also covers the
// op's I/O thread. `init <= len` is maintained by every constructor and by `set_init`.
unsafe impl IoBuf for RawRegion {
    fn stable_ptr(&self) -> *const u8 {
        self.ptr.as_ptr().cast_const()
    }
    fn bytes_init(&self) -> usize {
        self.init
    }
    fn bytes_total(&self) -> usize {
        self.len
    }
}

// SAFETY: the region is writable for `len` bytes per the `RawRegion::new` contract;
// `set_init` clamps to `len`.
unsafe impl IoBufMut for RawRegion {
    fn stable_mut_ptr(&mut self) -> *mut u8 {
        self.ptr.as_ptr()
    }
    unsafe fn set_init(&mut self, pos: usize) {
        self.init = self.init.max(pos.min(self.len));
    }
}
