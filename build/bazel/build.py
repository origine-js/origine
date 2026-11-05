#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pydantic>=2.9,<3", "rich==14.2.0", "textual==8.2.8", "typer==0.19.2"]
# ///
"""Build, run and inspect origine with Bazel: `just build`, `just run`, `just show`.

The model (profiles, features, presets) is model.py, the TUI tui.py, the Bazel event stream bazel_events.py. Bazel knows no profiles: it
has one plain setting per module (//build/bazel/opt, the optimization: Zig modules, Rust crates and
every C/C++ library, `c_<library>`), one per feature and one per compression option (//build/bazel/settings), and every invocation states all of them.

    just build                           # the dev profile, every feature, no compression
    just build release-fast              # dev | release-fast | release-balanced | release-small | v8-debug
    just build -x minimal                # a feature profile (default | minimal)
    just build -F typescript,http        # an explicit feature set (repeatable, comma-separated)
    just build release-balanced -C icu   # compression: engine-snapshot,icu,user-snapshot,user-codecache | none
    just run release-fast -- examples/io/timers/init.js
    just show                            # profiles, features, compression and every module's mode
    just i                               # pick all of the above, or edit a copy of a profile, in a TUI
    just build my-preset                 # a preset saved from `just i` (build/bazel/profiles.toml, local-profiles.toml)
    uv run --script build/bazel/build.py examples [options]
"""

import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Annotated

import typer
from pydantic import ValidationError
from rich.box import ROUNDED
from rich.console import Console
from rich.progress import BarColumn, MofNCompleteColumn, Progress, TextColumn
from rich.table import Table

try:
    from model import (
        BUILD_PROFILES, COMPRESSION, FEATURE_PROFILES, FEATURES, OPT_C, OPT_RUST, OPT_ZIG, PROFILE_ALIASES, ROOT, STOCK_PROFILES,
        PresetError, Request,
    )
except ValueError as error:  # model.PresetError: a profiles.toml / local-profiles.toml that does not load
    sys.exit(f"error: {error}")

BINARY = ROOT / "bazel-bin/src/origine"

console = Console()

# Arguments after `--`: Bazel flags for `build`, the program's arguments for `run`.
TAIL: list[str] = []


def split_list(values: list[str] | None) -> list[str]:
    return [item for value in values or [] for item in value.split(",") if item]


def make_request(words: list[str] | None, feature_profile: str | None, features: list[str] | None, compression: list[str] | None) -> Request:
    """`words` are the positionals: at most one build profile, and `+name` features (`+dns +http`)."""
    def fail(message: str) -> typer.Exit:
        console.print(f"[red]error:[/] {message}")
        return typer.Exit(2)

    words = words or []
    profiles = [w for w in words if not w.startswith("+")]
    if len(profiles) > 1:
        raise fail(f"one build profile at a time, got {', '.join(profiles)}")
    profile_name = PROFILE_ALIASES.get(profiles[0] if profiles else "dev", profiles[0] if profiles else "dev")
    if profile_name not in BUILD_PROFILES:
        raise fail(f"unknown build profile {profile_name!r}; profiles: {', '.join(BUILD_PROFILES)}")
    build = BUILD_PROFILES[profile_name]
    if feature_profile is not None and feature_profile not in FEATURE_PROFILES:
        raise fail(f"unknown feature profile {feature_profile!r}; profiles: {', '.join(FEATURE_PROFILES)}")
    # Base: the -F set if given, else -x's feature profile, else the profile's own (a preset's), else every feature. `+name` adds to the base; `+@none` drops it.
    base = frozenset(name.removeprefix("+") for name in split_list(features)) or (
        FEATURE_PROFILES[feature_profile].features if feature_profile
        else build.features if build.features is not None
        else FEATURE_PROFILES["default"].features
    )
    plus = [name.removeprefix("+") for name in split_list([w for w in words if w.startswith("+")])]
    if "@none" in plus:
        base = frozenset()
        plus = [name for name in plus if name != "@none"]
    chosen = base | frozenset(plus)
    names = split_list(compression)
    if names == ["none"]:
        names = []
    elif "none" in names:
        raise fail("`-C none` cannot be combined with other options")
    for name in names:
        if name not in COMPRESSION:
            raise fail(f"unknown compression {name!r}; options: {', '.join(COMPRESSION)}, none")
    try:
        return Request(
            build=build, features=chosen,
            compression=frozenset(names) if compression else build.compression,
        )
    except ValidationError as error:
        raise fail("; ".join(e["msg"].removeprefix("Value error, ") for e in error.errors())) from None


# ---------------------------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------------------------

app = typer.Typer(add_completion=False, no_args_is_help=True, help=__doc__.split("\n\n")[0])

