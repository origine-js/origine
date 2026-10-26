//! Statistics and process counters.

use core::ffi::{CStr, c_char};
use core::ptr::NonNull;

use crate::sys;

/// Counters for the process as mimalloc sees it (a few are zero where the OS gives none).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ProcessInfo {
    pub elapsed_ms: usize,
    pub user_ms: usize,
    pub system_ms: usize,
    pub current_rss: usize,
    pub peak_rss: usize,
    pub current_commit: usize,
    pub peak_commit: usize,
    pub page_faults: usize,
}

#[must_use]
pub fn process_info() -> ProcessInfo {
    let mut info = ProcessInfo::default();
    // SAFETY: every argument points at a field of `info`, which outlives the call.
    unsafe {
        sys::mi_process_info(
            &raw mut info.elapsed_ms,
            &raw mut info.user_ms,
            &raw mut info.system_ms,
            &raw mut info.current_rss,
            &raw mut info.peak_rss,
            &raw mut info.current_commit,
            &raw mut info.peak_commit,
            &raw mut info.page_faults,
        );
    }
    info
}

/// Prints the process statistics to stderr.
pub fn print() {
    // SAFETY: a null output function means stderr.
    unsafe { sys::mi_stats_print_out(None, core::ptr::null_mut()) }
}

/// Prints the options and their values to stderr.
pub fn print_options() {
    // SAFETY: as for `print`.
    unsafe { sys::mi_options_print_out(None, core::ptr::null_mut()) }
}

/// Zeroes the counters.
pub fn reset() {
    sys::mi_stats_reset();
}

/// Folds this thread's counters into the process totals (mimalloc does so on thread exit).
pub fn merge() {
    sys::mi_stats_merge();
}

/// The process statistics as JSON.
#[must_use]
pub fn json() -> Option<String> {
    // SAFETY: a null buffer asks mimalloc to allocate one.
    let text = NonNull::new(unsafe { sys::mi_stats_get_json(0, core::ptr::null_mut::<c_char>()) })?;
    // SAFETY: mimalloc returns a NUL-terminated string that stays valid until freed below.
    let owned = unsafe { CStr::from_ptr(text.as_ptr()) }.to_string_lossy().into_owned();
    // SAFETY: the buffer was allocated by mimalloc and is not used again.
    unsafe { sys::mi_free(text.as_ptr().cast()) };
    Some(owned)
}

#[cfg(all(test, mimalloc_linked, not(miri)))]
mod tests {
    use super::*;

    #[test]
    fn json_is_an_object() {
        let text = json().unwrap();
        assert!(text.starts_with('{'));
    }

    #[test]
    fn process_info_reports_memory() {
        let info = process_info();
        assert!(info.current_rss > 0 || info.current_commit > 0);
    }
}
