extern fn origine_probe_rust(x: u32) callconv(.c) u32;

/// Accepts and returns values; retains no resources.
export fn origine_probe_zig(x: u32) u32 {
    return origine_probe_rust(x) + 3;
}
