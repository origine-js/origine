//! Heaps: groups of allocations that live in their own pages.
//!
//! A [`Heap`] is first-class in mimalloc 3: any thread may allocate from it and free its blocks,
//! so it is `Send + Sync`. Dropping one hands its live blocks to the main heap (they stay valid);
//! [`Heap::destroy`] instead frees every block at once, the point of having a heap per task.
//!
//! A [`Theap`] is the calling thread's part of a heap. Allocating through it skips the
//! thread-local lookup the plain functions do, which pays off for a runtime that keeps per-thread
//! state anyway. It is `!Send`: only the thread that obtained it may allocate through it.

use core::alloc::Layout;
use core::ffi::c_void;
use core::fmt;
use core::marker::PhantomData;
use core::ptr::NonNull;

use crate::arena::ArenaId;
use crate::sys;

/// The allocator is out of memory (or the request was impossible).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutOfMemory;

impl fmt::Display for OutOfMemory {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("mimalloc is out of memory")
    }
}

impl core::error::Error for OutOfMemory {}

/// Alignment every block has without asking. Larger alignments take the `*_aligned` calls: a
/// small block is only naturally aligned up to a power of two of its size.
const WORD_ALIGN: usize = size_of::<usize>();

/// Whether `layout` can take mimalloc's `*_small` entry points.
fn is_small(layout: Layout) -> bool {
    layout.size() <= sys::SMALL_SIZE_MAX && layout.align() <= WORD_ALIGN
}

fn non_null(ptr: *mut c_void) -> Option<NonNull<u8>> {
    NonNull::new(ptr.cast())
}

/// A mimalloc heap.
#[derive(Debug)]
pub struct Heap {
    raw: NonNull<sys::mi_heap_t>,
}

// SAFETY: mimalloc 3 heaps are first-class: allocation, freeing and collection are thread-safe.
unsafe impl Send for Heap {}
// SAFETY: as above; `&Heap` only allows those thread-safe operations.
unsafe impl Sync for Heap {}

impl Heap {
    /// A new heap over the process's memory.
    pub fn new() -> Result<Self, OutOfMemory> {
        // SAFETY: no preconditions.
        let raw = unsafe { sys::mi_heap_new() };
        NonNull::new(raw).map(|raw| Self { raw }).ok_or(OutOfMemory)
    }

    /// A new heap that allocates only from `arena`.
    pub fn in_arena(arena: ArenaId) -> Result<Self, OutOfMemory> {
        // SAFETY: `arena` came from `Arena::manage`, so it names a managed arena.
        let raw = unsafe { sys::mi_heap_new_in_arena(arena.as_raw()) };
        NonNull::new(raw).map(|raw| Self { raw }).ok_or(OutOfMemory)
    }

    /// Uninitialized storage for `layout` from this heap, or `None` on out-of-memory. Release it
    /// with [`free`](crate::free) from any thread, or by [`destroy`](Self::destroy).
    #[must_use]
    pub fn alloc(&self, layout: Layout) -> Option<NonNull<u8>> {
        let ptr = if is_small(layout) {
            // SAFETY: `self.raw` is a live heap and the size is within `SMALL_SIZE_MAX`.
            unsafe { sys::mi_heap_malloc_small(self.raw.as_ptr(), layout.size()) }
        } else {
            // SAFETY: `self.raw` is a live heap; the layout has a power-of-two alignment.
            unsafe { sys::mi_heap_malloc_aligned(self.raw.as_ptr(), layout.size(), layout.align()) }
        };
        non_null(ptr)
    }

    /// As [`alloc`](Self::alloc), zero-filled.
    #[must_use]
    pub fn alloc_zeroed(&self, layout: Layout) -> Option<NonNull<u8>> {
        let ptr = if layout.align() <= WORD_ALIGN {
            // SAFETY: `self.raw` is a live heap.
            unsafe { sys::mi_heap_zalloc(self.raw.as_ptr(), layout.size()) }
        } else {
            // SAFETY: `self.raw` is a live heap; the layout has a power-of-two alignment.
            unsafe { sys::mi_heap_zalloc_aligned(self.raw.as_ptr(), layout.size(), layout.align()) }
        };
        non_null(ptr)
    }

