//! mimalloc's runtime options, typed.
//!
//! An option takes its initial value from the environment (`MIMALLOC_<NAME>`, for example
//! `MIMALLOC_PURGE_DELAY=0`) the first time it is read, unless [`Setting::set`] or
//! [`Setting::set_default`] ran first. Set options before the allocations they should affect,
//! ideally first thing in `main`; some, like [`Setting::ReserveOsMemory`], only act at startup.
//! [`Tuning`] bundles the ones upstream's "getting the best performance" guide names.

use core::ffi::c_long;

use crate::sys;

/// A mimalloc option (`mi_option_t`). The numbers are those of mimalloc 3.6.0; the Zig side
/// checks them against the header at build time (`lib/mimalloc/tests/abi.c`) and a test here
/// pins a few. Variants named `Deprecated*` keep the numbering contiguous and do nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(i32)]
#[non_exhaustive]
pub enum Setting {
    /// Print error messages
    ShowErrors = 0,
    /// Print statistics on termination
    ShowStats = 1,
    /// Print verbose messages
    Verbose = 2,
    DeprecatedEagerCommit = 3,
    /// Eager commit arenas? Use 2 to enable just on overcommit systems (=2)
    ArenaEagerCommit = 4,
    /// Should a memory purge decommit? (=1). Set to 0 to use memory reset on a purge (instead of decommit)
    PurgeDecommits = 5,
    /// Allow use of large (2 or 4 MiB) OS pages, implies eager commit.
    AllowLargeOsPages = 6,
    /// Reserve N huge OS pages (1GiB pages) at startup
    ReserveHugeOsPages = 7,
    /// Reserve huge OS pages at a specific NUMA node
    ReserveHugeOsPagesAt = 8,
    /// Reserve specified amount of OS memory in an arena at startup (internally, this value is in KiB; use 'mi_option_get_size')
    ReserveOsMemory = 9,
    DeprecatedSegmentCache = 10,
    DeprecatedPageReset = 11,
    DeprecatedAbandonedPagePurge = 12,
    DeprecatedSegmentReset = 13,
    DeprecatedEagerCommitDelay = 14,
    /// Memory purging is delayed by N milli seconds; use 0 for immediate purging or -1 for no purging at all. (=10)
    PurgeDelay = 15,
    /// 0 = use all available numa nodes, otherwise use at most N nodes.
    UseNumaNodes = 16,
    /// 1 = do not use OS memory for allocation (but only programmatically reserved arenas)
    DisallowOsAlloc = 17,
    /// Tag used for OS logging (macOS only for now) (=100)
    OsTag = 18,
    /// Issue at most N error messages
    MaxErrors = 19,
    /// Issue at most N warning messages
    MaxWarnings = 20,
    /// Max. percentage of the abandoned segments can be reclaimed per try (=10%)
    DeprecatedMaxSegmentReclaim = 21,
    /// If set, release all memory on exit; sometimes used for dynamic unloading but can be unsafe
    DestroyOnExit = 22,
    /// Initial memory size for arena reservation (= 1 GiB on 64-bit) (internally, this value is in KiB; use 'mi_option_get_size')
    ArenaReserve = 23,
    /// Multiplier for 'purge_delay' for the purging delay for arenas (=10)
    ArenaPurgeMult = 24,
    DeprecatedPurgeExtendDelay = 25,
    /// 1 = do not use arena's for allocation (except if using specific arena id's)
    DisallowArenaAlloc = 26,
    /// Retry on out-of-memory for N milli seconds (=400), set to 0 to disable retries. (only on windows)
    RetryOnOom = 27,
    /// Allow visiting theap blocks from abandoned threads (=0)
    DeprecatedVisitAbandoned = 28,
    /// Only used when building with MI_GUARDED: minimal rounded object size for guarded objects (=0)
    GuardedMin = 29,
    /// Only used when building with MI_GUARDED: maximal rounded object size for guarded objects (=0)
    GuardedMax = 30,
    /// Disregard minimal alignment requirement to always place guarded blocks exactly in front of a guard page (=0)
    UnsafeGuardedPrecise = 31,
    /// Guard an object in the min/max range about every N requested bytes (=0)
    GuardedSampleRate = 32,
    /// Can be set to allow for a (more) deterministic re-execution when a guard page is triggered (=0)
    GuardedSampleSeed = 33,
    /// Collect theaps every N (=10000) generic allocation calls
    GenericCollect = 34,
    /// Heap-creation default for reclaim on free: -1 disallow, 0 originating theap only, 1 allow across theaps
    PageReclaimOnFree = 35,
    /// Retain N full (small) pages per size class (=2)
    PageFullRetain = 36,
    /// Max candidate pages to consider for allocation (=4)
    PageMaxCandidates = 37,
    /// Max user space virtual address bits to consider (=48)
    MaxVabits = 38,
    /// Commit the full pagemap (to always catch invalid pointer uses) (=0)
    PagemapCommit = 39,
    /// Commit page memory on-demand
    PageCommitOnDemand = 40,
    /// Don't reclaim pages of the same originating theap if we already own N pages (in that size class) (=-1 (unlimited))
    PageMaxReclaim = 41,
    /// Don't reclaim pages across threads if we already own N pages (in that size class) (=32)
    PageCrossThreadMaxReclaim = 42,
    /// Allow transparent huge pages? (=1) (on Android =0 by default). Set to 0 to disable THP for the process.
    AllowThp = 43,
    /// Set minimal purge size (in KiB) (=0). By default set to either 64 or 2048 if THP is enabled.
    ArenaPurgeMinSize = 44,
    /// Set maximal object size that can be allocated in an arena (in KiB) (=2GiB on 64-bit).
    ArenaMaxObjectSize = 45,
    /// Experimental: associate local numa node with an initial arena allocation
    ArenaIsNumaLocal = 46,
    /// On each theap collection, the theap stats are merged automatically with the parent heap
    StatsMergeOnCollect = 47,
    /// Number of allocated bytes between automatic snapshots of the heap profiler (=1GiB)
    ProfileAllocInterval = 48,
    /// Number of in-use bytes grown between automatic snapshots of the heap profiler (=0, disabled)
    ProfileInuseInterval = 49,
    /// Number of seconds between automatic snapshots of the  heap profiler (=0, disabled)
    ProfileTimeInterval = 50,
    /// Sample rate (in bytes) for heap profiler (=512 KiB)
    ProfileSampleRate = 51,
    /// On a page stats update, merge theap stats into the parent heap if N bytes were freed/allocated; 0 disables (=512 KiB)
    StatsMergeThreshold = 52,
    /// Ranges above this size are purged immediately
    ArenaPurgeImmediateSize = 53,
}

