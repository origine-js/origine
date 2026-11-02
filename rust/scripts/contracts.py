#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.8"
# dependencies = []
# ///
"""Generated cross-language contract files (docs/contracts.md). One list, used by both modes.

  contracts.py gen     rewrite the committed generated files in the repository
  contracts.py check   regenerate into a temporary tree, fail if a committed file differs, and
                       run the checks that need no generation (clang on the Zig-generated C
                       files, exported-symbol prefixes, registered natives)

Needs: zig, cargo (offline: bindgen is already in rust/Cargo.lock), libclang (LIBCLANG_PATH),
/usr/bin/clang or any `clang`.
"""

import difflib
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SCRIPTS = Path(__file__).resolve().parent

# path (relative to the repository root) of each generated file
FILES = [
    "rust/crates/origine_api_core/src/errno_table.rs",
    "types/generated/errno.d.ts",
    "src/api/transform/oxc_abi_check.c",
    "src/api/api_abi_check.c",
    "rust/crates/origine_api/src/abi_gen.rs",
    "rust/crates/origine_io/src/sys_gen.rs",
    "rust/crates/origine_oxc/src/header_abi.rs",
    "rust/crates/origine_repl/src/header_abi.rs",
    "src/repl/repl_abi_check.c",
]

# The Zig declarations of each ABI against its header (surfaces B, C, E and G).
CLANG_CHECKS = [
    ("rust/crates/origine_oxc/include", "src/api/transform/oxc_abi_check.c"),
    ("rust/crates/origine_repl/include", "src/repl/repl_abi_check.c"),
    ("rust/crates/origine_api/include", "src/api/api_abi_check.c"),
]


def generate(out: Path) -> None:
    for name in FILES:
        (out / name).parent.mkdir(parents=True, exist_ok=True)
    # Surface D (errno table, TypeScript errno types) and the Zig half of surfaces E and G
    # (oxc_abi_check.c, repl_abi_check.c): from Zig declarations.
    subprocess.run(
        ["zig", "run", "src/gen_contracts.zig", "--", str(out)], cwd=ROOT, check=True
    )
    # Surfaces A, E and G: bindgen over the C headers.
    bindgen = [
        (
            "io-sys",
            "../src/io/include/origine_io.h",
            "rust/crates/origine_io/src/sys_gen.rs",
        ),
        (
            "oxc-abi",
            "crates/origine_oxc/include/origine_oxc.h",
            "rust/crates/origine_oxc/src/header_abi.rs",
        ),
        (
            "repl-abi",
            "crates/origine_repl/include/origine_repl.h",
            "rust/crates/origine_repl/src/header_abi.rs",
        ),
        (
            "api-abi",
            "crates/origine_api/include/origine_api.h",
            "rust/crates/origine_api/src/abi_gen.rs",
        ),
    ]
    for mode, header, output in bindgen:
        subprocess.run(
            [
                "cargo",
                "run",
                "-q",
                "--offline",
                "--locked",
                "-p",
                "origine_gen",
                "--",
                mode,
                header,
                str(out / output),
            ],
            cwd=ROOT / "rust",
            check=True,
        )


def check() -> int:
    status = 0
    with tempfile.TemporaryDirectory() as tmp:
        generated = Path(tmp)
        generate(generated)
        for name in FILES:
            committed = (ROOT / name).read_text()
            fresh = (generated / name).read_text()
            if committed == fresh:
                continue
            sys.stdout.writelines(
                difflib.unified_diff(
                    committed.splitlines(keepends=True),
                    fresh.splitlines(keepends=True),
                    fromfile=str(ROOT / name),
                    tofile=str(generated / name),
                )
            )
            print(
                f"check-contracts: {name} is stale; run `just gen-contracts` and commit the result",
                file=sys.stderr,
            )
            status = 1
    for include, source in CLANG_CHECKS:
        if subprocess.run(
            ["clang", "-fsyntax-only", "-I", str(ROOT / include), str(ROOT / source)]
        ).returncode:
            status = 1
    # Symbols the pre-link step would hide (surface F).
    if subprocess.run([sys.executable, str(SCRIPTS / "check-exports.py")]).returncode:
        status = 1
    # Registered natives vs the names the JS glue uses (surface B).
    if subprocess.run([sys.executable, str(SCRIPTS / "check-natives.py")]).returncode:
        status = 1
    return status


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode not in ("gen", "check"):
        print("usage: contracts.py gen|check", file=sys.stderr)
        return 2
    if not os.environ.get("LIBCLANG_PATH") and os.path.isdir(
        "/Library/Developer/CommandLineTools/usr/lib"
    ):
        os.environ["LIBCLANG_PATH"] = "/Library/Developer/CommandLineTools/usr/lib"
    if mode == "gen":
        generate(ROOT)
        return 0
    return check()


if __name__ == "__main__":
    sys.exit(main())
