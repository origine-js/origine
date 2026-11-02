# Vendored aws-lc-sys

`aws-lc-sys` 0.47.0 (AWS-LC 5.12.0), from crates.io, patched so that cargo links the AWS-LC that
origine builds with the Zig build system (`lib/aws-lc/aws_lc.zig`) instead of compiling its own.
Upstream's README is `README.upstream.md` and its LICENSE is kept. docs/aws-lc.md has the whole
picture.

## What was removed or changed

- `builder/` and `Cargo.toml.orig` are gone; `build.rs` replaces `builder/main.rs` and only emits
  the link/include/cfg directives for the tree at `$ORIGINE_AWS_LC_PREFIX` (see below).
- The build dependencies (cc, cmake, bindgen, dunce, fs_extra, pkg-config) are gone with it.
- `tests/`, `include/rust_wrapper.h` and the crate's `CMakeLists.txt` are gone.
- `src/` keeps only `lib.rs` and the cross-platform `universal_crypto.rs` bindings; the
  per-platform bindings and the bindgen path are gone, so only the `universal` cfg is used.
- `aws-lc/` is trimmed to the sources `lib/aws-lc/sources.zig` compiles for aarch64-macos and
  x86_64/aarch64-linux: other targets' assembly and generated sources, tests, fuzzers, tools,
  perl asm generators and cmake files are removed. `generated-include/` keeps the symbol-prefix
  headers.
- `Cargo.toml` keeps the upstream name, version and `links = "aws_lc_0_47_0"` (the lockfile and the
  symbol prefix depend on them), drops the `include` list and keeps the feature names aws-lc-rs
  refers to as no-ops.

## build.rs

It requires `ORIGINE_AWS_LC_PREFIX` (set by `build.zig`, see docs/aws-lc.md) and emits
`rustc-link-search`, `rustc-link-lib=static:-bundle=aws_lc_crypto`, `rustc-cfg=universal` and the
`include` metadata aws-lc-rs needs. It never compiles anything.

## Updating

Replace this directory with the new crates.io package (keeping the changes above), then follow
docs/aws-lc.md: bump the patched version/`links`, trim `aws-lc/`, regenerate
`lib/aws-lc/sources.zig`, and run the checks listed there.
