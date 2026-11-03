#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""CONTRACT (docs/contracts.md, surface F): every `#[no_mangle]` / `#[unsafe(no_mangle)]` fn in the
Rust crates must have a name starting with a prefix that rust/build.zig keeps global
(`kept_symbol_prefixes`); anything else is hidden by the pre-link step and Zig cannot call it.
(origine_api_macros only generates `origine_api_native_*` items.) The prefixes are read from
rust/build.zig so there is one list.

usage: check-exports.py   (from anywhere; prints violations, exits 1 if any)
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent

PREFIXES = re.compile(r"^const kept_symbol_prefixes = .*\{(.*)\};$", re.MULTILINE)
NO_MANGLE = re.compile(r"^\s*#\[(unsafe\()?no_mangle")
FN = re.compile(r"fn ([A-Za-z_0-9]+)")


def kept_prefixes() -> list[str]:
    match = PREFIXES.search((ROOT / "rust" / "build.zig").read_text())
    return re.findall(r'"([^"]+)"', match.group(1)) if match else []


def sources() -> list[Path]:
    files: list[Path] = []
    for base in (ROOT / "rust" / "crates", ROOT / "rust" / "src"):
        for path in sorted(base.rglob("*.rs")):
            posix = path.as_posix()
            if "/src" not in posix or "/target/" in posix:
                continue
            if "origine_api_macros" in posix:
                continue
            files.append(path)
    return files


def main() -> int:
    prefixes = kept_prefixes()
    if not prefixes:
        print("check-exports: kept_symbol_prefixes not found in rust/build.zig", file=sys.stderr)
        return 2
    bad = False
    for path in sources():
        armed = False
        for line in path.read_text().splitlines():
            if NO_MANGLE.match(line):
                armed = True
                continue
            if not armed:
                continue
            match = FN.search(line)
            if match is None:
                continue
            name = match.group(1)
            armed = False
            if not any(name.startswith(prefix) for prefix in prefixes):
                print(
                    f"{path}: #[no_mangle] fn {name} does not start with a kept prefix "
                    f"({' '.join(prefixes)})"
                )
                bad = True
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
