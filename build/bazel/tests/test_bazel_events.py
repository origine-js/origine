#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pydantic>=2.9,<3"]
# ///
"""BEP parsing and the reducer, on a recorded build (lz4.bep.json). Run: uv run --script build/bazel/tests/test_bazel_events.py"""

import asyncio
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import bazel_events as be


def test_recorded_build() -> None:
    state = be.BuildState()
    events = [be.parse_event(line) for line in (HERE / "lz4.bep.json").read_text().splitlines()]
    for event in events:
        state.apply(event)
    assert isinstance(events[0], be.Started) and events[0].command == "build"
    assert state.finished and state.success and state.targets_completed == state.targets_configured == 1
    assert any("liblz4.a" in line for line in state.lines)


def test_progress_and_errors() -> None:
    state = be.BuildState()
    state.apply(be.parse_event('{"id":{"progress":{}},"progress":{"stderr":"[48 / 1,235] Compiling x.cc\\nERROR: boom\\n"}}'))
    assert (state.done, state.total) == (48, 1235) and abs(state.fraction - 48 / 1235) < 1e-9
    assert state.errors == ["ERROR: boom"]
    state.apply(be.parse_event('{"id":{"actionCompleted":{"label":"//a:b"}},"action":{"success":false,"exitCode":1,"type":"CppCompile"}}'))
    assert state.actions == 1 and state.actions_failed == 1 and state.mnemonics == {"CppCompile": 1}
    assert isinstance(be.parse_event('{"id":{"somethingNew":{}}}'), be.Other)


def test_follow_handles_partial_lines() -> None:
    async def run() -> list[be.Event]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bep.json"
            done = asyncio.Event()
            seen: list[be.Event] = []

            async def reader() -> None:
                async for event in be.follow(path, done, interval=0.01):
                    seen.append(event)

            task = asyncio.create_task(reader())
            with path.open("w") as out:
                out.write('{"id":{"started":{}},"started":{"command":"build"}}\n{"id":{"progress":')
                out.flush()
                await asyncio.sleep(0.05)
                out.write('{}},"progress":{"stderr":"hi"}}\n')
            done.set()
            await task
            return seen

    seen = asyncio.run(run())
    assert [type(e).__name__ for e in seen] == ["Started", "Progress"] and seen[1].stderr == "hi"


def test_run_bazel_with_a_fake_bazel() -> None:
    """The process driver, on a stand-in `bazel` that waits (stderr), then writes the recorded events."""
    async def run() -> be.BuildState:
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "bazel"
            fake.write_text(
                "#!/bin/sh\n"
                "for a in \"$@\"; do case $a in --build_event_json_file=*) out=${a#*=};; esac; done\n"
                "echo 'Another command (pid=1) is running. Waiting for it to complete...' >&2\n"
                "sleep 0.2\n"
                f"cp '{HERE / 'lz4.bep.json'}' \"$out\"\n"
                "exit 3\n"
            )
            fake.chmod(0o755)
            state = be.BuildState()
            async for event in be.run_bazel(["build", "//x"], cwd=Path(directory), bazel=str(fake)):
                state.apply(event)
            return state

    state = asyncio.run(run())
    assert state.lines[0].startswith("Another command"), list(state.lines)[:2]
    assert state.finished and state.success and state.returncode == 3


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print("ok", name)
