//! Links the Zig-built `libnghttp2.a` (lib/nghttp2) only when `ORIGINE_NGHTTP2_LIB` (a directory)
//! is set, so the normal workspace build is unaffected; the product links it from Zig. Tests and dev
//! builds of this crate set it.
fn main() {
    println!("cargo:rerun-if-env-changed=ORIGINE_NGHTTP2_LIB");
    println!("cargo:rerun-if-changed=build.rs");
    if let Some(dir) = std::env::var_os("ORIGINE_NGHTTP2_LIB") {
        println!("cargo:rustc-link-search=native={}", dir.to_string_lossy());
        println!("cargo:rustc-link-lib=static=nghttp2");
    }
}