    /// Resizes a block of this heap, moving it if needed; `None` leaves it valid.
    ///
    /// # Safety
    ///
    /// `ptr` must be a live block of this heap allocated with `layout`'s alignment.
    #[must_use]
    pub unsafe fn realloc(&self, ptr: NonNull<u8>, align: usize, new_size: usize) -> Option<NonNull<u8>> {
        // SAFETY: the caller guarantees `ptr` is a live block of this heap; `align` is a power of two.
        non_null(unsafe { sys::mi_heap_realloc_aligned(self.raw.as_ptr(), ptr.as_ptr().cast(), new_size, align) })
    }

    /// Whether `ptr` points into a block of this heap.
    #[must_use]
    pub fn contains(&self, ptr: *const u8) -> bool {
        // SAFETY: `self.raw` is live; the call only inspects `ptr` as an address.
        unsafe { sys::mi_heap_contains(self.raw.as_ptr(), ptr.cast()) }
    }

    /// Returns free pages of this heap to the OS (all of them when `force`).
    pub fn collect(&self, force: bool) {
        // SAFETY: `self.raw` is a live heap.
        unsafe { sys::mi_heap_collect(self.raw.as_ptr(), force) }
    }

    /// This thread's [`Theap`] for the heap, created on first use.
    #[must_use]
    pub fn theap(&self) -> Theap {
        // SAFETY: `self.raw` is a live heap.
        let raw = unsafe { sys::mi_heap_theap(self.raw.as_ptr()) };
        Theap::from_raw(raw)
    }

    /// Frees every block of the heap, live or not, and the heap itself.
    ///
    /// # Safety
    ///
    /// No pointer allocated from this heap may be used afterwards, and no other thread may be
    /// using the heap.
    pub unsafe fn destroy(self) {
        let raw = self.raw.as_ptr();
        core::mem::forget(self);
        // SAFETY: `raw` is a live heap that nobody uses; the caller accepts losing its blocks.
        unsafe { sys::mi_heap_destroy(raw) }
    }
}

impl Drop for Heap {
    /// Hands the live blocks to the main heap, so pointers into them stay valid.
    fn drop(&mut self) {
        // SAFETY: `self.raw` is a live heap that this value owns.
        unsafe { sys::mi_heap_delete(self.raw.as_ptr()) }
    }
}

/// A thread's part of a heap, for allocating without the thread-local lookup. Not `Send`.
#[derive(Debug, Clone, Copy)]
pub struct Theap {
    raw: NonNull<sys::mi_theap_t>,
    /// Ties the value to its thread.
    _not_send: PhantomData<*mut ()>,
}

impl Theap {
    fn from_raw(raw: *mut sys::mi_theap_t) -> Self {
        Self { raw: NonNull::new(raw).expect("mimalloc returns a theap for a live heap"), _not_send: PhantomData }
    }

    /// The calling thread's default theap: fetch it once per thread and keep it.
    #[must_use]
    pub fn current() -> Self {
        // SAFETY: no preconditions.
        Self::from_raw(unsafe { sys::mi_theap_get_default() })
    }

    /// Uninitialized storage for `layout`, or `None` on out-of-memory.
    #[must_use]
    pub fn alloc(&self, layout: Layout) -> Option<NonNull<u8>> {
        let raw = self.raw.as_ptr();
        let (size, align) = (layout.size(), layout.align());
        let ptr = if is_small(layout) {
            // SAFETY: `raw` is a live theap of the calling thread (the type is `!Send`), and the size is within `SMALL_SIZE_MAX`.
            unsafe { sys::mi_theap_malloc_small(raw, size) }
        } else if align <= WORD_ALIGN {
            // SAFETY: `raw` is a live theap of the calling thread (the type is `!Send`).
            unsafe { sys::mi_theap_malloc(raw, size) }
        } else {
            // SAFETY: `raw` is a live theap of the calling thread (the type is `!Send`), and `align` is a power of two.
            unsafe { sys::mi_theap_malloc_aligned(raw, size, align) }
        };
        non_null(ptr)
    }

