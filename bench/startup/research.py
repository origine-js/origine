# /// script
# requires-python = ">=3.11"
# dependencies = ["typer>=0.12"]
# ///
"""Measure isolated startup variants in seeded, interleaved batches.

Configuration: a JSON array of {name, binary, env?}; optional args defaults to the
TypeScript example. Each case gets a private cwd and cache, preventing one engine
variant from sweeping another's snapshots. Generated artifacts belong in zig-out.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import re
import resource
import shutil
import statistics
import subprocess
import time

import typer


def summarize(values: list[int]) -> dict[str, float]:
    """Return descriptive statistics in nanoseconds, retaining no input storage."""
    ordered = sorted(values)
    mean = statistics.mean(values)
    deviation = statistics.stdev(values) if len(values) > 1 else 0.0
    return {
        "median_ns": statistics.median(values),
        "mean_ns": mean,
        "stdev_ns": deviation,
        "p95_ns": ordered[math.ceil(len(ordered) * 0.95) - 1],
        "min_ns": ordered[0],
        "max_ns": ordered[-1],
        "cv": deviation / mean if mean else 0.0,
    }


def invoke(case: dict, trace: bool) -> dict:
    """Own one child until completion; retain only numeric measurements, never env contents."""
    if case.get("reset_init_cache", False):
        # Only the fixture cache created by this harness; this is not a cold OS-page-cache run.
        shutil.rmtree(Path(case["cwd"]) / "examples/typescript/__oricache__", ignore_errors=True)
    env = dict(os.environ)
    for key in ["V8_STARTUP_TRACE", "ORIGINE_SNAPSHOT_LOG", "ORIGINE_NO_SNAPSHOT",
                "ORIGINE_RESEARCH_FLAGS", "ORIGINE_RESEARCH_THREADS",
                "ORIGINE_RESEARCH_SINGLE_PLATFORM", "ORIGINE_RESEARCH_RETAIN_ENGINE"]:
        env.pop(key, None)
    env.update(case.get("env", {}))
    if trace:
        env["V8_STARTUP_TRACE"] = "1"
    # A cwd= argument forces Python onto fork/exec on macOS. Change the single-threaded
    # harness's cwd before timing, allowing Popen to use posix_spawn instead.
    previous = Path.cwd()
    os.chdir(case["cwd"])
    try:
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        start = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
        result = subprocess.run(
            [case["binary"], *case.get("args", ["examples/typescript/init.ts"])],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, env=env, check=True, close_fds=False,
        )
        end = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
    finally:
        os.chdir(previous)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    row = {
        "wall_ns": end - start,
        "cpu_user_ns": round((after.ru_utime - before.ru_utime) * 1e9),
        "cpu_system_ns": round((after.ru_stime - before.ru_stime) * 1e9),
    }
    for kind, name, ns in re.findall(
        rb"^(startup|scope_detail|research_span) (\w+): (\d+) ns$", result.stderr, re.M
    ):
        key = kind.decode() + "." + name.decode()
        if key == "startup.total" and key in row:
            continue
        row[key] = row.get(key, 0) + int(ns)
    clocks = dict(re.findall(rb"^research_clock (\w+): (\d+)$", result.stderr, re.M))
    if b"main_entry" in clocks:
        row["launch_to_main_ns"] = int(clocks[b"main_entry"]) - start
        row["after_main_to_return_ns"] = end - int(clocks[b"main_end"])
    return row


def main(
    config: Path,
    output: Path,
    runs: int = 150,
    batches: int = 3,
    warmup: int = 5,
    trace: bool = False,
    pause_seconds: float = 2.0,
    seed: int = 20261023,
) -> None:
    """Write raw samples and summaries; owns only output artifacts and child processes."""
    if runs < 2 or batches < 1 or warmup < 0 or not 0 <= pause_seconds <= 60:
        raise typer.BadParameter("runs >= 2, batches >= 1, warmup >= 0, pause in [0,60]")
    root = Path.cwd()
    cases = json.loads(config.read_text())
    names = [case["name"] for case in cases]
    if len(set(names)) != len(names):
        raise typer.BadParameter("case names must be unique")
    output.parent.mkdir(parents=True, exist_ok=True)
    for case in cases:
        if not re.fullmatch(r"[A-Za-z0-9_-]+", case["name"]):
            raise typer.BadParameter("case names must be simple path components")
        binary = (root / case["binary"]).resolve()
        case["binary"] = str(binary)
        case["binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        cwd = output.parent / "workloads" / case["name"]
        fixture = cwd / "examples/typescript"
        fixture.mkdir(parents=True, exist_ok=True)
        for name in ["init.ts", "greeter.ts"]:
            shutil.copyfile(root / "examples/typescript" / name, fixture / name)
        case["cwd"] = str(cwd.resolve())
    report = {
        "platform": platform.platform(), "python": platform.python_version(),
        "clock": "CLOCK_MONOTONIC", "quantile": "nearest-rank p95",
        "runs_per_batch": runs, "batches": batches, "warmup": warmup,
        "trace": trace, "seed": seed, "cases": cases, "samples": [],
        "summary_by_batch": [],
    }
    rng = random.Random(seed)
    for batch in range(batches):
        if batch:
            time.sleep(pause_seconds)
        for case in cases:
            for _ in range(warmup):
                invoke(case, trace)
        rows = []
        for iteration in range(runs):
            order = list(cases)
            rng.shuffle(order)
            for case in order:
                row = {"case": case["name"], "batch": batch + 1,
                       "iteration": iteration, **invoke(case, trace)}
                rows.append(row)
        report["samples"].extend(rows)
        summary = {}
        for case in cases:
            selected = [row for row in rows if row["case"] == case["name"]]
            metrics = sorted(set.intersection(*(set(row) for row in selected))
                             - {"case", "batch", "iteration"})
            summary[case["name"]] = {
                key: summarize([row[key] for row in selected]) for key in metrics
            }
            wall = summary[case["name"]]["wall_ns"]
            typer.echo(f"batch {batch+1} {case['name']}: "
                       f"p50 {wall['median_ns']/1e6:.3f} ms, "
                       f"p95 {wall['p95_ns']/1e6:.3f} ms, "
                       f"sd {wall['stdev_ns']/1e6:.3f} ms")
        report["summary_by_batch"].append(summary)
        output.write_text(json.dumps(report, indent=2) + "\n")
    typer.echo(f"Raw measurements: {output}")


if __name__ == "__main__":
    typer.run(main)
