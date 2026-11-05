"""`just i`: pick a build profile and edit a copy of it, in a Textual app.

The state is one immutable `model.Selection` (a template plus overrides). Every widget is drawn from it
by `BuildApp.render_selection`; every edit builds a new Selection and assigns it, so there is no
widget-to-widget state to keep in step. The app only chooses: `run()` returns an `Outcome` and build.py
performs it (except "build here", which streams Bazel's build events into a log screen, see
bazel_events.py).
"""

import shlex
from dataclasses import dataclass, field
from typing import Literal

from pydantic import ValidationError
from rich.box import ROUNDED
from rich.console import Group
from rich.table import Table
from rich.text import Text
from textual import events
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Grid, Horizontal, Vertical, VerticalScroll
from textual.message import Message
from textual.reactive import reactive
from textual.screen import ModalScreen, Screen
from textual.widgets import (
    Button, Checkbox, Collapsible, DataTable, Footer, Header, Input, Label, OptionList, ProgressBar, RichLog, Select,
    SelectionList, Static,
)
from textual.widgets.option_list import Option
from textual.widgets.selection_list import Selection as Choice

import bazel_events
from model import BUILD_PROFILES, COMPRESSION, FEATURES, KINDS, PresetError, ROOT, Selection, profile_levels, reload_profiles, save_preset

# A level key per kind: `s` is Zig's safe but Rust's and C's size level, as in `-Os`.
LEVEL_KEYS: dict[str, dict[str, str]] = {
    "zig": {"d": "debug", "s": "safe", "f": "fast", "m": "small"},
    "rust": {"0": "0", "1": "1", "2": "2", "3": "3", "s": "s", "z": "z"},
    "c": {"i": "inherit", "0": "0", "1": "1", "2": "2", "3": "3", "s": "s", "z": "z"},
}
ALL_LEVEL_KEYS = frozenset(char for keys in LEVEL_KEYS.values() for char in keys)
SECTION_NAMES = {"zig": "Zig modules (-O<mode>)", "rust": "Rust crates (-Copt-level)", "c": "C/C++ libraries (-O<level>, inherit = compilation mode)"}
NARROW = 140  # columns; below it the side column goes under the options


@dataclass
class Outcome:
    """What the user decided; build.py carries it out."""

    selection: Selection
    action: Literal["build", "run", "print"]
    args: list[str] = field(default_factory=list)  # program arguments, for "run"
    checks: list[str] = field(default_factory=list)  # "tests" and/or "examples", after a "build"


class ModuleTable(DataTable):
    """The module list. Level keys, Space and `a`/`u` are messages; the app decides what they mean."""

    class Level(Message):
        def __init__(self, char: str) -> None:
            super().__init__()
            self.char = char

    class Mark(Message):
        def __init__(self, action: Literal["toggle", "all", "none"]) -> None:
            super().__init__()
            self.action = action

    def on_key(self, event: events.Key) -> None:
        if event.character in ALL_LEVEL_KEYS:
            self.post_message(self.Level(event.character or ""))
        elif event.key == "space":
            self.post_message(self.Mark("toggle"))
        elif event.character in ("a", "u"):
            self.post_message(self.Mark("all" if event.character == "a" else "none"))
        else:
            return
        event.stop()
        event.prevent_default()


class ChangesList(OptionList):
    BINDINGS = [Binding("delete,backspace", "revert_change", "Revert")]

    class Revert(Message):
        def __init__(self, change_id: str) -> None:
            super().__init__()
            self.change_id = change_id

    def action_revert_change(self) -> None:
        if self.highlighted is not None and (option := self.get_option_at_index(self.highlighted)).id:
            self.post_message(self.Revert(str(option.id)))