WordsArg = Annotated[
    list[str] | None,
    typer.Argument(help="profile (" + " | ".join(BUILD_PROFILES) + ", default dev) and +features, e.g. release-small +dns +http"),
]
FeatureProfileOpt = Annotated[str | None, typer.Option("--feature-profile", "-x", help=" | ".join(FEATURE_PROFILES) + " (default: the profile's own, else default)")]
FeatureOpt = Annotated[
    list[str] | None, typer.Option("--feature", "-F", help="features, comma-separated (repeatable): " + ", ".join(FEATURES))
]
CompressionOpt = Annotated[
    list[str] | None,
    typer.Option("--compression", "-C", help="comma-separated, or none: " + ", ".join(COMPRESSION) + " (default: the profile's)"),
]


def bazel(*args: str) -> int:
    console.print(f"[dim]$ bazel {' '.join(args)}[/]")
    return subprocess.call(["bazel", *args], cwd=ROOT)


def summary(request: Request, seconds: float | None = None) -> None:
    # Labels are the structure (bold cyan); the profile name is the headline (bold green); the box
    # and the description, size and timing are context (dim).
    table = Table(show_header=False, box=ROUNDED, border_style="dim", padding=(0, 1))
    table.add_column(style="bold cyan", no_wrap=True)
    table.add_column()
    table.add_row("profile", f"[bold green]{request.build.name}[/]  [dim]{request.build.doc}[/]")
    table.add_row("features", feature_chips(request.features))
    table.add_row("compression", ", ".join(sorted(request.compression)) or "[dim]none[/]")
    console.print(table)
    if BINARY.exists():
        timing = f" | [dim]took {seconds:.3f} s[/]" if seconds is not None else ""
        console.print(f"[bold cyan]✓ built[/]  {BINARY.relative_to(ROOT)} | [dim]{BINARY.stat().st_size / 2**20:.2f} MiB[/]{timing}")


def feature_chips(features: frozenset[str]) -> str:
    """Features as `+name` chips, e.g. `+dns +http`."""
    return " ".join(f"[dim]+[/]{name}" for name in sorted(features)) or "[dim]none[/]"


def header(request: Request) -> None:
    """The profile and features, printed before Bazel starts."""
    console.print(f"[bold cyan]{'profile':<10}[/]  [bold green]{request.build.name}[/]  [dim]{request.build.doc}[/]")
    console.print(f"[bold cyan]{'features':<10}[/]  {feature_chips(request.features)}")


def build_request(request: Request) -> int:
    header(request)
    started = time.monotonic()
    code = bazel("build", *request.bazel_flags(), *TAIL, "//src:origine")
    if code == 0 and "--nobuild" in TAIL:
        console.print("[green]analyzed[/] (--nobuild)")
    elif code == 0:
        summary(request, time.monotonic() - started)
    return code


@app.command()
def build(words: WordsArg = None, feature_profile: FeatureProfileOpt = None, feature: FeatureOpt = None, compression: CompressionOpt = None) -> None:
    """Build bazel-bin/src/origine; Bazel flags may follow `--`."""
    raise typer.Exit(build_request(make_request(words, feature_profile, feature, compression)))


@app.command()
def run(words: WordsArg = None, feature_profile: FeatureProfileOpt = None, feature: FeatureOpt = None, compression: CompressionOpt = None) -> None:
    """Build, then run origine in the current directory; its arguments follow `--`."""
    request = make_request(words, feature_profile, feature, compression)
    args = list(TAIL)
    TAIL.clear()
    if code := build_request(request):
        raise typer.Exit(code)
    raise typer.Exit(subprocess.call([BINARY, *args]))


@app.command()
def examples(
    words: WordsArg = None,
    feature_profile: FeatureProfileOpt = None,
    feature: FeatureOpt = None,
    compression: CompressionOpt = None,
    timeout: Annotated[int, typer.Option(help="seconds per example")] = 30,
) -> None:
    """Build, then run every examples/**/init.{js,ts}; list the ones that fail."""
    request = make_request(words, feature_profile, feature, compression)
    if code := build_request(request):
        raise typer.Exit(code)
    raise typer.Exit(run_examples(request, timeout))


