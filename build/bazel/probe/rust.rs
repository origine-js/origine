unsafe extern "C" {
    fn origine_probe_cpp(x: u32) -> u32;
}

/// Accepts and returns values; retains no resources.
#[unsafe(no_mangle)]
pub extern "C" fn origine_probe_rust(x: u32) -> u32 {
    // SAFETY: the linked C++ implementation accepts every u32 and retains nothing.
    unsafe { origine_probe_cpp(x).wrapping_mul(7) }
}
