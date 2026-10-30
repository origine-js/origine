# /// script
# requires-python = ">=3.12"
# dependencies = ["typer==0.27.3"]
# ///
"""Native transform benchmark. Run with uv run bench/transform/run.py --help."""
from __future__ import annotations
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import resource
import statistics
import subprocess
import sys
import time
import typer

app = typer.Typer()
ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
KINDS = {"ts": 0, "tsx": 1, "jsx": 2}
MODES = ["yuku-fast", "yuku-safe", "yuku-small", "oxc-O3", "oxc-O3-checked", "oxc-Os", "oxc-Oz", "swc-next-O3", "swc-next-O3-checked", "swc-next-Os", "swc-next-Oz"]

def command(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)

def library(mode):
    if mode.startswith("yuku"):
        return ROOT / "target" / mode / "lib/libbench_yuku.dylib"
    name = "bench_swc_next" if mode.startswith("swc-next") else "bench_oxc"
    return ROOT / "target" / mode / f"release/lib{name}.dylib"

def engine(mode):
    return next(name for name in ["yuku", "oxc", "swc-next"] if mode.startswith(name + "-"))

def load(mode):
    lib = C.CDLL(str(library(mode)))
    fn = lib.bench_transform
    fn.argtypes = [C.c_char_p, C.c_size_t, C.c_uint32, C.c_void_p, C.c_size_t]
    fn.restype = C.c_int64
    return fn

@app.command()
def fetch():
    """Download the exact upstream revisions in sources.lock.json."""
    sources = json.loads((ROOT / "sources.lock.json").read_text())
    for name, source in sources.items():
        destination = ROOT / "vendor" / name
        if destination.exists():
            current = command(["git", "-C", str(destination), "rev-parse", "HEAD"], capture_output=True).stdout.strip()
            if current != source["revision"]:
                raise RuntimeError(f"{destination}: existing revision differs from the lock; refusing to overwrite")
            continue
        destination.mkdir(parents=True)
        command(["git", "init", str(destination)])
        command(["git", "-C", str(destination), "fetch", "--depth", "1", source["url"], source["revision"]])
        command(["git", "-C", str(destination), "checkout", "--detach", "FETCH_HEAD"])

def inventory():
    rows = []
    for repo in ["cordis", "webui", "vue-core", "vite"]:
        base = ROOT / "vendor" / repo
        search = base / "packages" if repo != "vite" else base
        for path in sorted(search.rglob("*")):
            ext = path.suffix[1:]
            if ext not in KINDS or path.name.endswith(".d.ts"):
                continue
            rel = path.relative_to(base).as_posix()
            if repo != "vite":
                if not ("/src/" in rel or (repo == "webui" and "/client/" in rel)):
                    continue
                if any(part in {"__tests__", "__test__", "tests", "fixtures"} for part in path.parts):
                    continue
                if ".test." in path.name or ".spec." in path.name:
                    continue
            elif ext == "ts" or not (rel.startswith("playground/") or rel.startswith("packages/create-vite/")):
                continue
            data = path.read_bytes()
            rows.append(dict(repo=repo, path=rel, kind=ext, bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
    return rows

@app.command()
def build():
    """Build isolated native libraries, without modifying Origine."""
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / "target/zig-cache"))
    for mode in ["fast", "safe", "small"]:
        command(["zig", "build", "--build-file", str(ROOT / "build.zig"), f"-Doptimize={mode}", "--prefix", str(ROOT / "target" / f"yuku-{mode}")], env=env)
    for name in ["oxc", "swc-next"]:
        for mode, opt, checked in [("O3", "3", False), ("O3-checked", "3", True), ("Os", "s", False), ("Oz", "z", False)]:
            env = dict(os.environ, CARGO_TARGET_DIR=str(ROOT / "target" / f"{name}-{mode}"), CARGO_PROFILE_RELEASE_OPT_LEVEL=opt, CARGO_PROFILE_RELEASE_OVERFLOW_CHECKS=str(checked).lower(), CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS=str(checked).lower())
            command(["cargo", "build", "--manifest-path", str(ROOT / f"native-{name}/Cargo.toml"), "--release", "--locked", "--offline"], env=env)

