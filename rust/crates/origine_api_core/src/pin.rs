//! The V8-free decisions behind pinned guest buffers (`origine_api::pinned`): may a guest
//! `ArrayBuffer` be taken over (detached and used in place) or must it be copied, is a captured
//! window inside its store, and how large may a host-allocated read be. Pure functions, so they
//! are unit tested here (and under Miri) without V8.

use crate::{NativeError, errno};

/// Largest buffer a host-provided read (`fileReadAlloc`/`filePreadAlloc`) allocates up front:
/// the same 256 MiB as `readAll`. Larger requests fail `FileTooBig` before anything is allocated.
pub const MAX_ALLOC_READ: usize = 256 << 20;

/// What V8 says about the store behind a guest buffer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StoreTraits {
    /// `SharedArrayBuffer` memory: other threads (workers) may touch it, it is never detachable.
    pub shared: bool,
    /// Resizable / growable by user JS: its length can change under the op.
    pub resizable: bool,
    /// `ArrayBuffer::is_detachable()` (false for buffers WebAssembly or asm.js uses).
    pub detachable: bool,
}

impl StoreTraits {
    /// Whether the buffer may be pinned (detached and handed to the loop): only a plain, fixed
    /// length, detachable, non-shared buffer. Everything else is copied.
    pub fn pinnable(self) -> bool {
        !self.shared && !self.resizable && self.detachable
    }
}

/// How a guest buffer region takes part in an operation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Plan {
    /// Zero bytes: complete without I/O; the buffer is left untouched (not even detached).
    Empty,
    /// Detach the buffer and let the loop use its store in place.
    Pin,
    /// Copy at call time (writes) or use a host buffer and copy out at completion (reads); the
    /// guest's buffer stays usable.
    Copy,
}

/// The plan for a region of `len` bytes whose store has `traits`.
pub fn plan(traits: StoreTraits, len: usize) -> Plan {
    if len == 0 {
        Plan::Empty
    } else if traits.pinnable() {
        Plan::Pin
    } else {
        Plan::Copy
    }
}

/// Whether `offset..offset + len` lies inside a store of `store_len` bytes (overflow-safe). The
/// window is captured from the view before detaching, but it is checked against the store
/// again before a raw pointer is formed from it.
pub fn window_fits(offset: usize, len: usize, store_len: usize) -> bool {
    offset.checked_add(len).is_some_and(|end| end <= store_len)
}

/// `len` as the size of a host-allocated read: `Err(FileTooBig)` above [`MAX_ALLOC_READ`].
pub fn check_alloc_len(len: usize) -> Result<usize, NativeError> {
    if len > MAX_ALLOC_READ { Err(NativeError::Errno(errno::FILE_TOO_BIG)) } else { Ok(len) }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PLAIN: StoreTraits = StoreTraits { shared: false, resizable: false, detachable: true };

    #[test]
    fn only_plain_detachable_buffers_are_pinned() {
        assert!(PLAIN.pinnable());
        assert!(!StoreTraits { shared: true, ..PLAIN }.pinnable());
        assert!(!StoreTraits { resizable: true, ..PLAIN }.pinnable());
        assert!(!StoreTraits { detachable: false, ..PLAIN }.pinnable());
        assert!(!StoreTraits { shared: true, resizable: true, detachable: false }.pinnable());
    }

    #[test]
    fn plan_depends_on_length_then_eligibility() {
        assert_eq!(plan(PLAIN, 0), Plan::Empty);
        assert_eq!(plan(StoreTraits { shared: true, ..PLAIN }, 0), Plan::Empty);
        assert_eq!(plan(PLAIN, 1), Plan::Pin);
        assert_eq!(plan(StoreTraits { detachable: false, ..PLAIN }, 1), Plan::Copy);
        assert_eq!(plan(StoreTraits { resizable: true, ..PLAIN }, 4096), Plan::Copy);
    }

    #[test]
    fn windows_are_bound_checked() {
        assert!(window_fits(0, 0, 0));
        assert!(window_fits(2, 6, 8));
        assert!(window_fits(8, 0, 8));
        assert!(!window_fits(2, 7, 8));
        assert!(!window_fits(9, 0, 8));
        assert!(!window_fits(usize::MAX, 2, usize::MAX));
        assert!(!window_fits(1, usize::MAX, usize::MAX));
    }

    #[test]
    fn alloc_reads_are_capped() {
        assert!(matches!(check_alloc_len(0), Ok(0)));
        assert!(matches!(check_alloc_len(MAX_ALLOC_READ), Ok(MAX_ALLOC_READ)));
        assert!(matches!(check_alloc_len(MAX_ALLOC_READ + 1), Err(NativeError::Errno(errno::FILE_TOO_BIG))));
        assert!(matches!(check_alloc_len(usize::MAX), Err(NativeError::Errno(errno::FILE_TOO_BIG))));
    }
}
