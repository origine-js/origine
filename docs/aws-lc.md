# AWS-LC

rustls (`origine_tls`) uses aws-lc-rs, whose `aws-lc-sys` crate normally compiles AWS-LC in its
build script (cc, or cmake for some configurations). origine builds AWS-LC with the Zig build
system instead, like its other C libraries, and links that copy into the binary. Both crates are
vendored, so the build never fetches a crate and aws-lc-sys's cc/cmake builder never runs.

| piece | where |
| --- | --- |
| Zig build of AWS-LC | `lib/aws-lc/` (package: `build.zig`, hard-coded lists in `sources.zig`, module `aws_lc`) |
| vendored crates | `rust/vendor/aws-lc-rs`, `rust/vendor/aws-lc-sys` (`[patch.crates-io]` in `rust/Cargo.toml`) |
| cargo side | `rust/vendor/aws-lc-sys/build.rs`: emits the link/include directives, nothing else |
| wiring | `build.zig`: the `aws_lc` dependency, `awsLcPrefix`, `CargoAwsLc`, `cargoCommand`, the `aws-lc-prefix` step; `justfile`: `test-net` |

## Source: the vendored aws-lc-sys crate

`rust/vendor/aws-lc-sys` is the crates.io package whose version `rust/Cargo.lock` pins (0.47.0,
AWS-LC 5.12.0), with its AWS-LC sources kept and its cc/cmake/bindgen machinery removed. It is not
an AWS-LC release: it is the exact tree the Rust bindings were generated from, so the symbol
prefix headers, the pregenerated `universal` bindings and the C sources cannot skew.

- `aws-lc/`: the AWS-LC tree, trimmed to the sources origine's three targets compile;
- `generated-include/openssl/boringssl_prefix_symbols*.h`: the symbol-prefix headers;
- `src/universal_crypto.rs`: the pregenerated bindings, whose `link_name`s carry the prefix.

Everything is compiled with `BORINGSSL_PREFIX=aws_lc_0_47_0` (the crate's `links` key), so the
library exports `aws_lc_0_47_0_*` names and matches the bindings. The defines are those of
aws-lc-sys's cc builder (`builder/cc_builder.rs`) with its compiler checks answered for Zig's
clang (the checked headers are removed with the rest of the builder).

The per-target source lists are hard-coded in `lib/aws-lc/sources.zig` rather than read from the
crate's build-system files at configure time; the comment at the top of that file documents how
they were produced (the CMake lists, minus tests/fuzzers/tools) and what to regenerate when the
crate is bumped. A source the lists do not name is never compiled by accident.

The package also exposes a module `aws_lc` (the public C headers with `BORINGSSL_PREFIX` defined)
for Zig consumers; the root imports it but nothing uses it yet. libssl is behind `-Dssl`, which the
root sets from `-Dquic`.

## Cargo: a patched build script

`rust/Cargo.toml` patches both crates to their vendored paths. The vendored `aws-lc-sys` declares
the same `links = "aws_lc_0_47_0"` and keeps a minimal `build.rs` that only:

```
cargo:rustc-link-search=native=$ORIGINE_AWS_LC_PREFIX/lib
cargo:rustc-link-lib=static:-bundle=aws_lc_crypto
cargo:rustc-cfg=universal
cargo:include=$ORIGINE_AWS_LC_PREFIX/include
```

- `universal` selects the crate's cross-platform pregenerated bindings, the ones its build script
  picked when `all-bindings` was off (aws-lc-rs depends on it with `default-features = false`).
- `static:-bundle`: `liborigine_native.a` refers to libcrypto without embedding it; the final Zig
  link adds `aws_lc_crypto` (as for nghttp2). Cargo's own test executables link it from the prefix.
- `include` is the metadata aws-lc-rs's build script requires (`DEP_AWS_LC_0_47_0_INCLUDE`).

`ORIGINE_AWS_LC_PREFIX` is the install prefix (the directory holding `lib/`, `include/` and
`links`), written by the `aws-lc-prefix` step. The prefix is only known in the make phase (`zig
build -p` changes it), so `build.zig` prepends `env ORIGINE_AWS_LC_PREFIX=<prefix>` to the cargo
command, with `<prefix>` passed as a `LazyPath` argument (no configure-time string, no wrapper). A
cargo invocation without the variable fails in the build script with a message pointing here; it
never falls back to compiling AWS-LC.

## Commands

| command | AWS-LC |
| --- | --- |
| `zig build`, `zig build test` | built for the target with `-Dtls` (default) and installed to `zig-out/{lib,include,links}` |
| `zig build aws-lc-prefix` | just that install tree (for `just test-net`) |
| `zig build clippy` | built for the host (clippy checks origine_tls whatever the features, so `-Dtls` must stay on) |
| `zig build test-alloc`, Miri (`just check-rust`) | not involved (no crate there depends on aws-lc-sys) |
| `just test-net` | `zig build aws-lc-prefix`, then `cargo test` with `ORIGINE_AWS_LC_PREFIX=zig-out` |

`aws_lc_ssl` is libssl (C++, `-fno-exceptions -fno-rtti`), built only for QUIC's TLS API and not
linked yet; it needs the C++ runtime of the final link, which is V8's libc++. Its own `SSL_*` names
are not prefixed (the prefix list covers libcrypto); its calls into libcrypto are. C consumers of
the headers must define `BORINGSSL_PREFIX` to the contents of `links`.

## Updating

Bump `aws-lc-rs`/`aws-lc-sys` in `rust/Cargo.lock`, replace `rust/vendor/aws-lc-sys` with the new
crate (keeping `Cargo.toml`, `build.rs`, `src/lib.rs`, `README.md` and the trimmed `aws-lc/` and
`generated-include/`), then regenerate `lib/aws-lc/sources.zig` as its header describes and update
`crate`/`links` if the version changed. `rust/vendor/aws-lc-rs` only pins the pair; it needs no
changes unless aws-lc-rs itself does. Check `zig build aws-lc-prefix`, `zig build clippy`,
`zig build test` and `just test-net`.

## Size and build time

`just check-size` (macOS aarch64, `-Doptimize=small`, stripped), 2026-11-02:
44,051,104 bytes with aws-lc-sys's build (cc, `-Oz` and `OPENSSL_SMALL`, since the release
profile is `opt-level = "z"`), 44,092,784 bytes with the Zig build (`ReleaseFast`, no
`OPENSSL_SMALL`): +41,680 bytes.

Clean build on the same machine (M-series, 10 cores): libcrypto alone 17.8 s wall, 60 s CPU; with
libssl 23.2 s wall, 101 s CPU. aws-lc-sys's own cc build (`-Oz`) took 10.5 s wall, 34 s CPU, but
ran once per cargo profile and target (the release staticlib, debug for clippy and `test-net`);
the Zig build is shared by all of them and cached.
