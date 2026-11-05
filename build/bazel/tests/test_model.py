#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pydantic>=2.9,<3"]
# ///
"""Selection, presets and levels (no terminal). Run: uv run --script build/bazel/tests/test_model.py"""

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import model as m


def test_selection_roundtrip() -> None:
    s = m.Selection.start("release-small")
    assert s.changes() == [] and s.command() == "just build release-small"
    edited = s.set_levels(["c:v8"], "3").set_levels(["zig:v8"], "small").with_features(set())
    assert {c.id for c in edited.changes()} >= {"level:c:v8", "feature:http"}
    assert edited.profile().name == "custom(release-small)" and "bazel build" in edited.command()
    for change in edited.changes():
        edited = edited.revert(change.id)
    assert edited == s


def test_feature_closure() -> None:
    with_requires = next(f for f in m.FEATURES.values() if f.requires)
    s = m.Selection.start("dev").with_features(set())
    ticked = s.with_features({with_requires.name})
    assert set(with_requires.requires) <= ticked.features
    assert with_requires.name not in ticked.with_features(ticked.features - set(with_requires.requires)).features


def test_levels_validate() -> None:
    base = m.STOCK_PROFILES["dev"]
    for bad in ({"c:nope": "3"}, {"c:v8": "fast"}, {"zig:v8": "3"}, {"x": "1"}):
        try:
            m.with_levels(base, bad, name="t", doc="t")
        except ValueError:
            continue
        raise AssertionError(f"accepted {bad}")


def test_preset_file_roundtrip() -> None:
    with tempfile.TemporaryDirectory() as directory:
        original = m.PRESET_FILES
        m.PRESET_FILES = (("shared", Path(directory) / "profiles.toml"), ("local", Path(directory) / "local.toml"))
        # presets are located by ROOT-relative names in messages; keep them loadable from a temp dir
        m.ROOT, root = Path(directory), m.ROOT
        try:
            sel = m.Selection.start("release-small").set_levels(["c:v8"], "3").with_features({"http", "tls"})
            m.save_preset("local", "mine", sel.preset_table("test"))
            m.reload_profiles()
            built = m.BUILD_PROFILES["mine"]
            assert built.origin == "local" and built.c["v8"] == "3"
            again = m.Selection.start("mine")
            assert again.features == sel.features and again.changes() == []
            assert again.request().bazel_flags() == sel.request().bazel_flags()
            # a stock name, the other file's name and a bad level are refused, and the file is left as it was
            before = (Path(directory) / "local.toml").read_text()
            for name, table in (("dev", sel.preset_table()), ("bad", {"extends": "dev", "overrides": {"c:v8": "fast"}})):
                try:
                    m.save_preset("local", name, table)
                except m.PresetError:
                    continue
                raise AssertionError(name)
            assert (Path(directory) / "local.toml").read_text() == before
        finally:
            m.PRESET_FILES, m.ROOT = original, root
            m.reload_profiles()


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print("ok", name)
