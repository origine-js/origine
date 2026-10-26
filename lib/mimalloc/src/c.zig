//! The mimalloc C ABI as `extern` declarations, grouped like `mimalloc.h` (3.6.0 plus the
//! patches in `../patches`). Nothing here checks anything: use the wrappers in `mimalloc.zig`.
//!
//! Every allocating function returns caller-owned storage released with `mi_free` (or the
//! heap's `destroy`); null means out of memory. Only the functions the wrappers use are
//! declared, so this file doubles as the list of what the Zig side depends on.
const mi = @import("mimalloc.zig");

// ---- Standard malloc interface ----
pub extern fn mi_malloc(size: usize) ?*anyopaque;
pub extern fn mi_zalloc(size: usize) ?*anyopaque;
pub extern fn mi_calloc(count: usize, size: usize) ?*anyopaque;
pub extern fn mi_realloc(p: ?*anyopaque, newsize: usize) ?*anyopaque;
pub extern fn mi_expand(p: ?*anyopaque, newsize: usize) ?*anyopaque;
pub extern fn mi_free(p: ?*anyopaque) void;
pub extern fn mi_strdup(s: [*:0]const u8) ?[*:0]u8;
pub extern fn mi_usable_size(p: ?*const anyopaque) usize;
pub extern fn mi_good_size(size: usize) usize;

// ---- Fast paths ----
pub extern fn mi_malloc_small(size: usize) ?*anyopaque;
pub extern fn mi_zalloc_small(size: usize) ?*anyopaque;
pub extern fn mi_free_size(p: ?*anyopaque, size: usize) void;
pub extern fn mi_free_size_aligned(p: ?*anyopaque, size: usize, alignment: usize) void;
pub extern fn mi_free_aligned(p: ?*anyopaque, alignment: usize) void;

// ---- Aligned allocation (`alignment` follows `size`; a power of two) ----
pub extern fn mi_malloc_aligned(size: usize, alignment: usize) ?*anyopaque;
pub extern fn mi_zalloc_aligned(size: usize, alignment: usize) ?*anyopaque;
pub extern fn mi_realloc_aligned(p: ?*anyopaque, newsize: usize, alignment: usize) ?*anyopaque;

// ---- Heaps (first-class in mimalloc 3: usable from any thread) ----
pub extern fn mi_heap_new() ?*mi.Heap;
pub extern fn mi_heap_new_in_arena(arena_id: mi.Arena.Id) ?*mi.Heap;
pub extern fn mi_heap_delete(heap: *mi.Heap) void;
pub extern fn mi_heap_destroy(heap: *mi.Heap) void;
pub extern fn mi_heap_main() *mi.Heap;
pub extern fn mi_heap_collect(heap: *mi.Heap, force: bool) void;
pub extern fn mi_heap_contains(heap: *const mi.Heap, p: ?*const anyopaque) bool;
pub extern fn mi_heap_of(p: ?*const anyopaque) ?*mi.Heap;
pub extern fn mi_heap_malloc(heap: *mi.Heap, size: usize) ?*anyopaque;
pub extern fn mi_heap_zalloc(heap: *mi.Heap, size: usize) ?*anyopaque;
pub extern fn mi_heap_malloc_small(heap: *mi.Heap, size: usize) ?*anyopaque;
pub extern fn mi_heap_malloc_aligned(heap: *mi.Heap, size: usize, alignment: usize) ?*anyopaque;
pub extern fn mi_heap_zalloc_aligned(heap: *mi.Heap, size: usize, alignment: usize) ?*anyopaque;
pub extern fn mi_heap_realloc_aligned(heap: *mi.Heap, p: ?*anyopaque, newsize: usize, alignment: usize) ?*anyopaque;
pub extern fn mi_heap_theap(heap: *mi.Heap) *mi.Theap;

