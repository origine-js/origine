#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pydantic>=2.9,<3", "rich==14.2.0", "textual==8.2.8", "typer==0.19.2"]
# ///
"""Build, run and inspect origine with Bazel: `just build`, `just run`, `just show`.

This file is the only place build profiles and feature profiles exist. Bazel knows no profiles: it
has one plain setting per module (//build/bazel/opt, the optimization), one per feature and one per
compression option (//build/bazel/settings), and every invocation states all of them.

    just build                           # the dev profile, every feature, no compression
    just build release-fast              # dev | release-fast | release-balanced | release-small | v8-debug
    just build -x minimal                # a feature profile (default | minimal)
    just build -F typescript,http        # an explicit feature set (repeatable, comma-separated)
    just build release-balanced -C icu   # compression: engine-snapshot,icu,user-snapshot,user-codecache | none
    just run release-fast -- examples/io/timers/init.js
    just show                            # profiles, features, compression and every module's mode
    just i                               # pick all of the above (or a custom profile) in a TUI
    uv run --script build/bazel/build.py examples [options]
"""

import ast
import os
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Annotated, Literal, get_args

import typer
from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator
from rich.box import ROUNDED
from rich.console import Console, Group
from rich.progress import BarColumn, MofNCompleteColumn, Progress, TextColumn
from rich.table import Table
from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Checkbox, DataTable, Footer, Header, Input, Label, OptionList, Select, SelectionList, Static, TabbedContent, TabPane
from textual.widgets.option_list import Option
from textual.widgets.selection_list import Selection

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "bazel-bin/src/origine"
SETTINGS = "//build/bazel/settings"
OPT = "//build/bazel/opt"
ZIG_MODE_FLAG = "--@rules_zig//zig/settings:mode"

console = Console()

# Arguments after `--`: Bazel flags for `build`, the program's arguments for `run`.
TAIL: list[str] = []


def load_literal(path: Path, name: str) -> dict:
    """A top-level dict literal of a .bzl file, read without running it (keep them plain literals)."""
    for node in ast.parse(path.read_text()).body:
        if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == name for t in node.targets):
            return ast.literal_eval(node.value)
    sys.exit(f"{path}: no {name}")


# ---------------------------------------------------------------------------------------------
# Features and compression: declared in build/bazel/features.bzl, loaded here.
# ---------------------------------------------------------------------------------------------


class Feature(BaseModel):
    model_config = ConfigDict(frozen=True)
    name: str
    doc: str
    requires: tuple[str, ...] = ()


class CompressionOption(BaseModel):
    model_config = ConfigDict(frozen=True)
    flag: str  # the Bazel setting, e.g. engine_snapshot_compression
    doc: str

    @property
    def name(self) -> str:
        """The user-facing name: `engine-snapshot`, `icu`, `user-snapshot`, `user-codecache`."""
        return self.flag.removesuffix("_compression").replace("_", "-")


FEATURES = {
    name: Feature(name=name, doc=info["doc"], requires=tuple(info["requires"]))
    for name, info in load_literal(ROOT / "build/bazel/features.bzl", "FEATURES").items()
}
COMPRESSION = {
    option.name: option
    for option in (
        CompressionOption(flag=flag, doc=info["doc"])
        for flag, info in load_literal(ROOT / "build/bazel/features.bzl", "COMPRESSION").items()
    )
}


def check_features(names: frozenset[str]) -> frozenset[str]:
    """Raises ValueError for an unknown feature or one whose `requires` is not in the set."""
    for name in sorted(names):
        if name not in FEATURES:
            raise ValueError(f"unknown feature {name!r}; features: {', '.join(FEATURES)}")
    for name in sorted(names):
        for required in FEATURES[name].requires:
            if required not in names:
                raise ValueError(f"feature {name!r} requires {required!r} (add -F {required})")
    return names


class FeatureProfile(BaseModel):
    """A named feature set; `-x` picks one, `-F` states a set directly."""

    model_config = ConfigDict(frozen=True)
    name: str
    doc: str
    features: frozenset[str]

    @model_validator(mode="after")
    def _requirements(self) -> "FeatureProfile":
        check_features(self.features)
        return self