@app.command()
def prepare():
    """Record pinned sources and select identical, syntax-valid TS inputs."""
    rows = inventory()
    (ROOT / "results/inventory.json").write_text(json.dumps(rows, indent=2) + "\n")
    outputs, coverage = [], []
    funcs = {mode: load(mode) for mode in ["yuku-fast", "oxc-O3", "swc-next-O3"]}
    for row in rows:
        source = (ROOT / "vendor" / row["repo"] / row["path"]).read_bytes()
        out = C.create_string_buffer(max(65536, len(source) * 16))
        for mode, fn in funcs.items():
            n = fn(source, len(source), KINDS[row["kind"]], out, len(out))
            result = dict(row, engine=engine(mode), status=int(n) if n < 0 else 0, output_bytes=max(0, n))
            coverage.append(result)
            if n >= 0:
                outputs.append(dict(key=len(coverage)-1, code=out.raw[:n].decode()))
    validator = "const fs=require('fs'),vm=require('vm'); const rows=JSON.parse(fs.readFileSync(0,'utf8'));console.log(JSON.stringify(rows.map(r=>{try{new vm.SourceTextModule(r.code);return {key:r.key,ok:true}}catch(e){return {key:r.key,ok:false,error:e.message}}})));"
    proc = command([str(Path.home()/".vite-plus/bin/node"), "--experimental-vm-modules", "-e", validator], input=json.dumps(outputs), capture_output=True)
    for result in json.loads(proc.stdout):
        coverage[result["key"]]["v8_syntax_valid"] = result["ok"]
        if not result["ok"]:
            coverage[result["key"]]["v8_error"] = result["error"]
    (ROOT / "results/coverage.json").write_text(json.dumps(coverage, indent=2) + "\n")
    valid = {(r["repo"], r["path"], r["engine"]) for r in coverage if r["status"] == 0 and r.get("v8_syntax_valid")}
    groups = {}
    for row in rows:
        key = (row["repo"], row["path"])
        # TS compares identical files accepted by all three engines. JSX tasks require JS output.
        if row["kind"] == "ts" and all((*key, engine) in valid for engine in ["yuku", "oxc", "swc-next"]):
            groups.setdefault(row["repo"]+"/ts-common", []).append(row)
        if (*key, "oxc") in valid:
            groups.setdefault(row["repo"]+"/"+row["kind"]+"-oxc-all", []).append(row)
    for repo in ["cordis", "webui", "vue-core"]:
        accepted = [r for r in rows if r["repo"] == repo and r["kind"] == "ts" and (repo, r["path"], "swc-next") in valid]
        if accepted and accepted != groups.get(repo+"/ts-oxc-all"):
            groups[repo+"/ts-swc-next-all"] = accepted
    (ROOT / "results/groups.json").write_text(json.dumps(groups, indent=2) + "\n")
    print(json.dumps({k: {"files": len(v), "bytes":sum(r["bytes"] for r in v)} for k,v in groups.items()}, indent=2))

@app.command()
def worker(mode: str, group: str, iterations: int = 20):
    """One isolated sample, with sources and destination buffers preloaded."""
    rows = json.loads((ROOT/"results/groups.json").read_text())[group]
    items = []
    out = C.create_string_buffer(max(65536, max(r["bytes"] for r in rows)*16))
    for row in rows:
        source = (ROOT/"vendor"/row["repo"]/row["path"]).read_bytes()
        items.append((source, KINDS[row["kind"]], out))
    baseline_rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss/1024**2
    fn = load(mode)
    def sweep():
        checksum = 0
        for src, kind, out in items:
            n = fn(src, len(src), kind, out, len(out))
            if n < 0:
                raise RuntimeError(f"{mode} failed in timed group {group}: {n}")
            checksum += n
        return checksum
    for _ in range(3):
        sweep()
    pilot_start = time.perf_counter_ns()
    sweep()
    pilot_ns = time.perf_counter_ns() - pilot_start
    iterations = max(iterations, int(150_000_000 / max(1, pilot_ns)))
    before = resource.getrusage(resource.RUSAGE_SELF)
    cpu0, wall0 = time.process_time_ns(), time.perf_counter_ns()
    checksum = 0
    for _ in range(iterations):
        checksum += sweep()
    wall, cpu = time.perf_counter_ns()-wall0, time.process_time_ns()-cpu0
    after = resource.getrusage(resource.RUSAGE_SELF)
    print(json.dumps(dict(mode=mode, group=group, iterations=iterations, files=len(rows), input_bytes=sum(r["bytes"] for r in rows), wall_ms=wall/1e6/iterations, cpu_ms=cpu/1e6/iterations, cpu_percent=100*cpu/wall, peak_rss_mib=after.ru_maxrss/1024**2, warmup_peak_rss_mib=before.ru_maxrss/1024**2, baseline_rss_mib=baseline_rss, peak_increment_mib=max(0, after.ru_maxrss/1024**2-baseline_rss), checksum=checksum)))

