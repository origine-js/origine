// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0 OR ISC

// origine: only the cross-platform pregenerated bindings are vendored (src/universal_crypto.rs,
// selected by the `universal` cfg that build.rs sets). The per-platform bindings and the bindgen
// path are removed; see README.md.

mod universal_crypto;
pub use universal_crypto::*;

#[allow(non_snake_case, clippy::cast_possible_wrap)]
#[must_use]
pub fn ERR_GET_LIB(packed_error: u32) -> i32 {
    ((packed_error >> 24) & 0xFF) as i32
}

#[allow(non_snake_case, clippy::cast_possible_wrap)]
#[must_use]
pub fn ERR_GET_REASON(packed_error: u32) -> i32 {
    (packed_error & 0x0FFF) as i32
}

#[allow(non_snake_case)]
#[must_use]
pub fn ERR_GET_FUNC(_packed_error: u32) -> i32 {
    0
}

#[cfg(feature = "all-bindings")]
use std::os::raw::{c_char, c_long, c_void};

#[cfg(feature = "all-bindings")]
#[allow(non_snake_case, clippy::not_unsafe_ptr_arg_deref)]
pub fn BIO_get_mem_data(b: *mut BIO, pp: *mut *mut c_char) -> c_long {
    unsafe { BIO_ctrl(b, BIO_CTRL_INFO, 0, pp.cast::<c_void>()) }
}

pub fn init() {
    unsafe { CRYPTO_library_init() }
}

/// Always `0`: `aws-lc-sys` does not track an AWS-LC FIPS release branch.
#[must_use]
pub const fn fips_version() -> u32 {
    0
}
