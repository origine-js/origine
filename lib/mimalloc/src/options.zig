//! mimalloc's runtime options (`mi_option_t`), typed.
//!
//! Options read their initial value from the environment (`MIMALLOC_<NAME>`, for example
//! `MIMALLOC_PURGE_DELAY=0`) the first time they are queried, unless `set` or `setDefault` ran
//! first. Set options before the first allocation that matters (ideally first thing in `main`):
//! some, like `reserve_os_memory`, only act at startup. `Tuning` bundles the ones the upstream
//! "getting the best performance" guide mentions.
const std = @import("std");
const c = @import("c.zig");

/// The numbers are `mi_option_e` from mimalloc 3.6.0; `tests/abi.c` fails the test build if they
/// drift. Options marked deprecated are kept so the numbering stays contiguous; they do nothing.
pub const Option = enum(c_int) {
    /// Print error messages
    show_errors = 0,
    /// Print statistics on termination
    show_stats = 1,
    /// Print verbose messages
    verbose = 2,
    deprecated_eager_commit = 3,
    /// Eager commit arenas? Use 2 to enable just on overcommit systems (=2)
    arena_eager_commit = 4,
    /// Should a memory purge decommit? (=1). Set to 0 to use memory reset on a purge (instead of decommit)
    purge_decommits = 5,
    /// Allow use of large (2 or 4 MiB) OS pages, implies eager commit.
    allow_large_os_pages = 6,
    /// Reserve N huge OS pages (1GiB pages) at startup
    reserve_huge_os_pages = 7,
    /// Reserve huge OS pages at a specific NUMA node
    reserve_huge_os_pages_at = 8,
    /// Reserve specified amount of OS memory in an arena at startup (internally, this value is in KiB; use 'mi_option_get_size')
    reserve_os_memory = 9,
    deprecated_segment_cache = 10,
    deprecated_page_reset = 11,
    deprecated_abandoned_page_purge = 12,
    deprecated_segment_reset = 13,
    deprecated_eager_commit_delay = 14,
    /// Memory purging is delayed by N milli seconds; use 0 for immediate purging or -1 for no purging at all. (=10)
    purge_delay = 15,
    /// 0 = use all available numa nodes, otherwise use at most N nodes.
    use_numa_nodes = 16,
    /// 1 = do not use OS memory for allocation (but only programmatically reserved arenas)
    disallow_os_alloc = 17,
    /// Tag used for OS logging (macOS only for now) (=100)
    os_tag = 18,
    /// Issue at most N error messages
    max_errors = 19,
    /// Issue at most N warning messages
    max_warnings = 20,
    /// Max. percentage of the abandoned segments can be reclaimed per try (=10%)
    deprecated_max_segment_reclaim = 21,
    /// If set, release all memory on exit; sometimes used for dynamic unloading but can be unsafe
    destroy_on_exit = 22,
    /// Initial memory size for arena reservation (= 1 GiB on 64-bit) (internally, this value is in KiB; use 'mi_option_get_size')
    arena_reserve = 23,
    /// Multiplier for 'purge_delay' for the purging delay for arenas (=10)
    arena_purge_mult = 24,
    deprecated_purge_extend_delay = 25,
    /// 1 = do not use arena's for allocation (except if using specific arena id's)
    disallow_arena_alloc = 26,
    /// Retry on out-of-memory for N milli seconds (=400), set to 0 to disable retries. (only on windows)
    retry_on_oom = 27,
    /// Allow visiting theap blocks from abandoned threads (=0)
    deprecated_visit_abandoned = 28,
    /// Only used when building with MI_GUARDED: minimal rounded object size for guarded objects (=0)
    guarded_min = 29,
    /// Only used when building with MI_GUARDED: maximal rounded object size for guarded objects (=0)
    guarded_max = 30,
    /// Disregard minimal alignment requirement to always place guarded blocks exactly in front of a guard page (=0)
    unsafe_guarded_precise = 31,
    /// Guard an object in the min/max range about every N requested bytes (=0)
    guarded_sample_rate = 32,
    /// Can be set to allow for a (more) deterministic re-execution when a guard page is triggered (=0)
    guarded_sample_seed = 33,
    /// Collect theaps every N (=10000) generic allocation calls
    generic_collect = 34,
    /// Heap-creation default for reclaim on free: -1 disallow, 0 originating theap only, 1 allow across theaps
    page_reclaim_on_free = 35,
    /// Retain N full (small) pages per size class (=2)
    page_full_retain = 36,
    /// Max candidate pages to consider for allocation (=4)
    page_max_candidates = 37,
    /// Max user space virtual address bits to consider (=48)
    max_vabits = 38,
    /// Commit the full pagemap (to always catch invalid pointer uses) (=0)
    pagemap_commit = 39,
    /// Commit page memory on-demand
    page_commit_on_demand = 40,
    /// Don't reclaim pages of the same originating theap if we already own N pages (in that size class) (=-1 (unlimited))
    page_max_reclaim = 41,
    /// Don't reclaim pages across threads if we already own N pages (in that size class) (=32)
    page_cross_thread_max_reclaim = 42,
    /// Allow transparent huge pages? (=1) (on Android =0 by default). Set to 0 to disable THP for the process.
    allow_thp = 43,
    /// Set minimal purge size (in KiB) (=0). By default set to either 64 or 2048 if THP is enabled.
    arena_purge_min_size = 44,
    /// Set maximal object size that can be allocated in an arena (in KiB) (=2GiB on 64-bit).
    arena_max_object_size = 45,
    /// Experimental: associate local numa node with an initial arena allocation
    arena_is_numa_local = 46,
    /// On each theap collection, the theap stats are merged automatically with the parent heap
    stats_merge_on_collect = 47,
    /// Number of allocated bytes between automatic snapshots of the heap profiler (=1GiB)
    profile_alloc_interval = 48,
    /// Number of in-use bytes grown between automatic snapshots of the heap profiler (=0, disabled)
    profile_inuse_interval = 49,
    /// Number of seconds between automatic snapshots of the  heap profiler (=0, disabled)
    profile_time_interval = 50,
    /// Sample rate (in bytes) for heap profiler (=512 KiB)
    profile_sample_rate = 51,
    /// On a page stats update, merge theap stats into the parent heap if N bytes were freed/allocated; 0 disables (=512 KiB)
    stats_merge_threshold = 52,
    /// Ranges above this size are purged immediately
    arena_purge_immediate_size = 53,
    _,

    /// Pre-3.0 names that map to a current option.
    pub const large_os_pages: Option = .allow_large_os_pages;
    pub const eager_region_commit: Option = .arena_eager_commit;
    pub const reset_decommits: Option = .purge_decommits;
    pub const reset_delay: Option = .purge_delay;
    pub const limit_os_alloc: Option = .disallow_os_alloc;
    pub const minimal_purge_size: Option = .arena_purge_min_size;

    /// The option's current value (booleans are 0 or 1).
    pub fn get(option: Option) c_long {
        return c.mi_option_get(option);
    }

    /// The value clamped to `[min, max]`.
    pub fn getClamped(option: Option, min: c_long, max: c_long) c_long {
        return c.mi_option_get_clamp(option, min, max);
    }

    /// For options measured in KiB internally (`reserve_os_memory`, `arena_reserve`): the value in bytes.
    pub fn getSize(option: Option) usize {
        return c.mi_option_get_size(option);
    }

    pub fn isEnabled(option: Option) bool {
        return c.mi_option_is_enabled(option);
    }

    /// Sets the value, overriding the environment.
    pub fn set(option: Option, value: c_long) void {
        c.mi_option_set(option, value);
    }

    /// Sets the value only if neither the environment nor `set` already decided it.
    pub fn setDefault(option: Option, value: c_long) void {
        c.mi_option_set_default(option, value);
    }

    pub fn setEnabled(option: Option, enable: bool) void {
        c.mi_option_set_enabled(option, enable);
    }

    pub fn setEnabledDefault(option: Option, enable: bool) void {
        c.mi_option_set_enabled_default(option, enable);
    }
};

