#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""Run a command with ORIGINE_AWS_LC_PREFIX set to the Zig-built AWS-LC.

`lib/aws-lc` installs libcrypto into the build's install prefix, which is only known in the make
phase (it is not `zig-out` when `zig build -p` is used), so `zig build` passes it here as a
`LazyPath` argument. This only sets the variable and replaces itself with the command;
docs/aws-lc.md has the whole picture.

usage: cargo-aws-lc.py <aws-lc prefix> <command> [args...]
"""

import os
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print(
            "usage: cargo-aws-lc.py <aws-lc prefix> <command> [args...]",
            file=sys.stderr,
        )
        return 2
    os.environ["ORIGINE_AWS_LC_PREFIX"] = os.path.abspath(sys.argv[1])
    try:
        os.execvp(sys.argv[2], sys.argv[2:])
    except OSError as error:
        print(f"cargo-aws-lc.py: {sys.argv[2]}: {error.strerror}", file=sys.stderr)
        return 127
    raise AssertionError("unreachable: os.execvp replaces the process")


if __name__ == "__main__":
    sys.exit(main())
