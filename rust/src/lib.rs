//! The one Rust static library of origine: re-exports every member crate so their
//! `#[unsafe(no_mangle)] extern "C"` items end up in `liborigine_native.a`.
#[cfg(feature = "typescript")]
pub use origine_oxc::*;
