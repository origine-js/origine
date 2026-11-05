"""The model behind build.py and its TUI: modules, profiles, features, presets and the `Selection`.

Everything that is a fact about the build (not about printing it or driving a terminal) lives here, so the
Typer commands (build.py), the Textual app (tui.py) and the tests share one definition. Build profiles
are Python models, Bazel knows none: `Request.bazel_flags()` turns one into plain settings.
"""

import ast
import json
import re
import sys
import tomllib
from collections.abc import Mapping
from pathlib import Path
from typing import Literal, get_args

from pydantic import BaseModel, ConfigDict, Field, model_validator

ROOT = Path(__file__).resolve().parents[2]
SETTINGS = "//build/bazel/settings"
OPT = "//build/bazel/opt"
ZIG_MODE_FLAG = "--@rules_zig//zig/settings:mode"


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
CLevel = Literal["inherit", "0", "1", "2", "3", "s", "z"]  # inherit: --compilation_mode decides

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
OPT_C = load_literal(ROOT / "build/bazel/opt.bzl", "C_LIBRARIES")

ZIG_GLOBAL_MODE = {"debug": "debug", "safe": "release_safe", "fast": "release_fast", "small": "release_small"}


class BuildProfile(BaseModel):
    """How a build optimizes each module, plus what else it passes to Bazel.

    `zig`, `rust` and `c` hold the mode of EVERY module (Bazel has no defaults that matter); `zig_mode`
    is rules_zig's global mode (modules without their own `-O`, the generated option modules). `c` is
    per C/C++ library (`C_LIBRARIES`): `inherit` leaves it to `compilation_mode`, else `-O<level>`.
    """

    model_config = ConfigDict(frozen=True)
    name: str
    doc: str
    zig_mode: ZigMode
    zig: dict[str, ZigMode]
    rust: dict[str, RustLevel]
    c: dict[str, CLevel] = Field(default_factory=lambda: dict(OPT_C))
    compression: frozenset[str] = frozenset()
    compilation_mode: Literal["opt", "dbg"] = "opt"
    # Cross-language ThinLTO: every module is LLVM bitcode (C/C++ `-flto=thin`, Rust
    # `-Clinker-plugin-lto`, Zig bitcode made a ThinLTO object by Clang) and ld64.lld optimizes them
    # together at the final link, with build.zig's release link options (`LTO_FLAGS`).
    lto: bool = False
    bazel_flags: tuple[str, ...] = ()  # e.g. --copt=-Os
    features: frozenset[str] | None = None  # the profile's own feature set (a preset's); None: the feature profile's
    origin: Literal["stock", "shared", "local"] = "stock"  # where it is defined: here, profiles.toml, local-profiles.toml

    @model_validator(mode="after")
    def _complete(self) -> "BuildProfile":
        if self.features is not None:
            check_features(self.features)
        for kind, given, declared in (("Zig", self.zig, OPT_ZIG), ("Rust", self.rust, OPT_RUST), ("C", self.c, OPT_C)):
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
    c: dict[str, CLevel] | None = None,
    **rest,
) -> BuildProfile:
    """Expands the critical/host groups into a mode per module. Critical Zig is `fast` (mimalloc
    `safe`) unless stated; lz4 is `small` in every profile, as build.zig's `.small` dependency.
    `v8_zig` and `v8_rust` override the v8 modules (`v8`, `rusty_v8`) when a profile keeps V8 apart.
    `c` overrides libraries of `C_LIBRARIES`; the rest keep opt.bzl's defaults."""
    zig: dict[str, ZigMode] = {m: critical_zig or "fast" for m in ZIG_CRITICAL}
    zig["mimalloc"] = mimalloc or ("safe" if critical_zig is None else critical_zig)
    zig["lz4"] = "small"
    zig |= {m: host_zig for m in ZIG_HOST}
    rust: dict[str, RustLevel] = {c: critical_rust for c in RUST_CRITICAL} | {c: host_rust for c in RUST_HOST}
    if v8_zig:
        zig["v8"] = v8_zig
    if v8_rust:
        rust["rusty_v8"] = v8_rust
    return BuildProfile(name=name, doc=doc, zig=zig, rust=rust, c=OPT_C | (c or {}), zig_mode=host_zig, **rest)