    /// As [`alloc`](Self::alloc), zero-filled.
    #[must_use]
    pub fn alloc_zeroed(&self, layout: Layout) -> Option<NonNull<u8>> {
        let raw = self.raw.as_ptr();
        let (size, align) = (layout.size(), layout.align());
        let ptr = if is_small(layout) {
            // SAFETY: `raw` is a live theap of the calling thread (the type is `!Send`), and the size is within `SMALL_SIZE_MAX`.
            unsafe { sys::mi_theap_zalloc_small(raw, size) }
        } else if align <= WORD_ALIGN {
            // SAFETY: `raw` is a live theap of the calling thread (the type is `!Send`).
            unsafe { sys::mi_theap_zalloc(raw, size) }
        } else {
            // SAFETY: `raw` is a live theap of the calling thread (the type is `!Send`), and `align` is a power of two.
            unsafe { sys::mi_theap_zalloc_aligned(raw, size, align) }
        };
        non_null(ptr)
    }

    /// Returns free pages of this theap to the OS (all of them when `force`).
    pub fn collect(&self, force: bool) {
        // SAFETY: `self.raw` is a live theap of this thread.
        unsafe { sys::mi_theap_collect(self.raw.as_ptr(), force) }
    }
}

#[cfg(all(test, mimalloc_linked, not(miri)))]
mod tests {
    use super::*;

    fn layout(size: usize, align: usize) -> Layout {
        Layout::from_size_align(size, align).unwrap()
    }

    #[test]
    fn heap_blocks_are_aligned_zeroed_and_owned() {
        let heap = Heap::new().unwrap();
        for (size, align) in [(8, 8), (100, 8), (24, 16), (1024, 64), (5000, 4096)] {
            let block = heap.alloc_zeroed(layout(size, align)).unwrap();
            assert_eq!(block.as_ptr() as usize % align, 0, "{size}/{align}");
            // SAFETY: the block is `size` bytes, zero-filled and live.
            assert!(unsafe { core::slice::from_raw_parts(block.as_ptr(), size) }.iter().all(|b| *b == 0));
            assert!(heap.contains(block.as_ptr()));
            crate::free(block);
        }
        heap.collect(false);
    }

    #[test]
    fn heap_realloc_keeps_contents() {
        let heap = Heap::new().unwrap();
        let block = heap.alloc(layout(10, 8)).unwrap();
        // SAFETY: the block is 10 bytes and live.
        unsafe { block.as_ptr().write_bytes(0x5a, 10) };
        // SAFETY: `block` is a live block of `heap` with alignment 8.
        let bigger = unsafe { heap.realloc(block, 8, 10_000) }.unwrap();
        // SAFETY: the first 10 bytes were preserved.
        assert!(unsafe { core::slice::from_raw_parts(bigger.as_ptr(), 10) }.iter().all(|b| *b == 0x5a));
        crate::free(bigger);
    }

    #[test]
    fn destroy_frees_everything() {
        let heap = Heap::new().unwrap();
        let _ = heap.alloc(layout(64, 8)).unwrap();
        // SAFETY: the pointer is not used again and no other thread uses the heap.
        unsafe { heap.destroy() };
    }

    #[test]
    fn blocks_are_freed_on_another_thread() {
        let heap = Heap::new().unwrap();
        let block = heap.alloc(layout(4096, 8)).unwrap().as_ptr() as usize;
        std::thread::spawn(move || {
            crate::free(NonNull::new(block as *mut u8).unwrap());
        })
        .join()
        .unwrap();
    }

    #[test]
    fn theap_matches_the_plain_path() {
        let theap = Theap::current();
        let a = theap.alloc(layout(64, 8)).unwrap();
        let b = theap.alloc_zeroed(layout(5000, 32)).unwrap();
        assert_eq!(b.as_ptr() as usize % 32, 0);
        crate::free(a);
        crate::free(b);
        theap.collect(false);
    }
}
