# Startup latency and consistency research

Research date: 2026-10-23. Scope: origine on macOS arm64, pinned V8 15.8.30 (`a98309795399032afd2f191adaa94ed6e9918437`). This report separates verified source behavior from optimization hypotheses. No saving estimate below is a measured result unless explicitly identified as such.

**Design boundary:** init evaluation constructs the prepared application image. It is allowed to perform application setup; runtime restores that image and calls exported `main`, which performs runtime work. Image construction is intentional one-time preparation, not the startup path to optimize here.

**Latest result:** snapshot-resident scope helpers and exact-size private-copy image reads were applied after broader workload tests. Blanket eager compilation was rejected because it regressed larger graphs. See the applied trial below for p50/p95 and memory results; security checks and normal cleanup are preserved.

## Applied trial: safe general-purpose defaults

The follow-up trial kept two changes and rejected blanket eager compilation.

- **Snapshot-resident scope bootstrap helpers:** engine/init snapshots now retain the existing JS hardener and unsupported-prototype predicate in private context data. New scopes restore them instead of recompiling/bootstrap initialization. The native export validator, intrinsic restrictions and cleanup remain unchanged. Old/no-snapshot contexts perform the same fallback initialization. [Implementation](../src/managed/bootstrap.zig), [scope integration](../src/managed/scope.zig).
- **One-allocation init-image reads:** open/stat the regular cache file, allocate its exact size with the required 16-byte alignment, read all bytes, and verify EOF. The 1 GiB bound, format/key/engine checks, content hashes, owned stable buffer and all cleanup remain. This avoids geometric stream-buffer growth while preserving a private copy. A regression restores an already-loaded image after its file has been truncated/overwritten. [Reader](../src/api/init_cache.zig), [cache tests](../src/tests/managed/init_cache.zig).
- **Rejected:** eager compilation + retained code. It helped the tiny TypeScript input slightly but penalized a 20-module graph containing 2,000 unused functions by 0.35–0.5 ms, with ~29% init-image growth. Eager compilation and `kKeep` were reverted; ordinary imports and both snapshot code-handling policies remain unchanged.
- **Not adopted:** direct file-backed mapping. It would couple the live V8 image to later file mutation/truncation; a private stable copy preserves the existing reliability boundary. No sandbox, validation, worker, JIT or cleanup policy was relaxed.

### Outcome: interleaved, tracing disabled

Three batches of 150 measured launches for each workload/variant; five warmups per batch, isolated caches and no concurrent builds. The retained candidate combines helper preparation and exact-size image reads. Values pool 450 observations per row; they belong to this run set, not an earlier Hyperfine session.

| Workload | Baseline p50 ms | Retained p50 ms | Baseline p95 ms | Retained p95 ms |
|---|---:|---:|---:|---:|
| TypeScript example | 8.475 | 8.348 | 9.292 | 9.132 |
| Empty startup / REPL EOF | 7.919 | 7.659 | 8.552 | 8.394 |
| 20-module graph, 2,000 unused functions | 9.774 | 9.577 | 10.639 | 10.324 |

Per-batch baseline-minus-retained median improvements were **0.162/0.101/0.128 ms** for TypeScript, **0.257/0.316/0.218 ms** for empty startup, and **0.209/0.161/0.215 ms** for the larger graph. These are modest improvements, not a multi-millisecond V8 initialization win. Tail improvements are aggregate observations, not a guarantee of lower variance in every batch.

Independent 30-run Hyperfine peak-RSS checks:

| Workload | Baseline median MiB | Retained median MiB |
|---|---:|---:|
| TypeScript | 19.906 | 19.563 |
| Empty startup | 19.109 | 17.508 |
| Larger graph | 21.328 | 20.813 |

Preparing the helper context adds **9,672 bytes (~9.4 KiB)** to the init-image file in these fixtures; the exact-size reader does not change the image format or size. No material resident-memory penalty appeared in these checks. The new helper is not a replacement for runtime validation: the same predicate still rejects proxies, mutable unsupported kinds and forbidden prototypes, and dynamic-code generation remains locked down.