class SavePresetScreen(ModalScreen[tuple[str, str, str] | None]):
    """Name, destination and description of a new preset."""

    BINDINGS = [("escape", "dismiss(None)", "cancel")]
    DEFAULT_CSS = """
    SavePresetScreen { align: center middle; }
    SavePresetScreen > Vertical { width: 72; height: auto; border: round $accent; padding: 1 2; background: $surface; }
    SavePresetScreen Label { margin-top: 1; }
    """

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("Save as preset (then `just build <name>` works)")
            yield Input(placeholder="name: lowercase letters, digits, -", id="name")
            yield Input(placeholder="what it is for (optional)", id="doc")
            yield Select(
                [("local  (build/bazel/local-profiles.toml, gitignored)", "local"), ("shared (build/bazel/profiles.toml, committed)", "shared")],
                allow_blank=False, value="local", id="where",
            )
            yield Label("", id="error")
            yield Label("Enter saves, Esc cancels", classes="hint")

    def on_input_submitted(self, event: Input.Submitted) -> None:
        name = self.query_one("#name", Input).value.strip()
        if not name:
            self.query_one("#error", Label).update("name is required")
            return
        self.dismiss((name, str(self.query_one("#where", Select).value), self.query_one("#doc", Input).value.strip()))


class BuildLogScreen(Screen[int]):
    """Runs `bazel build` and shows its build events: progress, counters and the output lines."""

    BINDINGS = [("escape", "leave", "Back")]
    DEFAULT_CSS = """
    BuildLogScreen #counters { height: 1; padding: 0 1; }
    BuildLogScreen ProgressBar { padding: 0 1; }
    BuildLogScreen RichLog { border: round $primary; height: 1fr; }
    """

    def __init__(self, flags: list[str], target: str = "//src:origine") -> None:
        super().__init__()
        self.flags, self.target = flags, target
        self.state = bazel_events.BuildState()

    def compose(self) -> ComposeResult:
        yield Header()
        yield ProgressBar(total=None, show_eta=False, id="bar")
        yield Static("starting Bazel (it may wait for another command's lock)...", id="counters")
        yield RichLog(id="log", wrap=True, markup=False, highlight=False)
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = f"bazel build {self.target}"
        self.run_worker(self.stream(), exclusive=True)

    async def stream(self) -> None:
        log, bar = self.query_one("#log", RichLog), self.query_one("#bar", ProgressBar)
        async for event in bazel_events.run_bazel(["build", *self.flags, self.target], cwd=ROOT):
            self.state.apply(event)
            if isinstance(event, bazel_events.Progress):
                for line in (event.stdout + event.stderr).splitlines():
                    log.write(Text(line))
            state = self.state
            if (fraction := state.fraction) is not None:
                bar.update(total=state.total, progress=state.done)
            self.query_one("#counters", Static).update(
                f"targets {state.targets_completed}/{state.targets_configured}   actions {state.actions}"
                f"   failed {state.actions_failed}   " + ("running" if not state.finished else ("[green]done[/]" if state.success else "[red]failed[/]"))
            )
        self.sub_title = f"bazel build {self.target}: " + ("succeeded" if self.state.returncode == 0 else f"exit {self.state.returncode}")

    def action_leave(self) -> None:
        self.dismiss(self.state.returncode or 0)


