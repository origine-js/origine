#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""Run cargo for the rust/ workspace with the V8_ZIG_* variables the vendored `v8` crate's build.rs
consumes (lib/v8_zig/rusty_v8/build.rs; see lib/v8_zig/docs/rusty.md).

usage: cargo-v8.py <archive> <mimalloc> <icu> <v8_root> <gn_compile_commands.json> <binding_dir> <command...>

`zig build` calls this for the staticlib; `zig build rust-env` writes the same exports for
`just check-rust` (see `v8_env` in build.zig). Borrows its arguments; writes only what cargo writes.
"""

import os
import sys


def main() -> int:
    if len(sys.argv) < 8:
        print(
            "usage: cargo-v8.py <archive> <mimalloc> <icu> <v8_root> "
            "<gn_compile_commands.json> <binding_dir> <command...>",
            file=sys.stderr,
        )
        return 2
    archive, mimalloc, icu, v8_root, commands, binding = map(
        os.path.abspath, sys.argv[1:7]
    )
    os.environ.update(
        V8_ZIG_ARCHIVE=archive,
        V8_ZIG_MIMALLOC=mimalloc,
        V8_ZIG_ICU=icu,
        V8_ZIG_V8_ROOT=v8_root,
        V8_ZIG_GN_OUT=os.path.dirname(commands),
        V8_ZIG_BINDING=binding,
    )
    # bindgen needs libclang >= 21.1; V8's clang bundle does not ship one.
    if (
        "LIBCLANG_PATH" not in os.environ
        and os.path.isdir("/Library/Developer/CommandLineTools/usr/lib")
    ):
        os.environ["LIBCLANG_PATH"] = "/Library/Developer/CommandLineTools/usr/lib"
    # rust/rust-toolchain.toml pins the toolchain by working directory.
    rust = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(rust)
    try:
        os.execvp(sys.argv[7], sys.argv[7:])
    except OSError as error:
        print(f"cargo-v8.py: {sys.argv[7]}: {error.strerror}", file=sys.stderr)
        return 127
    raise AssertionError("unreachable: os.execvp replaces the process")


if __name__ == "__main__":
    sys.exit(main())
