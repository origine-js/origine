# Yuku vs Oxc vs SWC Next: native TS / TSX / JSX transforms

Measured 2026-10-28 on **Apple M4 Max, 16 logical CPUs, 128 GiB RAM, macOS 27.2 arm64**. Yuku 0.24.1 / Zig 0.17.0; Oxc 0.155.0 and SWC Next 0.4.0 / rustc 1.101.0-nightly (07e526db9 2026-10-19); V8 validation via Node v24.22.1. Seven fresh-process samples per build/group, randomized serial order. All engines were rerun together after adding SWC Next; the original two-engine measurements were replaced.

**Cooldown:** at least 1 s between every fresh-process sample, including changes of build/workload and sample rounds. All 454 observed gaps were at least 1.000039 seconds (maximum 1.005385 seconds). Warmups and timed sweeps within a worker are batched without pauses. Cooldowns are outside the timing region; raw results preserve worker timestamps and observed intervals.

**For Origine’s full TS/TSX/JSX contract, Oxc remains the complete existing choice.** Yuku strips erasable TS but rejects runtime TS constructs. SWC Next’s semantic TS transformer lowers enums, namespaces and parameter properties, but its native pipeline still preserves JSX. These results use the new swc-project/swc-next rewrite, not classic SWC. [Primary-source features and V8 integration evidence](../../docs/research/yuku-oxc-features.md).

## Coverage before speed

| Source | Files | Input bytes | Yuku accepted JS | Oxc accepted JS | SWC Next accepted JS |
|---|---|---|---|---|---|
| cordis/ts | 31 | 207,385 | 12 | 31 | 31 |
| webui/ts | 57 | 139,251 | 48 | 57 | 57 |
| vue-core/ts | 233 | 1,642,087 | 194 | 233 | 233 |
| vite/tsx | 13 | 15,908 | 2 | 13 | 2 |
| vite/jsx | 9 | 15,283 | 1 | 9 | 1 |

Acceptance requires no native diagnostics and successful V8 ES-module syntax parsing. A few `.tsx`/`.jsx` files need no JSX lowering and can pass preservation pipelines; that does not establish JSX transform support. Every successfully emitted corpus file was checked. These checks do not resolve imports, execute applications or prove semantic equivalence.

Cordis and WebUI package source directories and Vue-core package `src` supply the required TS sources. Declarations, tests and fixtures are excluded there; WebUI package `client` is included. Eligible required-package sources contain no TSX/JSX, so Vite create-vite templates and playgrounds provide those workloads. Vue `.vue` SFCs are excluded: they need a separate framework compiler. Exact paths and SHA-256 hashes are in [inventory.json](results/inventory.json).

## Identical accepted TS subsets

**Median milliseconds per entire group**, not per file. Each sample averages at least 20 sweeps, or enough to target approximately 150 ms. Inputs and one reusable destination buffer are preloaded. Three warmups and one pilot precede timing. Time includes Python/ctypes overhead, parse/transform/codegen, output copy and freeing temporary allocations; it excludes library loading, file I/O and V8 checks.

| Build | cordis: 12 files / 26,975 B | webui: 48 files / 90,861 B | vue-core: 194 files / 1,014,016 B |
|---|---|---|---|
| yuku-fast | 0.1340 | 0.3980 | 4.4528 |
| yuku-safe | 0.1729 | 0.5291 | 5.5926 |
| yuku-small | 0.3122 | 0.8890 | 8.6595 |
| oxc-O3 | 0.2465 | 0.7111 | 8.5405 |
| oxc-O3-checked | 0.2887 | 0.8020 | 9.0758 |
| oxc-Os | 0.2771 | 0.8188 | 9.2769 |
| oxc-Oz | 0.6456 | 1.7837 | 18.3175 |
| swc-next-O3 | 0.2072 | 0.6416 | 7.9772 |
| swc-next-O3-checked | 0.3061 | 0.9534 | 10.4030 |
| swc-next-Os | 0.2321 | 0.7291 | 8.4751 |
| swc-next-Oz | 0.5201 | 1.4560 | 14.7950 |

