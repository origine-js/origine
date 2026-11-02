// origine: AWS-LC is built by the Zig build system (lib/aws-lc/build.zig), not here. This build
// script only tells cargo where that build installed libcrypto and its headers, and which
// pregenerated bindings to use. `ORIGINE_AWS_LC_PREFIX` is set by the Zig build (`build.zig`) and
// by `just test-net`. See README.md and docs/aws-lc.md.

use std::env;
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=ORIGINE_AWS_LC_PREFIX");
    println!("cargo:rustc-check-cfg=cfg(universal)");

    let Some(prefix) = env::var_os("ORIGINE_AWS_LC_PREFIX").map(PathBuf::from) else {
        panic!(
            "ORIGINE_AWS_LC_PREFIX is not set: the vendored aws-lc-sys links the AWS-LC that the \
             Zig build produces (lib/aws-lc). Build through `zig build` or `just test-net`, or set \
             it to that install tree. See docs/aws-lc.md."
        );
    };

    println!(
        "cargo:rustc-link-search=native={}",
        prefix.join("lib").display()
    );
    // `-bundle`: liborigine_native.a refers to libcrypto without embedding it; the final Zig link
    // adds `aws_lc_crypto` (as for nghttp2). Cargo's own test executables link it from here.
    println!("cargo:rustc-link-lib=static:-bundle=aws_lc_crypto");
    // The crate's cross-platform pregenerated bindings (src/universal_crypto.rs).
    println!("cargo:rustc-cfg=universal");
    // aws-lc-rs's build script requires this (`DEP_AWS_LC_0_47_0_INCLUDE`).
    println!("cargo:include={}", prefix.join("include").display());
}
