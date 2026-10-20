//! A `GlobalAlloc` that forwards to mimalloc's `mi_*` API.
//!
//! The mimalloc library is built and linked by the Zig build (it only defines `mi_*`; libc's
//! `malloc` and the macOS zones are not overridden), so Rust and Zig/V8 share one allocator
//! implementation. This crate declares the extern symbols and links nothing itself: a binary or
//! test that installs [`MiMalloc`] as its `#[global_allocator]` must link mimalloc.
//!
//! Under Miri the allocator is not used (Miri cannot call foreign allocators); install it with
//! `#[cfg(not(miri))]`.

use std::alloc::{GlobalAlloc, Layout};
use std::ffi::c_void;

unsafe extern "C" {
    fn mi_malloc_aligned(size: usize, alignment: usize) -> *mut c_void;
    fn mi_zalloc_aligned(size: usize, alignment: usize) -> *mut c_void;
    fn mi_realloc_aligned(p: *mut c_void, newsize: usize, alignment: usize) -> *mut c_void;
    fn mi_free(p: *mut c_void);
}

/// Global allocator backed by mimalloc.
#[derive(Debug, Default, Clone, Copy)]
pub struct MiMalloc;

// SAFETY: every method forwards to the matching mimalloc function with the layout's size and
// alignment, which satisfies the `GlobalAlloc` contract (alignment is a power of two, blocks are
// valid until freed, `realloc` preserves contents up to the smaller size). mimalloc is
// thread-safe.
unsafe impl GlobalAlloc for MiMalloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        // SAFETY: `layout.size()` is non-zero (GlobalAlloc contract) and `align()` a power of two.
        unsafe { mi_malloc_aligned(layout.size(), layout.align()).cast() }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        // SAFETY: as for `alloc`.
        unsafe { mi_zalloc_aligned(layout.size(), layout.align()).cast() }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, _layout: Layout) {
        // SAFETY: `ptr` was returned by this allocator (GlobalAlloc contract) and is freed once.
        unsafe { mi_free(ptr.cast()) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        // SAFETY: `ptr` was allocated by this allocator with `layout`; `new_size` is non-zero and
        // fits `isize` when rounded up to the alignment (caller contract).
        unsafe { mi_realloc_aligned(ptr.cast(), new_size, layout.align()).cast() }
    }
}