/// The upstream performance recommendations that are options. Fields left null keep mimalloc's
/// (or the environment's) value; `apply` uses the `*Default` setters, so an explicit
/// `MIMALLOC_*` variable still wins and operators can override a built-in tuning.
pub const Tuning = struct {
    /// Use 2 MiB/4 MiB OS pages (`allow_large_os_pages`). Faster for allocation-heavy programs,
    /// but pins memory and may need OS configuration.
    large_os_pages: ?bool = null,
    /// Reserve this many 1 GiB huge OS pages at startup (`reserve_huge_os_pages`); Linux only.
    huge_os_pages: ?usize = null,
    /// Transparent huge pages (`allow_thp`): `false` can noticeably reduce RSS.
    transparent_huge_pages: ?bool = null,
    /// Delay before freed memory is returned to the OS, in milliseconds (`purge_delay`). 0 is
    /// immediate (lowest RSS), -1 never (fastest, highest RSS); mimalloc's default is 10.
    purge_delay_ms: ?i32 = null,
    /// Memory to reserve in an arena at startup, in bytes (`reserve_os_memory`).
    reserve_bytes: ?usize = null,

    /// Applies the non-null fields as defaults.
    pub fn apply(tuning: Tuning) void {
        if (tuning.large_os_pages) |on| Option.allow_large_os_pages.setEnabledDefault(on);
        if (tuning.huge_os_pages) |pages| Option.reserve_huge_os_pages.setDefault(@intCast(pages));
        if (tuning.transparent_huge_pages) |on| Option.allow_thp.setEnabledDefault(on);
        if (tuning.purge_delay_ms) |ms| Option.purge_delay.setDefault(ms);
        // Stored in KiB.
        if (tuning.reserve_bytes) |bytes| Option.reserve_os_memory.setDefault(@intCast(bytes / 1024));
    }
};

test "Tuning.apply leaves unset fields alone" {
    const before = Option.purge_delay.get();
    (Tuning{}).apply();
    try std.testing.expectEqual(before, Option.purge_delay.get());
}

test "options round-trip" {
    const original = Option.max_warnings.get();
    defer Option.max_warnings.set(original);
    Option.max_warnings.set(7);
    try std.testing.expectEqual(@as(c_long, 7), Option.max_warnings.get());
    try std.testing.expectEqual(@as(c_long, 3), Option.max_warnings.getClamped(0, 3));
}
