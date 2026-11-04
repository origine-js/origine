#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["rich==14.2.0"]
# ///
"""Move the Chromium pins in MODULE.bazel to a V8 release: `just bump-v8 15.9.1`.

Every `https://chromium.googlesource.com/<repository>@<commit>` string in MODULE.bazel is matched by
repository against the DEPS file of that V8 tag and given its commit; V8 itself gets the tag's commit.
The Clang archive (`origine_llvm`) moves to the revision DEPS names, with its digest. A repository
DEPS no longer lists is an error. Review the diff, then rebuild: the patch series may need updating.
"""

import ast
import base64
import hashlib
import json
import re
import sys
import urllib.request
from pathlib import Path

from rich.console import Console
from rich.progress import BarColumn, DownloadColumn, Progress, TransferSpeedColumn
from rich.table import Table

MODULE = Path(__file__).resolve().parents[2] / "MODULE.bazel"
GOOGLESOURCE = "https://chromium.googlesource.com"
V8 = GOOGLESOURCE + "/v8/v8.git"
LLVM_PLATFORM = "Mac_arm64"

console = Console(stderr=True)


def fail(message: str) -> None:
    console.print(f"[bold red]error:[/] {message}")
    sys.exit(1)


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url) as response:
        return response.read()


def sha256(url: str) -> str:
    digest = hashlib.sha256()
    size = 0
    with urllib.request.urlopen(url) as response:
        expected = response.headers.get("Content-Length")
        with Progress("[progress.description]{task.description}", BarColumn(), DownloadColumn(), TransferSpeedColumn(), console=console) as progress:
            task = progress.add_task("hashing " + url.rsplit("/", 1)[1], total=int(expected) if expected else None)
            while chunk := response.read(1 << 20):
                digest.update(chunk)
                size += len(chunk)
                progress.update(task, advance=len(chunk))
    # urllib does not notice a connection cut short; a digest of a truncated file is a wrong pin.
    if expected is not None and int(expected) != size:
        fail(f"{url}: received {size} of {expected} bytes; run again")
    return digest.hexdigest()


def parse_deps(text: str) -> dict:
    """The `deps` of a gclient DEPS file, read without executing it.

    Only literals, `Var(name)`, `Str(literal)` and `+` on strings are understood; anything else is an
    error, so downloaded text is never run.
    """
    variables: dict = {}

    def value(node):
        if isinstance(node, ast.Constant):
            return node.value
        if isinstance(node, ast.Dict):
            return {value(k): value(v) for k, v in zip(node.keys, node.values)}
        if isinstance(node, (ast.List, ast.Tuple)):
            return [value(e) for e in node.elts]
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            return value(node.left) + value(node.right)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and len(node.args) == 1:
            argument = value(node.args[0])
            if node.func.id == "Str":
                return argument
            if node.func.id == "Var":
                return variables[argument]
        raise ValueError(f"unsupported DEPS expression: {ast.dump(node)[:120]}")

    deps = None
    for statement in ast.parse(text).body:
        if isinstance(statement, ast.Assign) and len(statement.targets) == 1 and isinstance(statement.targets[0], ast.Name):
            if statement.targets[0].id == "vars":
                variables.update(value(statement.value))
            elif statement.targets[0].id == "deps":
                deps = value(statement.value)
    return deps


def main() -> None:
    if len(sys.argv) != 2:
        console.print(__doc__)
        sys.exit(2)
    version = sys.argv[1]
    with console.status(f"Reading the DEPS of V8 {version}"):
        body = fetch(f"{GOOGLESOURCE}/v8/v8/+/refs/tags/{version}?format=JSON").decode().split("\n", 1)[1]
        revision = json.loads(body)["commit"]
        deps = parse_deps(base64.b64decode(fetch(f"{GOOGLESOURCE}/v8/v8/+/{revision}/DEPS?format=TEXT")).decode())

    commits = {V8: revision}
    for entry in deps.values():
        url = entry.get("url") if isinstance(entry, dict) else entry
        if isinstance(url, str) and "@" in url:
            remote, commit = url.rsplit("@", 1)
            commits[remote] = commit

    before = MODULE.read_text()
    changes = Table("pin", "from", "to", title=f"V8 {version} ({revision[:12]})", title_justify="left")

    def repin(match):
        remote, old = match.group(1), match.group(2)
        if remote not in commits:
            fail(f"{remote}: not in the DEPS of V8 {version}")
        if old != commits[remote]:
            changes.add_row(remote.removeprefix(GOOGLESOURCE + "/"), old[:12], f"[green]{commits[remote][:12]}")
        return f"{remote}@{commits[remote]}"

    text = re.sub(r"(https://chromium\.googlesource\.com/[^\"@]+)@([0-9a-f]{40})", repin, before)
    text = re.sub(r"# V8 \d+\.\d+\.\d+\S*", f"# V8 {version}", text)

    clang = next(
        m.group(1)
        for o in deps["third_party/llvm-build/Release+Asserts"]["objects"]
        if (m := re.fullmatch(r"Linux_x64/clang-(llvmorg-.+)\.tar\.xz", o["object_name"]))
    )
    url = f"https://commondatastorage.googleapis.com/chromium-browser-clang/{LLVM_PLATFORM}/clang-{clang}.tar.xz"
    llvm = re.search(r'name = "origine_llvm",\n\s+url = "([^"]+)",\n\s+sha256 = "([0-9a-f]+)"', text)
    if not llvm:
        fail("MODULE.bazel: no origine_llvm http_archive with url and sha256")
    if llvm.group(1) != url:
        old = re.search(r"clang-(llvmorg-.+)\.tar\.xz", llvm.group(1)).group(1)
        start, end = llvm.span()
        text = text[:start] + llvm.group(0).replace(llvm.group(1), url).replace(llvm.group(2), sha256(url)) + text[end:]
        changes.add_row("clang (origine_llvm)", old, f"[green]{clang}")

    if text == before:
        console.print(f"[green]MODULE.bazel already pins V8 {version}")
        return
    MODULE.write_text(text)
    console.print(changes)
    console.print("[bold]Updated MODULE.bazel.[/] Review the diff, then rebuild V8 (`just build-v8`); the patch series may need updating.")


if __name__ == "__main__":
    main()
