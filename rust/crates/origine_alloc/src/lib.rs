//! Rust bindings for mimalloc 3.6.0, the allocator Rust, Zig and V8 share in this process.
//!
//! The mimalloc library is built and linked by the Zig build (`lib/mimalloc`; it only defines
//! `mi_*`: libc's `malloc` and the macOS zones are not overridden). This crate declares the
//! symbols and links nothing itself: a binary or test that uses it must link mimalloc. Under
//! Miri nothing here can run (Miri cannot call foreign allocators).
//!
//! Layers, from thin to convenient:
//! * [`sys`]: the raw C ABI;
//! * [`MiMalloc`]: a `#[global_allocator]`;
//! * [`Heap`] and [`Theap`]: heaps (any thread) and a thread's part of a heap, [`ArenaId`]
//!   for memory mimalloc is told to manage;
//! * [`Setting`] and [`Tuning`]: runtime options; [`stats`]: statistics.
//!
//! Following upstream's "getting the best performance": blocks up to
//! [`SMALL_SIZE_MAX`] bytes take the shorter `*_small` path, zeroed memory comes from the
//! zeroing calls rather than a `memset`, and [`Theap::current`] spares a runtime that keeps
//! per-thread state the thread-local lookup. Freeing always uses plain `mi_free`: the sized
//! `mi_free_size` fast path is only valid for the exact allocation size, which `realloc` and
//! in-place resizing do not preserve.

use core::alloc::{GlobalAlloc, Layout};
use core::ptr::NonNull;

mod arena;
mod heap;
mod option;
pub mod stats;
pub mod sys;

pub use arena::{ArenaId, ManageOptions, NotManageable, max_object_size, min_alignment, min_size, purge, reserve, reserve_huge_pages};
pub use heap::{Heap, OutOfMemory, Theap};
pub use option::{Setting, Tuning};
pub use stats::ProcessInfo;
pub use sys::SMALL_SIZE_MAX;

/// The linked mimalloc as `major * 10000 + minor * 100 + patch` (30600 is 3.6.0).
#[must_use]
pub fn version() -> u32 {
    u32::try_from(sys::mi_version()).unwrap_or(0)
}

/// Returns free memory to the OS (all of it when `force`).
pub fn collect(force: bool) {
    sys::mi_collect(force);
}

/// The size mimalloc would really reserve for a request of `size` bytes.
#[must_use]
pub fn good_size(size: usize) -> usize {
    sys::mi_good_size(size)
}

/// How many bytes are usable at `ptr`, at least what was asked for.
///
/// # Safety
///
/// `ptr` must be a live block from mimalloc.
#[must_use]
pub unsafe fn usable_size(ptr: NonNull<u8>) -> usize {
    // SAFETY: the caller guarantees `ptr` is a live mimalloc block.
    unsafe { sys::mi_usable_size(ptr.as_ptr().cast()) }
}

/// Frees a block from any heap, on any thread.
pub fn free(ptr: NonNull<u8>) {
    // SAFETY: blocks handed out by this crate's allocation functions are mimalloc blocks that the
    // owner frees once.
    unsafe { sys::mi_free(ptr.as_ptr().cast()) }
}

/// Alignment every block has without asking. Larger alignments take the `*_aligned` calls: a
/// small block is only naturally aligned up to a power of two of its size.
const WORD_ALIGN: usize = size_of::<usize>();

/// Global allocator backed by mimalloc.
#[derive(Debug, Default, Clone, Copy)]
pub struct MiMalloc;

// SAFETY: every method forwards to the matching mimalloc function with the layout's size and
// alignment, which satisfies the `GlobalAlloc` contract (alignment is a power of two, blocks are
// valid until freed, `realloc` preserves contents up to the smaller size). mimalloc is
// thread-safe. The small entry points are used only for sizes and alignments they accept.
unsafe impl GlobalAlloc for MiMalloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if layout.size() <= SMALL_SIZE_MAX && layout.align() <= WORD_ALIGN {
            // SAFETY: the size is within `SMALL_SIZE_MAX` (GlobalAlloc: non-zero).
            unsafe { sys::mi_malloc_small(layout.size()).cast() }
        } else {
            // SAFETY: `layout.size()` is non-zero and `align()` a power of two.
            unsafe { sys::mi_malloc_aligned(layout.size(), layout.align()).cast() }
        }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        if layout.size() <= SMALL_SIZE_MAX && layout.align() <= WORD_ALIGN {
            // SAFETY: as for `alloc`.
            unsafe { sys::mi_zalloc_small(layout.size()).cast() }
        } else {
            // SAFETY: as for `alloc`.
            unsafe { sys::mi_zalloc_aligned(layout.size(), layout.align()).cast() }
        }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, _layout: Layout) {
        // SAFETY: `ptr` was returned by this allocator (GlobalAlloc contract) and is freed once.
        unsafe { sys::mi_free(ptr.cast()) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        // SAFETY: `ptr` was allocated by this allocator with `layout`; `new_size` is non-zero and
        // fits `isize` when rounded up to the alignment (caller contract).
        unsafe { sys::mi_realloc_aligned(ptr.cast(), new_size, layout.align()).cast() }
    }
}

#[cfg(all(test, mimalloc_linked, not(miri)))]
mod tests {
    use super::*;

    #[test]
    fn the_linked_version_is_3_6_0() {
        assert_eq!(version(), 30600);
        assert!(good_size(100) >= 100);
    }

    #[test]
    #[allow(clippy::multiple_unsafe_ops_per_block, reason = "a test of the allocator's raw contract")]
    fn global_allocator_paths() {
        let mi = MiMalloc;
        for (size, align) in [(1, 1), (8, 8), (24, 16), (1024, 8), (1025, 8), (100, 64), (1 << 20, 4096)] {
            let layout = Layout::from_size_align(size, align).unwrap();
            // SAFETY: the layout has a non-zero size; every block is freed with its layout once.
            unsafe {
                let zeroed = mi.alloc_zeroed(layout);
                assert!(!zeroed.is_null());
                assert_eq!(zeroed as usize % align, 0, "{size}/{align}");
                assert!(core::slice::from_raw_parts(zeroed, size).iter().all(|b| *b == 0));
                zeroed.write_bytes(0xa5, size);
                let bigger = mi.realloc(zeroed, layout, size * 2);
                assert!(!bigger.is_null());
                assert_eq!(*bigger, 0xa5);
                mi.dealloc(bigger, Layout::from_size_align(size * 2, align).unwrap());
                let plain = mi.alloc(layout);
                assert!(!plain.is_null());
                assert!(usable_size(NonNull::new_unchecked(plain)) >= size);
                mi.dealloc(plain, layout);
            }
        }
    }
}
