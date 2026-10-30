# Yuku and Oxc: transform coverage and embedded V8 fit

Research date: 2026-10-28. Yuku source inspected at `35678b85a437d1fb4c722e8c2381f155c33d49fe`; Origine's Oxc crates are pinned to `0.155.0` in [rust/Cargo.toml](../../rust/Cargo.toml). Documentation on the public sites can move independently of these revisions. This note makes no speed or memory claims.

## The workloads are not interchangeable

| Requested operation | Yuku's existing native pipeline | Oxc transformer |
|---|---|---|
| Erasable TS → JS | Supported by parse + codegen `strip=true` | Supported by parser + semantics + transformer + codegen |
| TS enum, namespace, parameter property lowering | Not supported by `strip`; omission produces diagnostics | Runtime TypeScript transformation exists; enum lowering is also covered by Origine's local test |
| TSX → executable JS | Not complete: removes TS but retains JSX | JSX lowering supported |
| JSX → executable JS | Not complete: printer preserves JSX | Automatic or classic runtime supported |

Yuku documents type erasure, and reports constructs needing runtime generation rather than lowering them: enums, namespaces, `export =`, `import = require()`, and parameter properties. A successful parse therefore does not establish a successful TS-to-JS compilation; callers must inspect codegen diagnostics. [Yuku codegen documentation](https://yuku.fyi/parser/codegen/)

The pinned Yuku printer emits `<`, `/>`, and `</` directly in `emit_jsx_opening_element` and `emit_jsx_closing_element`. Its options expose no JSX runtime transform. This is source-level evidence of JSX preservation, even with `strip=true`; parsing JSX must not be described as compiling it to JS. [Pinned Yuku printer, options and JSX emitters](https://github.com/yuku-toolchain/yuku/blob/35678b85a437d1fb4c722e8c2381f155c33d49fe/src/parser/codegen/printer.zig#L2933)

Oxc exposes JSX automatic/classic runtimes, configurable import source/factory/fragment, development output and preservation mode. Automatic mode can introduce runtime imports, which an embedder must resolve. Preservation mode is useful for a syntax-processing comparison, but is not the requested executable-JS task. [Oxc JSX documentation](https://oxc.rs/docs/guide/usage/transformer/jsx)

Oxc also documents namespace and enum options, legacy decorators and metadata generation; metadata requiring type inference can fall back to `Object`. Neither a type-stripper nor this transform pipeline should be treated as a replacement for type checking. [Oxc TypeScript documentation](https://oxc.rs/docs/guide/usage/transformer/typescript)

## Maps and diagnostics

Yuku emits Source Map V3 with UTF-16 columns, optional source content, a single source entry and empty names; map support can be removed at build time. Parse errors and scope-dependent semantic errors are separate stages. A comparable correctness-oriented benchmark should specify whether semantic checking is included. [Yuku codegen](https://yuku.fyi/parser/codegen/), [Yuku parser](https://yuku.fyi/parser/)

Oxc supports source map generation and a pipeline including semantic analysis, TypeScript transformation, JSX and optional target lowering. Feature selection must be explicit when comparing it with type erasure alone. [Oxc transformer documentation](https://oxc.rs/docs/guide/usage/transformer)

## Fit for Origine's V8 embedder

**Oxc already fits the current integration.** [origine_oxc](../../rust/crates/origine_oxc/src/lib.rs) builds a fresh allocator, parses, checks semantics, transforms and generates code, with no ES target downleveling configured. It forces ES modules, rejects diagnostics at every stage and exposes a small C ABI. Rust owns its result until `origine_oxc_result_free`; the [Zig adapter](../../src/api/transform/oxc.zig) copies output into the caller's allocator and releases the Rust result. ABI checks verify layout and signatures against the [C header](../../rust/crates/origine_oxc/include/origine_oxc.h).

The current wrapper exposes automatic/classic JSX, development mode, runtime import source, classic factories, verbatim imports and optional inline maps. It catches unwinding panics as an internal-error result. Changing to an aborting Rust panic strategy would change that failure behavior. The Zig adapter explicitly notes that V8 ignores the appended inline map comment; generating a map alone does not provide mapped runtime stack traces. [Current wrapper documentation](../../rust/crates/origine_oxc/docs/README.md), [Zig adapter](../../src/api/transform/oxc.zig)

**Yuku can be embedded directly in Zig for the supported subset.** Its parser takes a Zig allocator; the tree borrows source bytes and owns an arena. Codegen returns separately owned output. This avoids requiring a Node addon, N-API, or a JS AST transfer for native integration, but still needs an adapter matching Origine's diagnostics and ownership conventions. [Yuku native parser API](https://yuku.fyi/parser/), [pinned native codegen API](https://github.com/yuku-toolchain/yuku/blob/35678b85a437d1fb4c722e8c2381f155c33d49fe/src/parser/codegen/printer.zig)

These are compiler libraries rather than V8 engine plugins: the useful boundary is UTF-8 source in, JS text out, followed by V8 module compilation. Origine already implements that boundary in [src/api/graph.zig](../../src/api/graph.zig). Yuku's retained JSX is unacceptable at that boundary; runtime TS omission must likewise fail. Oxc's generated JSX helper imports require an available JSX runtime. Vue SFC files require a separate Vue compiler; extracting a script block does not compile a template. Compatibility with application sources also requires correct import resolution and framework-specific transforms, not merely V8 syntax acceptance.

## Release-mode interpretation

Zig 0.17 calls its safety/optimization modes `.fast`, `.safe`, and `.small` (older names: `ReleaseFast`, `ReleaseSafe`, `ReleaseSmall`). The installed compiler's `std/lang.zig` defines fast as performance with safety disabled, safe as performance with safety enabled, and small as code size with safety disabled. Record the exact Zig version and flags; a safety mode and an LLVM optimization level are different dimensions. In particular, do not label `.small` as `-O3` unless the compiler invocation or emitted LLVM attributes establish that combination. [Zig build-mode reference](https://ziglang.org/documentation/master/#Build-Mode), [Yuku build forwards the selected mode](https://github.com/yuku-toolchain/yuku/blob/35678b85a437d1fb4c722e8c2381f155c33d49fe/build.zig)

For Rust, use `opt-level=3`, `"s"`, and `"z"` for the requested O3/Os/Oz comparisons. Cargo documents that size modes need measurement: they do not guarantee a smaller or faster artifact. Rust has independently configurable overflow checks and debug assertions, so no Rust profile is an exact Zig safety-mode equivalent. Keep panic strategy, allocator, target CPU, LTO, codegen units, symbol stripping and features fixed or report them. [Cargo profile reference](https://doc.rust-lang.org/cargo/reference/profiles.html)

Origine's current release profile is mixed: default `opt-level="z"`, thin LTO, 16 codegen units, stripped symbols, unwind panics, with Oxc's hot-path crates overridden to level 3. A benchmark of that profile is not a uniform Oz benchmark. [Current Cargo profile](../../rust/Cargo.toml)

For library sizes, report artifact format. A Rust `staticlib` includes upstream dependencies; an `rlib` is a different artifact. Raw archive bytes are useful packaging measurements but do not equal incremental linked binary size, because final linking can discard unused sections. Measure an identical linked harness or final binary delta separately. [Rust linkage reference](https://doc.rust-lang.org/reference/linkage.html)

## Decision boundary

For Origine's present TS/TSX/JSX contract, Oxc is the complete existing choice. Yuku is a candidate for an explicitly restricted erasable-TS path or for parsing/analyzing JS and TS; using it for all three requested transforms first needs JSX and runtime-TypeScript lowering, or an additional compiler. Report unsupported cases and coverage before ranking durations, RSS, CPU usage or library sizes. This conclusion follows from feature coverage and local integration evidence, not a performance prediction.

## SWC Next extension

SWC Next was inspected at `71c3f7982004f9acc6da83c742183466bd5ba229`. It is a separate rewrite with separate APIs: classic SWC's transform coverage must not be attributed to it. Its README calls the Rust API very early, recommends classic SWC's Rust API for production, warns of AST handles not being tied to their owning AST and consequent undefined behavior through safe APIs, and says `.swcrc` compatibility is not implemented. This materially weakens its present suitability for production embedding. [Pinned README](https://github.com/swc-project/swc-next/blob/71c3f7982004f9acc6da83c742183466bd5ba229/README.md)

There are **two different TypeScript paths**; a benchmark must identify which it measures. This benchmark measures the semantic TypeScript lowering pass, not the fixed-width eraser:

| Path | Actual behavior | Requested executable-JS coverage |
|---|---|---|
| `swc_next_type_strip::strip_types(source, Options)` | Replaces type syntax with whitespace while preserving UTF-16 positions and lines; parses internally; requires explicit type imports/exports | Erasable TS only; TSX retains JSX |
| `swc_next_ecma_transformer::Transformer::transform(ast, semantic, TransformerOptions)` with `typescript: Some(...)` | Uses semantic analysis for TypeScript lowering, then reanalyzes and runs configured scope transforms | Broader TS, but JSX and some module forms remain unsuitable for direct V8 compilation |

The strip path explicitly diagnoses enums, instantiated namespaces/modules/globals, parameter properties, `import =`, `export =`, and angle-bracket assertions. Output with diagnostics is recovery output and may change semantics. It does not resolve names or inline const enums. TSX is supported as input but JSX is explicitly preserved. [Pinned type-strip API and contract](https://github.com/swc-project/swc-next/blob/71c3f7982004f9acc6da83c742183466bd5ba229/crates/swc_type_strip/src/lib.rs#L38)

The full transform path genuinely includes enum, namespace, parameter-property and import-alias lowering, plus type erasure; it is not restricted to the strip path's subset. `TypeScriptOptions` exposes `verbatim_module_syntax`, `preserve_const_enums` and JSX import-retention settings. The native caller must normalize runtime syntax and analyze before transforming, as its own tests do. [Transformer entry point](https://github.com/swc-project/swc-next/blob/71c3f7982004f9acc6da83c742183466bd5ba229/crates/swc_ecma_transformer/src/lib.rs#L29), [lowering modules](https://github.com/swc-project/swc-next/blob/71c3f7982004f9acc6da83c742183466bd5ba229/crates/swc_ecma_transformer/src/typescript/lower/mod.rs), [options](https://github.com/swc-project/swc-next/blob/71c3f7982004f9acc6da83c742183466bd5ba229/crates/swc_ecma_transformer/src/typescript/options.rs), [native transform test setup](https://github.com/swc-project/swc-next/blob/71c3f7982004f9acc6da83c742183466bd5ba229/crates/swc_ecma_transformer/src/typescript/tests/mod.rs)

**There is no JSX-to-JS lowering in the inspected public transformer options.** `JsxImportOptions` is documented as retaining factory dependencies for a later transform; it is not a React automatic/classic JSX emitter. The code generator prints `<` and JSX attributes directly. TSX/JSX-to-executable-JS therefore remains unsupported by these native paths. [JSX options](https://github.com/swc-project/swc-next/blob/71c3f7982004f9acc6da83c742183466bd5ba229/crates/swc_ecma_transformer/src/typescript/options.rs), [literal JSX printer](https://github.com/swc-project/swc-next/blob/71c3f7982004f9acc6da83c742183466bd5ba229/crates/swc_ecma_codegen/src/printer.rs#L5030)

**Broader TS coverage still does not guarantee V8-ready output.** The full transform's tests explicitly expect `export = value;` to survive. External `import Foo = require('pkg')` is lowered to a synchronous import expression; the JSX tests expect `import.sync`, so do not assume ordinary ESM or `require` output. These forms require an additional compatible transform or runtime support and must be caught by output compilation checks. [Module tests](https://github.com/swc-project/swc-next/blob/71c3f7982004f9acc6da83c742183466bd5ba229/crates/swc_ecma_transformer/src/typescript/tests/modules.rs#L160), [import-equals lowering](https://github.com/swc-project/swc-next/blob/71c3f7982004f9acc6da83c742183466bd5ba229/crates/swc_ecma_transformer/src/typescript/lower/modules.rs#L220), [JSX import tests](https://github.com/swc-project/swc-next/blob/71c3f7982004f9acc6da83c742183466bd5ba229/crates/swc_ecma_transformer/src/typescript/tests/jsx.rs)

Native codegen exposes `print(&Ast, Options) -> PrintResult`, with optional maps controlled by `source_map_path`. The fixed-width strip path instead preserves source positions without generating a map. The inspected npm core's Rust module exports parser and codegen only; an Origine integration should call the native Rust crates through a purpose-built C ABI, as it does for Oxc, rather than assume a transform API or Node addon is usable inside bare V8. Such an adapter needs explicit ownership, diagnostic conversion and panic policy. [Codegen API](https://github.com/swc-project/swc-next/blob/71c3f7982004f9acc6da83c742183466bd5ba229/crates/swc_ecma_codegen/src/printer.rs#L30), [npm core exports](https://github.com/swc-project/swc-next/blob/71c3f7982004f9acc6da83c742183466bd5ba229/npm/core/src/lib.rs)

SWC Next's upstream release profile uses O3, fat LTO, one codegen unit, aborting panics and symbol stripping. These differ from Origine's thin-LTO/unwind profile and must be recorded or normalized for fair comparisons. The full `Transformer::transform` rebuilds semantics after TypeScript transformation. This benchmark instead calls the public `typescript::transform` after runtime normalization and semantic analysis, avoiding unrelated scope transforms and post-transform reanalysis. It still performs more work than a syntax-only strip path. [Pinned Cargo profiles](https://github.com/swc-project/swc-next/blob/71c3f7982004f9acc6da83c742183466bd5ba229/Cargo.toml#L88), [transform pipeline](https://github.com/swc-project/swc-next/blob/71c3f7982004f9acc6da83c742183466bd5ba229/crates/swc_ecma_transformer/src/lib.rs#L47)
