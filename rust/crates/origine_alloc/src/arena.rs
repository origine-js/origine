//! Arenas: memory mimalloc allocates from beyond its own OS requests — reserved up front, huge
//! pages, or a range someone else owns (for example pages inside the V8 sandbox).

use core::ffi::c_void;
use core::ptr::NonNull;

use crate::heap::OutOfMemory;
use crate::sys;

/// A managed arena (`mi_arena_id_t`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ArenaId(NonNull<c_void>);

/// How [`ArenaId::manage`] treats the range.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ManageOptions {
    /// The range is already committed (readable and writable).
    pub committed: bool,
    /// mimalloc must never decommit or reset it.
    pub pinned: bool,
    /// The range is known to be zero-filled.
    pub zeroed: bool,
    /// NUMA node, or -1 for none.
    pub numa_node: i32,
    /// Only heaps made for this arena ([`Heap::in_arena`](crate::Heap::in_arena)) allocate from it.
    pub exclusive: bool,
}

impl Default for ManageOptions {
    fn default() -> Self {
        Self { committed: false, pinned: false, zeroed: false, numa_node: -1, exclusive: true }
    }
}

/// mimalloc refused the range (misaligned, too small or too large).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NotManageable;

impl core::fmt::Display for NotManageable {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str("mimalloc cannot manage this memory range")
    }
}

impl core::error::Error for NotManageable {}

impl ArenaId {
    pub(crate) fn as_raw(self) -> *mut c_void {
        self.0.as_ptr()
    }

    /// Hands `[start, start + len)` to mimalloc. The range must be aligned to
    /// [`min_alignment`], at least [`min_size`] bytes, and at most 16 GiB for [`unload`](Self::unload)
    /// to work.
    ///
    /// # Safety
    ///
    /// The memory must stay mapped and unused by anything else until the arena is
    /// [unloaded](Self::unload): mimalloc keeps the arena's metadata inside it.
    pub unsafe fn manage(start: NonNull<u8>, len: usize, options: ManageOptions) -> Result<Self, NotManageable> {
        let mut id: sys::mi_arena_id_t = core::ptr::null_mut();
        // SAFETY: the caller guarantees the range is valid; `id` is a valid out-pointer.
        let ok = unsafe {
            sys::mi_manage_os_memory_ex(
                start.as_ptr().cast(),
                len,
                options.committed,
                options.pinned,
                options.zeroed,
                options.numa_node,
                options.exclusive,
                &raw mut id,
            )
        };
        NonNull::new(id).filter(|_| ok).map(Self).ok_or(NotManageable)
    }

    /// Whether `ptr` points into this arena.
    #[must_use]
    pub fn contains(self, ptr: *const u8) -> bool {
        // SAFETY: `self` names a managed arena; `ptr` is only inspected as an address.
        unsafe { sys::mi_arena_contains(self.as_raw(), ptr.cast()) }
    }

    /// The arena's whole range as `(start, len)`.
    #[must_use]
    pub fn area(self) -> (*mut u8, usize) {
        let mut len = 0;
        // SAFETY: `self` names a managed arena; `len` is a valid out-pointer.
        let start = unsafe { sys::mi_arena_area(self.as_raw(), &raw mut len) };
        (start.cast(), len)
    }

    /// Takes the arena out of mimalloc so its range may be unmapped (needs the
    /// `0001-enable-arena-unload` patch). `Err` if it is not an exclusive arena over external memory.
    ///
    /// # Safety
    ///
    /// Every heap made in the arena must be destroyed and every block freed already; the id is
    /// invalid afterwards.
    pub unsafe fn unload(self) -> Result<(), NotManageable> {
        // SAFETY: the caller guarantees nothing uses the arena; null out-pointers are allowed.
        let ok = unsafe { sys::mi_arena_unload(self.as_raw(), core::ptr::null_mut(), core::ptr::null_mut(), core::ptr::null_mut()) };
        if ok { Ok(()) } else { Err(NotManageable) }
    }
}

/// Reserves `size` bytes of OS memory as a (shared) arena.
pub fn reserve(size: usize, commit: bool, allow_large: bool) -> Result<(), OutOfMemory> {
    if sys::mi_reserve_os_memory(size, commit, allow_large) == 0 { Ok(()) } else { Err(OutOfMemory) }
}

/// Reserves `pages` 1 GiB huge pages on `numa_node` (-1 for any), waiting at most `timeout_ms`
/// (0 for no limit). Linux only.
pub fn reserve_huge_pages(pages: usize, numa_node: i32, timeout_ms: usize) -> Result<(), OutOfMemory> {
    if sys::mi_reserve_huge_os_pages_at(pages, numa_node, timeout_ms) == 0 { Ok(()) } else { Err(OutOfMemory) }
}

/// Alignment a managed range must have.
#[must_use]
pub fn min_alignment() -> usize {
    sys::mi_arena_min_alignment()
}

/// Smallest managed range.
#[must_use]
pub fn min_size() -> usize {
    sys::mi_arena_min_size()
}

/// Largest block an arena serves; bigger requests go to the OS.
#[must_use]
pub fn max_object_size() -> usize {
    sys::mi_arena_max_object_size()
}

/// Purges free arena memory to the OS now.
pub fn purge() {
    sys::mi_arenas_purge();
}

#[cfg(all(test, mimalloc_linked, not(miri)))]
mod tests {
    use super::*;

    #[test]
    fn limits_are_sane() {
        assert!(min_alignment().is_power_of_two());
        assert!(min_size() > 0);
        assert!(max_object_size() > 0);
    }

    #[test]
    fn a_misaligned_range_is_refused() {
        let mut bytes = [0u8; 64];
        // SAFETY: the array outlives the call; a refused range is never used.
        let result = unsafe { ArenaId::manage(NonNull::from(&mut bytes).cast(), bytes.len(), ManageOptions::default()) };
        assert_eq!(result, Err(NotManageable));
    }
}
