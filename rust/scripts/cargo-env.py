#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""Run a command (cargo) in rust/ with environment variables whose values are paths from the Zig build.

usage: cargo-env.py [NAME=path ...] -- <command> [args...]

A Zig `Run` step cannot export a variable from a `LazyPath` (the path is known only at make time), so
the build passes them as arguments and this script makes them absolute, exports them and replaces
itself with the command. Used for the V8_ZIG_* variables the vendored `v8` crate's build.rs reads
(lib/v8_zig/rusty_v8/build.rs, lib/v8_zig/docs/rusty.md) and ORIGINE_AWS_LC_PREFIX, which the vendored
aws-lc-sys build.rs reads (docs/aws-lc.md). The working directory is rust/, where rust-toolchain.toml
pins the toolchain.
"""

import os
import sys
from pathlib import Path

RUST = Path(__file__).resolve().parent.parent
# bindgen needs libclang >= 21.1; V8's clang bundle does not ship one.
COMMAND_LINE_TOOLS = "/Library/Developer/CommandLineTools/usr/lib"


def main() -> int:
    args = sys.argv[1:]
    if "--" not in args or args.index("--") == len(args) - 1:
        print("usage: cargo-env.py [NAME=path ...] -- <command> [args...]", file=sys.stderr)
        return 2
    split = args.index("--")
    for pair in args[:split]:
        name, _, path = pair.partition("=")
        if not name or not path:
            print(f"cargo-env.py: expected NAME=path, got {pair!r}", file=sys.stderr)
            return 2
        os.environ[name] = os.path.abspath(path)
    if "LIBCLANG_PATH" not in os.environ and os.path.isdir(COMMAND_LINE_TOOLS):
        os.environ["LIBCLANG_PATH"] = COMMAND_LINE_TOOLS
    command = args[split + 1 :]
    os.chdir(RUST)
    try:
        os.execvp(command[0], command)
    except OSError as error:
        print(f"cargo-env.py: {command[0]}: {error.strerror}", file=sys.stderr)
        return 127
    raise AssertionError("unreachable: os.execvp replaces the process")


if __name__ == "__main__":
    sys.exit(main())
