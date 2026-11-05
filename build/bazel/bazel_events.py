"""Bazel's Build Event Protocol (BEP) as a stream of typed events, and a reducer that turns it into state.

No terminal, Textual or Typer in here: any front end can use it. Run Bazel with
`--build_event_json_file=<path>` (newline-delimited JSON, one event per line), then:

    async for event in run_bazel(["build", "//src:origine"], cwd=ROOT):
        state.apply(event)          # BuildState: targets, actions, [N / M] progress, last lines, errors

`parse_event` and `BuildState` are pure, so they can be tested on a recorded file (see tests/).
BEP's schema is Bazel's (`build_event_stream.proto`); only the fields below are read and everything
else becomes `Other`, so a newer Bazel adding events never breaks this.
"""

import asyncio
import json
import re
import tempfile
from collections import deque
from collections.abc import AsyncIterator
from pathlib import Path

from pydantic import BaseModel, ConfigDict, Field

PROGRESS_LINE = re.compile(r"\[([\d,]+) / ([\d,]+)\]")  # Bazel's "[48 / 1,235] Compiling foo.cc; 3s ..."


class Event(BaseModel):
    model_config = ConfigDict(frozen=True)


class Started(Event):
    command: str = ""
    bazel_version: str = ""


class Progress(Event):
    """Text Bazel would have printed (its stdout/stderr), in order."""

    stdout: str = ""
    stderr: str = ""


class TargetConfigured(Event):
    label: str


class TargetCompleted(Event):
    label: str
    success: bool


class ActionCompleted(Event):
    """An executed action (every action needs `--build_event_publish_all_actions`; failed ones always come)."""

    label: str = ""
    mnemonic: str = ""
    success: bool = True
    exit_code: int = 0


class Finished(Event):
    success: bool
    exit_code: int
    exit_name: str = ""


class Exited(Event):
    """Not from BEP: the Bazel process itself ended (always the last event of `run_bazel`)."""

    returncode: int


class Other(Event):
    kind: str = ""


def parse_event(line: str) -> Event:
    """One BEP JSON line -> an event. ValueError for a line that is not a JSON object."""
    data = json.loads(line)
    if not isinstance(data, dict):
        raise ValueError(f"not a BEP event: {line[:80]!r}")
    event_id = data.get("id") or {}
    kind = next(iter(event_id), "")
    if kind == "started":
        body = data.get("started", {})
        return Started(command=body.get("command", ""), bazel_version=body.get("buildToolVersion", ""))
    if kind == "progress":
        body = data.get("progress", {})
        return Progress(stdout=body.get("stdout", ""), stderr=body.get("stderr", ""))
    if kind == "targetConfigured":
        return TargetConfigured(label=event_id[kind].get("label", ""))
    if kind == "targetCompleted":
        return TargetCompleted(label=event_id[kind].get("label", ""), success=bool(data.get("completed", {}).get("success")))
    if kind == "actionCompleted":
        body = data.get("action", {})
        return ActionCompleted(
            label=event_id[kind].get("label", ""), mnemonic=body.get("type", ""),
            success=bool(body.get("success", False)), exit_code=int(body.get("exitCode", 0)),
        )
    if kind == "buildFinished":
        body = data.get("finished", {})
        code = body.get("exitCode", {})
        return Finished(success=bool(body.get("overallSuccess")), exit_code=int(code.get("code", 0)), exit_name=code.get("name", ""))
    return Other(kind=kind)


