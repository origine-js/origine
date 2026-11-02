# AWS-LC

rustls (`origine_tls`) uses aws-lc-rs, whose `aws-lc-sys` crate normally compiles AWS-LC in its
build script (cc, or cmake for some configurations). origine builds AWS-LC with the Zig build
system instead, like its other C libraries, and links that copy into the binary. aws-lc-sys's
build script never runs, so no cmake, no C compiler driven by cargo and no second copy of
AWS-LC.

| piece | where |
| --- | --- |
| Zig build of AWS-LC | `lib/aws-lc/build.zig` (package `aws_lc`, a lazy path dependency of the root) |
| cargo side | `rust/scripts/cargo-aws-lc.sh` (a `links` build-script override) |
| wiring | `build.zig`: `awsLcDependency`, `CargoAwsLc`, `cargoCommand`; `justfile`: `test-net` |

## Source: the aws-lc-sys crate itself

`lib/aws-lc/build.zig.zon` fetches `aws-lc-sys-<version>.crate` from static.crates.io, the very
version `rust/Cargo.lock` pins (its sha256 is Cargo.lock's `checksum`). Not an AWS-LC release,
because the crate is what the Rust side was generated from:

- `aws-lc/`: the AWS-LC tree (5.12.0 for crate 0.47.0), including the pre-generated assembly;
- `generated-include/openssl/boringssl_prefix_symbols*.h`: the symbol-prefix headers;
- `builder/cc_builder/<platform>.rs`: the source list per target, read by `lib/aws-lc/build.zig`
  at configure time (`universal.rs` plus `apple_aarch64.rs`, `linux_x86_64.rs`, ...);
- `src/universal_crypto.rs`: the pregenerated bindings, whose `link_name`s carry the prefix.

Everything is compiled with `BORINGSSL_PREFIX=aws_lc_0_47_0` (the crate's `links` key, read from
its `Cargo.toml`), so the library exports `aws_lc_0_47_0_*` names and matches the bindings. The
defines are those of aws-lc-sys's cc builder (`builder/cc_builder.rs`) with its compiler checks
answered for Zig's clang.

Assembly is on for aarch64/x86_64 macOS and Linux (and arm, x86, ppc64le Linux, for which the
crate has lists); Windows builds C only (`OPENSSL_NO_ASM`, its x86_64 assembly is NASM). CPU
jitter entropy is built (at `-O0`, as AWS-LC requires) except for Apple targets cross-compiled
without an SDK (`CoreServices.h`); `-Djitter=false` turns it off. Built `ReleaseFast`;
`-Dsmall` in `lib/aws-lc` adds `OPENSSL_SMALL`.

Artifacts: `aws_lc_crypto` (libcrypto, linked) and `aws_lc_ssl` (libssl, C++, built with `-Dquic`
for QUIC's TLS API but not linked by anything yet; it needs the C++ runtime of the final link,
which is V8's libc++, and C consumers of the headers must define `BORINGSSL_PREFIX` to the
contents of `links`). libssl's own `SSL_*` names are not prefixed (the prefix list covers
libcrypto); its calls into libcrypto are.

## Cargo: a `links` override

aws-lc-sys declares `links = "aws_lc_0_47_0"`, so cargo can replace its build script with
configuration. `rust/scripts/cargo-aws-lc.sh <prefix> <triple|host> cargo <subcommand> ...` adds,
after the subcommand (cargo forwards those to `cargo-clippy`):

```
--config target.<triple>.aws_lc_0_47_0.rustc-link-search=["native=<prefix>/lib"]
--config target.<triple>.aws_lc_0_47_0.rustc-link-lib=["static:-bundle=aws_lc_crypto"]
--config target.<triple>.aws_lc_0_47_0.rustc-cfg=["universal"]
--config target.<triple>.aws_lc_0_47_0.include="<prefix>/include"
```

- `rustc-cfg universal` picks the crate's `src/universal_crypto.rs`, as its build script does
  when the `all-bindings` feature is off (aws-lc-rs depends on aws-lc-sys with
  `default-features = false`; nothing in the lockfile turns it on). If something enabled
  `all-bindings`, the crate would fail to compile (missing `BIO_ctrl`) instead of linking wrongly.
- `static:-bundle`: `liborigine_native.a` refers to libcrypto without embedding it; Zig links
  `aws_lc_crypto` into every program that links the Rust library (`native_libs` in `build.zig`,
  next to nghttp2). Cargo's own test executables link it from `<prefix>/lib`.
- `include` is the metadata aws-lc-rs's build script requires (`DEP_AWS_LC_*_INCLUDE`).

`<prefix>` is the `prefix` named lazy path of `lib/aws-lc` (`lib/libaws_lc_crypto.a`, `include/`,
`links`); `zig build` in `lib/aws-lc` installs the same layout. Its path is content-addressed, so a
changed library changes the override and cargo relinks. The script refuses to run when `links` is
not the aws-lc-sys version of `rust/Cargo.lock`: an override for another key would be ignored
silently and aws-lc-sys would build its own copy again.

Alternatives that were not taken: aws-lc-sys's own system-library mode
(`AWS_LC_SYS_SYSTEM_DIR`, `_STATIC`, `_SYSTEM_BINDINGS`) still runs the build script, needs a
bindings file without the crate's `#![allow]` prelude (`include!` rejects inner attributes) and
links the library *bundled* into the Rust staticlib, where its symbols would be localized with the
rest; a patched aws-lc-sys (`[patch.crates-io]`) means vendoring code. The override needs neither
and works with `--locked --offline`.

## Commands

| command | AWS-LC |
| --- | --- |
| `zig build`, `zig build test` | built for the target with `-Dtls` (default); not fetched with `-Dtls=false` |
| `zig build clippy` | built for the host (clippy checks origine_tls whatever the features); with `-Dtls=false` clippy falls back to aws-lc-sys's build script |
| `zig build test-alloc`, Miri (`just check-rust`) | not involved (no crate there depends on aws-lc-sys) |
| `just test-net` | `lib/aws-lc` installed into `zig-out/aws-lc`, then `cargo test` through the script |

A cargo command run by hand without the script builds AWS-LC through aws-lc-sys's build script as
upstream does; that still works but is not what ships.

## Updating

Bump `aws-lc-rs`/`aws-lc-sys` in `rust/Cargo.lock`, then in `lib/aws-lc/build.zig.zon` set
`.version` to the new aws-lc-sys version and `.url` to its `.crate`, and take the hash `zig build`
reports. The links name, prefix, source lists and libssl sources follow from the crate. Check
`zig build clippy`, `zig build test` and `just test-net`; if the crate starts listing a new kind of
source (a new directory with its own flags, as s2n-bignum and jitterentropy have), `lib/aws-lc/build.zig`
panics on it rather than guessing.

## Size and build time

`just check-size` (macOS aarch64, `-Doptimize=small`, stripped), 2026-11-02:
44,051,104 bytes with aws-lc-sys's build (cc, `-Oz` and `OPENSSL_SMALL`, since the release
profile is `opt-level = "z"`), 44,092,784 bytes with the Zig build (`ReleaseFast`, no
`OPENSSL_SMALL`): +41,680 bytes.

Clean build on the same machine (M-series, 10 cores): libcrypto alone (`zig build crypto` in
`lib/aws-lc`) 17.8 s wall, 60 s CPU; with libssl 23.2 s wall, 101 s CPU. aws-lc-sys's own cc build
(`-Oz`) took 10.5 s wall, 34 s CPU, but ran once per cargo profile and target (the release
staticlib, debug for clippy and `test-net`); the Zig build is shared by all of them and cached.
