# Previous run without cooldown: Yuku / Oxc / SWC Next

Measured 2026-10-28 on **Apple M4 Max, 16 logical CPUs, 128 GiB RAM, macOS 27.2 arm64**. Yuku 0.24.1 / Zig 0.17.0; Oxc 0.155.0 and SWC Next 0.4.0 / rustc 1.101.0-nightly (07e526db9 2026-10-19); V8 validation via Node v24.22.1. Seven fresh-process samples per build/group, randomized serial order. All engines were rerun together after adding SWC Next; the original two-engine measurements were replaced.

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
| yuku-fast | 0.1337 | 0.3909 | 4.4943 |
| yuku-safe | 0.1716 | 0.5161 | 5.6698 |
| yuku-small | 0.2935 | 0.8558 | 8.5415 |
| oxc-O3 | 0.2399 | 0.7029 | 8.9120 |
| oxc-O3-checked | 0.2697 | 0.7806 | 9.2676 |
| oxc-Os | 0.2733 | 0.7953 | 9.4168 |
| oxc-Oz | 0.6197 | 1.7903 | 18.1760 |
| swc-next-O3 | 0.2052 | 0.6468 | 8.0373 |
| swc-next-O3-checked | 0.2966 | 0.9213 | 10.7543 |
| swc-next-Os | 0.2214 | 0.7267 | 8.4381 |
| swc-next-Oz | 0.5099 | 1.4202 | 14.6505 |

All three engines receive identical files in each common subset. Yuku performs parse + stripping codegen; Oxc performs parse + semantics + transformer + codegen; SWC Next performs parse + runtime normalization + semantics with all syntax checks + its public TypeScript lowering pass + codegen. The SWC Next wrapper deliberately skips unrelated ES downlevel transforms and post-transform semantic rebuilding. This compares usable native pipelines with different work and feature coverage, not identical algorithms.

## Full TS corpus and JSX-lowering workloads

| Build | cordis/ts-oxc-all: 31 files | webui/ts-oxc-all: 57 files | vue-core/ts-oxc-all: 233 files | vite/tsx-oxc-all: 13 files | vite/jsx-oxc-all: 9 files |
|---|---|---|---|---|---|
| oxc-O3 | 2.0489 | 1.1955 | 13.9358 | 0.1108 | 0.0941 |
| oxc-O3-checked | 2.2623 | 1.2942 | 14.9320 | 0.1280 | 0.1113 |
| oxc-Os | 2.2778 | 1.3111 | 15.0517 | 0.1348 | 0.1158 |
| oxc-Oz | 4.7519 | 2.7983 | 29.1844 | 0.3104 | 0.2656 |
| swc-next-O3 | 2.1953 | 1.1093 | 13.3674 | — | — |
| swc-next-O3-checked | 2.7104 | 1.5428 | 17.4974 | — | — |
| swc-next-Os | 2.1898 | 1.2278 | 14.3539 | — | — |
| swc-next-Oz | 3.9072 | 2.2451 | 24.5214 | — | — |

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

Actual stripped Mach-O dylibs and native static archives are measured for the benchmark wrappers and their reachable dependencies. Rust static archives include runtime and dependency objects; archive size is not the size added to Origine after final linking/LTO/dead stripping. Feature coverage differs. Artifact SHA-256 hashes are in [environment.json](results/no-cooldown-previous/environment.json).

Zig `.fast`, `.safe` and `.small` are compared against Rust O3; Os and Oz use Cargo opt-level `s` and `z`. `.small` is Zig’s size-oriented release mode, not an independent “small + O3” setting. Both Rust wrappers use thin LTO, one codegen unit, stripped symbols and aborting panics. O3-checked enables overflow checks and debug assertions, not an exact equivalent of Zig `.safe`. SWC Next upstream uses fat LTO; thin LTO here matches the Oxc benchmark. Toolchain-default CPU targeting is used, without explicitly matched microarchitecture tuning.

## CPU and RSS for every measured group

