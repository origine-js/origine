#!/bin/sh
# Runs cargo for the rust/ workspace with the V8_ZIG_* variables the vendored `v8` crate's
# build.rs consumes (lib/v8_zig/rusty_v8/build.rs; see lib/v8_zig/docs/rusty.md).
#
# usage: cargo-v8.sh <archive> <mimalloc> <v8_root> <gn_compile_commands.json> <binding_dir> <cargo args...>
#
# `zig build` calls this for the staticlib; `zig build rust-env` writes the same exports for
# `just check-rust` (see `v8_env` below). Borrows its arguments; writes only what cargo writes.
set -eu
abs() { case $1 in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$(pwd)" "$1" ;; esac; }
export V8_ZIG_ARCHIVE=$(abs "$1") V8_ZIG_MIMALLOC=$(abs "$2") V8_ZIG_V8_ROOT=$(abs "$3")
commands=$(abs "$4")
export V8_ZIG_GN_OUT=$(dirname "$commands") V8_ZIG_BINDING=$(abs "$5")
shift 5
# bindgen needs libclang >= 21.1; V8's clang bundle does not ship one.
if [ -z "${LIBCLANG_PATH:-}" ] && [ -d /Library/Developer/CommandLineTools/usr/lib ]; then
    export LIBCLANG_PATH=/Library/Developer/CommandLineTools/usr/lib
fi
# rust/rust-toolchain.toml pins the toolchain by working directory.
cd "$(dirname "$0")/.."
exec "$@"