STOCK_PROFILES = {
    p.name: p
    for p in [
        profile(
            "dev", "optimize for fast debugging (default; reuse release v8)",
            critical_zig=None, host_zig="debug", critical_rust="3", host_rust="0",
        ),
        profile(
            "release-fast", "everything optimized for speed",
            critical_zig="fast", host_zig="fast", critical_rust="3", host_rust="3",
            lto=True,
        ),
        profile(
            "release-balanced", "balanced between size and performance",
            critical_zig=None, host_zig="small", critical_rust="3", host_rust="s",
            compression=frozenset({"icu"}),
            lto=True,
        ),
        profile(
            "release-small", "release small, release v8, everything else small; engine snapshot and ICU compressed",
            critical_zig="small", host_zig="small", critical_rust="s", host_rust="s",
            v8_zig="fast", v8_rust="3",
            compression=frozenset({"engine-snapshot", "icu"}),
            # C/C++ (V8 included) and the registry crates, which have no per-crate setting.
            lto=True,
        ),
        profile(
            "release-smaller", "release smaller, everything small, including v8",
            critical_zig="small", host_zig="small", critical_rust="s", host_rust="s",
            compression=frozenset({"engine-snapshot", "icu"}),
            # C/C++ (V8 included) and the registry crates, which have no per-crate setting.
            bazel_flags=("--copt=-Os", "--@rules_rust//rust/settings:extra_rustc_flags=-Copt-level=s"),
            lto=True,
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


# What `lto` adds. `origine_thin_lto` is the toolchain feature V8's objects already have (its
# REPO.bazel), so V8 is unchanged and stays cached; it puts `-flto=thin` on the other C/C++ and on
# the link. The link options are build.zig's release link (identical code folding, merged functions,
# no local symbols).
LTO_FLAGS = (
    "--features=origine_thin_lto",
    "--@rules_rust//rust/settings:extra_rustc_flag=-Clinker-plugin-lto",
    f"--{OPT}:lto=true",
    "--linkopt=-Wl,--icf=all",
    "--linkopt=-Wl,-mllvm,-enable-merge-functions",
    "--linkopt=-Wl,-x",
)

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
        flags += LTO_FLAGS if b.lto else [f"--{OPT}:lto=false"]
        flags += [f"--{OPT}:{module}={mode}" for module, mode in (b.zig | b.rust).items()]
        flags += [f"--{OPT}:c_{library}={level}" for library, level in b.c.items()]
        flags += [f"--{SETTINGS}:{name}={str(name in self.features).lower()}" for name in FEATURES]
        flags += [f"--{SETTINGS}:{o.flag}={str(name in self.compression).lower()}" for name, o in COMPRESSION.items()]
        return flags


# ---------------------------------------------------------------------------------------------
# Levels: every module is a (kind, name) with a level; "kind:name" is its key everywhere.
# ---------------------------------------------------------------------------------------------

KINDS = ("zig", "rust", "c")
MODES: dict[str, tuple[str, ...]] = {"zig": get_args(ZigMode), "rust": get_args(RustLevel), "c": get_args(CLevel)}
DECLARED: dict[str, dict[str, str]] = {"zig": OPT_ZIG, "rust": OPT_RUST, "c": OPT_C}


def split_key(key: str) -> tuple[str, str]:
    """`c:v8` -> (`c`, `v8`); ValueError for an unknown kind or module."""
    kind, _, module = key.partition(":")
    if kind not in DECLARED or module not in DECLARED[kind]:
        raise ValueError(f"unknown module {key!r}; modules are zig:<name>, rust:<crate>, c:<library> (see `just show`)")
    return kind, module


def profile_levels(build: BuildProfile) -> dict[str, str]:
    """Every module of a profile as `kind:name` -> level, in `KINDS` order."""
    return {f"{kind}:{module}": level for kind in KINDS for module, level in getattr(build, kind).items()}


def with_levels(
    base: BuildProfile,
    overrides: Mapping[str, str],
    *,
    name: str,
    doc: str,
    zig_mode: str | None = None,
    compilation_mode: str | None = None,
    **rest,
) -> BuildProfile:
    """A copy of `base` with some modules at other levels (and optionally another Zig/compilation mode)."""
    levels = {kind: dict(getattr(base, kind)) for kind in KINDS}
    for key, level in overrides.items():
        kind, module = split_key(key)
        if level not in MODES[kind]:
            raise ValueError(f"{key}: {level!r} is not a {kind} level; levels: {', '.join(MODES[kind])}")
        levels[kind][module] = level
    changes = {"name": name, "doc": doc, **levels, **rest}
    if zig_mode:
        changes["zig_mode"] = zig_mode
    if compilation_mode:
        changes["compilation_mode"] = compilation_mode
    return BuildProfile.model_validate(base.model_dump() | changes)


# ---------------------------------------------------------------------------------------------
# Presets: named profiles saved from the TUI, in two files. profiles.toml is committed and shared,
# local-profiles.toml is yours (gitignored).
#
#     [my-preset]
#     extends = "release-small"          # a stock profile or a preset defined above it (required)
#     doc = "what it is for"
#     features = ["http", "tls"]         # optional: else the extended profile's / every feature
#     compression = ["icu"]              # optional: else the extended profile's
#     zig_mode = "small"                 # optional
#     compilation_mode = "opt"           # optional
#     lto = true                         # optional: else the extended profile's
#     [my-preset.overrides]              # optional: kind:module = level
#     "c:v8" = "3"
# ---------------------------------------------------------------------------------------------

PRESET_FILES = (("shared", ROOT / "build/bazel/profiles.toml"), ("local", ROOT / "build/bazel/local-profiles.toml"))
PRESET_KEYS = {"extends", "doc", "features", "compression", "zig_mode", "compilation_mode", "lto", "overrides"}
PRESET_NAME = re.compile(r"^[a-z][a-z0-9-]*$")
PRESET_HEADER = {
    "shared": "# Shared build presets (committed). Saved from `just i`; format: build/bazel/model.py, `PRESET_FILES`.\n",
    "local": "# Your build presets (gitignored). Saved from `just i`; format: build/bazel/model.py, `PRESET_FILES`.\n",
}


class PresetError(ValueError):
    """A preset file or entry that cannot be used; the message names the file and the preset."""


def read_preset_tables(path: Path) -> dict[str, dict]:
    if not path.exists():
        return {}
    try:
        return tomllib.loads(path.read_text())
    except tomllib.TOMLDecodeError as error:
        raise PresetError(f"{path.relative_to(ROOT)}: {error}") from None


def preset_profile(path: Path, origin: str, name: str, table: dict, known: Mapping[str, BuildProfile]) -> BuildProfile:
    where = f"{path.relative_to(ROOT)}: [{name}]"
    if not PRESET_NAME.match(name):
        raise PresetError(f"{where}: names are lowercase letters, digits and `-`, starting with a letter")
    if name in known:
        raise PresetError(f"{where}: name already taken by {known[name].origin} profile {name!r}")
    if unknown := sorted(set(table) - PRESET_KEYS):
        raise PresetError(f"{where}: unknown keys {unknown}; keys: {sorted(PRESET_KEYS)}")
    extends = table.get("extends")
    if extends not in known:
        raise PresetError(f"{where}: `extends` must name an earlier profile, got {extends!r}; have: {', '.join(known)}")
    base = known[extends]
    try:
        features = frozenset(table["features"]) if "features" in table else base.features
        compression = frozenset(table["compression"]) if "compression" in table else base.compression
        return with_levels(
            base, table.get("overrides", {}), name=name, doc=table.get("doc", f"{extends} (preset)"),
            zig_mode=table.get("zig_mode"), compilation_mode=table.get("compilation_mode"),
            features=features, compression=compression, origin=origin,
            **({"lto": bool(table["lto"])} if "lto" in table else {}),
        )
    except ValueError as error:  # pydantic's ValidationError is one
        message = "; ".join(e["msg"].removeprefix("Value error, ") for e in error.errors()) if hasattr(error, "errors") else str(error)
        raise PresetError(f"{where}: {message}") from None


def load_profiles() -> dict[str, BuildProfile]:
    """Stock profiles, then the shared presets, then the local ones (each file may extend the ones before it)."""
    profiles = dict(STOCK_PROFILES)
    for origin, path in PRESET_FILES:
        for name, table in read_preset_tables(path).items():
            profiles[name] = preset_profile(path, origin, name, table, profiles)
    return profiles


def dump_preset_tables(origin: str, tables: Mapping[str, dict]) -> str:
    """TOML for the preset tables; strings and lists of strings only, so JSON spellings are valid TOML."""
    def key(text: str) -> str:
        return text if re.fullmatch(r"[A-Za-z0-9_-]+", text) else json.dumps(text)

    out = [PRESET_HEADER[origin]]
    for name, table in tables.items():
        out.append(f"\n[{key(name)}]\n")
        out += [f"{key(k)} = {json.dumps(v)}\n" for k, v in table.items() if k != "overrides"]
        if table.get("overrides"):
            out.append(f"\n[{key(name)}.overrides]\n")
            out += [f"{json.dumps(k)} = {json.dumps(v)}\n" for k, v in table["overrides"].items()]
    return "".join(out)


def save_preset(origin: str, name: str, table: dict) -> Path:
    """Adds (or replaces, within the same file) a preset; the other presets of the file are kept as they are.

    Raises PresetError if `name` is taken by a stock profile or by a preset of the other file."""
    path = dict(PRESET_FILES)[origin]
    tables = read_preset_tables(path)
    tables[name] = table
    previous = path.read_text() if path.exists() else None
    path.write_text(dump_preset_tables(origin, tables))
    try:
        load_profiles()  # validates the whole file (and every file after it) with the new entry
    except PresetError:
        if previous is None:
            path.unlink()
        else:
            path.write_text(previous)
        raise
    return path


BUILD_PROFILES = load_profiles()


def reload_profiles() -> None:
    """Re-reads the preset files into `BUILD_PROFILES` (in place, so every importer sees it)."""
    fresh = load_profiles()
    BUILD_PROFILES.clear()
    BUILD_PROFILES.update(fresh)
PROFILE_ALIASES = {"release": "release-balanced"}  # names accepted on the command line that stand for another profile


# ---------------------------------------------------------------------------------------------
# Selection: what the TUI edits. A template (any profile) plus overrides; everything else derives.
# ---------------------------------------------------------------------------------------------


class Change(BaseModel):
    """One difference from the template, as the TUI lists it. `id` is what `Selection.revert` takes."""

    model_config = ConfigDict(frozen=True)
    id: str
    label: str


class Selection(BaseModel):
    """A template and the edits on top of it. Immutable: every edit returns a new Selection."""

    model_config = ConfigDict(frozen=True)
    template: str
    features: frozenset[str]
    compression: frozenset[str]
    zig_mode: str | None = None  # None: the template's
    compilation_mode: str | None = None
    overrides: dict[str, str] = Field(default_factory=dict)  # `kind:module` -> level, only those that differ

    @classmethod
    def start(cls, template: str) -> "Selection":
        base = BUILD_PROFILES[template]
        features = base.features if base.features is not None else FEATURE_PROFILES["default"].features
        return cls(template=template, features=features, compression=base.compression)

    @property
    def base(self) -> BuildProfile:
        return BUILD_PROFILES[self.template]

    @property
    def base_features(self) -> frozenset[str]:
        return Selection.start(self.template).features

    def levels(self) -> dict[str, str]:
        """Every module's level after the overrides."""
        return profile_levels(self.base) | self.overrides

    def set_levels(self, keys: list[str], level: str) -> "Selection":
        """`keys` at `level` (an override equal to the template's level is dropped)."""
        base = profile_levels(self.base)
        overrides = dict(self.overrides)
        for key in keys:
            kind, _ = split_key(key)
            if level not in MODES[kind]:
                raise ValueError(f"{key}: {level!r} is not a {kind} level; levels: {', '.join(MODES[kind])}")
            if level == base[key]:
                overrides.pop(key, None)
            else:
                overrides[key] = level
        return self.model_copy(update={"overrides": overrides})

    def with_features(self, new: set[str] | frozenset[str]) -> "Selection":
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
        return self.model_copy(update={"features": frozenset(result)})

    def profile(self) -> BuildProfile:
        if not (self.overrides or self.zig_mode or self.compilation_mode):
            return self.base
        return with_levels(
            self.base, self.overrides, name=f"custom({self.template})", doc=f"{self.template} with edits",
            zig_mode=self.zig_mode, compilation_mode=self.compilation_mode,
        )

    def request(self) -> Request:
        return Request(build=self.profile(), features=self.features, compression=self.compression)

    def changes(self) -> list[Change]:
        found = []
        if self.zig_mode:
            found.append(Change(id="zig_mode", label=f"zig mode {self.base.zig_mode} → {self.zig_mode}"))
        if self.compilation_mode:
            found.append(Change(id="compilation_mode", label=f"compilation {self.base.compilation_mode} → {self.compilation_mode}"))
        base = profile_levels(self.base)
        found += [Change(id=f"level:{key}", label=f"{key} {base[key]} → {level}") for key, level in self.overrides.items()]
        base_features = self.base_features
        found += [Change(id=f"feature:{n}", label=f"+feature {n}") for n in sorted(self.features - base_features)]
        found += [Change(id=f"feature:{n}", label=f"-feature {n}") for n in sorted(base_features - self.features)]
        found += [Change(id=f"compression:{n}", label=f"+compression {n}") for n in sorted(self.compression - self.base.compression)]
        found += [Change(id=f"compression:{n}", label=f"-compression {n}") for n in sorted(self.base.compression - self.compression)]
        return found

    def revert(self, change_id: str) -> "Selection":
        kind, _, name = change_id.partition(":")
        if kind in ("zig_mode", "compilation_mode"):
            return self.model_copy(update={kind: None})
        if kind == "level":
            return self.set_levels([name], profile_levels(self.base)[name])
        if kind == "feature":
            return self.with_features(self.features | {name} if name in self.base_features else self.features - {name})
        if kind == "compression":
            return self.model_copy(update={"compression": self.compression | {name} if name in self.base.compression else self.compression - {name}})
        raise ValueError(f"unknown change {change_id!r}")

    def command(self) -> str:
        """The shell command that reproduces this: `just build ...`, or raw Bazel while modules are edited."""
        request = self.request()
        if self.overrides or self.zig_mode or self.compilation_mode:
            return "bazel build " + " ".join(request.bazel_flags()) + " //src:origine"
        words = ["just build", self.template]
        if self.features != self.base_features:
            words.append("+@none" if not self.features else "-F " + ",".join(sorted(self.features)))
        if self.compression != self.base.compression:
            words.append("-C " + (",".join(sorted(self.compression)) or "none"))
        return " ".join(words)

    def preset_table(self, doc: str = "") -> dict:
        """This selection as a preset table (the format above); features and compression are always stated."""
        table: dict = {"extends": self.template, "doc": doc or f"{self.template} with edits"}
        table["features"] = sorted(self.features)
        table["compression"] = sorted(self.compression)
        if self.zig_mode:
            table["zig_mode"] = self.zig_mode
        if self.compilation_mode:
            table["compilation_mode"] = self.compilation_mode
        if self.overrides:
            table["overrides"] = dict(self.overrides)
        return table