The helper-only trace isolated scope creation at **0.552 -> 0.346 ms** for empty startup; the former compile/setup stages (0.095 + 0.155 ms) become a ~0.009 ms restore. Cached init contexts already carried their own helpers, so the helper change alone did not produce a reliable application-cache-hit improvement. The private-copy reader is the targeted cached-application improvement.

Artifacts: `zig-out/applicable-startup/results/comparison.json` (all four preparation variants across three workloads), `sized-comparison.json` (baseline/helper/final), `traced.json`, `sized-traced.json`, and `rss-final-summary.json`. The first candidate matrix contained 5,400 untraced launches and the final read comparison 4,050; RSS and diagnostic trace runs are separate. These prefixes contain ordinary binaries without the earlier `ORIGINE_RESEARCH_*` switches.

## Candidate mechanisms considered

The API template is now prepared in snapshots, so further API micro-optimization has a small ceiling. Investigate the remaining process lifetime, V8 initialization, isolate construction, and snapshot file validation before changing JS code. The application trace begins in `main` and currently ends before destruction: its total cannot explain pre-main loading, teardown, or the parent benchmark's spawning/waiting overhead. See [the startup trace](../lib/v8_zig/src/diagnostics/startup.zig), [main](../src/main.zig), and [engine ownership](../src/engine.zig).

| Candidate | Why it is relevant | Experiment and acceptance condition |
|---|---|---|
| Preserve compiled code in both snapshots | Both creators currently use `createBlob(0)`, corresponding to V8 `kClear`. Preparing and freezing objects does not itself preserve their compiled code. | A/B `kKeep` in engine **and** init snapshot creation. Compare cached-image startup p50/p95/p99, first JS call, blob size, and RSS. Compile runtime entry functions without invoking `main`; application preparation belongs to init evaluation. |
| Reduce code-range allocation retries | V8 can try 16 reservations near `.text` before fallback. Address-space placement can therefore contribute startup work and variability. | A/B `--no-better-code-range-allocation`; record allocation attempts and JS throughput. Do not assume less startup work means better steady-state calls. |
| True no-worker platform for short CLI work | The current CLI explicitly selects one V8 worker. A no-worker mode may remove thread creation/join and background contention. | Pair `NewSingleThreadedDefaultPlatform` with `--single-threaded`; compare with current one-worker platform and retain the latter for throughput-heavy workloads if needed. |
| Narrow concurrency control | Disabling only concurrent optimization is a smaller change than deterministic mode or disabling JIT entirely. | A/B `--no-concurrent-recompilation`, with short and long-running workloads and GC tail latency. |
| Snapshot loading and validation | The cache reads the complete image into allocated memory and hashes every file-backed source. | Measure read/copy/hash/parse separately. Test a read-only mapping with equivalent alignment, ownership and content validation, not an mtime-only shortcut. |
| Compiler PGO and startup layout | Existing builtin PGO primarily changes generated JS builtins, not all C++ initialization paths. | Profile the actual startup, then test native C++ PGO and/or a Mach-O order file. Compare cold and warm page faults as well as elapsed time. |
| Persistent process or isolate pool | Process/V8 initialization costs are repeated by each executable invocation. | If the product can support it, benchmark a separate persistent execution mode; document reset, authority, lifetime and isolation semantics. This changes the architecture and is not a drop-in CLI optimization. |

The table records the source-backed hypotheses investigated. The controlled measurements and final ranking below distinguish rejected probes from promising follow-up work. No runtime policy changes were applied.

## Snapshot code retention: mechanism and tradeoff

`src/managed/snapshot.zig` and `src/managed/init_snapshot.zig` both pass zero to `SnapshotCreator.createBlob`. In the pinned public V8 header, `FunctionCodeHandling` is ordered `{ kClear, kKeep }`; `CreateBlob` documents that this controls inclusion of compiled function code. Thus the prepared API graph and frozen network classes do not imply that all corresponding compiled function code survives serialization. [Current engine snapshot](../src/managed/snapshot.zig), [current init snapshot](../src/managed/init_snapshot.zig), [pinned V8 snapshot API](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/include/v8-snapshot.h).