All three engines receive identical files in each common subset. Yuku performs parse + stripping codegen; Oxc performs parse + semantics + transformer + codegen; SWC Next performs parse + runtime normalization + semantics with all syntax checks + its public TypeScript lowering pass + codegen. The SWC Next wrapper deliberately skips unrelated ES downlevel transforms and post-transform semantic rebuilding. This compares usable native pipelines with different work and feature coverage, not identical algorithms.

## Full TS corpus and JSX-lowering workloads

| Build | cordis/ts-oxc-all: 31 files | webui/ts-oxc-all: 57 files | vue-core/ts-oxc-all: 233 files | vite/tsx-oxc-all: 13 files | vite/jsx-oxc-all: 9 files |
|---|---|---|---|---|---|
| oxc-O3 | 2.0840 | 1.1924 | 13.5155 | 0.1134 | 0.0973 |
| oxc-O3-checked | 2.3166 | 1.3056 | 14.6255 | 0.1299 | 0.1141 |
| oxc-Os | 2.3043 | 1.3426 | 14.8966 | 0.1385 | 0.1183 |
| oxc-Oz | 4.6867 | 2.8107 | 29.7937 | 0.3252 | 0.2888 |
| swc-next-O3 | 2.0522 | 1.1491 | 13.2027 | — | — |
| swc-next-O3-checked | 2.7847 | 1.5885 | 17.3089 | — | — |
| swc-next-Os | 2.2526 | 1.2685 | 14.2030 | — | — |
| swc-next-Oz | 4.0254 | 2.3102 | 24.9748 | — | — |

Values are milliseconds per whole group. An em dash means the complete group is unsupported; it is not a zero or an omitted fast result. JSX lowering is classic React-style for Oxc. Preserved JSX is not counted as executable JS. No framework-specific template/runtime correctness is established for Vue, Preact, Solid or Qwik.

## Compiled library sizes

| Build | Dynamic bytes | Dynamic KiB | Static archive bytes |
|---|---|---|---|
| yuku-fast | 822,288 | 803.02 | 1,027,256 |
| yuku-safe | 1,003,248 | 979.73 | 1,280,088 |
| yuku-small | 677,600 | 661.72 | 1,030,704 |
| oxc-O3 | 2,387,664 | 2331.70 | 9,981,672 |
| oxc-O3-checked | 3,017,024 | 2946.31 | 11,862,808 |
| oxc-Os | 1,977,376 | 1931.03 | 10,500,968 |
| oxc-Oz | 1,371,600 | 1339.45 | 11,133,112 |
| swc-next-O3 | 1,575,632 | 1538.70 | 8,344,936 |
| swc-next-O3-checked | 2,154,416 | 2103.92 | 9,533,096 |
| swc-next-Os | 1,279,072 | 1249.09 | 8,332,944 |
| swc-next-Oz | 985,664 | 962.56 | 8,713,288 |

Actual stripped Mach-O dylibs and native static archives are measured for the benchmark wrappers and their reachable dependencies. Rust static archives include runtime and dependency objects; archive size is not the size added to Origine after final linking/LTO/dead stripping. Feature coverage differs. Artifact SHA-256 hashes are in [environment.json](results/environment.json).

Zig `.fast`, `.safe` and `.small` are compared against Rust O3; Os and Oz use Cargo opt-level `s` and `z`. `.small` is Zig’s size-oriented release mode, not an independent “small + O3” setting. Both Rust wrappers use thin LTO, one codegen unit, stripped symbols and aborting panics. O3-checked enables overflow checks and debug assertions, not an exact equivalent of Zig `.safe`. SWC Next upstream uses fat LTO; thin LTO here matches the Oxc benchmark. Toolchain-default CPU targeting is used, without explicitly matched microarchitecture tuning.

## CPU and RSS for every measured group