FEATURE_PROFILES = {
    p.name: p
    for p in [
        FeatureProfile(name="default", doc="every feature", features=frozenset(FEATURES)),
        FeatureProfile(name="minimal", doc="no optional feature", features=frozenset()),
    ]
}

# ---------------------------------------------------------------------------------------------
# Build profiles: the mode of every module.
# ---------------------------------------------------------------------------------------------

ZigMode = Literal["debug", "safe", "fast", "small"]
RustLevel = Literal["0", "1", "2", "3", "s", "z"]

# The modules, in //build/bazel:opt.bzl (checked against it below).
ZIG_CRITICAL = ["safe", "io", "io_native", "v8", "util", "diagnostics", "mimalloc", "lz4"]
ZIG_HOST = ["engine", "managed", "origine_main", "snapshot_tool_main"]
RUST_CRITICAL = [
    "origine_io", "origine_alloc", "origine_oxc", "origine_tls", "origine_h2", "origine_dns",
    "origine_transport", "rusty_v8",
]
RUST_HOST = ["origine_api", "origine_api_core", "origine_api_fs", "origine_repl", "origine_native"]

OPT_ZIG = load_literal(ROOT / "build/bazel/opt.bzl", "ZIG_MODULES")
OPT_RUST = load_literal(ROOT / "build/bazel/opt.bzl", "RUST_CRATES")

ZIG_GLOBAL_MODE = {"debug": "debug", "safe": "release_safe", "fast": "release_fast", "small": "release_small"}


class BuildProfile(BaseModel):
    """How a build optimizes each module, plus what else it passes to Bazel.

    `zig` and `rust` hold the mode of EVERY module (Bazel has no defaults that matter); `zig_mode` is
    rules_zig's global mode (modules without their own `-O`, the generated option modules).
    """

    model_config = ConfigDict(frozen=True)
    name: str
    doc: str
    zig_mode: ZigMode
    zig: dict[str, ZigMode]
    rust: dict[str, RustLevel]
    compression: frozenset[str] = frozenset()
    compilation_mode: Literal["opt", "dbg"] = "opt"
    bazel_flags: tuple[str, ...] = ()  # e.g. --copt=-Os

    @model_validator(mode="after")
    def _complete(self) -> "BuildProfile":
        for kind, given, declared in (("Zig", self.zig, OPT_ZIG), ("Rust", self.rust, OPT_RUST)):
            if set(given) != set(declared):
                raise ValueError(
                    f"{self.name}: {kind} modules differ from build/bazel/opt.bzl: "
                    f"missing {sorted(set(declared) - set(given))}, unknown {sorted(set(given) - set(declared))}"
                )
        for option in self.compression:
            if option not in COMPRESSION:
                raise ValueError(f"{self.name}: unknown compression {option!r}")
        return self


def profile(
    name: str,
    doc: str,
    *,
    critical_zig: ZigMode | None,
    host_zig: ZigMode,
    critical_rust: RustLevel,
    host_rust: RustLevel,
    mimalloc: ZigMode | None = None,
    v8_zig: ZigMode | None = None,
    v8_rust: RustLevel | None = None,
    **rest,
) -> BuildProfile:
    """Expands the critical/host groups into a mode per module. Critical Zig is `fast` (mimalloc
    `safe`) unless stated; lz4 is `small` in every profile, as build.zig's `.small` dependency.
    `v8_zig` and `v8_rust` override the v8 modules (`v8`, `rusty_v8`) when a profile keeps V8 apart."""
    zig: dict[str, ZigMode] = {m: critical_zig or "fast" for m in ZIG_CRITICAL}
    zig["mimalloc"] = mimalloc or ("safe" if critical_zig is None else critical_zig)
    zig["lz4"] = "small"
    zig |= {m: host_zig for m in ZIG_HOST}
    rust: dict[str, RustLevel] = {c: critical_rust for c in RUST_CRITICAL} | {c: host_rust for c in RUST_HOST}
    if v8_zig:
        zig["v8"] = v8_zig
    if v8_rust:
        rust["rusty_v8"] = v8_rust
    return BuildProfile(name=name, doc=doc, zig=zig, rust=rust, zig_mode=host_zig, **rest)


