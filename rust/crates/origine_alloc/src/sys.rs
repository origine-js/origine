//! The mimalloc C ABI (mimalloc 3.6.0 plus the patches in `lib/mimalloc/patches`).
//!
//! Raw declarations, grouped like `mimalloc.h`; use the safe layer in the crate root unless you
//! need something it does not cover. Every allocating function returns null on out-of-memory and
//! caller-owned storage that `mi_free` (or the heap's destruction) releases.
//!
//! Functions that take no pointers and cannot break memory safety are declared `safe`.

#![allow(non_camel_case_types, reason = "names follow mimalloc.h")]

use core::ffi::{c_char, c_int, c_long, c_void};
use core::marker::{PhantomData, PhantomPinned};

/// Largest request of the `*_small` functions (`MI_SMALL_SIZE_MAX`).
pub const SMALL_SIZE_MAX: usize = 128 * size_of::<usize>();

macro_rules! opaque {
    ($(#[$meta:meta])* $name:ident) => {
        $(#[$meta])*
        #[repr(C)]
        pub struct $name {
            _data: [u8; 0],
            _marker: PhantomData<(*mut u8, PhantomPinned)>,
        }
    };
}

opaque!(
    /// `mi_heap_t`.
    mi_heap_t
);
opaque!(
    /// `mi_theap_t`.
    mi_theap_t
);

/// `mi_arena_id_t`: null is "no arena".
pub type mi_arena_id_t = *mut c_void;
/// `mi_output_fun`.
pub type mi_output_fun = unsafe extern "C" fn(msg: *const c_char, arg: *mut c_void);

unsafe extern "C" {
    // ---- Standard malloc interface ----
    pub fn mi_malloc(size: usize) -> *mut c_void;
    pub fn mi_zalloc(size: usize) -> *mut c_void;
    pub fn mi_calloc(count: usize, size: usize) -> *mut c_void;
    pub fn mi_realloc(p: *mut c_void, newsize: usize) -> *mut c_void;
    pub fn mi_expand(p: *mut c_void, newsize: usize) -> *mut c_void;
    pub fn mi_free(p: *mut c_void);
    pub fn mi_usable_size(p: *const c_void) -> usize;
    pub safe fn mi_good_size(size: usize) -> usize;

    // ---- Fast paths ----
    pub fn mi_malloc_small(size: usize) -> *mut c_void;
    pub fn mi_zalloc_small(size: usize) -> *mut c_void;
    pub fn mi_free_size(p: *mut c_void, size: usize);
    pub fn mi_free_size_aligned(p: *mut c_void, size: usize, alignment: usize);
    pub fn mi_free_aligned(p: *mut c_void, alignment: usize);

    // ---- Aligned allocation (`alignment` follows `size`; a power of two) ----
    pub fn mi_malloc_aligned(size: usize, alignment: usize) -> *mut c_void;
    pub fn mi_zalloc_aligned(size: usize, alignment: usize) -> *mut c_void;
    pub fn mi_realloc_aligned(p: *mut c_void, newsize: usize, alignment: usize) -> *mut c_void;

    // ---- Heaps (first-class in mimalloc 3: usable from any thread) ----
    pub fn mi_heap_new() -> *mut mi_heap_t;
    pub fn mi_heap_new_in_arena(arena_id: mi_arena_id_t) -> *mut mi_heap_t;
    pub fn mi_heap_delete(heap: *mut mi_heap_t);
    pub fn mi_heap_destroy(heap: *mut mi_heap_t);
    pub fn mi_heap_main() -> *mut mi_heap_t;
    pub fn mi_heap_collect(heap: *mut mi_heap_t, force: bool);
    pub fn mi_heap_contains(heap: *const mi_heap_t, p: *const c_void) -> bool;
    pub fn mi_heap_of(p: *const c_void) -> *mut mi_heap_t;
    pub fn mi_heap_malloc(heap: *mut mi_heap_t, size: usize) -> *mut c_void;
    pub fn mi_heap_zalloc(heap: *mut mi_heap_t, size: usize) -> *mut c_void;
    pub fn mi_heap_malloc_small(heap: *mut mi_heap_t, size: usize) -> *mut c_void;
    pub fn mi_heap_malloc_aligned(heap: *mut mi_heap_t, size: usize, alignment: usize) -> *mut c_void;
    pub fn mi_heap_zalloc_aligned(heap: *mut mi_heap_t, size: usize, alignment: usize) -> *mut c_void;
    pub fn mi_heap_realloc_aligned(heap: *mut mi_heap_t, p: *mut c_void, newsize: usize, alignment: usize) -> *mut c_void;
    pub fn mi_heap_theap(heap: *mut mi_heap_t) -> *mut mi_theap_t;

    // ---- Thread-local heaps ("theaps"): only the creating thread may allocate from one ----
    pub fn mi_theap_get_default() -> *mut mi_theap_t;
    pub fn mi_theap_set_default(theap: *mut mi_theap_t) -> *mut mi_theap_t;
    pub fn mi_theap_collect(theap: *mut mi_theap_t, force: bool);
    pub fn mi_theap_malloc(theap: *mut mi_theap_t, size: usize) -> *mut c_void;
    pub fn mi_theap_zalloc(theap: *mut mi_theap_t, size: usize) -> *mut c_void;
    pub fn mi_theap_malloc_small(theap: *mut mi_theap_t, size: usize) -> *mut c_void;
    pub fn mi_theap_zalloc_small(theap: *mut mi_theap_t, size: usize) -> *mut c_void;
    pub fn mi_theap_malloc_aligned(theap: *mut mi_theap_t, size: usize, alignment: usize) -> *mut c_void;
    pub fn mi_theap_zalloc_aligned(theap: *mut mi_theap_t, size: usize, alignment: usize) -> *mut c_void;
    pub fn mi_theap_realloc(theap: *mut mi_theap_t, p: *mut c_void, newsize: usize) -> *mut c_void;

    // ---- Arenas ----
    pub safe fn mi_reserve_os_memory(size: usize, commit: bool, allow_large: bool) -> c_int;
    pub safe fn mi_reserve_huge_os_pages_at(pages: usize, numa_node: c_int, timeout_msecs: usize) -> c_int;
    pub fn mi_manage_os_memory_ex(
        start: *mut c_void,
        size: usize,
        is_committed: bool,
        is_pinned: bool,
        is_zero: bool,
        numa_node: c_int,
        exclusive: bool,
        arena_id: *mut mi_arena_id_t,
    ) -> bool;
    pub fn mi_arena_contains(arena_id: mi_arena_id_t, p: *const c_void) -> bool;
    pub fn mi_arena_area(arena_id: mi_arena_id_t, size: *mut usize) -> *mut c_void;
    pub safe fn mi_arena_min_alignment() -> usize;
    pub safe fn mi_arena_min_size() -> usize;
    pub safe fn mi_arena_max_object_size() -> usize;
    /// Enabled by `lib/mimalloc/patches/0001-enable-arena-unload.patch`.
    pub fn mi_arena_unload(arena_id: mi_arena_id_t, base: *mut *mut c_void, accessed_size: *mut usize, full_size: *mut usize) -> bool;
    pub safe fn mi_arenas_purge();

    // ---- Process and thread ----
    pub safe fn mi_version() -> c_int;
    pub safe fn mi_collect(force: bool);
    pub safe fn mi_thread_init();
    pub fn mi_thread_done();
    pub fn mi_process_info(
        elapsed_msecs: *mut usize,
        user_msecs: *mut usize,
        system_msecs: *mut usize,
        current_rss: *mut usize,
        peak_rss: *mut usize,
        current_commit: *mut usize,
        peak_commit: *mut usize,
        page_faults: *mut usize,
    );

    // ---- Statistics ----
    pub safe fn mi_stats_reset();
    pub safe fn mi_stats_merge();
    pub fn mi_stats_get_json(buf_size: usize, buf: *mut c_char) -> *mut c_char;
    pub fn mi_stats_print_out(out: Option<mi_output_fun>, arg: *mut c_void);
    pub fn mi_options_print_out(out: Option<mi_output_fun>, arg: *mut c_void);

    // ---- Options (`mi_option_t` is a C int) ----
    pub safe fn mi_option_is_enabled(option: c_int) -> bool;
    pub safe fn mi_option_set_enabled(option: c_int, enable: bool);
    pub safe fn mi_option_set_enabled_default(option: c_int, enable: bool);
    pub safe fn mi_option_get(option: c_int) -> c_long;
    pub safe fn mi_option_get_clamp(option: c_int, min: c_long, max: c_long) -> c_long;
    pub safe fn mi_option_get_size(option: c_int) -> usize;
    pub safe fn mi_option_set(option: c_int, value: c_long);
    pub safe fn mi_option_set_default(option: c_int, value: c_long);
}