V8's own warmup routine makes a cold snapshot, restores it, runs a warmup script in a disposable context, creates a clean context, and serializes with `kKeep`. This is a useful pattern for keeping compilation benefits without intentionally preserving the warmup script's mutated application context. It is not a guarantee that every optimization or machine-code tier survives. Evaluate the pinned implementation, not a historical API example. [V8 warmup implementation](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/snapshot/snapshot.cc), [V8 custom startup snapshots](https://v8.dev/blog/custom-startup-snapshots).

A candidate must change both creators: clearing code when generating the per-init snapshot could undo benefits of keeping code in the embedded engine snapshot. Measure blob growth and deserialization: retaining unused functions could cost more to load than the compilation it saves. Do not warm real filesystem/network operations, capture credentials, or serialize runtime authority merely to exercise code. The existing JS-only API template is the appropriate boundary.

## Native initialization cannot all move into a JS snapshot

Pinned `V8::Initialize` initializes operating-system support, thread isolation, the sandbox, isolate-group state, CPU features, built-in descriptors, WebAssembly infrastructure where enabled, and external references. Isolate initialization then establishes heap spaces, pointer/dispatch tables, thread-local state, and deserializes startup data. These are native process/isolate resources, distinct from JavaScript object initialization. The measured V8/isolate stages must be subdivided before attributing their whole duration to snapshot deserialization. [V8 initialization](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/init/v8.cc), [isolate initialization](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/execution/isolate.cc).

Sandbox initialization reserves address space with guard regions and may fall back to smaller reservations. This is virtual-address reservation, not equivalent physical RSS. Disabling the sandbox would change an intentional security boundary; it is not a default optimization proposal. Likewise, disabling pointer compression trades the heap representation and ABI/build configuration, not just a timer. [Pinned sandbox implementation](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/sandbox/sandbox.cc), [V8 sandbox design](https://v8.dev/blog/sandbox), [V8 pointer compression](https://v8.dev/blog/pointer-compression).

`--no-better-code-range-allocation` is a more focused investigation. In the pinned `CodeRange::InitReservation`, the enabled external-code-space/shared-pointer-cage configuration can perform up to sixteen placement attempts to stay near executable text. Turning off that extra search preserves the sandbox while changing locality policy. Any potential startup-tail benefit must be weighed against built-in-call performance. A developer build's `--trace-code-range-allocation` can expose attempts; trace output must be disabled for the actual benchmark. [Code-range implementation](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/heap/code-range.cc), [V8's explanation of short built-in-call locality](https://v8.dev/blog/short-builtin-calls).

`profile_deserialization`, `trace_deserialization`, `trace_code_range_allocation`, and `serialization_statistics` are developer flags in the pinned source. Do not assume that a release archive exposes them. If unavailable, add targeted tracing to the corresponding native boundaries in a diagnostic build and keep its findings separate from production timing. [Pinned flag definitions](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/flags/flag-definitions.h).

## Worker and JIT choices need separate product modes

Passing zero to **NewDefaultPlatform** means choosing a worker count from available processors; it does not disable workers. The pinned public API provides **NewSingleThreadedDefaultPlatform**, explicitly requiring `--single-threaded`, for an actual no-worker platform. The default platform constructor initializes its worker task runner, and destruction terminates runners. The current CLI uses one worker, while test support passes zero, so those configurations are not equivalent. [Public platform API](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/include/libplatform/libplatform.h), [platform implementation](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/libplatform/default-platform.cc), [CLI engine defaults](../src/engine.zig), [test configuration](../src/tests/support.zig).

A reasonable progression is current platform + `--no-concurrent-recompilation`, then `--single-threaded`, then true no-worker platform + `--single-threaded`. These isolate different effects. Longer-lived CPU workloads and larger heaps must be included because shifting compilation/GC work onto the foreground can worsen execution tails even if startup improves. The pinned flags document the implications, including disabling concurrent/parallel GC and compilation paths. [Pinned flag implications](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/flags/flag-definitions.h).

`--predictable` is a diagnostic control, not a promise of stable wall-clock latency: it changes GC behavior, disables several concurrent compilation paths and concurrent code-cache deserialization, and supplies a fixed random seed when one was not set. OS scheduling and storage still vary. Do not install a fixed random seed or predictable mode as the production answer to variance. `--no-memory-reducer` is a useful negative control rather than a strong startup candidate: pinned defaults schedule its initial delay at 30 seconds, far beyond this millisecond CLI workload. [Pinned predictable and memory-reducer flags](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/flags/flag-definitions.h).

`--jitless` is a larger execution-policy choice: it removes runtime executable-memory allocation and disables JIT tiers. It may suit a deliberately interpreted scripting mode, but must be tested on actual application code, regexes and WebAssembly requirements. Historical V8 benchmark results do not establish today's startup saving here. [V8 JIT-less design and tradeoffs](https://v8.dev/blog/jitless).

Flags must be selected before engine initialization, which freezes them. Code caches compare a flags hash; origine's engine key already includes V8's code-cache version tag. Use separate variant identities and independently warmed caches. Safest practice is regenerating engine/init snapshots under the variant's exact configuration rather than comparing a baseline hit against a variant miss. [Initialization flag freeze](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/init/v8.cc), [code-cache validation](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/src/snapshot/code-serializer.cc), [origine cache identity](../src/api/init_cache.zig).

## Native build and binary layout

The local GN defaults already disable snapshot compression and handle zapping, enable pointer compression and the sandbox, and disable a shared read-only heap because concurrently using different snapshots is an embedder concern. Release artifacts use ThinLTO, and the application link uses dead stripping and identical-code folding. Do not propose enabling these already-present optimizations as new wins. Inspect effective GN settings, because stock V8 defaults differ from the project's `zig/.gn`. [Current build](../build.zig), [existing builtin-PGO analysis](../lib/v8_zig/docs/builtin-pgo.md), local `lib/v8_zig/.lp-cache/v8-15.8.30/zig/.gn`.

The existing PGO coverage targets V8-generated builtins. C++ compiler PGO over engine/isolate initialization is a distinct experiment. LLVM temporal profiling also records first-call ordering to improve code layout and reduce text-page faults; its documented Mach-O output feeds `-order_file`. Train on representative CLI startup plus real longer-running programs, retain a holdout workload, and test p95/p99 as well as mean. Enabling built-in reordering is not an automatic safe extension: the existing profile policy deliberately disables it for configuration-specific compatibility. [Clang instrumentation and temporal profiling](https://clang.llvm.org/docs/UsersManual.html#profiling-with-instrumentation), [project builtin-PGO policy](../lib/v8_zig/docs/builtin-pgo.md).

Cold and warm executable page-in are different targets. Apple documents dyld loading/fixup work and static initializers, and its launch tooling can identify pre-main initializers and page faults. Those mechanisms are relevant to a native CLI even though UI-specific launch advice is not. Profile dyld activity and system execution rather than calling the entire unexplained remainder “loader overhead.” [Apple launch profiling](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time), [Apple linker and page-in explanation](https://developer.apple.com/videos/play/wwdc2022/110362/).

## Cache and distribution consistency

The current engine key hashes executable identity/size/mtime plus every embedded module source on each start. Snapshot validation reads every file-backed module and hashes its content. File access and hashing can be reduced with a stable build identifier and generated embedded-module digest, but mutable/custom `Config.modules` and V8 flags must remain covered. A mapped image removes an allocation/copy only if alignment, lifetimes and malformed-file handling remain equivalent. These are source-derived proposals; their measured ceilings are the relevant cache sub-stages, not the entire runtime. [Cache implementation](../src/api/init_cache.zig), [snapshot format and ownership](../src/managed/init_snapshot.zig).

Avoid replacing content validation with mtime-only acceptance: it changes current cache correctness guarantees. For immutable deployment artifacts, an explicit precompiled/bundled mode with a content-addressed manifest can avoid per-run source reads while keeping a clear integrity model. Cache misses should be separately reported and scheduled: a synchronous init-snapshot build can produce a large first-run tail even when warm launches are stable. A code-cache-first foreground path plus offline cache preparation is a candidate product policy, not a proven change.

## Make measurements repeatable before choosing a winner

On Apple silicon, QoS influences the scheduler's choice of performance/efficiency cores. It is a scheduling hint, not a supported promise of fixed core placement or timing. Compare inherited QoS against an appropriate user-initiated class only for genuinely interactive work; avoid real-time scheduling or claiming that raising priority removes system variance. Apple's own recommendation is to use the lowest appropriate QoS. [Apple silicon scheduling](https://developer.apple.com/documentation/apple-silicon/tuning-your-code-s-performance-for-apple-silicon), [Apple CPU-work scheduling](https://developer.apple.com/documentation/xcode/scheduling-cpu-work-efficiently).

Benchmark candidates in randomized/interleaved order across multiple batches, with no builds or other agents' CPU-heavy work running concurrently. Record OS/hardware, build flags, power/thermal conditions, cache state, input size, stdout destination and whether tracing is enabled. Report p50, p95, p99, dispersion, RSS and CPU/system time. Include freshly cold/missing caches separately from warm filesystem/cache runs. Warmup does not retain the engine between executable invocations. The repository already contains an interleaved comparison script, but it currently exercises the empty REPL rather than this TypeScript input and therefore needs workload arguments for an exact comparison. [Existing comparison harness](../lib/v8_zig/build-tools/scripts/compare-startup.py) (see also [bench/startup/research.py](../bench/startup/research.py)), [Apple warm/cold-launch measurement guidance](https://developer.apple.com/videos/play/wwdc2019/423/).

A fixed seed can reproduce the benchmark's ordering; that does not require fixing V8's production random seed or disabling ASLR. Diagnostic traces and profilers perturb very short executions, so retain untraced full-process measurements as the outcome metric and use traces to explain mechanisms.

## Controlled local measurements

### Method and scope

Machine: Apple M4 Max, 16 logical CPUs, 128 GiB RAM, AC power; macOS arm64. This does not establish constant thermal state or a fixed core assignment. All variants used the existing release V8 archive and `-Doptimize=small`. The workload was the unchanged `examples/typescript/init.ts` plus `greeter.ts`, with stdin/stdout discarded and stderr captured. Results are specific to this small program, not a throughput benchmark.

The new [measurement harness](../bench/startup/research.py) randomizes case order with a fixed *harness* seed, warms each case separately, and records individual wall, child CPU, and optional stage measurements. Each case has its own cwd/source copies/cache: otherwise `sweepStale` would delete a competing engine's cache and turn an A/B into alternating misses. Snapshot reuse was verified for all final variants. Quantiles use nearest-rank p95/p99. Raw files contain binary SHA-256 fingerprints and sample records. No builds ran during the final measurements.

Python `Popen(cwd=...)` forced fork/exec on this machine. The harness now changes its own cwd before timing and uses `close_fds=False` to permit `posix_spawn`; a direct diagnostic confirmed that path is used. Pre-main time still includes parent spawn overhead, loading, static initialization and Zig's pre-main process setup. It is **not** a measurement of dyld alone. The wall numbers below belong to this harness and must not be compared to an earlier Hyperfine session as a controlled speedup.

Temporary changes added buffered lifecycle/cache probes and selectable research flags. They were built to ignored `zig-out/research/{baseline,keep-code,platform,eager-keep}` prefixes. All seven modified implementation files were restored byte-for-byte and checked against backups afterward; the production binary was not overwritten. The permanent additions are this report and the reusable measurement script.

### End-to-end candidates: tracing disabled

Three interleaved batches, 100 measured runs per case per batch, five discarded warmups. Values below pool 300 samples; inspect the per-batch results before treating a small difference as a win.

| Variant | p50 ms | p95 ms | p99 ms | Interpretation |
|---|---:|---:|---:|---|
| Current `kClear` policy | 8.477 | 9.716 | 10.743 | Baseline |
| `kKeep` in both snapshot builders | 8.537 | 9.428 | 10.898 | No median improvement |
| Eager compile + `kKeep` | 8.413 | 9.690 | 10.097 | Small median change; not a decisive tail win |
| True no-worker platform + `--single-threaded` | 8.438 | 9.623 | 10.285 | Compare with platform control, not just the baseline binary |
| Same platform-probe binary, ordinary one-worker platform | 8.451 | 9.547 | 10.337 | No-worker gain is negligible |
| Eager/keep plus retain global engine until process exit | 8.277 | 9.327 | 10.715 | Small gain; no general teardown recommendation |

For eager/keep, the baseline-minus-candidate batch medians were **0.122, 0.008 and 0.187 ms**. The third batch had a shared tail increase across variants. A pooled p99 estimate from 300 samples rests on very few observations and is exploratory.

The eager candidate used `kEagerCompile` (compile option `2`) for snapshot glue and uncached module compilation, with `kKeep` (`createBlob(1)`) in both creators. It did **not** call application `main` during snapshot construction. These settings must not be conflated: retaining code alone cannot preserve bytecode that was never compiled.

A separate three-batch, 150-run-per-case untraced flag comparison found:

| Flag on current one-worker platform | Pooled p50 ms | p95 ms |
|---|---:|---:|
| Default | 8.353 | 9.085 |
| `--no-better-code-range-allocation` | 8.345 | 9.012 |
| `--single-threaded` | 8.345 | 9.042 |
| `--no-concurrent-recompilation` | 8.311 | 9.120 |

Differences changed sign across batches or did not improve tails. None is supported as a production startup/consistency optimization by this experiment. The one-worker-platform flag probe and the true no-worker-platform probe are separate experiments.

### What the extra lifecycle probes revealed

A separate traced run used three batches of 70 runs per case. These are diagnostic timings, not the untraced outcome numbers above. Baseline median components:

| Span | Median ms |
|---|---:|
| Parent launch to entry into `main` | 2.261 |
| V8 process initialization | 1.339 |
| Host preparation + init snapshot loading/validation | 0.599 |
| Runtime/isolate creation | 1.952 |
| Scope creation | 0.321 |
| First application `main()` call | 0.162 |
| Global engine teardown | 1.070 |
| After final in-main probe to parent return | 0.357 |

Components are nested where indicated and medians are not additive. Parent launch/return spans include harness/OS costs. The additional ~1 ms teardown span was previously absent from `startup total`.

Splitting teardown in the platform control showed **V8::Dispose ~1.095 ms**, **DisposePlatform ~0.001 ms**, and **platform deletion/worker joining ~0.021 ms**. The no-worker platform reduced deletion to ~0.001 ms, leaving the expensive global disposal unchanged. This falsifies the hypothesis that one background worker's join explains the bulk of teardown.

V8's public API says disposal is normally unnecessary immediately before process exit, so a terminal-process-only retention experiment is legitimate; the host/runtime/isolate were still destroyed first. However, the apparent saving is misleading: global teardown dropped to ~0 ms while the after-main-to-parent-return span rose from **0.364 to 1.352 ms**. Most cleanup cost moved into process exit. End-to-end savings versus the same eager/keep binary were only about **0.09–0.14 ms** by batch medians, not 1.1 ms. Keep ordinary cleanup for embedders; this experiment does not justify changing it. [Pinned V8 disposal contract](https://github.com/v8/v8/blob/a98309795399032afd2f191adaa94ed6e9918437/include/v8-initialization.h).

Eager compilation + retained code changed the first main call from **0.162 to 0.064 ms**, while isolate creation moved from **1.952 to 1.984 ms** and the image got larger:

| Init snapshot | Bytes |
|---|---:|
| Clear | 620,592 |
| Keep only | 623,400 |
| Eager + keep | 660,792 |

This is a real local first-call benefit with loading/deserialization tradeoffs; evaluate broader applications before changing defaults.

Cache sub-probes on the eager/keep candidate measured **engine-key computation 0.064 ms**, **image read/allocation 0.378 ms**, **metadata parse 0.002 ms**, and **source-content validation 0.026 ms**. These are sub-stages of the ~0.615 ms host/init-snapshot stage, not independent additions. The evidence favors investigating image I/O/copying before weakening source validation or micro-optimizing metadata parsing. The image-read span is a ceiling on *that work*, not a promised `mmap` saving: mapped-page faults can move into V8 deserialization.

### Cache-miss predictability

A separate interleaved experiment used three batches of 60 runs per case. The miss case deleted only its private init-cache directory before every child; OS executable/source pages remained warm. These are **application-cache misses, not cold filesystem or cold machine measurements**.

| Cache state | p50 ms | p95 ms | p99 ms |
|---|---:|---:|---:|
| Warm init snapshot | 9.851 | 11.348 | 12.301 |
| Init snapshot absent, rebuilt synchronously | 18.774 | 20.620 | 21.847 |
| Existing `ORIGINE_NO_SNAPSHOT=1` mode | 14.096 | 15.621 | 16.805 |

Compare within this batch set: its baseline is slower than earlier batches, so cross-session subtraction is invalid. Still, a missing init snapshot adds roughly **9 ms** to the median within the controlled comparison. The last row disables both engine/init snapshots and code caching; it does not isolate just one of those features.

This quantifies the intentional init-preparation cost. It is separate from cached-image startup and is not a reason to change the evaluate-init/restore/call-main design. The current executable-path/size/mtime key also invalidates caches when the binary moves or is touched. A stable content-derived build/ABI/flags identity could reduce unnecessary misses and permit deliberate cache distribution, but it must cover native code, snapshot format, default/custom module sources and V8 flags correctly. Do not substitute a manually maintained version string or weaker source validation.

## Final optimization order under the init/main design

1. **Keep the measured low-risk changes:** prepare immutable scope helpers in snapshots, and use exact-size stable image reads. They improve the tested startup paths without weaker validation or cleanup.
2. **Profile native V8 initialization/isolate creation before selecting further defaults.** These remain the largest in-process stages. Native C++ PGO/order files are potential next experiments; existing builtin PGO/ThinLTO/ICF are already enabled.
3. **Treat eager compilation as workload-dependent, not a general default.** The first-call benefit on the small fixture did not generalize to a larger module graph; all eager/keep policy changes were reverted in the applied trial.
4. **Keep preparation and cached startup as separate performance contracts.** Init evaluates application setup, then runtime restores the image and invokes main. No new persistent-process or reduced-cleanup mode was introduced.
5. **Require tail/memory/behavior checks for subsequent changes.** The tested thread/address-placement flags were not convincing wins; direct mapping would weaken stable-buffer ownership. Neither was retained.

For consistency measurements, retain seeded interleaving, multiple batches, independently warmed caches, traced explanations plus untraced outcomes, child CPU times and p50/p95/p99. Do not silently mix results from a CPU-heavy build with idle results. One discarded exploratory batch overlapped linking and produced 18–19 ms medians versus ~9 ms in its later batches; it is retained as a confounded artifact, not evidence for a candidate.

## Reproduction and artifacts

The harness accepts a JSON list with `name`, absolute or repo-relative `binary`, optional `env`, optional `args`, and optional `reset_init_cache`. Its default workload is the TypeScript example, copied into a private case cwd. Example:

```json
[
  {"name": "baseline", "binary": "zig-out/bin/origine"},
  {"name": "candidate", "binary": "zig-out/candidate/bin/origine"}
]
```

```sh
uv run --script bench/startup/research.py cases.json zig-out/startup/results.json --runs 150 --batches 3
uv run --script bench/startup/research.py cases.json zig-out/startup/traced.json --runs 70 --batches 3 --trace
```

Research configurations and raw results are in ignored `zig-out/research/results/`:

- `final-cases.json`, `final-untraced.json`, `final-traced.json`: all snapshot/platform/lifetime variants.
- `baseline-cases.json`, `flag-probes-untraced.json`: narrow V8 flag probes with the corrected spawn method.
- `cache-cases.json`, `cache-states-untraced.json`: cache hit/miss/all-snapshots-off comparison.
- `cache-hit-verification.json`: verified warm snapshot reuse for each final candidate.
- `flag-probes-traced.json`: initial fork/exec diagnostic run; do not use its wall times as the final baseline.
- `flag-probes-untraced-confounded.json`: explicitly discarded build-overlap run.

The `ORIGINE_RESEARCH_*` switches exist only in those temporary research executables, not in the restored production source or `zig-out/bin/origine`. The generic harness also works with ordinary separately built candidate binaries. Reconstruct snapshot candidates from the precise policies above; do not assume those research environment switches are a supported CLI API.