BUILD_PROFILES = {
    p.name: p
    for p in [
        profile(
            "dev", "optimize for fast debugging (default; reuse release v8)",
            critical_zig=None, host_zig="debug", critical_rust="3", host_rust="0",
        ),
        profile(
            "release-fast", "everything optimized for speed",
            critical_zig="fast", host_zig="fast", critical_rust="3", host_rust="3",
        ),
        profile(
            "release-balanced", "balanced between size and performance",
            critical_zig=None, host_zig="small", critical_rust="3", host_rust="s",
        ),
        profile(
            "release-small", "release small, release v8, everything else small; engine snapshot and ICU compressed",
            critical_zig="small", host_zig="small", critical_rust="s", host_rust="s",
            v8_zig="fast", v8_rust="3",
            compression=frozenset({"engine-snapshot", "icu"}),
            # C/C++ (V8 included) and the registry crates, which have no per-crate setting.
        ),
        profile(
            "release-smaller", "release smaller, everything small, including v8",
            critical_zig="small", host_zig="small", critical_rust="s", host_rust="s",
            compression=frozenset({"engine-snapshot", "icu"}),
            # C/C++ (V8 included) and the registry crates, which have no per-crate setting.
            bazel_flags=("--copt=-Os", "--@rules_rust//rust/settings:extra_rustc_flags=-Copt-level=s"),
        ),
        # # Commented out: no jitless v8 build flag yet
        # profile(
        #     "release-tiny", "everything small (including v8, jitless)",
        #     critical_zig="small", host_zig="small", critical_rust="s", host_rust="s",
        #     compression=frozenset({"engine-snapshot", "icu"}),
        #     # C/C++ (V8 included) and the registry crates, which have no per-crate setting.
        #     bazel_flags=("--copt=-Os", "--@rules_rust//rust/settings:extra_rustc_flags=-Copt-level=s"),
        # ),
        profile(
            "v8-debug", "everything debug (its own debug v8, used for v8 patching work)",
            critical_zig=None, host_zig="debug", critical_rust="0", host_rust="0",
            compilation_mode="dbg",
        ),
    ]
}


# Names accepted on the command line that stand for another profile.
PROFILE_ALIASES = {"release": "release-balanced"}


class Request(BaseModel):
    """One invocation: a build profile, a feature set and the compression options."""

    model_config = ConfigDict(frozen=True)
    build: BuildProfile
    features: frozenset[str]
    compression: frozenset[str]

    @model_validator(mode="after")
    def _features(self) -> "Request":
        check_features(self.features)
        return self

    def bazel_flags(self) -> list[str]:
        b = self.build
        flags = [f"--compilation_mode={b.compilation_mode}", f"{ZIG_MODE_FLAG}={ZIG_GLOBAL_MODE[b.zig_mode]}", *b.bazel_flags]
        flags += [f"--{OPT}:{module}={mode}" for module, mode in (b.zig | b.rust).items()]
        flags += [f"--{SETTINGS}:{name}={str(name in self.features).lower()}" for name in FEATURES]
        flags += [f"--{SETTINGS}:{o.flag}={str(name in self.compression).lower()}" for name, o in COMPRESSION.items()]
        return flags


def split_list(values: list[str] | None) -> list[str]:
    return [item for value in values or [] for item in value.split(",") if item]