class BuildApp(App[Outcome | None]):
    """Pick a template, edit it, see the command; build, run or print."""

    TITLE = "origine build"
    selection: reactive[Selection] = reactive(Selection.start("dev"), init=False)

    CSS = """
    #cols { layout: grid; grid-size: 3 1; grid-columns: 30 1fr 64; grid-gutter: 0 1; height: 1fr; }
    .narrow #cols { grid-size: 2 2; grid-columns: 30 1fr; grid-rows: 1fr 14; }
    .narrow #side { column-span: 2; }
    #templates { border: round $primary; height: 100%; }
    #options { border: round $primary; }
    #side { border: round $accent; padding: 0 1; }
    #changes { height: 9; border: round $surface; }
    #preview { height: 1fr; overflow-y: auto; }
    #modules { height: 30; }
    #filter { margin: 0 0 1 0; }
    SelectionList { height: auto; max-height: 14; }
    #actions { height: 3; }
    #actions Input { width: 28; }
    #actions Checkbox { width: auto; border: none; }
    #actions Button { min-width: 9; margin-left: 1; }
    #command { height: 1; padding: 0 1; text-wrap: nowrap; text-overflow: ellipsis; color: $text-muted; }
    """
    BINDINGS = [
        Binding("b", "finish('build')", "Build"),
        Binding("r", "finish('run')", "Run"),
        Binding("B", "build_here", "Build here"),
        Binding("p", "finish('print')", "Print"),
        Binding("y", "copy", "Copy"),
        Binding("s", "save", "Save preset"),
        Binding("slash", "focus_filter", "Filter"),
        Binding("c", "toggle_changed_only", "Changed only"),
        Binding("ctrl+r", "reset", "Reset"),
        Binding("q,escape", "quit_app", "Quit"),
    ]

    def __init__(self, template: str = "dev") -> None:
        super().__init__()
        self.marked: set[str] = set()
        self.changed_only = False
        self._initial = template
        self.valid = True

    # -- layout ------------------------------------------------------------------------------

    def compose(self) -> ComposeResult:
        yield Header()
        with Grid(id="cols"):
            yield OptionList(id="templates")
            with VerticalScroll(id="options"):
                with Collapsible(title="Features", collapsed=True, id="sec-features"):
                    yield SelectionList[str](
                        *[
                            Choice(Text.assemble(f.name, "  ", (f.doc + (f"  (needs {', '.join(f.requires)})" if f.requires else ""), "dim")), f.name)
                            for f in FEATURES.values()
                        ],
                        id="features",
                    )
                with Collapsible(title="Compression", collapsed=True, id="sec-compression"):
                    yield SelectionList[str](
                        *[Choice(Text.assemble(o.name, "  ", (o.doc, "dim")), name) for name, o in COMPRESSION.items()],
                        id="compression",
                    )
                with Collapsible(title="Optimization", collapsed=False, id="sec-optimization"):
                    yield Input(placeholder="/ filter modules (name or kind:, e.g. c:  or  v8)", id="filter")
                    yield ModuleTable(id="modules", cursor_type="row", zebra_stripes=True)
            with Vertical(id="side"):
                yield Label("Changes from the template  (Delete reverts)")
                yield ChangesList(id="changes")
                yield Static(id="preview")
        with Horizontal(id="actions"):
            yield Input(placeholder="run args", id="args")
            yield Checkbox("tests", id="chk-tests")
            yield Checkbox("examples", id="chk-examples")
            yield Button("Build", id="btn-build", variant="primary")
            yield Button("Run", id="btn-run")
            yield Button("Print", id="btn-print")
            yield Button("Copy", id="btn-copy")
            yield Button("Save", id="btn-save")
        yield Static(id="command")
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one("#modules", ModuleTable)
        table.add_column("", key="mark", width=1)
        table.add_column("module", key="module")
        table.add_column("template", key="template")
        table.add_column("current", key="current")
        self.selection = Selection.start(self._initial)
        self.fill_templates()
        self.render_selection()
        self.on_resize()

    def on_resize(self, event: events.Resize | None = None) -> None:
        self.screen.set_class(self.size.width < NARROW, "narrow")

    def fill_templates(self) -> None:
        templates = self.query_one("#templates", OptionList)
        templates.clear_options()
        templates.add_options(
            [
                Option(Text.assemble((p.name, "bold"), (f"  {p.origin}" if p.origin != "stock" else "", "cyan"), "\n", (p.doc, "dim")), id=p.name)
                for p in BUILD_PROFILES.values()
            ]
        )
        templates.highlighted = list(BUILD_PROFILES).index(self.selection.template)

    # -- state -> widgets (the one place widgets are written) --------------------------------

    def watch_selection(self) -> None:
        if self.is_mounted:
            self.render_selection()

    def render_selection(self) -> None:
        selection = self.selection
        for widget_id, wanted, universe in (("#features", selection.features, FEATURES), ("#compression", selection.compression, COMPRESSION)):
            widget = self.query_one(widget_id, SelectionList)
            have = set(widget.selected)
            for name in universe:
                if (name in wanted) != (name in have):
                    (widget.select if name in wanted else widget.deselect)(name)
        self.query_one("#sec-features", Collapsible).title = f"Features · {len(selection.features)}/{len(FEATURES)} on"
        self.query_one("#sec-compression", Collapsible).title = f"Compression · {', '.join(sorted(selection.compression)) or 'none'}"
        self.render_table()
        changes = self.query_one("#changes", ChangesList)
        changes.clear_options()
        found = selection.changes()
        changes.add_options([Option(c.label, id=c.id) for c in found] or [Option(Text(f"none: exactly {selection.template}", style="dim"), disabled=True)])
        try:
            request = selection.request()
            error = None
        except (ValidationError, ValueError) as exc:
            request, error = None, exc
        self.valid = request is not None
        self.query_one("#preview", Static).update(self.preview(request, error))
        self.query_one("#command", Static).update(selection.command() if request else "")
        self.sub_title = f"{selection.template}" + (f" · {len(found)} change{'s' * (len(found) != 1)}" if found else "")

    def preview(self, request, error) -> Group | Text:
        if request is None:
            return Text(str(error), style="bold red")
        table = Table(show_header=False, box=ROUNDED, border_style="dim", padding=(0, 1))
        table.add_column(style="bold cyan", no_wrap=True)
        table.add_column()
        build = request.build
        table.add_row("profile", f"[bold green]{build.name}[/]\n[dim]{build.doc}[/]")
        table.add_row("features", " ".join(f"[dim]+[/]{n}" for n in sorted(request.features)) or "[dim]none[/]")
        table.add_row("compression", ", ".join(sorted(request.compression)) or "[dim]none[/]")
        table.add_row("modes", f"zig {build.zig_mode} · {build.compilation_mode}")
        parts: list = [table]
        if self.selection.overrides or self.selection.zig_mode or self.selection.compilation_mode:
            parts.append(Text("\nEdited modules have no `just build` spelling: press s to save a preset.", style="dim"))
        return Group(*parts)

    def visible_keys(self) -> list[str]:
        selection = self.selection
        text = self.query_one("#filter", Input).value.strip().lower()
        keys = [
            key for key in selection.levels()
            if (not self.changed_only or key in selection.overrides) and (not text or text in key.lower())
        ]
        return keys

    def render_table(self) -> None:
        table = self.query_one("#modules", ModuleTable)
        cursor_key = self.cursor_key()
        table.clear()
        base, levels = profile_levels(self.selection.base), self.selection.levels()
        keys = self.visible_keys()
        self.marked &= set(levels)
        for kind in KINDS:
            section = [key for key in keys if key.startswith(kind + ":")]
            if not section:
                continue
            table.add_row("", Text(SECTION_NAMES[kind], style="bold underline"), "", "", key=f"hdr:{kind}")
            for key in section:
                changed = levels[key] != base[key]
                table.add_row(
                    Text("●", style="bold cyan") if key in self.marked else "",
                    key.split(":", 1)[1],
                    Text(base[key], style="dim"),
                    Text(levels[key], style="bold yellow" if changed else ""),
                    key=key,
                )
        if cursor_key is not None:
            try:
                table.move_cursor(row=table.get_row_index(cursor_key))
            except Exception:  # the row is filtered out now
                pass

    def cursor_key(self) -> str | None:
        table = self.query_one("#modules", ModuleTable)
        if not table.row_count:
            return None
        return str(table.coordinate_to_cell_key(table.cursor_coordinate).row_key.value)

    # -- events -> new Selection -------------------------------------------------------------

    def on_option_list_option_highlighted(self, event: OptionList.OptionHighlighted) -> None:
        if event.option_list.id == "templates" and event.option.id != self.selection.template:
            self.marked.clear()
            self.selection = Selection.start(str(event.option.id))

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        if event.option_list.id == "templates":
            self.action_reset()

    def on_selection_list_selected_changed(self, event: SelectionList.SelectedChanged) -> None:
        selected = frozenset(event.selection_list.selected)
        if event.selection_list.id == "compression":
            self.selection = self.selection.model_copy(update={"compression": selected})
        else:
            self.selection = self.selection.with_features(selected)

    def on_input_changed(self, event: Input.Changed) -> None:
        if event.input.id == "filter":
            self.render_table()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id == "filter":
            self.query_one("#modules").focus()

    def on_module_table_level(self, message: ModuleTable.Level) -> None:
        keys = sorted(self.marked) if self.marked else [k for k in [self.cursor_key()] if k and not k.startswith("hdr:")]
        selection, skipped = self.selection, 0
        for key in keys:
            level = LEVEL_KEYS[key.split(":", 1)[0]].get(message.char)
            if level is None:
                skipped += 1
            else:
                selection = selection.set_levels([key], level)
        self.selection = selection
        if skipped:
            self.notify(f"{skipped} module(s) have no level for {message.char!r}", severity="warning")

    def on_module_table_mark(self, message: ModuleTable.Mark) -> None:
        if message.action == "none":
            self.marked.clear()
        elif message.action == "all":
            self.marked |= set(self.visible_keys())
        else:
            key = self.cursor_key()
            if key and key.startswith("hdr:"):
                section = {k for k in self.visible_keys() if k.startswith(key.removeprefix("hdr:") + ":")}
                self.marked = self.marked - section if section <= self.marked else self.marked | section
            elif key:
                self.marked ^= {key}
        self.render_table()

    def on_changes_list_revert(self, message: ChangesList.Revert) -> None:
        self.selection = self.selection.revert(message.change_id)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        match event.button.id:
            case "btn-build":
                self.action_finish("build")
            case "btn-run":
                self.action_finish("run")
            case "btn-print":
                self.action_finish("print")
            case "btn-copy":
                self.action_copy()
            case "btn-save":
                self.action_save()

    # -- actions -----------------------------------------------------------------------------

    def action_reset(self) -> None:
        self.marked.clear()
        self.selection = Selection.start(self.selection.template)
        self.render_selection()  # a no-op assignment does not notify

    def action_quit_app(self) -> None:
        self.exit(None)

    def action_focus_filter(self) -> None:
        self.query_one("#sec-optimization", Collapsible).collapsed = False
        self.query_one("#filter", Input).focus()

    def action_toggle_changed_only(self) -> None:
        self.changed_only = not self.changed_only
        self.notify("showing changed modules only" if self.changed_only else "showing every module")
        self.render_table()

    def action_copy(self) -> None:
        self.copy_to_clipboard(self.selection.command())
        self.notify("command copied")

    def action_finish(self, action: str) -> None:
        if not self.valid:
            self.bell()
            return
        checks = [name for name in ("tests", "examples") if self.query_one(f"#chk-{name}", Checkbox).value]
        args = shlex.split(self.query_one("#args", Input).value) if action == "run" else []
        self.exit(Outcome(self.selection, action, args, checks if action == "build" else []))  # type: ignore[arg-type]

    def action_build_here(self) -> None:
        if self.valid:
            self.push_screen(BuildLogScreen(self.selection.request().bazel_flags()))

    def action_save(self) -> None:
        def saved(result: tuple[str, str, str] | None) -> None:
            if result is None:
                return
            name, origin, doc = result
            try:
                path = save_preset(origin, name, self.selection.preset_table(doc))
            except PresetError as error:
                self.notify(str(error), severity="error", timeout=10)
                return
            reload_profiles()
            self.marked.clear()
            self.selection = Selection.start(name)
            self.fill_templates()
            self.render_selection()
            self.notify(f"saved {name!r} to {path.relative_to(ROOT)}: `just build {name}`")

        self.push_screen(SavePresetScreen(), saved)
