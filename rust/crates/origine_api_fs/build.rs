//! Links the Zig-built `liborigine_io.a` only when `ORIGINE_IO_LIB` (a directory) is set, so the
//! normal workspace build is unaffected. Tests of this crate set it (or run under Miri's mock).
fn main() {
    println!("cargo:rerun-if-env-changed=ORIGINE_IO_LIB");
    println!("cargo:rerun-if-changed=build.rs");
    if let Some(dir) = std::env::var_os("ORIGINE_IO_LIB") {
        println!("cargo:rustc-link-search=native={}", dir.to_string_lossy());
        println!("cargo:rustc-link-lib=static=origine_io");
    }
}