CPU ms and wall ms are per group sweep. CPU utilization = process CPU / wall × 100; 100% means one core, not the whole 16-core machine. Peak RSS is macOS `getrusage` in MiB and includes Python/Typer, preloaded input/buffer, mapped native library pages and allocator state. Δ peak is the post-use process high-water mark minus its pre-library-load high-water mark: an approximate incremental process peak, not an isolated library allocation count or leak measurement. Independent medians need not add exactly.

| Build | Group | Wall ms | CPU ms | CPU % | Peak RSS MiB | Δ peak MiB | Wall min–max ms |
|---|---|---|---|---|---|---|---|
| oxc-O3 | cordis/ts-common | 0.2399 | 0.2399 | 99.99 | 30.03 | 1.92 | 0.2366–0.2586 |
| oxc-O3-checked | cordis/ts-common | 0.2697 | 0.2696 | 99.98 | 30.45 | 2.22 | 0.2644–0.2803 |
| oxc-Os | cordis/ts-common | 0.2733 | 0.2732 | 99.99 | 30.05 | 1.80 | 0.2655–0.2759 |
| oxc-Oz | cordis/ts-common | 0.6197 | 0.6197 | 99.99 | 29.95 | 1.61 | 0.6112–0.6258 |
| swc-next-O3 | cordis/ts-common | 0.2052 | 0.2043 | 99.92 | 30.12 | 1.91 | 0.1949–0.2316 |
| swc-next-O3-checked | cordis/ts-common | 0.2966 | 0.2964 | 99.99 | 30.53 | 2.23 | 0.2928–0.3107 |
| swc-next-Os | cordis/ts-common | 0.2214 | 0.2214 | 99.98 | 29.84 | 1.75 | 0.2151–0.2549 |
| swc-next-Oz | cordis/ts-common | 0.5099 | 0.5086 | 99.91 | 29.77 | 1.36 | 0.4876–0.5656 |
| yuku-fast | cordis/ts-common | 0.1337 | 0.1333 | 99.98 | 29.47 | 1.16 | 0.1306–0.1452 |
| yuku-safe | cordis/ts-common | 0.1716 | 0.1715 | 99.94 | 29.84 | 1.42 | 0.1688–0.1770 |
| yuku-small | cordis/ts-common | 0.2935 | 0.2934 | 99.99 | 29.06 | 0.92 | 0.2905–0.3125 |
| oxc-O3 | cordis/ts-oxc-all | 2.0489 | 2.0488 | 99.99 | 31.02 | 2.42 | 2.0087–2.0974 |
| oxc-O3-checked | cordis/ts-oxc-all | 2.2623 | 2.2623 | 99.99 | 31.22 | 2.67 | 2.2354–2.7101 |
| oxc-Os | cordis/ts-oxc-all | 2.2778 | 2.2777 | 99.99 | 30.69 | 2.09 | 2.2710–2.7355 |
| oxc-Oz | cordis/ts-oxc-all | 4.7519 | 4.7513 | 99.96 | 30.59 | 1.92 | 4.5707–5.2273 |
| swc-next-O3 | cordis/ts-oxc-all | 2.1953 | 2.1903 | 99.86 | 31.05 | 2.20 | 2.0437–2.6620 |
| swc-next-O3-checked | cordis/ts-oxc-all | 2.7104 | 2.7101 | 99.99 | 31.55 | 2.78 | 2.6809–2.9156 |
| swc-next-Os | cordis/ts-oxc-all | 2.1898 | 2.1897 | 99.99 | 30.44 | 1.91 | 2.1724–2.2388 |
| swc-next-Oz | cordis/ts-oxc-all | 3.9072 | 3.9071 | 99.99 | 30.28 | 1.55 | 3.8436–4.2921 |
| oxc-O3 | vite/jsx-oxc-all | 0.0941 | 0.0941 | 99.99 | 30.12 | 1.73 | 0.0937–0.0944 |
| oxc-O3-checked | vite/jsx-oxc-all | 0.1113 | 0.1112 | 99.96 | 30.33 | 1.94 | 0.1094–0.1165 |
| oxc-Os | vite/jsx-oxc-all | 0.1158 | 0.1158 | 99.99 | 29.81 | 1.64 | 0.1145–0.1178 |
| oxc-Oz | vite/jsx-oxc-all | 0.2656 | 0.2656 | 100.00 | 29.59 | 1.42 | 0.2627–0.2853 |
| oxc-O3 | vite/tsx-oxc-all | 0.1108 | 0.1108 | 99.98 | 30.02 | 1.88 | 0.1086–0.1143 |
| oxc-O3-checked | vite/tsx-oxc-all | 0.1280 | 0.1280 | 99.99 | 30.23 | 2.08 | 0.1272–0.1326 |
| oxc-Os | vite/tsx-oxc-all | 0.1348 | 0.1348 | 99.99 | 30.08 | 1.81 | 0.1332–0.1557 |
| oxc-Oz | vite/tsx-oxc-all | 0.3104 | 0.3103 | 99.99 | 29.62 | 1.53 | 0.3052–0.3198 |
| oxc-O3 | vue-core/ts-common | 8.9120 | 8.8482 | 99.89 | 32.17 | 2.56 | 8.4891–9.3993 |
| oxc-O3-checked | vue-core/ts-common | 9.2676 | 9.2674 | 99.99 | 32.41 | 2.73 | 9.1548–10.6747 |
| oxc-Os | vue-core/ts-common | 9.4168 | 9.4162 | 99.98 | 31.88 | 2.28 | 9.1773–10.1927 |
| oxc-Oz | vue-core/ts-common | 18.1760 | 18.1610 | 99.98 | 31.64 | 2.11 | 17.6801–19.6232 |
| swc-next-O3 | vue-core/ts-common | 8.0373 | 8.0368 | 99.98 | 32.64 | 2.62 | 7.8696–8.4636 |
| swc-next-O3-checked | vue-core/ts-common | 10.7543 | 10.7346 | 99.82 | 33.72 | 3.80 | 10.5974–11.5503 |
| swc-next-Os | vue-core/ts-common | 8.4381 | 8.4381 | 99.99 | 31.88 | 2.31 | 8.3697–9.4340 |
| swc-next-Oz | vue-core/ts-common | 14.6505 | 14.6493 | 99.99 | 31.72 | 2.02 | 14.4615–14.8455 |
| yuku-fast | vue-core/ts-common | 4.4943 | 4.4926 | 99.97 | 32.77 | 3.17 | 4.4634–4.7335 |
| yuku-safe | vue-core/ts-common | 5.6698 | 5.6675 | 99.99 | 37.16 | 7.50 | 5.5430–5.8941 |
| yuku-small | vue-core/ts-common | 8.5415 | 8.5141 | 99.98 | 32.80 | 2.92 | 8.3536–8.9581 |
| oxc-O3 | vue-core/ts-oxc-all | 13.9358 | 13.9076 | 99.91 | 34.73 | 4.16 | 13.7949–14.5959 |
| oxc-O3-checked | vue-core/ts-oxc-all | 14.9320 | 14.9229 | 99.97 | 34.27 | 3.77 | 14.6942–16.0096 |
| oxc-Os | vue-core/ts-oxc-all | 15.0517 | 15.0484 | 99.98 | 33.91 | 3.38 | 14.7517–15.8096 |
| oxc-Oz | vue-core/ts-oxc-all | 29.1844 | 29.1082 | 99.95 | 34.22 | 3.14 | 28.2312–30.4668 |
| swc-next-O3 | vue-core/ts-oxc-all | 13.3674 | 13.3659 | 99.99 | 34.50 | 4.11 | 13.1866–14.4010 |
| swc-next-O3-checked | vue-core/ts-oxc-all | 17.4974 | 17.4675 | 99.95 | 35.16 | 4.55 | 17.0861–18.4144 |
| swc-next-Os | vue-core/ts-oxc-all | 14.3539 | 14.3401 | 99.99 | 34.59 | 4.14 | 14.0987–14.9894 |
| swc-next-Oz | vue-core/ts-oxc-all | 24.5214 | 24.5103 | 99.96 | 35.19 | 4.64 | 23.9373–25.5341 |
| oxc-O3 | webui/ts-common | 0.7029 | 0.7028 | 99.99 | 30.25 | 2.06 | 0.6766–0.7579 |
| oxc-O3-checked | webui/ts-common | 0.7806 | 0.7805 | 99.99 | 30.44 | 2.22 | 0.7716–0.8585 |
| oxc-Os | webui/ts-common | 0.7953 | 0.7953 | 99.98 | 30.12 | 1.91 | 0.7861–0.8643 |
| oxc-Oz | webui/ts-common | 1.7903 | 1.7829 | 99.90 | 29.88 | 1.55 | 1.7144–1.8709 |
| swc-next-O3 | webui/ts-common | 0.6468 | 0.6467 | 99.99 | 30.08 | 1.86 | 0.6187–0.7081 |
| swc-next-O3-checked | webui/ts-common | 0.9213 | 0.9213 | 99.99 | 30.53 | 2.23 | 0.9016–0.9683 |
| swc-next-Os | webui/ts-common | 0.7267 | 0.7266 | 99.99 | 29.92 | 1.62 | 0.7086–0.8588 |
| swc-next-Oz | webui/ts-common | 1.4202 | 1.4201 | 99.99 | 29.62 | 1.23 | 1.3973–1.4821 |
| yuku-fast | webui/ts-common | 0.3909 | 0.3909 | 99.99 | 29.56 | 1.30 | 0.3834–0.4175 |
| yuku-safe | webui/ts-common | 0.5161 | 0.5161 | 99.99 | 29.70 | 1.52 | 0.5098–0.5864 |
| yuku-small | webui/ts-common | 0.8558 | 0.8557 | 99.99 | 29.44 | 1.00 | 0.8307–0.9665 |
| oxc-O3 | webui/ts-oxc-all | 1.1955 | 1.1951 | 99.96 | 30.42 | 2.20 | 1.1352–1.2920 |
| oxc-O3-checked | webui/ts-oxc-all | 1.2942 | 1.2941 | 99.99 | 30.75 | 2.36 | 1.2518–1.3283 |
| oxc-Os | webui/ts-oxc-all | 1.3111 | 1.3110 | 99.99 | 30.38 | 1.94 | 1.2935–1.3913 |
| oxc-Oz | webui/ts-oxc-all | 2.7983 | 2.7973 | 99.96 | 29.97 | 1.73 | 2.7286–2.9192 |
| swc-next-O3 | webui/ts-oxc-all | 1.1093 | 1.1093 | 99.99 | 30.20 | 2.00 | 1.0977–1.2893 |
| swc-next-O3-checked | webui/ts-oxc-all | 1.5428 | 1.5427 | 99.99 | 30.84 | 2.58 | 1.5097–1.7012 |
| swc-next-Os | webui/ts-oxc-all | 1.2278 | 1.2275 | 99.99 | 29.98 | 1.78 | 1.2071–1.3680 |
| swc-next-Oz | webui/ts-oxc-all | 2.2451 | 2.2451 | 99.99 | 29.64 | 1.36 | 2.2015–2.3798 |

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

[README.md](README.md) documents commands and measurement definitions. Both Rust wrappers have checked-in Cargo lockfiles; [sources.lock.json](sources.lock.json) pins upstream source commits. [raw.json](results/no-cooldown-previous/raw.json) contains **455 samples** across **65 build/group combinations**. Wall min–max values are observed sample-average ranges, not confidence intervals. Run `uv run --locked bench/transform/run.py report` to regenerate this report from saved results.

This is one machine and corpus snapshot. CPU affinity, thermal/frequency controls and system-wide idleness were not enforced. Python call overhead matters most for tiny groups; RSS depends on OS/allocator behavior. No cold-start latency, full application execution, final Origine binary-size delta or full embedded-V8 RSS was measured. Origine’s current mixed Oz/O3, 16-codegen-unit, unwind profile differs from these uniform benchmark profiles; changing its profile requires a separate final-binary test. Aborting panics here must not be copied into its panic-catching ABI without reviewing that contract. These results do not predict Linux/x86-64 or other V8 builds.
