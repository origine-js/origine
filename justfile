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

# Exercise the REPL in a real pseudo-terminal (Tab, suggestions, history, colors).
test-repl:
    zig build
    uv run --no-project src/repl/tests/terminal_smoke.py

# Everything CI-style: cross-language contracts, Rust lints + Miri, then formatting and JS/TS lint.
check: check-contracts check-rust check-format

oxlint := "oxlint@1.89.0"
oxfmt := "oxfmt@0.74.0"
js_paths := "bench examples src/js src/repl"

# Rust: clippy with warnings denied (every `unsafe` needs a `// SAFETY:` comment, enforced by
# clippy::undocumented_unsafe_blocks and friends in rust/Cargo.toml) and Miri over the crates'
# tests. origine_api (the V8 glue) cannot run under Miri because it links V8; its pure-Rust logic
# lives in origine_api_core, which is Miri-tested. Miri runs origine_io against its pure-Rust fake of the C API (cfg(miri)).
check-rust:
    # Through zig: the `v8` crate's build script needs the V8_ZIG_* environment (rust/scripts/cargo-v8.sh).
    zig build clippy -Dcargo-offline=true
    cd rust && MIRIFLAGS="-Zmiri-disable-isolation" cargo miri test --offline --locked -p origine_io -p origine_oxc -p origine_api_core -p origine_api_fs -p origine_api_macros

# Formatting (rustfmt, oxfmt) and JS/TS lint (oxlint, configured in .oxlintrc.json).
check-format:
    cd rust && cargo fmt --check -p origine_native $(for d in crates/*; do printf ' -p %s' "$(basename $d)"; done)
    bunx {{oxfmt}} --check {{js_paths}}
    bunx {{oxlint}} -D warnings {{js_paths}}

# Regenerate the committed files derived from another language's declarations (bindgen over the C
# headers, errno table and oxc ABI check from Zig). See docs/contracts.md.
gen-contracts:
    rust/scripts/contracts.sh gen

# Fail when a generated contract file is stale, or when Zig/C/Rust declarations of the same ABI
# differ: regenerates into a temp tree and diffs, compiles the Zig-generated oxc check with clang,
# checks exported symbol prefixes, and runs the Zig test that compares c_api.zig, op.zig and
# backend.zig with origine_io.h. (The Rust-side comparisons are compile-time checks in
# `check-rust`.)
check-contracts:
    rust/scripts/contracts.sh check
    zig build test-io -Dtypescript=false

# Apply the formatters.
format:
    cd rust && cargo fmt -p origine_native $(for d in crates/*; do printf ' -p %s' "$(basename $d)"; done)
    bunx {{oxfmt}} {{js_paths}}
