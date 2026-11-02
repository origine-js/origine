# Vendored aws-lc-rs

`aws-lc-rs` 1.19.0 from crates.io, vendored unmodified (upstream README in `README.upstream.md`,
LICENSE kept) so that it and `aws-lc-sys` are pinned together by `[patch.crates-io]` in
`rust/Cargo.toml`. `util/`, `scripts/`, the Makefile and the README template are removed;
`examples/` stays so its manifest targets exist. `aws-lc-sys` is the vendored, patched one that
links the Zig-built AWS-LC; see `../aws-lc-sys/README.md` and docs/aws-lc.md.

## Updating

Replace the directory with the new crate (same trims) together with `../aws-lc-sys`, update
`rust/Cargo.lock`, and follow docs/aws-lc.md.
