#!/bin/sh
# Runs a cargo command with aws-lc-sys's build script overridden (cargo's `links` override), so
# rustls/aws-lc-rs use the Zig-built AWS-LC (lib/aws-lc) and no cc/cmake build of it runs.
# See docs/aws-lc.md.
#
# usage: cargo-aws-lc.sh <aws-lc prefix> <rust target triple | host> cargo <subcommand> <args...>
#
# <aws-lc prefix> is lib/aws-lc's install tree: lib/libaws_lc_crypto.a, include/ and `links` (the
# crate's `links` key, aws_lc_0_47_0, which is also the symbol prefix of the library and of the
# crate's bindings). `host` stands for the triple cargo builds for without --target.
#
# The override (`[target.<triple>.<links>]`, passed as --config) replaces the build script:
#   rustc-cfg universal     selects the crate's pregenerated src/universal_crypto.rs bindings, the
#                           ones its build script picks when the `all-bindings` feature is off
#                           (aws-lc-rs depends on it with default-features = false);
#   rustc-link-lib          `static:-bundle`: the Rust staticlib does not embed libcrypto, the
#                           final Zig link adds it (as for nghttp2); test executables link it;
#   include                 the metadata aws-lc-rs's build script requires (DEP_AWS_LC_*_INCLUDE).
# Borrows its arguments; writes only what cargo writes.
set -eu
abs() { case $1 in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$(pwd)" "$1" ;; esac; }
prefix=$(abs "$1")
triple=$2
shift 2
if [ "$triple" = host ]; then
    # rust/rust-toolchain.toml selects the toolchain by working directory.
    triple=$(cd "$(dirname "$0")/.." && rustc -vV | sed -n 's/^host: //p')
fi
links=$(cat "$prefix/links")
# An override for another `links` key would be ignored and aws-lc-sys would quietly build its own
# AWS-LC: lib/aws-lc must fetch the aws-lc-sys version rust/Cargo.lock pins.
locked=$(sed -n '/^name = "aws-lc-sys"$/{n;s/^version = "\(.*\)"$/\1/p;}' "$(dirname "$0")/../Cargo.lock" | tr . _)
if [ -n "$locked" ] && [ "aws_lc_$locked" != "$links" ]; then
    echo "cargo-aws-lc.sh: rust/Cargo.lock pins aws-lc-sys $locked but lib/aws-lc built $links; update lib/aws-lc/build.zig.zon (docs/aws-lc.md)" >&2
    exit 1
fi
key="target.$triple.$links"
cmd=$1
subcommand=$2
shift 2
# After the subcommand: cargo forwards only those to an external one (cargo-clippy runs `cargo check`).
exec "$cmd" "$subcommand" \
    --config "$key.rustc-link-search=[\"native=$prefix/lib\"]" \
    --config "$key.rustc-link-lib=[\"static:-bundle=aws_lc_crypto\"]" \
    --config "$key.rustc-cfg=[\"universal\"]" \
    --config "$key.include=\"$prefix/include\"" \
    "$@"
