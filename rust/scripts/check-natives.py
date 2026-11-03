#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""CONTRACT (docs/contracts.md, surface B): the guest glue (src/js/glue/*.js) must use exactly the
natives the Rust registry declares (`#[native(path = "namespace.name")]` in
rust/crates/origine_api, and the class installers of `#[class(path = "namespace.Class")]`).
  - every registered `namespace.name` is referenced in the glue (as `native.ns.name`, or `ops.name`
    for the async fs ops, which glue/fs.js reaches through `makeAsyncOps(native.fsAsync, ..)`);
  - every `native.<registered namespace>.<name>` the glue mentions is registered.

usage: check-natives.py   (from anywhere; prints violations, exits 1 if any)
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
API = ROOT / "rust" / "crates" / "origine_api" / "src"
GLUE = ROOT / "src" / "js" / "glue"

ATTRIBUTE = re.compile(r"^#\[(native|class)\(")
PATH = re.compile(r'path = "([A-Za-z0-9]+\.[A-Za-z0-9]+)"')


def registered() -> list[str]:
    paths: set[str] = set()
    for source in sorted(API.glob("*.rs")):
        for line in source.read_text().splitlines():
            if ATTRIBUTE.match(line):
                paths.update(PATH.findall(line))
    return sorted(paths)


def glue_lines() -> list[str]:
    lines: list[str] = []
    for source in sorted(GLUE.rglob("*")):
        if source.is_file():
            lines.extend(source.read_text(errors="replace").splitlines())
    return lines


def main() -> int:
    paths = registered()
    if not paths:
        print("check-natives: no registered natives found", file=sys.stderr)
        return 2
    lines = glue_lines()
    status = 0
    for path in paths:
        namespace, name = path.split(".", 1)
        used = any(
            re.search(rf"native\.{namespace}\.{name}\b", line)
            or re.search(rf"\bops\.{name}\b", line)
            or re.search(rf"^\s*\.{name}\(", line)
            for line in lines
        )
        if not used:
            print(
                f"check-natives: {path} is registered in Rust but never used by src/js/glue",
                file=sys.stderr,
            )
            status = 1
    for namespace in sorted({path.split(".", 1)[0] for path in paths}):
        mentioned = {
            match
            for line in lines
            for match in re.findall(rf"native\.{namespace}\.([A-Za-z0-9]+)", line)
        }
        for name in sorted(mentioned):
            if f"{namespace}.{name}" not in paths:
                print(
                    f"check-natives: the glue uses native.{namespace}.{name}, "
                    "which no #[native(path = ...)] registers",
                    file=sys.stderr,
                )
                status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