@app.command()
def measure(samples: int = 7, iterations: int = 20, cooldown_seconds: float = typer.Option(1.0, min=0.0), output_dir: Path = ROOT / "results"):
    """Randomized serial samples; never benchmark during compilation."""
    groups = json.loads((ROOT/"results/groups.json").read_text())
    output_dir.mkdir(parents=True, exist_ok=True)
    coverage = json.loads((ROOT/"results/coverage.json").read_text())
    valid = {(r["engine"], r["repo"], r["path"]) for r in coverage if r["status"] == 0 and r.get("v8_syntax_valid")}
    jobs = [(mode, group) for mode in MODES for group, rows in groups.items() if all((engine(mode), r["repo"], r["path"]) in valid for r in rows)]
    rng = random.Random(20261028)
    results = []
    previous_finished_ns = None
    run_started = time.time()
    for sample in range(samples):
        rng.shuffle(jobs)
        for mode, group in jobs:
            cooldown_actual_seconds = None
            if previous_finished_ns is not None:
                remaining = cooldown_seconds - (time.monotonic_ns() - previous_finished_ns) / 1e9
                if remaining > 0:
                    time.sleep(remaining)
                cooldown_actual_seconds = (time.monotonic_ns() - previous_finished_ns) / 1e9
            worker_started = time.time()
            proc = command([sys.executable, __file__, "worker", mode, group, "--iterations", str(iterations)], capture_output=True)
            previous_finished_ns = time.monotonic_ns()
            row = json.loads(proc.stdout)
            row["sample"] = sample
            row["worker_started_unix"] = worker_started
            row["worker_finished_unix"] = time.time()
            row["cooldown_actual_seconds"] = cooldown_actual_seconds
            results.append(row)
            (output_dir/"raw.json").write_text(json.dumps(results, indent=2)+"\n")
            if len(results) % 5 == 0:
                print(f"Completed {len(results)}/{samples * len(jobs)} benchmark processes", flush=True)
        print(f"Completed sample {sample+1}/{samples}", flush=True)
        (output_dir/"raw.json").write_text(json.dumps(results, indent=2)+"\n")
    sizes = []
    for mode in MODES:
        dynamic = library(mode)
        static = dynamic.parent / ("libbench_yuku_static.a" if mode.startswith("yuku") else ("libbench_swc_next.a" if mode.startswith("swc-next") else "libbench_oxc.a"))
        sizes.append(dict(mode=mode, dylib_bytes=dynamic.stat().st_size, archive_bytes=static.stat().st_size, dylib_sha256=hashlib.sha256(dynamic.read_bytes()).hexdigest()))
    meta = dict(date="2026-10-28", platform=platform.platform(), machine=platform.machine(), python=sys.version, samples=samples, iterations=iterations, revisions={name:command(["git", "-C", str(ROOT/"vendor"/name), "rev-parse", "HEAD"],capture_output=True).stdout.strip() for name in ["yuku","cordis","webui","vue-core","vite","swc-next"]}, sizes=sizes)
    for name,args in {"zig":["zig","version"],"rustc":["rustc","--version"],"node":[str(Path.home()/".vite-plus/bin/node"),"--version"]}.items():
        meta[name]=command(args,capture_output=True).stdout.strip()
    meta.update(json.loads((ROOT/"results/hardware.json").read_text()))
    meta.update(yuku_version="0.24.1", oxc_version="0.155.0", swc_next_version="0.4.0")
    meta.update(cooldown_seconds=cooldown_seconds, run_started_unix=run_started, run_finished_unix=time.time())
    (output_dir/"environment.json").write_text(json.dumps(meta, indent=2)+"\n")
    summaries=[]
    for mode, group in sorted(jobs):
        rows=[r for r in results if r["mode"]==mode and r["group"]==group]
        summary=dict(mode=mode,group=group,files=rows[0]["files"],input_bytes=rows[0]["input_bytes"])
        for key in ["wall_ms","cpu_ms","cpu_percent","peak_rss_mib","peak_increment_mib"]:
            summary[key]=statistics.median(r[key] for r in rows)
        summary["wall_min_ms"]=min(r["wall_ms"] for r in rows)
        summary["wall_max_ms"]=max(r["wall_ms"] for r in rows)
        summaries.append(summary)
    (output_dir/"summary.json").write_text(json.dumps(summaries,indent=2)+"\n")

