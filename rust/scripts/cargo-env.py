#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""Run a command (cargo) in rust/ with environment variables whose values are paths from the Zig build.

usage: cargo-env.py [NAME=path ...] [--copy ARTIFACT DEST] -- <command> [args...]

A Zig `Run` step cannot export a variable from a `LazyPath` (the path is known only at make time), so
the build passes them as arguments and this script makes them absolute, exports them and replaces
itself with the command. Used for the V8_ZIG_* variables the vendored `v8` crate's build.rs reads
(lib/v8_zig/rusty_v8/build.rs, lib/v8_zig/docs/rusty.md) and ORIGINE_AWS_LC_PREFIX, which the vendored
aws-lc-sys build.rs reads (docs/aws-lc.md). The working directory is rust/, where rust-toolchain.toml
pins the toolchain.

With `--copy`, the command runs as a child and, when it succeeds, ARTIFACT (relative to rust/) is
copied to DEST: a Zig output path, so the Run caches and delivers the file. A copy, not a link: cargo
rewrites files in target/ in place.
Its output is printed only when it fails: a cached Zig Run reports any stderr of a successful run under
the "failed command:" header, and cargo always writes progress there (lints run in `just check-rust`).
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

RUST = Path(__file__).resolve().parent.parent
# bindgen needs libclang >= 21.1; V8's clang bundle does not ship one.
COMMAND_LINE_TOOLS = "/Library/Developer/CommandLineTools/usr/lib"


def main() -> int:
    args = sys.argv[1:]
    if "--" not in args or args.index("--") == len(args) - 1:
        print("usage: cargo-env.py [NAME=path ...] [--copy ARTIFACT DEST] -- <command> [args...]", file=sys.stderr)
        return 2
    split = args.index("--")
    options = args[:split]
    copy = None
    if "--copy" in options:
        at = options.index("--copy")
        if len(options[at + 1 : at + 3]) != 2:
            print("cargo-env.py: --copy needs ARTIFACT DEST", file=sys.stderr)
            return 2
        copy = (options[at + 1], os.path.abspath(options[at + 2]))
        options = options[:at] + options[at + 3 :]
    for pair in options:
        name, _, path = pair.partition("=")
        if not name or not path:
            print(f"cargo-env.py: expected NAME=path, got {pair!r}", file=sys.stderr)
            return 2
        os.environ[name] = os.path.abspath(path)
    if "LIBCLANG_PATH" not in os.environ and os.path.isdir(COMMAND_LINE_TOOLS):
        os.environ["LIBCLANG_PATH"] = COMMAND_LINE_TOOLS
    command = args[split + 1 :]
    os.chdir(RUST)
    if copy is not None:
        artifact, dest = copy
        try:
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        except OSError as error:
            print(f"cargo-env.py: {command[0]}: {error.strerror}", file=sys.stderr)
            return 127
        if result.returncode != 0:
            sys.stderr.buffer.write(result.stdout)
            return result.returncode
        shutil.copyfile(RUST / artifact, dest)
        return 0
    try:
        os.execvp(command[0], command)
    except OSError as error:
        print(f"cargo-env.py: {command[0]}: {error.strerror}", file=sys.stderr)
        return 127
    raise AssertionError("unreachable: os.execvp replaces the process")


if __name__ == "__main__":
    sys.exit(main())
