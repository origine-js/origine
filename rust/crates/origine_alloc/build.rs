//! Lets this crate's tests link the mimalloc the Zig build produced.
//!
//! The library is built by `lib/mimalloc`, not by cargo, so there is nothing to compile here.
//! `rust/scripts/cargo-v8.sh` (which `zig build` and `zig build clippy`/`test-alloc` go through)
//! exports its path as `V8_ZIG_MIMALLOC`; when that is set the tests link it and the tests that
//! call mimalloc are compiled in (`cfg(mimalloc_linked)`). A bare `cargo test` still builds and
//! runs the rest.

fn main() {
    println!("cargo::rustc-check-cfg=cfg(mimalloc_linked)");
    println!("cargo::rerun-if-env-changed=V8_ZIG_MIMALLOC");
    if let Ok(archive) = std::env::var("V8_ZIG_MIMALLOC") {
        println!("cargo::rustc-link-arg={archive}");
        println!("cargo::rustc-cfg=mimalloc_linked");
    }
}
