# Bazel entry points available during migration. App build/run and the full
# runtime checks remain in justfile.zig-build-system.old until their targets pass.
export PATH := env("HOME") + "/.vite-plus/bin:/opt/homebrew/bin:" + env("PATH")

default:
    @just --list

# Fetch the pinned V8 source and apply its patch series, without compiling it; prints where it is.
patch-v8:
    bazel fetch --repo=@v8
    @echo "$(bazel info output_base)/external/$(bazel mod dump_repo_mapping '' | python3 -c 'import json, sys; print(json.load(sys.stdin)["v8"])')"

# Build V8 directly with Bazel; source and patch changes invalidate its actions.
build-v8 *args:
    bazel build --config=fast @v8//:icu/v8 {{ args }}

# The migrated core targets and the three-language ThinLTO acceptance probe.
test-bootstrap *args:
    bazel test --config=fast //:bootstrap-tests {{ args }}

test-io *args:
    bazel test //:test-io {{ args }}

test-core *args:
    bazel test //rust:core-tests {{ args }}

test-net *args:
    bazel test --config=fast //rust/crates/origine_tls:tls_test //rust/crates/origine_h2:h2_test //rust/crates/origine_dns:dns_test {{ args }}

test-oxc *args:
    bazel test --config=fast //rust/crates/origine_oxc:oxc_test {{ args }}

test-lto *args:
    bazel test --config=fast //build/bazel/probe:thin_lto_test {{ args }}

# Cargo supplies metadata only; Bazel compiles each local crate independently.
sync-rust-deps:
    uv run --script build/bazel/sync-rust-deps.py

check-rust-deps:
    uv run --script build/bazel/sync-rust-deps.py --check

# Move V8 and the Chromium sources of its DEPS (ICU, libc++, LLVM, ...) in MODULE.bazel to a V8 release.
bump-v8 version:
    uv run --script build/bazel/bump_v8.py {{ version }}

# Miri retains its Cargo workflow and the original workspace/toolchain.
test-miri:
    cd rust && MIRIFLAGS="-Zmiri-disable-isolation" cargo miri test --offline --locked -p origine_io -p origine_oxc -p origine_repl -p origine_api_core -p origine_api_fs -p origine_api_macros

oxlint := "oxlint@1.89.0"
oxfmt := "oxfmt@0.74.0"
js_paths := "bench examples src/js src/repl"
typescript := "typescript@7.0.2"

check-format:
    cd rust && cargo fmt --check -p origine_native $(for d in crates/*; do printf ' -p %s' "$(basename $d)"; done)
    zig fmt --check build.zig src
    vpx {{ oxfmt }} --check {{ js_paths }}
    vpx {{ oxlint }} -D warnings {{ js_paths }}

check-types:
    types/scripts/check-surface.sh
    vpx {{ typescript }} -p types/tests
    vpx {{ typescript }} -p types/tests/repl
    vpx {{ typescript }} -p types/tests/tsconfig.examples.json

format:
    cd rust && cargo fmt -p origine_native $(for d in crates/*; do printf ' -p %s' "$(basename $d)"; done)
    zig fmt build.zig src
    vpx {{ oxfmt }} {{ js_paths }}