impl Setting {
    /// The option's current value (booleans are 0 or 1).
    #[must_use]
    pub fn get(self) -> c_long {
        sys::mi_option_get(self as i32)
    }

    /// The value clamped to `min..=max`.
    #[must_use]
    pub fn get_clamped(self, min: c_long, max: c_long) -> c_long {
        sys::mi_option_get_clamp(self as i32, min, max)
    }

    /// For options measured in KiB internally (`ReserveOsMemory`, `ArenaReserve`): the value in bytes.
    #[must_use]
    pub fn get_size(self) -> usize {
        sys::mi_option_get_size(self as i32)
    }

    #[must_use]
    pub fn is_enabled(self) -> bool {
        sys::mi_option_is_enabled(self as i32)
    }

    /// Sets the value, overriding the environment.
    pub fn set(self, value: c_long) {
        sys::mi_option_set(self as i32, value);
    }

    /// Sets the value only if neither the environment nor [`Setting::set`] already decided it.
    pub fn set_default(self, value: c_long) {
        sys::mi_option_set_default(self as i32, value);
    }

    pub fn set_enabled(self, enable: bool) {
        sys::mi_option_set_enabled(self as i32, enable);
    }

    pub fn set_enabled_default(self, enable: bool) {
        sys::mi_option_set_enabled_default(self as i32, enable);
    }
}

/// The upstream performance recommendations that are options. Fields left `None` keep
/// mimalloc's (or the environment's) value; [`Tuning::apply`] uses the `*_default` setters, so an
/// explicit `MIMALLOC_*` variable still wins and operators can override a built-in tuning.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
#[non_exhaustive]
pub struct Tuning {
    /// Use 2 MiB/4 MiB OS pages (`AllowLargeOsPages`). Faster for allocation-heavy programs, but
    /// pins memory and may need OS configuration.
    pub large_os_pages: Option<bool>,
    /// Reserve this many 1 GiB huge OS pages at startup (`ReserveHugeOsPages`); Linux only.
    pub huge_os_pages: Option<usize>,
    /// Transparent huge pages (`AllowThp`): `false` can noticeably reduce RSS.
    pub transparent_huge_pages: Option<bool>,
    /// Delay before freed memory goes back to the OS, in milliseconds (`PurgeDelay`). 0 is
    /// immediate (lowest RSS), -1 never (fastest, highest RSS); mimalloc's default is 10.
    pub purge_delay_ms: Option<i32>,
    /// Memory to reserve in an arena at startup, in bytes (`ReserveOsMemory`).
    pub reserve_bytes: Option<usize>,
}

impl Tuning {
    /// Applies the fields that are set, as defaults.
    pub fn apply(&self) {
        if let Some(on) = self.large_os_pages {
            Setting::AllowLargeOsPages.set_enabled_default(on);
        }
        if let Some(pages) = self.huge_os_pages {
            Setting::ReserveHugeOsPages.set_default(c_long::try_from(pages).unwrap_or(c_long::MAX));
        }
        if let Some(on) = self.transparent_huge_pages {
            Setting::AllowThp.set_enabled_default(on);
        }
        if let Some(ms) = self.purge_delay_ms {
            Setting::PurgeDelay.set_default(c_long::from(ms));
        }
        if let Some(bytes) = self.reserve_bytes {
            // Stored in KiB.
            Setting::ReserveOsMemory.set_default(c_long::try_from(bytes / 1024).unwrap_or(c_long::MAX));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_match_the_header() {
        // A sample across the range; the Zig side asserts every one against `mimalloc.h`.
        assert_eq!(Setting::ShowErrors as i32, 0);
        assert_eq!(Setting::PurgeDelay as i32, 15);
        assert_eq!(Setting::DestroyOnExit as i32, 22);
        assert_eq!(Setting::AllowThp as i32, 43);
        assert_eq!(Setting::ArenaPurgeImmediateSize as i32, 53);
    }

    #[cfg(all(mimalloc_linked, not(miri)))]
    #[test]
    fn values_round_trip() {
        let original = Setting::MaxWarnings.get();
        Setting::MaxWarnings.set(7);
        assert_eq!(Setting::MaxWarnings.get(), 7);
        assert_eq!(Setting::MaxWarnings.get_clamped(0, 3), 3);
        Setting::MaxWarnings.set(original);
    }

    #[cfg(all(mimalloc_linked, not(miri)))]
    #[test]
    fn empty_tuning_changes_nothing() {
        let before = Setting::PurgeDelay.get();
        Tuning::default().apply();
        assert_eq!(Setting::PurgeDelay.get(), before);
    }
}