@app.command()
def verify():
    """Check representative emitted programs in V8, including runtime behavior."""
    probes = {
        "erasable-ts": ("ts", "export const answer: number = 42;"),
        "const-enum": ("ts", "const enum E { A=41, B }; export const answer = E.B;"),
        "enum": ("ts", "enum E { A=41, B }; export const answer = E.B;"),
        "namespace": ("ts", "namespace N { export const n = 42 }; export const answer = N.n;"),
        "parameter-property": ("ts", "class Box { constructor(public n: number) {} }; export const answer = new Box(42).n;"),
        "tsx": ("tsx", "const React = {createElement: (_tag: any, _props: any, n: number) => n}; const n: number = 42; export const answer = <span>{n}</span>;"),
        "jsx": ("jsx", "const React = {createElement: (_tag, _props, n) => n}; export const answer = <span>{42}</span>;"),
    }
    rows = []
    out = C.create_string_buffer(65536)
    for mode in MODES:
        fn = load(mode)
        for name, (kind, source) in probes.items():
            src = source.encode()
            n = fn(src, len(src), KINDS[kind], out, len(out))
            row = dict(mode=mode, probe=name, status=min(n, 0))
            if n >= 0:
                row["code"] = out.raw[:n].decode()
            rows.append(row)
    script = """const fs=require('fs'),vm=require('vm');
    (async()=>{const rows=JSON.parse(fs.readFileSync(0,'utf8'));
    for(const r of rows) { if(r.status<0) continue;
      try { const m=new vm.SourceTextModule(r.code); await m.link(()=>{throw Error('unexpected import')}); await m.evaluate(); r.answer=m.namespace.answer; r.runtime_pass=r.answer===42; }
      catch(e) {r.runtime_pass=false;r.error=e.message;}
    } console.log(JSON.stringify(rows));})()"""
    proc = command([str(Path.home()/".vite-plus/bin/node"), "--experimental-vm-modules", "-e", script], input=json.dumps(rows), capture_output=True)
    results = json.loads(proc.stdout)
    for row in results:
        expected = row["mode"].startswith("oxc") or row["probe"] == "erasable-ts" or (row["mode"].startswith("swc-next") and row["probe"] not in {"tsx", "jsx"})
        if bool(row.get("runtime_pass")) != expected:
            raise RuntimeError(f"Unexpected feature result: {row}")
    (ROOT/"results/probes.json").write_text(json.dumps(results, indent=2)+"\n")
    print(f"Verified {len(results)} mode/feature combinations in V8")
    module_rows = []
    for mode in ["yuku-fast", "oxc-O3", "swc-next-O3"]:
        fn = load(mode)
        for name, source in {
            "import-equals": "import Foo = require('pkg'); export const answer = Foo.answer;",
            "export-equals": "const value = 42; export = value;",
        }.items():
            src = source.encode()
            n = fn(src, len(src), KINDS["ts"], out, len(out))
            row = dict(mode=mode, probe=name, status=min(n, 0))
            if n >= 0:
                row["code"] = out.raw[:n].decode()
            module_rows.append(row)
    syntax_script = """const fs=require('fs'),vm=require('vm');
    const rows=JSON.parse(fs.readFileSync(0,'utf8'));
    for(const r of rows) {if(r.status<0) continue;
      try {new vm.SourceTextModule(r.code);r.v8_syntax_valid=true;}
      catch(e) {r.v8_syntax_valid=false;r.error=e.message;}
    } console.log(JSON.stringify(rows));"""
    proc = command([str(Path.home()/".vite-plus/bin/node"), "--experimental-vm-modules", "-e", syntax_script], input=json.dumps(module_rows), capture_output=True)
    module_results = json.loads(proc.stdout)
    for row in module_results:
        if row["mode"] == "swc-next-O3" and row.get("v8_syntax_valid"):
            raise RuntimeError(f"SWC Next module compatibility changed: {row}")
    (ROOT/"results/module-probes.json").write_text(json.dumps(module_results, indent=2)+"\n")
    print(f"Recorded {len(module_results)} additional module-form syntax checks")

@app.command()
def report():
    """Render the Markdown comparison from the saved JSON results."""
    from render_report import render
    render(ROOT)
    print(ROOT / "report.md")

if __name__ == "__main__":
    app()