CPU ms and wall ms are per group sweep. CPU utilization = process CPU / wall × 100; 100% means one core, not the whole 16-core machine. Peak RSS is macOS `getrusage` in MiB and includes Python/Typer, preloaded input/buffer, mapped native library pages and allocator state. Δ peak is the post-use process high-water mark minus its pre-library-load high-water mark: an approximate incremental process peak, not an isolated library allocation count or leak measurement. Independent medians need not add exactly.

| Build | Group | Wall ms | CPU ms | CPU % | Peak RSS MiB | Δ peak MiB | Wall min–max ms |
|---|---|---|---|---|---|---|---|
| oxc-O3 | cordis/ts-common | 0.2465 | 0.2465 | 99.98 | 30.31 | 1.89 | 0.2418–0.2762 |
| oxc-O3-checked | cordis/ts-common | 0.2887 | 0.2887 | 99.99 | 30.58 | 2.22 | 0.2664–0.3218 |
| oxc-Os | cordis/ts-common | 0.2771 | 0.2771 | 99.99 | 30.20 | 1.75 | 0.2663–0.3143 |
| oxc-Oz | cordis/ts-common | 0.6456 | 0.6456 | 100.00 | 29.91 | 1.59 | 0.6415–0.6495 |
| swc-next-O3 | cordis/ts-common | 0.2072 | 0.2072 | 100.00 | 30.11 | 1.77 | 0.2040–0.2183 |
| swc-next-O3-checked | cordis/ts-common | 0.3061 | 0.3061 | 100.00 | 30.64 | 2.25 | 0.2945–0.3130 |
| swc-next-Os | cordis/ts-common | 0.2321 | 0.2321 | 99.99 | 30.06 | 1.58 | 0.2207–0.2543 |
| swc-next-Oz | cordis/ts-common | 0.5201 | 0.5201 | 100.00 | 29.70 | 1.36 | 0.5166–0.5812 |
| yuku-fast | cordis/ts-common | 0.1340 | 0.1340 | 100.00 | 29.50 | 1.11 | 0.1323–0.1391 |
| yuku-safe | cordis/ts-common | 0.1729 | 0.1729 | 100.00 | 29.80 | 1.47 | 0.1711–0.1833 |
| yuku-small | cordis/ts-common | 0.3122 | 0.3122 | 100.00 | 29.30 | 0.88 | 0.2990–0.3449 |
| oxc-O3 | cordis/ts-oxc-all | 2.0840 | 2.0841 | 100.00 | 31.14 | 2.19 | 2.0339–2.1760 |
| oxc-O3-checked | cordis/ts-oxc-all | 2.3166 | 2.3127 | 99.98 | 31.48 | 2.52 | 2.2072–2.5642 |
| oxc-Os | cordis/ts-oxc-all | 2.3043 | 2.3042 | 100.00 | 30.98 | 2.16 | 2.2655–2.5527 |
| oxc-Oz | cordis/ts-oxc-all | 4.6867 | 4.6867 | 100.00 | 30.75 | 1.91 | 4.6504–4.8565 |
| swc-next-O3 | cordis/ts-oxc-all | 2.0522 | 2.0523 | 100.00 | 30.97 | 2.11 | 2.0386–2.3041 |
| swc-next-O3-checked | cordis/ts-oxc-all | 2.7847 | 2.7847 | 100.00 | 31.62 | 2.64 | 2.7208–2.8923 |
| swc-next-Os | cordis/ts-oxc-all | 2.2526 | 2.2526 | 100.00 | 30.78 | 1.86 | 2.2259–2.3508 |
| swc-next-Oz | cordis/ts-oxc-all | 4.0254 | 4.0255 | 100.00 | 30.45 | 1.56 | 3.9779–4.3871 |
| oxc-O3 | vite/jsx-oxc-all | 0.0973 | 0.0973 | 100.00 | 30.08 | 1.73 | 0.0943–0.1038 |
| oxc-O3-checked | vite/jsx-oxc-all | 0.1141 | 0.1141 | 99.99 | 30.34 | 2.00 | 0.1111–0.1173 |
| oxc-Os | vite/jsx-oxc-all | 0.1183 | 0.1183 | 100.00 | 30.00 | 1.62 | 0.1130–0.1333 |
| oxc-Oz | vite/jsx-oxc-all | 0.2888 | 0.2887 | 99.99 | 29.89 | 1.41 | 0.2782–0.3695 |
| oxc-O3 | vite/tsx-oxc-all | 0.1134 | 0.1134 | 99.99 | 30.39 | 1.88 | 0.1094–0.1210 |
| oxc-O3-checked | vite/tsx-oxc-all | 0.1299 | 0.1299 | 100.00 | 30.48 | 2.06 | 0.1258–0.1379 |
| oxc-Os | vite/tsx-oxc-all | 0.1385 | 0.1386 | 100.00 | 30.17 | 1.81 | 0.1358–0.1394 |
| oxc-Oz | vite/tsx-oxc-all | 0.3252 | 0.3252 | 100.00 | 29.91 | 1.50 | 0.3172–0.3363 |
| oxc-O3 | vue-core/ts-common | 8.5405 | 8.5396 | 99.99 | 32.23 | 2.27 | 8.3416–8.7111 |
| oxc-O3-checked | vue-core/ts-common | 9.0758 | 9.0749 | 99.99 | 32.66 | 2.78 | 9.0030–9.5804 |
| oxc-Os | vue-core/ts-common | 9.2769 | 9.2746 | 100.00 | 32.20 | 2.17 | 9.0466–9.5276 |
| oxc-Oz | vue-core/ts-common | 18.3175 | 18.3164 | 99.99 | 31.81 | 1.91 | 17.9103–19.3569 |
| swc-next-O3 | vue-core/ts-common | 7.9772 | 7.9769 | 99.99 | 32.45 | 2.56 | 7.9379–8.0936 |
| swc-next-O3-checked | vue-core/ts-common | 10.4030 | 10.4022 | 100.00 | 32.95 | 3.05 | 10.3364–10.7519 |
| swc-next-Os | vue-core/ts-common | 8.4751 | 8.4740 | 100.00 | 32.28 | 2.38 | 8.3229–8.5775 |
| swc-next-Oz | vue-core/ts-common | 14.7950 | 14.7940 | 99.99 | 31.92 | 1.97 | 14.6921–15.2199 |
| yuku-fast | vue-core/ts-common | 4.4528 | 4.4528 | 100.00 | 32.95 | 3.09 | 4.3782–4.4911 |
| yuku-safe | vue-core/ts-common | 5.5926 | 5.5923 | 100.00 | 37.39 | 7.38 | 5.5125–6.1443 |
| yuku-small | vue-core/ts-common | 8.6595 | 8.6592 | 100.00 | 32.92 | 2.92 | 8.4989–8.9502 |
| oxc-O3 | vue-core/ts-oxc-all | 13.5155 | 13.5146 | 99.99 | 34.14 | 3.42 | 13.4259–14.0554 |
| oxc-O3-checked | vue-core/ts-oxc-all | 14.6255 | 14.6243 | 99.99 | 34.47 | 3.66 | 14.4821–15.5313 |
| oxc-Os | vue-core/ts-oxc-all | 14.8966 | 14.8958 | 99.99 | 34.11 | 3.19 | 14.6746–15.3364 |
| oxc-Oz | vue-core/ts-oxc-all | 29.7937 | 29.7889 | 99.98 | 33.72 | 2.86 | 28.7673–30.6403 |
| swc-next-O3 | vue-core/ts-oxc-all | 13.2027 | 13.2016 | 99.99 | 34.64 | 3.95 | 13.0689–13.7900 |
| swc-next-O3-checked | vue-core/ts-oxc-all | 17.3089 | 17.3072 | 99.99 | 35.42 | 4.66 | 17.0107–18.4379 |
| swc-next-Os | vue-core/ts-oxc-all | 14.2030 | 14.2020 | 99.99 | 34.41 | 3.61 | 13.9757–14.8448 |
| swc-next-Oz | vue-core/ts-oxc-all | 24.9748 | 24.9684 | 99.99 | 34.30 | 3.30 | 24.2918–26.7978 |
| oxc-O3 | webui/ts-common | 0.7111 | 0.7095 | 99.99 | 30.58 | 1.91 | 0.6827–0.8171 |
| oxc-O3-checked | webui/ts-common | 0.8020 | 0.8021 | 100.00 | 30.77 | 2.34 | 0.7743–0.9327 |
| oxc-Os | webui/ts-common | 0.8188 | 0.8188 | 100.00 | 30.42 | 1.84 | 0.7986–0.8855 |
| oxc-Oz | webui/ts-common | 1.7837 | 1.7837 | 100.00 | 30.00 | 1.56 | 1.7380–1.8499 |
| swc-next-O3 | webui/ts-common | 0.6416 | 0.6416 | 100.00 | 30.20 | 1.80 | 0.6317–0.7418 |
| swc-next-O3-checked | webui/ts-common | 0.9534 | 0.9535 | 100.00 | 30.75 | 2.33 | 0.9241–1.0996 |
| swc-next-Os | webui/ts-common | 0.7291 | 0.7291 | 100.00 | 29.97 | 1.50 | 0.7136–0.7710 |
| swc-next-Oz | webui/ts-common | 1.4560 | 1.4560 | 100.00 | 29.66 | 1.23 | 1.4317–1.4943 |
| yuku-fast | webui/ts-common | 0.3980 | 0.3980 | 100.00 | 29.92 | 1.20 | 0.3861–0.4712 |
| yuku-safe | webui/ts-common | 0.5291 | 0.5291 | 100.00 | 30.03 | 1.48 | 0.5213–0.5801 |
| yuku-small | webui/ts-common | 0.8890 | 0.8889 | 100.00 | 29.41 | 1.00 | 0.8740–1.0075 |
| oxc-O3 | webui/ts-oxc-all | 1.1924 | 1.1924 | 100.00 | 30.55 | 2.03 | 1.1368–1.2544 |
| oxc-O3-checked | webui/ts-oxc-all | 1.3056 | 1.3056 | 100.00 | 31.03 | 2.34 | 1.2783–1.3790 |
| oxc-Os | webui/ts-oxc-all | 1.3426 | 1.3426 | 100.00 | 30.55 | 1.97 | 1.3177–1.4457 |
| oxc-Oz | webui/ts-oxc-all | 2.8107 | 2.8106 | 100.00 | 30.22 | 1.70 | 2.7783–3.1748 |
| swc-next-O3 | webui/ts-oxc-all | 1.1491 | 1.1490 | 100.00 | 30.44 | 1.92 | 1.1082–1.2151 |
| swc-next-O3-checked | webui/ts-oxc-all | 1.5885 | 1.5885 | 100.00 | 30.92 | 2.53 | 1.5649–1.6267 |
| swc-next-Os | webui/ts-oxc-all | 1.2685 | 1.2681 | 99.99 | 30.14 | 1.69 | 1.2242–1.3684 |
| swc-next-Oz | webui/ts-oxc-all | 2.3102 | 2.3100 | 100.00 | 29.88 | 1.33 | 2.2670–2.3867 |

