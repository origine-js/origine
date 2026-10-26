//! The one Rust static library of origine: re-exports every member crate so their
//! `#[unsafe(no_mangle)] extern "C"` items end up in `liborigine_native.a`.
pub use origine_api::*;
pub use origine_repl::*;

/// Rust shares the process allocator with Zig and V8: the mimalloc that the Zig build links.
/// (Not under Miri, which cannot call foreign allocators; not in `cargo test` of member crates,
/// which never link this crate.)
#[cfg(not(miri))]
#[global_allocator]
static GLOBAL: origine_alloc::MiMalloc = origine_alloc::MiMalloc;
#[cfg(feature = "typescript")]
pub use origine_oxc::*;
