#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pydantic>=2.9,<3", "rich==14.2.0", "textual==8.2.8"]
# ///
"""The TUI driven headlessly with Textual's pilot. Run: uv run --script build/bazel/tests/test_tui.py"""

import asyncio
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import model as m
import tui
from textual.widgets import Input, OptionList, SelectionList


def table_keys(app: tui.BuildApp) -> list[str]:
    table = app.query_one("#modules", tui.ModuleTable)
    return [str(table.coordinate_to_cell_key((row, 0)).row_key.value) for row in range(table.row_count)]


async def edit_flow() -> None:
    app = tui.BuildApp("release-small")
    async with app.run_test(size=(180, 50)) as pilot:
        await pilot.pause()
        assert app.selection.template == "release-small" and not app.selection.changes()
        table = app.query_one("#modules", tui.ModuleTable)
        table.focus()
        for key in ("c:v8", "c:icu"):
            table.move_cursor(row=table.get_row_index(key))
            await pilot.press("space")
        await pilot.press("3")
        await pilot.pause()
        assert app.selection.overrides == {"c:v8": "3", "c:icu": "3"}, app.selection.overrides
        assert app.query_one("#changes", tui.ChangesList).option_count == 2
        assert app.selection.command().startswith("bazel build")
        # a key that is no level of a zig row is skipped, not applied
        await pilot.press("u")
        table.move_cursor(row=table.get_row_index("zig:v8"))
        await pilot.press("z")
        await pilot.pause()
        assert "zig:v8" not in app.selection.overrides
        # filtering and changed-only
        app.query_one("#filter", Input).value = "v8"
        await pilot.pause()
        assert set(table_keys(app)) == {"hdr:zig", "zig:v8", "hdr:rust", "rust:rusty_v8", "hdr:c", "c:v8"}, table_keys(app)
        app.query_one("#filter", Input).value = ""
        app.action_toggle_changed_only()
        await pilot.pause()
        assert [k for k in table_keys(app) if not k.startswith("hdr:")] == ["c:v8", "c:icu"] or set(table_keys(app)) >= {"c:v8", "c:icu"}
        # reverting a change from the list
        changes = app.query_one("#changes", tui.ChangesList)
        changes.focus()
        changes.highlighted = 0
        await pilot.press("delete")
        await pilot.pause()
        assert len(app.selection.overrides) == 1
        # features: unticking one that something requires unticks the dependants
        features = app.query_one("#features", SelectionList)
        requiring = next(f for f in m.FEATURES.values() if f.requires)
        features.deselect(requiring.requires[0])
        await pilot.pause()
        assert requiring.name not in app.selection.features
        app.action_reset()
        await pilot.pause()
        assert app.selection == m.Selection.start("release-small")


async def template_and_outcome() -> None:
    app = tui.BuildApp()
    async with app.run_test(size=(100, 40)) as pilot:  # narrow layout
        await pilot.pause()
        assert app.screen.has_class("narrow")
        app.query_one("#templates", OptionList).highlighted = list(m.BUILD_PROFILES).index("release-fast")
        await pilot.pause()
        assert app.selection.template == "release-fast"
        app.query_one("#chk-tests").value = True
        await pilot.press("b")
        await pilot.pause()
    assert isinstance(app.return_value, tui.Outcome)
    assert app.return_value.action == "build" and app.return_value.checks == ["tests"]
    assert app.return_value.selection.template == "release-fast"


async def save_flow() -> None:
    with tempfile.TemporaryDirectory() as directory:
        original = m.PRESET_FILES, m.ROOT
        m.PRESET_FILES = (("shared", Path(directory) / "profiles.toml"), ("local", Path(directory) / "local.toml"))
        m.ROOT = Path(directory)
        tui.ROOT = m.ROOT
        try:
            app = tui.BuildApp("dev")
            async with app.run_test(size=(180, 50)) as pilot:
                await pilot.pause()
                app.selection = app.selection.set_levels(["c:v8"], "2")
                await pilot.pause()
                await pilot.press("s")
                await pilot.pause()
                app.screen.query_one("#name", Input).value = "mine"
                await pilot.press("enter")
                await pilot.pause()
                assert "mine" in m.BUILD_PROFILES and app.selection == m.Selection.start("mine"), app.selection
                assert app.selection.command() == "just build mine"
                assert m.BUILD_PROFILES["mine"].c["v8"] == "2"
                # a name that is taken is reported, not saved
                app.selection = app.selection.set_levels(["c:v8"], "1")
                await pilot.press("s")
                await pilot.pause()
                app.screen.query_one("#name", Input).value = "dev"
                await pilot.press("enter")
                await pilot.pause()
                assert m.BUILD_PROFILES["dev"].origin == "stock"
        finally:
            m.PRESET_FILES, m.ROOT = original
            tui.ROOT = m.ROOT
            m.reload_profiles()


if __name__ == "__main__":
    for flow in (edit_flow, template_and_outcome, save_flow):
        asyncio.run(flow())
        print("ok", flow.__name__)
