#!/bin/sh
# Generated cross-language contract files (docs/contracts.md). One list, used by both modes.
#
#   contracts.sh gen     rewrite the committed generated files in the repository
#   contracts.sh check   regenerate into a temporary tree, fail if a committed file differs, and
#                        run the checks that need no generation (clang on the Zig-generated C
#                        file, exported-symbol prefixes)
#
# Needs: zig, cargo (offline: bindgen is already in rust/Cargo.lock), libclang (LIBCLANG_PATH),
# /usr/bin/clang or any `clang`.
set -eu
repo=$(cd "$(dirname "$0")/../.." && pwd)
mode=${1:?usage: contracts.sh gen|check}

# path (relative to the repository root) of each generated file
files="rust/crates/origine_api_core/src/errno_table.rs
src/api/transform/oxc_abi_check.c
src/api/api_abi_check.c
rust/crates/origine_api/src/abi_gen.rs
rust/crates/origine_io/src/sys_gen.rs
rust/crates/origine_oxc/src/header_abi.rs"

if [ -z "${LIBCLANG_PATH:-}" ] && [ -d /Library/Developer/CommandLineTools/usr/lib ]; then
    export LIBCLANG_PATH=/Library/Developer/CommandLineTools/usr/lib
fi

# generate <root>: write every generated file below <root> (an existing directory tree).
generate() {
    out=$1
    for f in $files; do mkdir -p "$out/$(dirname "$f")"; done
    # Surface D (errno table) and the Zig half of surface E (oxc_abi_check.c): from Zig declarations.
    (cd "$repo" && zig run src/gen_contracts.zig -- "$out")
    # Surfaces A and E: bindgen over the C headers.
    (cd "$repo/rust" &&
        cargo run -q --offline --locked -p origine_gen -- io-sys ../src/io/include/origine_io.h "$out/rust/crates/origine_io/src/sys_gen.rs" &&
        cargo run -q --offline --locked -p origine_gen -- oxc-abi crates/origine_oxc/include/origine_oxc.h "$out/rust/crates/origine_oxc/src/header_abi.rs" &&
        cargo run -q --offline --locked -p origine_gen -- api-abi crates/origine_api/include/origine_api.h "$out/rust/crates/origine_api/src/abi_gen.rs")
}

case $mode in
gen)
    generate "$repo"
    ;;
check)
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    generate "$tmp"
    status=0
    for f in $files; do
        if ! diff -u "$repo/$f" "$tmp/$f"; then
            echo "check-contracts: $f is stale; run \`just gen-contracts\` and commit the result" >&2
            status=1
        fi
    done
    # The Zig declarations of the oxc ABI against the header (surface E).
    clang -fsyntax-only -I "$repo/rust/crates/origine_oxc/include" "$repo/src/api/transform/oxc_abi_check.c" || status=1
    # The Zig declarations of the origine_api ABI against its header (surfaces B and C).
    clang -fsyntax-only -I "$repo/rust/crates/origine_api/include" "$repo/src/api/api_abi_check.c" || status=1
    # Symbols the pre-link step would hide (surface F).
    "$repo/rust/scripts/check-exports.sh" || status=1
    # Registered natives vs the names the JS glue uses (surface B).
    "$repo/rust/scripts/check-natives.sh" || status=1
    exit $status
    ;;
*)
    echo "usage: contracts.sh gen|check" >&2
    exit 2
    ;;
esac
