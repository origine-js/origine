//! Raw bindings of `src/io/include/origine_io.h`.
//!
//! CONTRACT (docs/contracts.md, surface A): everything here is generated from the header into
//! `sys_gen.rs` by `just gen-contracts`; nothing is written by hand. `just check-contracts`
//! fails when the committed file is stale. Under Miri the functions are the pure-Rust fakes of
//! `mock.rs`, which must define every `oio_*` function with exactly the generated signature
//! (compile-time checked below and in `mock.rs`).
#![allow(non_camel_case_types, dead_code)]

#[rustfmt::skip]
#[macro_use]
#[allow(
    unused_macros,
    non_upper_case_globals,
    unsafe_op_in_unsafe_fn,
    clippy::all,
    clippy::undocumented_unsafe_blocks,
    clippy::multiple_unsafe_ops_per_block,
    clippy::missing_safety_doc
)]
#[path = "sys_gen.rs"]
pub(crate) mod generated;

pub use generated::*;

// Miri cannot call foreign functions: route every function to the pure-Rust fake in `mock.rs`.
// The list comes from the header, so a function without a fake does not compile under Miri. An
// explicit re-export shadows the glob import of the extern declaration above.
#[cfg(miri)]
macro_rules! reexport_mock {
    ($($f:ident),* $(,)?) => {
        #[allow(unused_imports)] // sendmsg/recvmsg have no safe wrapper yet
        pub use crate::mock::{$($f),*};
    };
}
#[cfg(miri)]
for_each_oio_fn!(reexport_mock);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn constants_follow_the_header() {
        assert_eq!(OIO_FDCWD, -1);
        assert_eq!(OIO_O_CREAT, 0x100);
        assert_eq!(OIO_CAP_FTRUNCATE, 1 << 13);
    }
}