def make_request(words: list[str] | None, feature_profile: str, features: list[str] | None, compression: list[str] | None) -> Request:
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
    if feature_profile not in FEATURE_PROFILES:
        raise fail(f"unknown feature profile {feature_profile!r}; profiles: {', '.join(FEATURE_PROFILES)}")
    # Base: the -F set if given, else the feature profile's. `+name` adds to the base; `+@none` drops it.
    base = frozenset(name.removeprefix("+") for name in split_list(features)) or FEATURE_PROFILES[feature_profile].features
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
FeatureProfileOpt = Annotated[str, typer.Option("--feature-profile", "-x", help=" | ".join(FEATURE_PROFILES))]
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
def build(words: WordsArg = None, feature_profile: FeatureProfileOpt = "default", feature: FeatureOpt = None, compression: CompressionOpt = None) -> None:
    """Build bazel-bin/src/origine; Bazel flags may follow `--`."""
    raise typer.Exit(build_request(make_request(words, feature_profile, feature, compression)))


@app.command()
def run(words: WordsArg = None, feature_profile: FeatureProfileOpt = "default", feature: FeatureOpt = None, compression: CompressionOpt = None) -> None:
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
    feature_profile: FeatureProfileOpt = "default",
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
    table = Table(title="Build profiles", title_justify="left")
    for column in ("profile", "zig mode", "compression", "extra flags", "what"):
        table.add_column(column)
    for p in BUILD_PROFILES.values():
        table.add_row(p.name, p.zig_mode, ", ".join(sorted(p.compression)) or "-", " ".join(p.bazel_flags) or "-", p.doc)
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

    table = Table(title="Module modes (Zig: -O<mode>; Rust: -Copt-level)", title_justify="left")
    table.add_column("module", no_wrap=True)
    for p in BUILD_PROFILES.values():
        table.add_column(p.name)
    for kind in ("zig", "rust"):
        for module in OPT_ZIG if kind == "zig" else OPT_RUST:
            table.add_row(f"{kind}:{module}", *[getattr(p, kind)[module] for p in BUILD_PROFILES.values()])
    console.print(table)

    if profile:
        request = make_request([profile], "default", None, None)
        console.print(f"[bold]{profile}[/] flags:\n  " + "\n  ".join(request.bazel_flags()))


# ---------------------------------------------------------------------------------------------
# `just i`: the interactive picker (Textual). It only chooses; the command runs the result.
# ---------------------------------------------------------------------------------------------

MODES: dict[str, tuple[str, ...]] = {"zig": get_args(ZigMode), "rust": get_args(RustLevel)}
# (label, kind, modules): the group rows of the Optimization tab. mimalloc follows the critical group.
GROUPS = [
    ("critical Zig", "zig", [m for m in ZIG_CRITICAL if m != "v8"]),
    ("host Zig", "zig", ZIG_HOST),
    ("critical Rust", "rust", RUST_CRITICAL[:-1]),
    ("host Rust", "rust", RUST_HOST),
    ("V8 (Zig)", "zig", ["v8"]),
    ("V8 (rusty_v8)", "rust", ["rusty_v8"]),
]


def equivalent_command(request: Request, template: BuildProfile) -> str:
    """The shell command that reproduces `request`: `just build ...` for a stock profile, else raw Bazel."""
    if request.build is not template:
        return "bazel build " + " ".join(request.bazel_flags()) + " //src:origine"
    words = ["just build", template.name]
    if request.features == FEATURE_PROFILES["default"].features:
        pass
    elif not request.features:
        words.append("-x minimal")
    else:
        words.append("-F " + ",".join(sorted(request.features)))
    if request.compression != template.compression:
        words.append("-C " + (",".join(sorted(request.compression)) or "none"))
    return " ".join(words)


class ArgsScreen(ModalScreen[str | None]):
    """Asks for the arguments of the program `run` starts."""

    BINDINGS = [("escape", "dismiss(None)", "cancel")]
    DEFAULT_CSS = """
    ArgsScreen { align: center middle; }
    ArgsScreen > Vertical { width: 70; height: auto; border: round $accent; padding: 1 2; background: $surface; }
    """

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("Arguments for origine (e.g. examples/io/timers/init.js)")
            yield Input(placeholder="init.js ...", id="args")

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self.dismiss(event.value)