// ---- Thread-local heaps ("theaps"): only the creating thread may allocate from one ----
pub extern fn mi_theap_get_default() *mi.Theap;
pub extern fn mi_theap_set_default(theap: *mi.Theap) *mi.Theap;
pub extern fn mi_theap_collect(theap: *mi.Theap, force: bool) void;
pub extern fn mi_theap_malloc(theap: *mi.Theap, size: usize) ?*anyopaque;
pub extern fn mi_theap_zalloc(theap: *mi.Theap, size: usize) ?*anyopaque;
pub extern fn mi_theap_malloc_small(theap: *mi.Theap, size: usize) ?*anyopaque;
pub extern fn mi_theap_zalloc_small(theap: *mi.Theap, size: usize) ?*anyopaque;
pub extern fn mi_theap_malloc_aligned(theap: *mi.Theap, size: usize, alignment: usize) ?*anyopaque;
pub extern fn mi_theap_zalloc_aligned(theap: *mi.Theap, size: usize, alignment: usize) ?*anyopaque;
pub extern fn mi_theap_realloc(theap: *mi.Theap, p: ?*anyopaque, newsize: usize) ?*anyopaque;

// ---- Arenas ----
pub extern fn mi_reserve_os_memory(size: usize, commit: bool, allow_large: bool) c_int;
pub extern fn mi_reserve_huge_os_pages_at(pages: usize, numa_node: c_int, timeout_msecs: usize) c_int;
pub extern fn mi_manage_os_memory_ex(start: ?*anyopaque, size: usize, is_committed: bool, is_pinned: bool, is_zero: bool, numa_node: c_int, exclusive: bool, arena_id: *mi.Arena.Id) bool;
pub extern fn mi_arena_contains(arena_id: mi.Arena.Id, p: ?*const anyopaque) bool;
pub extern fn mi_arena_area(arena_id: mi.Arena.Id, size: ?*usize) ?*anyopaque;
pub extern fn mi_arena_min_alignment() usize;
pub extern fn mi_arena_min_size() usize;
pub extern fn mi_arena_max_object_size() usize;
/// Enabled by `patches/0001-enable-arena-unload.patch`.
pub extern fn mi_arena_unload(arena_id: mi.Arena.Id, base: ?*?*anyopaque, accessed_size: ?*usize, full_size: ?*usize) bool;
pub extern fn mi_arenas_purge() void;

// ---- Process and thread ----
pub extern fn mi_version() c_int;
pub extern fn mi_collect(force: bool) void;
pub extern fn mi_thread_init() void;
pub extern fn mi_thread_done() void;
pub extern fn mi_is_in_heap_region(p: ?*const anyopaque) bool;
pub extern fn mi_process_info(
    elapsed_msecs: ?*usize,
    user_msecs: ?*usize,
    system_msecs: ?*usize,
    current_rss: ?*usize,
    peak_rss: ?*usize,
    current_commit: ?*usize,
    peak_commit: ?*usize,
    page_faults: ?*usize,
) void;

// ---- Statistics ----
pub extern fn mi_stats_reset() void;
pub extern fn mi_stats_merge() void;
pub extern fn mi_stats_get_json(buf_size: usize, buf: ?[*]u8) ?[*:0]u8;
pub extern fn mi_stats_print_out(out: ?*const OutputFn, arg: ?*anyopaque) void;
pub extern fn mi_options_print_out(out: ?*const OutputFn, arg: ?*anyopaque) void;

pub const OutputFn = fn (msg: [*:0]const u8, arg: ?*anyopaque) callconv(.c) void;

// ---- Options (`mi.Option` is `mi_option_t`) ----
pub extern fn mi_option_is_enabled(option: mi.Option) bool;
pub extern fn mi_option_set_enabled(option: mi.Option, enable: bool) void;
pub extern fn mi_option_set_enabled_default(option: mi.Option, enable: bool) void;
pub extern fn mi_option_get(option: mi.Option) c_long;
pub extern fn mi_option_get_clamp(option: mi.Option, min: c_long, max: c_long) c_long;
pub extern fn mi_option_get_size(option: mi.Option) usize;
pub extern fn mi_option_set(option: mi.Option, value: c_long) void;
pub extern fn mi_option_set_default(option: mi.Option, value: c_long) void;