## Features and embedded V8 fit

| Capability | Yuku native path | Oxc native path | SWC Next native TS path |
|---|---|---|---|
| Erasable TS | Yes | Yes | Yes |
| Enum / const enum | Diagnostic | Lowered | Lowered |
| Namespace / parameter property | Diagnostic | Lowered | Lowered |
| TSX / JSX → JS | Preserves JSX | Lowers JSX | Preserves JSX |
| Source maps | Available; disabled here | Available; disabled here | Available; disabled here |
| Semantic analysis in timed pipeline | No | Yes | Yes |
| Existing Origine integration | None | Checked C ABI + Zig adapter | None |

[Feature probes](results/probes.json) cover erasable TS, enum, const enum, namespace, parameter property, TSX and JSX across all 11 configurations: **77 expected outcomes checked in V8**. Runtime TS probes execute to answer 42 for Oxc and SWC Next. Yuku reports diagnostics for those constructs. JSX-containing outputs fail V8 parsing for Yuku and SWC Next; Oxc JSX probes execute successfully using a test classic factory.

SWC Next also has a separate fixed-width `type_strip` API; this benchmark uses its semantic TypeScript transformer, not that restricted eraser and not classic SWC. At the pinned revision, external `import = require()` can emit `import.sync(...)`, and `export =` can remain in output; these require separate V8/module compatibility work. The six additional [module-form checks](results/module-probes.json) reproduce both SWC Next syntax failures in V8. Oxc emits syntactically valid `require(...)` / `module.exports` for these probes, which still need runtime bindings to execute; compilation alone does not supply CommonJS support. JSX lowering is absent from its current native transformer options. Upstream marks the Rust API very early, recommends classic SWC for production, and documents AST-handle ownership soundness issues. The npm entry point exposes parser/codegen rather than this native TS transformer. [Pinned source evidence and caveats](../../docs/research/yuku-oxc-features.md#swc-next-extension).

V8 accepts JavaScript text; these libraries are compiler front ends, not V8 engine plugins. Oxc already implements Origine’s source→JS boundary through its checked C ABI. SWC Next can sit behind a similar native adapter for supported TS but needs a JSX stage, readiness review and module edge-case handling. A hybrid eraser/fallback path for Yuku or SWC Next needs consistent diagnostics and semantics. Automatic JSX needs runtime-import resolution; classic JSX needs a suitable factory. Syntax validation does not prove application compatibility.

## Reproducibility and limits

- [yuku `35678b85a437d1fb4c722e8c2381f155c33d49fe`](https://github.com/yuku-toolchain/yuku/tree/35678b85a437d1fb4c722e8c2381f155c33d49fe)
- [cordis `26d900345697adb87c3d3764bb6e8fc88a153929`](https://github.com/cordiverse/cordis/tree/26d900345697adb87c3d3764bb6e8fc88a153929)
- [webui `2a884b56e589d81c41e510922e6b9f12badef26a`](https://github.com/cordiverse/webui/tree/2a884b56e589d81c41e510922e6b9f12badef26a)
- [vue-core `ca034820b8288ab6da3a033626a7857401ee64a5`](https://github.com/vuejs/core/tree/ca034820b8288ab6da3a033626a7857401ee64a5)
- [vite `cce559ab158cc6b177d0911a0bea73436b48faff`](https://github.com/vitejs/vite/tree/cce559ab158cc6b177d0911a0bea73436b48faff)
- [swc-next `71c3f7982004f9acc6da83c742183466bd5ba229`](https://github.com/swc-project/swc-next/tree/71c3f7982004f9acc6da83c742183466bd5ba229)

[README.md](README.md) documents commands and measurement definitions. Both Rust wrappers have checked-in Cargo lockfiles; [sources.lock.json](sources.lock.json) pins upstream source commits. [raw.json](results/raw.json) contains **455 samples** across **65 build/group combinations**. Wall min–max values are observed sample-average ranges, not confidence intervals. Run `uv run --locked bench/transform/run.py report` to regenerate this report from saved results.

This is one machine and corpus snapshot. CPU affinity, thermal/frequency controls and system-wide idleness were not enforced. Python call overhead matters most for tiny groups; RSS depends on OS/allocator behavior. No cold-start latency, full application execution, final Origine binary-size delta or full embedded-V8 RSS was measured. Origine’s current mixed Oz/O3, 16-codegen-unit, unwind profile differs from these uniform benchmark profiles; changing its profile requires a separate final-binary test. Aborting panics here must not be copied into its panic-catching ABI without reviewing that contract. These results do not predict Linux/x86-64 or other V8 builds.