class TestsScreen(ModalScreen[list[str] | None]):
    """Which checks to run: `tests` is `just test` (zig build test), `examples` runs examples/**/init.*."""

    BINDINGS = [("escape", "dismiss(None)", "cancel"), ("r", "run", "Run")]
    DEFAULT_CSS = """
    TestsScreen { align: center middle; }
    TestsScreen > Vertical { width: 50; height: auto; border: round $accent; padding: 1 2; background: $surface; }
    TestsScreen Button { margin-top: 1; }
    """

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("Tests")
            yield Checkbox("run tests", id="tests")
            yield Checkbox("run examples (on the build above)", id="examples")
            yield Button("Run  [r]", variant="primary", id="run")
        yield Footer()

    def action_run(self) -> None:
        self.dismiss([c.id for c in self.query(Checkbox) if c.value and c.id])

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.action_run()


class BuildApp(App[tuple[Request, str, list[str]] | None]):
    """Pick a build profile (or edit a copy of one), features and compression; see the result live."""

    TITLE = "origine build"
    CSS = """
    #templates { width: 30; border: round $primary; }
    #tabs { width: 1fr; }
    #preview { width: 62; border: round $accent; padding: 0 1; overflow-y: auto; }
    .row { height: 3; }
    .row Label { width: 18; padding: 1 1 0 0; }
    .row Select { width: 1fr; }
    #modules { height: 1fr; margin-top: 1; }
    SelectionList { height: 1fr; }
    """
    BINDINGS = [
        Binding("b", "finish('build')", "Build"),
        Binding("r", "finish('run')", "Run"),
        Binding("t", "tests", "Tests"),
        Binding("p", "finish('print')", "Print command"),
        Binding("ctrl+r", "reset", "Reset"),
        Binding("q,escape", "quit_app", "Quit"),
    ]

    def __init__(self) -> None:
        super().__init__()
        self.template = BUILD_PROFILES["dev"]
        self.zig: dict[str, str] = dict(self.template.zig)
        self.rust: dict[str, str] = dict(self.template.rust)
        self.zig_mode: str = self.template.zig_mode
        self.compilation_mode: str = self.template.compilation_mode
        self.features: set[str] = set(FEATURE_PROFILES["default"].features)
        self.compression: set[str] = set(self.template.compression)

    # -- layout ------------------------------------------------------------------------------

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal():
            yield OptionList(
                *[Option(Text.assemble((p.name, "bold"), "\n", (p.doc, "dim")), id=p.name) for p in BUILD_PROFILES.values()],
                id="templates",
            )
            with TabbedContent(id="tabs"):
                with TabPane("Features", id="tab-features"):
                    yield Select(
                        [(f"{p.name}: {p.doc}", p.name) for p in FEATURE_PROFILES.values()],
                        prompt="load a feature profile", id="feature-profile",
                    )
                    yield SelectionList[str](
                        *[
                            Selection(
                                Text.assemble(f.name, "  ", (f.doc + (f"  (needs {', '.join(f.requires)})" if f.requires else ""), "dim")),
                                f.name, name in self.features,
                            )
                            for name, f in FEATURES.items()
                        ],
                        id="features",
                    )
                with TabPane("Compression", id="tab-compression"):
                    yield SelectionList[str](
                        *[Selection(Text.assemble(o.name, "  ", (o.doc, "dim")), name) for name, o in COMPRESSION.items()],
                        id="compression",
                    )
                with TabPane("Optimization", id="tab-opt"):
                    with Horizontal(classes="row"):
                        yield Label("Zig global mode")
                        yield Select([(m, m) for m in MODES["zig"]], allow_blank=False, id="zig-mode")
                    with Horizontal(classes="row"):
                        yield Label("compilation")
                        yield Select([("opt", "opt"), ("dbg", "dbg")], allow_blank=False, id="compilation")
                    for index, (label, kind, _) in enumerate(GROUPS):
                        with Horizontal(classes="row"):
                            yield Label(label)
                            yield Select([(m, m) for m in MODES[kind]], prompt="mixed", id=f"group-{index}")
                    yield DataTable(id="modules", cursor_type="row", zebra_stripes=True)
            yield Static(id="preview")
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one("#modules", DataTable)
        table.add_column("module", key="module")
        table.add_column("mode", key="mode")
        table.add_column("template", key="template")
        for kind, modules in (("zig", self.zig), ("rust", self.rust)):
            for module in modules:
                table.add_row(f"{kind}:{module}", "", "", key=f"{kind}:{module}")
        self.query_one("#templates", OptionList).highlighted = 0
        self.refresh_all()

    # -- state -> widgets --------------------------------------------------------------------

    def modes(self, kind: str) -> dict[str, str]:
        return self.zig if kind == "zig" else self.rust

    def load_template(self, name: str) -> None:
        self.template = BUILD_PROFILES[name]
        self.zig, self.rust = dict(self.template.zig), dict(self.template.rust)
        self.zig_mode, self.compilation_mode = self.template.zig_mode, self.template.compilation_mode
        self.compression = set(self.template.compression)
        self.refresh_all()

    def profile(self) -> BuildProfile:
        t = self.template
        if (self.zig, self.rust, self.zig_mode, self.compilation_mode) == (t.zig, t.rust, t.zig_mode, t.compilation_mode):
            return t
        return BuildProfile.model_validate(
            t.model_dump() | {
                "name": f"custom({t.name})", "doc": f"{t.name} with edits",
                "zig": self.zig, "rust": self.rust, "zig_mode": self.zig_mode, "compilation_mode": self.compilation_mode,
            }
        )

    def request(self) -> Request:
        return Request(build=self.profile(), features=frozenset(self.features), compression=frozenset(self.compression))

    def refresh_all(self) -> None:
        """Pushes the state into every widget (idempotent: widgets echo changes back as no-ops)."""
        for widget_id, wanted, universe in (("#features", self.features, FEATURES), ("#compression", self.compression, COMPRESSION)):
            selection = self.query_one(widget_id, SelectionList)
            for value in universe:
                (selection.select if value in wanted else selection.deselect)(value)
        self.query_one("#zig-mode", Select).value = self.zig_mode
        self.query_one("#compilation", Select).value = self.compilation_mode
        for index, (_, kind, modules) in enumerate(GROUPS):
            common = {self.modes(kind)[m] for m in modules}
            self.query_one(f"#group-{index}", Select).value = common.pop() if len(common) == 1 else Select.NULL
        table = self.query_one("#modules", DataTable)
        for kind, base in (("zig", self.template.zig), ("rust", self.template.rust)):
            for module, mode in self.modes(kind).items():
                changed = mode != base[module]
                table.update_cell(f"{kind}:{module}", "mode", Text(mode, style="bold yellow" if changed else ""))
                table.update_cell(f"{kind}:{module}", "template", Text(base[module], style="dim"))
        self.refresh_preview()

    def refresh_preview(self) -> None:
        preview = self.query_one("#preview", Static)
        try:
            request = self.request()
        except (ValidationError, ValueError) as error:
            preview.update(Text(str(error), style="bold red"))
            return
        table = Table(show_header=False, box=ROUNDED, border_style="dim", padding=(0, 1))
        table.add_column(style="bold cyan", no_wrap=True)
        table.add_column()
        table.add_row("profile", f"[bold green]{request.build.name}[/]\n[dim]{request.build.doc}[/]")
        table.add_row("features", feature_chips(request.features))
        table.add_row("compression", ", ".join(sorted(request.compression)) or "[dim]none[/]")
        table.add_row("zig mode", f"{request.build.zig_mode}  [dim]{request.build.compilation_mode}[/]")
        diff = [
            f"{kind}:{module} {base[module]} → [yellow]{mode}[/]"
            for kind, base in (("zig", self.template.zig), ("rust", self.template.rust))
            for module, mode in self.modes(kind).items() if mode != base[module]
        ]
        if diff:
            table.add_row("edits", "\n".join(diff))
        preview.update(Group(table, Text("\n" + equivalent_command(request, self.template), style="bold")))

    # -- widget events -----------------------------------------------------------------------

    def on_option_list_option_highlighted(self, event: OptionList.OptionHighlighted) -> None:
        if event.option.id != self.template.name:
            self.load_template(str(event.option.id))

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        self.load_template(str(event.option.id))  # picking the current one again discards the edits

    def on_selection_list_selected_changed(self, event: SelectionList.SelectedChanged) -> None:
        selected = set(event.selection_list.selected)
        if event.selection_list.id == "compression":
            self.compression = selected
        else:
            self.set_features(selected)
        self.refresh_preview()

    def set_features(self, new: set[str]) -> None:
        """Ticking a feature ticks what it requires; unticking one unticks what requires it."""
        result = set(new)
        for name in new - self.features:
            stack = [name]
            while stack:
                for required in FEATURES[stack.pop()].requires:
                    if required not in result:
                        result.add(required)
                        stack.append(required)
        for name in self.features - new:
            stack = [name]
            while stack:
                gone = stack.pop()
                for feature in FEATURES.values():
                    if gone in feature.requires and feature.name in result:
                        result.discard(feature.name)
                        stack.append(feature.name)
        self.features = result
        if result != new:
            self.refresh_all()

    def on_select_changed(self, event: Select.Changed) -> None:
        value, widget_id = event.value, event.select.id or ""
        if value is Select.NULL:
            return
        if widget_id == "feature-profile":
            self.features = set(FEATURE_PROFILES[str(value)].features)
        elif widget_id == "zig-mode":
            self.zig_mode = str(value)
        elif widget_id == "compilation":
            self.compilation_mode = str(value)
        elif widget_id.startswith("group-"):
            _, kind, modules = GROUPS[int(widget_id.removeprefix("group-"))]
            for module in modules:
                self.modes(kind)[module] = str(value)
        else:
            return
        self.refresh_all()

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        kind, module = str(event.row_key.value).split(":", 1)
        modes = MODES[kind]
        current = self.modes(kind)
        current[module] = modes[(modes.index(current[module]) + 1) % len(modes)]
        self.refresh_all()

    # -- actions -----------------------------------------------------------------------------

    def action_reset(self) -> None:
        self.load_template(self.template.name)

    def action_quit_app(self) -> None:
        self.exit(None)

    def action_tests(self) -> None:
        def chosen(names: list[str] | None) -> None:
            if names:
                self.exit((self.request(), "tests", names))

        try:
            self.request()
        except (ValidationError, ValueError):
            self.bell()
            return
        self.push_screen(TestsScreen(), chosen)

    def action_finish(self, action: str) -> None:
        try:
            request = self.request()
        except (ValidationError, ValueError):
            self.bell()
            return
        if action != "run":
            self.exit((request, action, []))
            return
        self.push_screen(ArgsScreen(), lambda args: self.exit((request, "run", shlex.split(args))) if args is not None else None)


@app.command()
def interactive() -> None:
    """Pick the build profile (or edit a copy of one), features and compression in a TUI, then build/run."""
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        console.print("[red]error:[/] `interactive` needs a terminal")
        raise typer.Exit(2)
    app_ = BuildApp()
    result = app_.run()
    if result is None:
        raise typer.Exit(0)
    request, action, args = result
    if action == "print":
        header(request)
        console.print(equivalent_command(request, app_.template), soft_wrap=True, highlight=False)
        raise typer.Exit(0)
    if action == "tests":
        code = subprocess.call(["zig", "build", "test"], cwd=ROOT) if "tests" in args else 0
        if "examples" in args and not build_request(request):
            code = run_examples(request, 30) or code
        elif "examples" in args:
            code = 1
        raise typer.Exit(code)
    if code := build_request(request):
        raise typer.Exit(code)
    if action == "run":
        raise typer.Exit(subprocess.call([BINARY, *args]))


app.command("i", hidden=True)(interactive)


def main() -> None:
    global TAIL
    if "--" in sys.argv:
        at = sys.argv.index("--")
        TAIL = sys.argv[at + 1:]
        del sys.argv[at:]
    app()


if __name__ == "__main__":
    main()
