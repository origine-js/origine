# Yuku / Oxc / SWC Next native transform benchmark

Measured results and interpretation: [report.md](report.md). Feature and V8 integration research: [../../docs/research/yuku-oxc-features.md](../../docs/research/yuku-oxc-features.md).

## Reproduce

Requires macOS arm64, Zig 0.17.0, Rust/Cargo (recorded version in `results/environment.json`), uv, and Vite Plus's Node at `~/.vite-plus/bin/node`. This harness does not build or alter Origine. Download/build directories are ignored.

```sh
uv run --locked bench/transform/run.py fetch
uv run --locked bench/transform/run.py build
uv run --locked bench/transform/run.py prepare
uv run --locked bench/transform/run.py verify
uv run --locked bench/transform/run.py measure --cooldown-seconds 1
uv run --locked bench/transform/run.py report
```

`fetch` checks out exact commits in `sources.lock.json`. `build` uses Cargo's checked-in lockfile and offline mode; on a machine without cached Rust crates first run `cargo fetch --manifest-path bench/transform/native-oxc/Cargo.toml --locked` and `cargo fetch --manifest-path bench/transform/native-swc-next/Cargo.toml --locked` after `fetch`. uv downloads the pinned script dependencies on first run. In restricted environments, use a writable `UV_CACHE_DIR`. The build assigns Zig a local writable global cache.

`prepare` inventories package source files, checks diagnostics, and validates every successful output with Node's V8 `SourceTextModule` without resolving imports or executing applications. Only TS files all three engines accept enter common-subset comparisons. `verify` executes representative TS/TSX/JSX feature probes under V8 across every build configuration. `measure` randomly orders serial samples; run it after builds complete and while the machine is otherwise idle.

## Measurements

Each timed operation sweeps an entire source group once. Sources and one reusable destination buffer are preloaded; there are three warmup sweeps and a pilot sweep. Each sample runs at least 20 sweeps, or enough to target approximately 150 ms, whichever is greater. Seven fresh-process samples are collected, with deterministic randomized ordering. By default, the runner waits at least 1 second from the end of each worker process before starting the next worker (454 gaps for 455 workers, about 7.6 minutes of pauses). Warmup and repeated timed sweeps within a worker are not separated by pauses. The requested and observed cooldown intervals and worker start/finish timestamps are saved; pauses are outside the timed region. `--output-dir` can stage a new run without replacing the previous results until it completes. Reported durations are medians of per-sweep averages, not per-file latency. Very small JSX/TSX groups are batched to avoid timer resolution dominating the result.

The native wrapper parses and generates code, copies the output into caller-owned storage, then releases its temporary allocations. All wrappers remove comments and disable source maps/minification/downleveling. Oxc uses classic JSX and preserves imports unless explicitly type-only. Oxc and SWC Next include semantic analysis; Yuku does not. SWC Next uses its public semantic TypeScript lowering pass after runtime normalization and syntax-checking semantic analysis, without unrelated ES transforms or redundant post-transform semantic rebuilding. `verbatim_module_syntax=true` preserves value imports. This is the SWC Next rewrite (0.4.0 at the pinned commit), not classic SWC, and not the separate restricted fixed-width type-strip API. These are each library's existing usable pipelines, with different feature coverage and validation depth. The Python/ctypes loop overhead is included in both. Library load, corpus I/O, V8 output checks and application execution are excluded from timing.

CPU milliseconds come from `process_time_ns`; CPU utilization is CPU/wall × 100, with 100% meaning one core. Peak RSS is macOS `getrusage(RUSAGE_SELF).ru_maxrss`, converted from bytes to MiB. It includes Python, Typer, preloaded input/buffer, mapped library pages and native allocator state. `peak_increment_mib` is the increase in the process high-water mark after loading/using the library over the pre-load high-water mark: it is an approximate incremental process peak, not an isolated allocation count or a memory-leak measurement. RSS warmup and pre-load baselines are preserved per sample.

Libraries use default host/CPU targeting for each toolchain, not explicitly matched microarchitecture tuning; this is a limitation of cross-toolchain comparisons. Rust uses thin LTO, one codegen unit, stripped artifacts and aborting panics. This differs from Origine's mixed optimization, 16-codegen-unit, unwinding profile. Zig uses stripped artifacts and its native release modes, with `std_options_debug_io = std.Io.failing` to follow Origine's prohibition on threaded std.Io. SWC Next upstream defaults to fat LTO; the benchmark uses thin LTO for both Rust libraries to align their settings. Rust's checked O3 profile enables overflow checks and debug assertions; it does not reproduce Zig `.safe` semantics.

The checked-in dynamic-library sizes and static archive sizes describe these benchmark wrappers with reachable dependencies. Static archives include runtime/dependency objects and are not the final linked size added to Origine; LTO/dead stripping can change the final binary substantially. Source maps are disabled at runtime; Yuku's map implementation remains a build option enabled in the module configuration. This is not a comparison of every feature of either toolchain.

## Result files

- `results/inventory.json`: exact paths, source byte sizes and SHA-256 hashes.
- `results/coverage.json`: per-file return status and V8 syntax acceptance; -1 is a parse/semantic error, -2 is a transform/codegen diagnostic, -3 is a Yuku allocation failure, -4 is insufficient output buffer.
- `results/groups.json`: exact source sets used for timing.
- `results/probes.json`: emitted code and V8 runtime feature checks.
- `results/module-probes.json`: six extra module-form syntax checks (`import =` and `export =`) for the baseline builds.
- `results/raw.json`: every measured sample, including iteration count and RSS baselines.
- `results/summary.json`: median metrics and min/max per-sample wall times.
- `results/environment.json`: tool versions, upstream revisions, library sizes and artifact hashes.
- `results/no-cooldown-previous/`: previous timing, summary and environment data, before introducing the 1-second cooldown; see `report-no-cooldown.md`.
- `results/hardware.json`: recorded CPU/RAM metadata for this measurement host; update this before measuring on another machine.

`report` regenerates the complete Markdown comparison from the saved results via `render_report.py`. Oxc and SWC Next full-corpus timings share the same source groups; the historic `-oxc-all` suffix names that accepted reference corpus, not an engine restriction. Unsupported full groups receive no timing.

V8 syntax acceptance is not application correctness. Vue `.vue` SFCs, declaration files, package tests and framework template transforms are outside this source-transform benchmark. Vite template/playground JSX inputs provide syntax-lowering workloads; classic React output does not establish correct Vue, Solid, Preact or Qwik framework behavior.
