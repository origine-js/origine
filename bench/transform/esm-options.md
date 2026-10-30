# ESM-only selection: Yuku, Oxc and SWC Next

Decision based on the completed 1-second-cooldown run: 455 samples, seven samples per build/workload, Apple M4 Max. Source versions, exact native configurations, all measurements and limitations are in [report.md](report.md). No new performance run or ESM-specialized library rebuild was performed for this decision note.

## Scope

All three native wrappers already parse inputs as ES modules and preserve ESM syntax. None of the inventoried source inputs contains TypeScript import-equals or export-equals forms (checked against the saved input inventory). The separate CommonJS/module-edge probes do not contribute to timings. ESM-only removes those compatibility requirements; it does not remove runtime enums, namespaces, parameter properties, or the need to lower JSX.

The library sizes below are for the existing benchmark wrappers. They are not measurements of libraries rebuilt with every CommonJS-specific branch removed. ESM source selection alone does not establish a size reduction.

## Full ESM TypeScript sources

Median milliseconds per entire repository source group. Both engines accept all 321 TS files, including runtime TS constructs. Small median differences with overlapping sample ranges should be treated as approximate ties, not established speed wins.

| Build | Dylib MiB | Static archive MiB | Cordis: 31 files, ms | WebUI: 57 files, ms | Vue-core: 233 files, ms | Vue peak RSS MiB |
|---|---:|---:|---:|---:|---:|---:|
| oxc-O3 | 2.277 | 9.519 | 2.0840 | 1.1924 | 13.5155 | 34.14 |
| oxc-O3-checked | 2.877 | 11.313 | 2.3166 | 1.3056 | 14.6255 | 34.47 |
| oxc-Os | 1.886 | 10.015 | 2.3043 | 1.3426 | 14.8966 | 34.11 |
| oxc-Oz | 1.308 | 10.617 | 4.6867 | 2.8107 | 29.7937 | 33.72 |
| swc-next-O3 | 1.503 | 7.958 | 2.0522 | 1.1491 | 13.2027 | 34.64 |
| swc-next-O3-checked | 2.055 | 9.091 | 2.7847 | 1.5885 | 17.3089 | 35.42 |
| swc-next-Os | 1.220 | 7.947 | 2.2526 | 1.2685 | 14.2030 | 34.41 |
| swc-next-Oz | 0.940 | 8.310 | 4.0254 | 2.3102 | 24.9748 | 34.30 |

RSS includes the Python harness, preloaded sources/buffer, mapped library and native allocator. All timed paths use approximately one CPU core. These RSS differences are small; they do not show a decisive memory advantage. Static archive bytes include runtime/dependency objects and do not predict the incremental final linked executable size. In particular, Oxc Os/Oz have smaller dylibs but larger static archives than O3.

## Restricted erasable-TS subset

Yuku cannot process the full required corpus: it accepts 12/31 Cordis, 48/57 WebUI and 194/233 Vue-core TS files. The next table compares identical files accepted by all three engines, not the full-corpus groups above.

| Build | Dylib MiB | Cordis: 12 files, ms | WebUI: 48 files, ms | Vue-core: 194 files, ms |
|---|---:|---:|---:|---:|
| yuku-fast | 0.784 | 0.1340 | 0.3980 | 4.4528 |
| yuku-safe | 0.957 | 0.1729 | 0.5291 | 5.5926 |
| yuku-small | 0.646 | 0.3122 | 0.8890 | 8.6595 |
| oxc-O3 | 2.277 | 0.2465 | 0.7111 | 8.5405 |
| swc-next-O3 | 1.503 | 0.2072 | 0.6416 | 7.9772 |

Yuku does less work: no semantic-model construction or checking is included. Oxc and SWC Next build semantics and run runtime-TypeScript lowering. ESM-only is not equivalent to erasable-only TS, so Yuku is not a replacement for the original Cordis/WebUI/Vue workload.

## Best options

1. **Production default with TS/TSX/JSX: Oxc O3.** It handles the complete requested transform scope, is already integrated with Origine, and gives the fastest measured Oxc path. Do not switch compilers for a few percent of TS timing difference when swc-next does not lower JSX and upstream marks its Rust API early.
2. **Size/speed compromise with the same features: Oxc Os.** Its dylib is 17.18% smaller than O3, with 10.2–12.6% longer full-TS transforms and about 22% longer JSX/TSX transforms in these samples. For static embedding, treat this as a candidate: measure the final Origine linked-size delta before choosing, because the measured raw archive is larger.
3. **Experimental TS-only choice: SWC Next Os (or O3 for maximum speed).** Os reduces its dylib by 18.82% versus its O3 build, at 7.6–10.4% more transform time. SWC Next Os is approximately 46.43% smaller in dylib bytes than Oxc O3 and takes about 5.1–8.1% more time on full TS groups. O3 is approximately 34% smaller than Oxc O3 and their TS timing ranges are close. These native paths preserve JSX; upstream production-readiness and AST-handle soundness caveats remain relevant even for ESM-only.
4. **Restricted eraser: Yuku fast.** Choose only if erasable TS is an explicit input contract and JSX is absent or compiled elsewhere. It is fastest on the common subset with a 0.784 MiB dylib. Yuku small saves about 0.138 MiB more but roughly doubles transform time on that subset, so fast is the better ordinary tradeoff. Keeping Oxc as a fallback adds a second compiler and does not save the Oxc library footprint.

Oxc Oz is appropriate only for a hard dynamic-library size budget: it cuts dylib bytes by 42.55% against O3 but takes 2.20–2.36 times as long for full TS and about 2.9 times as long for JSX/TSX. SWC Next Oz similarly trades about 1.9–2.0 times the TS duration for a 37.44% dylib reduction. Checked O3 and Yuku safe are diagnostic/safety choices, not the best speed/size points; they also do not provide equivalent safety guarantees across languages.

## ESM and V8 configuration

Preserve import/export syntax, disable CommonJS module lowering, and keep modern syntax for the V8 version actually shipped. Oxc automatic JSX emits ESM runtime imports, while classic JSX uses a factory in scope; either can fit ESM when the needed runtime is provided. The measured JSX timings use classic mode, so do not treat them as automatic-runtime benchmarks.

The standard Oxc transformer still requires semantic scope/binding information. Extra syntax/semantic error checks are optional; the measured builds keep them enabled. Disabling checks is an unmeasured optimization candidate, not a demonstrated speed improvement or removal of the semantic pass. V8 compilation is not a full substitute for checking the original source, because transformations may erase an invalid original construct.

These benchmark Rust libraries use thin LTO, one codegen unit and aborting panics; Origine currently uses a mixed Oz/O3, 16-codegen-unit, unwind profile. Preserve the panic-catching contract and separately benchmark the final linked binary before applying these profiles to Origine.

Primary-source feature and integration evidence: [research note](../../docs/research/yuku-oxc-features.md), [Oxc JSX docs](https://oxc.rs/docs/guide/usage/transformer/jsx), [Yuku type stripping](https://yuku.fyi/parser/codegen/), [pinned SWC Next README](https://github.com/swc-project/swc-next/blob/71c3f7982004f9acc6da83c742183466bd5ba229/README.md).