def run_examples(request: Request, timeout: int) -> int:
    """Runs every examples/**/init.{js,ts} on the built binary; prints the failures. Returns the exit code."""
    inits = sorted(p for p in (ROOT / "examples").rglob("init.*") if p.suffix in (".js", ".ts"))
    failed = []
    with tempfile.TemporaryDirectory() as home, Progress(
        TextColumn("{task.description}"), BarColumn(), MofNCompleteColumn(), console=console
    ) as progress:
        task = progress.add_task("examples", total=len(inits))
        for init in inits:
            relative = init.relative_to(ROOT)
            progress.update(task, description=str(relative.parent))
            try:
                result = subprocess.run(
                    [BINARY, relative], cwd=ROOT, env=os.environ | {"HOME": home},
                    capture_output=True, text=True, timeout=timeout,
                )
                if result.returncode:
                    failed.append((relative, (result.stderr or result.stdout).strip().splitlines()[-1:] or [""]))
            except subprocess.TimeoutExpired:
                failed.append((relative, [f"timed out after {timeout}s"]))
            progress.advance(task)
    if not failed:
        console.print(f"[green]all {len(inits)} examples passed[/]")
        return 0
    table = Table(title=f"{len(failed)} of {len(inits)} examples failed", title_justify="left")
    table.add_column("example")
    table.add_column("last line")
    for path, last in failed:
        table.add_row(str(path), last[0])
    console.print(table)
    off = sorted(set(FEATURES) - request.features)
    if off:
        console.print(f"[dim]features off: {', '.join(off)}; their examples are expected to fail[/]")
    return 1


@app.command()
def show(profile: Annotated[str | None, typer.Argument(help="print the Bazel flags of this profile too")] = None) -> None:
    """Print the build profiles, feature profiles, features, compression and every module's mode."""
    table = Table(title="Build profiles (stock; shared and local presets: build/bazel/profiles.toml, local-profiles.toml)", title_justify="left")
    for column in ("profile", "from", "zig mode", "features", "compression", "extra flags", "what"):
        table.add_column(column)
    for p in BUILD_PROFILES.values():
        table.add_row(
            p.name, p.origin, p.zig_mode, "-" if p.features is None else ", ".join(sorted(p.features)) or "none",
            ", ".join(sorted(p.compression)) or "-", " ".join(p.bazel_flags) or "-", p.doc,
        )
    console.print(table)

    table = Table(title="Feature profiles (-x)", title_justify="left")
    for column in ("profile", "features", "what"):
        table.add_column(column)
    for fp in FEATURE_PROFILES.values():
        table.add_row(fp.name, ", ".join(sorted(fp.features)) or "-", fp.doc)
    console.print(table)

    table = Table(title="Features (-F)", title_justify="left")
    for column in ("feature", "requires", "what it compiles in"):
        table.add_column(column)
    for f in FEATURES.values():
        table.add_row(f.name, ", ".join(f.requires) or "-", f.doc)
    console.print(table)

    table = Table(title="Compression (-C)", title_justify="left")
    for column in ("option", "Bazel setting", "what"):
        table.add_column(column)
    for o in COMPRESSION.values():
        table.add_row(o.name, o.flag, o.doc)
    console.print(table)

    table = Table(title="Module modes (Zig: -O<mode>; Rust: -Copt-level; C: -O<level>, inherit = --compilation_mode)", title_justify="left")
    table.add_column("module", no_wrap=True)
    for p in STOCK_PROFILES.values():
        table.add_column(p.name)
    for kind, declared in (("zig", OPT_ZIG), ("rust", OPT_RUST), ("c", OPT_C)):
        for module in declared:
            table.add_row(f"{kind}:{module}", *[getattr(p, kind)[module] for p in STOCK_PROFILES.values()])
    console.print(table)

    if profile:
        request = make_request([profile], None, None, None)
        console.print(f"[bold]{profile}[/] flags:\n  " + "\n  ".join(request.bazel_flags()))


# ---------------------------------------------------------------------------------------------
# `just i`
# ---------------------------------------------------------------------------------------------


@app.command()
def interactive() -> None:
    """Pick a profile and edit a copy of it (features, compression, any module's level) in a TUI."""
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        console.print("[red]error:[/] `interactive` needs a terminal")
        raise typer.Exit(2)
    from tui import BuildApp  # Textual loads only here, so the other commands stay fast

    outcome = BuildApp().run()
    if outcome is None:
        raise typer.Exit(0)
    request = outcome.selection.request()
    if outcome.action == "print":
        header(request)
        console.print(outcome.selection.command(), soft_wrap=True, highlight=False)
        raise typer.Exit(0)
    code = build_request(request)
    if code:
        raise typer.Exit(code)
    if outcome.action == "run":
        raise typer.Exit(subprocess.call([BINARY, *outcome.args]))
    if "tests" in outcome.checks:
        code = subprocess.call(["zig", "build", "test"], cwd=ROOT) or code
    if "examples" in outcome.checks:
        code = run_examples(request, 30) or code
    raise typer.Exit(code)


app.command("i", hidden=True)(interactive)


def main() -> None:
    global TAIL
    if "--" in sys.argv:
        at = sys.argv.index("--")
        TAIL = sys.argv[at + 1:]
        del sys.argv[at:]
    try:
        app()
    except PresetError as error:
        console.print(f"[red]error:[/] {error}")
        raise SystemExit(2) from None


if __name__ == "__main__":
    main()
