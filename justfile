default:
    @just --list

# Rebuild V8 (fetch, patch, ninja). Plain `zig build` reuses the last archive; run this
# after changing V8 or its patches. Pass `-Dv8_debug=true` for a debug V8.
build-v8 *args:
    zig build build-v8 {{args}}

# Build the app. V8 is built from source on the first build only (see `build-v8`);
# it is release V8 unless `v8_debug` is passed.
build mode="debug" v8="release":
    zig build {{ if mode == "release" { "-Doptimize=small" } else if mode == "debug" { "" } else { error("mode must be debug or release") } }} {{ if v8 == "debug" { "-Dv8_debug=true" } else if v8 == "release" { "" } else { error("v8 must be debug or release") } }}

# Run the shell against release V8.
run *args:
    zig build run -- {{args}}

# Working on V8 or its patches: rebuild a debug V8 (quick incremental compiles), then run.
v8-dev *args:
    zig build build-v8 -Dv8_debug=true
    zig build run -Dv8_debug=true -- {{args}}

# Fetch V8 and apply patches, then edit lib/v8_zig/.lp-cache/v8-*/.
patch-v8:
    zig build patch-v8

test:
    zig build test

# The networking crates' tests (origine_tls, origine_h2, origine_dns). origine_h2 links the Zig-built nghttp2;
# rustls links the Zig-built AWS-LC (docs/aws-lc.md).
test-net:
    cd lib/nghttp2 && zig build -Doptimize=ReleaseFast -p ../../zig-out/nghttp2
    zig build aws-lc-prefix
    cd rust && ORIGINE_NGHTTP2_LIB="$PWD/../zig-out/nghttp2/lib" ORIGINE_AWS_LC_PREFIX="$PWD/../zig-out" cargo test --offline --locked -p origine_tls -p origine_h2 -p origine_dns

# Exercise the REPL in a real pseudo-terminal (Tab, suggestions, history, colors).
test-repl:
    zig build
    uv run --no-project src/repl/tests/terminal_smoke.py

# Everything CI-style: cross-language contracts, Rust lints + Miri, then formatting and JS/TS lint.
check: check-contracts check-rust check-format check-types check-size

oxlint := "oxlint@1.89.0"
oxfmt := "oxfmt@0.74.0"
js_paths := "bench examples src/js src/repl"
typescript := "typescript@7.0.2"
tsc := typescript

# Rust: clippy with warnings denied (every `unsafe` needs a `// SAFETY:` comment, enforced by
# clippy::undocumented_unsafe_blocks and friends in rust/Cargo.toml) and Miri over the crates'
# tests. origine_api (the V8 glue) cannot run under Miri because it links V8; its pure-Rust logic
# lives in origine_api_core, which is Miri-tested. Miri runs origine_io against its pure-Rust fake of the C API (cfg(miri)).
check-rust:
    # Through zig: the `v8` crate's build script needs the V8_ZIG_* environment (rust/scripts/cargo-env.py).
    zig build clippy -Drust_cargo_offline=true
    cd rust && MIRIFLAGS="-Zmiri-disable-isolation" cargo miri test --offline --locked -p origine_io -p origine_oxc -p origine_repl -p origine_api_core -p origine_api_fs -p origine_api_macros

# The default release build stays within the binary budget (docs/http-design.md): 70 MB, stripped
# (Bun's size). `limit` is in MB (10^6 bytes). Builds into zig-out/size-check, not the install prefix.
check-size limit="70":
    zig build -Doptimize=small -Drust_cargo_offline=true -p zig-out/size-check
    cp zig-out/size-check/bin/origine zig-out/size-check/origine.stripped
    strip -S -x zig-out/size-check/origine.stripped
    size=$(wc -c < zig-out/size-check/origine.stripped); echo "origine (small, stripped): $size bytes"; test "$size" -le $(( {{limit}} * 1000000 ))

# Formatting (rustfmt, zig fmt, oxfmt) and JS/TS lint (oxlint, configured in .oxlintrc.json).
check-format:
    cd rust && cargo fmt --check -p origine_native $(for d in crates/*; do printf ' -p %s' "$(basename $d)"; done)
    zig fmt --check build.zig src
    vpx {{oxfmt}} --check {{js_paths}}
    vpx {{oxlint}} -D warnings {{js_paths}}

# Regenerate the committed files derived from another language's declarations (bindgen over the C
# headers, errno table and oxc ABI check from Zig). See docs/contracts.md.
gen-contracts:
    uv run --no-cache --script rust/scripts/contracts.py gen

# Fail when a generated contract file is stale, or when Zig/C/Rust declarations of the same ABI
# differ: regenerates into a temp tree and diffs, compiles the Zig-generated oxc check with clang,
# checks exported symbol prefixes, and runs the Zig test that compares c_api.zig, op.zig and
# backend.zig with origine_io.h. (The Rust-side comparisons are compile-time checks in
# `check-rust`.)
check-contracts:
    uv run --no-cache --script rust/scripts/contracts.py check
    zig build test-io -Dtypescript=false

# TypeScript: the declarations of `types/` (@origine/types) against their own tests (positive cases and
# `@ts-expect-error` negatives), the examples and benchmarks that run on origine, and a check that
# every public name of the JS runtime is declared. Needs network on the first run (the runner fetches tsc).
check-types:
    types/scripts/check-surface.sh
    vpx {{tsc}} -p types/tests
    vpx {{tsc}} -p types/tests/repl
    vpx {{tsc}} -p types/tests/tsconfig.examples.json

# Apply the formatters (rustfmt, zig fmt, oxfmt).
format:
    cd rust && cargo fmt -p origine_native $(for d in crates/*; do printf ' -p %s' "$(basename $d)"; done)
    zig fmt build.zig src
    vpx {{oxfmt}} {{js_paths}}

# Bazel (migration in progress; docs/bazel-migration-progress.md). The recipes above stay the way to
# build and run the app until the Bazel graph covers it.

# Fetch the pinned V8 source and apply its patch series, without compiling it; prints where it is.
bazel-patch-v8:
    bazel fetch --repo=@v8
    @echo "$(bazel info output_base)/external/$(bazel mod dump_repo_mapping '' | python3 -c 'import json, sys; print(json.load(sys.stdin)["v8"])')"

# Build V8 with Bazel; source and patch changes invalidate its actions.
bazel-build-v8 *args:
    bazel build --config=fast @v8//:icu/v8 {{args}}

# The migrated core targets and the three-language ThinLTO acceptance probe.
bazel-test-bootstrap *args:
    bazel test --config=fast //:bootstrap-tests {{args}}

bazel-test-io *args:
    bazel test //:test-io {{args}}

bazel-test-core *args:
    bazel test //rust:core-tests {{args}}

bazel-test-net *args:
    bazel test --config=fast //rust/crates/origine_tls:tls_test //rust/crates/origine_h2:h2_test //rust/crates/origine_dns:dns_test {{args}}

bazel-test-oxc *args:
    bazel test --config=fast //rust/crates/origine_oxc:oxc_test {{args}}

bazel-test-lto *args:
    bazel test --config=fast //build/bazel/probe:thin_lto_test {{args}}

# Regenerate the registry crate specs from rust/Cargo.lock (Cargo supplies metadata only).
bazel-sync-rust-deps:
    uv run --script build/bazel/sync-rust-deps.py

bazel-check-rust-deps:
    uv run --script build/bazel/sync-rust-deps.py --check

# Move V8 and the Chromium sources of its DEPS (ICU, libc++, LLVM, ...) in MODULE.bazel to a V8 release.
bazel-bump-v8 version:
    uv run --script build/bazel/bump_v8.py {{version}}