class BuildState(BaseModel):
    """What a front end shows. `apply` is the only way it changes; it is deterministic."""

    started: bool = False
    finished: bool = False
    success: bool | None = None  # None until the build finished
    targets_configured: int = 0
    targets_completed: int = 0
    targets_failed: list[str] = Field(default_factory=list)
    actions: int = 0
    actions_failed: int = 0
    done: int = 0  # the last "[done / total]" Bazel printed
    total: int = 0
    mnemonics: dict[str, int] = Field(default_factory=dict)  # actions executed, by mnemonic
    lines: deque[str] = Field(default_factory=lambda: deque(maxlen=500))  # the last output lines
    errors: list[str] = Field(default_factory=list)  # output lines that start with ERROR
    returncode: int | None = None  # the process's, from `Exited`

    @property
    def fraction(self) -> float | None:
        """0..1 progress, None while Bazel has not said how many actions there are."""
        return min(self.done / self.total, 1.0) if self.total else None

    def apply(self, event: Event) -> None:
        if isinstance(event, Started):
            self.started = True
        elif isinstance(event, Progress):
            for line in (event.stdout + event.stderr).splitlines():
                line = line.rstrip()
                if not line:
                    continue
                self.lines.append(line)
                if line.lstrip().startswith("ERROR"):
                    self.errors.append(line)
                if found := PROGRESS_LINE.search(line):
                    self.done, self.total = (int(g.replace(",", "")) for g in found.groups())
        elif isinstance(event, TargetConfigured):
            self.targets_configured += 1
        elif isinstance(event, TargetCompleted):
            self.targets_completed += 1
            if not event.success:
                self.targets_failed.append(event.label)
        elif isinstance(event, ActionCompleted):
            self.actions += 1
            self.actions_failed += not event.success
            if event.mnemonic:
                self.mnemonics[event.mnemonic] = self.mnemonics.get(event.mnemonic, 0) + 1
        elif isinstance(event, Finished):
            self.finished, self.success = True, event.success
        elif isinstance(event, Exited):
            self.returncode = event.returncode


async def follow(path: Path, process_done: asyncio.Event, *, interval: float = 0.05) -> AsyncIterator[Event]:
    """Yields the events of a growing BEP file. Ends once `process_done` is set and the file is drained.

    Only complete lines are parsed (a writer may be mid-line); lines that are not events are skipped."""
    buffer = ""
    position = 0
    while True:
        finished = process_done.is_set()  # read this BEFORE draining, so the last bytes are not missed
        if path.exists():
            with path.open("rb") as handle:
                handle.seek(position)
                chunk = handle.read()
                position += len(chunk)
            buffer += chunk.decode("utf-8", errors="replace")
        *lines, buffer = buffer.split("\n")
        for line in lines:
            if line.strip():
                try:
                    yield parse_event(line)
                except ValueError:
                    continue
        if finished and not buffer.strip():
            return
        if finished and not chunk:
            return
        await asyncio.sleep(interval)


async def run_bazel(args: list[str], *, cwd: Path, bazel: str = "bazel") -> AsyncIterator[Event]:
    """Runs `bazel <args>` and yields its BEP events, then `Exited`.

    Output comes only through the events (`Progress`), so a front end owns the screen. Until the first BEP
    event arrives, Bazel's own stderr is turned into `Progress` too: that is where the client says it is
    waiting for another command's lock or starting its server, before any event exists."""
    with tempfile.TemporaryDirectory() as directory:
        bep = Path(directory) / "bep.json"
        process = await asyncio.create_subprocess_exec(
            bazel, args[0], f"--build_event_json_file={bep}", "--build_event_publish_all_actions",
            "--color=no", "--curses=no", *args[1:],
            cwd=cwd, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
        )
        done = asyncio.Event()
        queue: asyncio.Queue[Event | None] = asyncio.Queue()
        events_started = False

        async def pump_stderr() -> None:
            assert process.stderr is not None
            async for raw in process.stderr:
                if not events_started:
                    queue.put_nowait(Progress(stderr=raw.decode("utf-8", errors="replace")))

        async def pump_events() -> None:
            nonlocal events_started
            async for event in follow(bep, done):
                events_started = True
                queue.put_nowait(event)

        async def wait() -> None:
            await process.wait()
            done.set()

        tasks = [asyncio.create_task(pump_stderr()), asyncio.create_task(pump_events()), asyncio.create_task(wait())]

        async def close() -> None:
            await asyncio.gather(*tasks, return_exceptions=True)
            queue.put_nowait(None)

        closer = asyncio.create_task(close())
        try:
            while (event := await queue.get()) is not None:
                yield event
        finally:
            if process.returncode is None:
                process.terminate()
            for task in (*tasks, closer):
                task.cancel()
            await asyncio.gather(*tasks, closer, return_exceptions=True)
            await process.wait()
        yield Exited(returncode=process.returncode or 0)
