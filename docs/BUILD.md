# Building origine

`origine` is a Zig application embedding V8. The root package builds the shell and links
three things: the V8 archive from `lib/v8_zig`, a Rust static library (`rust/`, always built),
and the Zig I/O library `liborigine_io.a` (`src/io/lib.zig`, always ReleaseFast). `lib/v8_zig`
is a local package that fetches, patches, and builds V8 and exposes the `@v8`, `@engine`,
`@managed`, `@util`, `@mimalloc`, and `@diagnostics` modules; for running the shell, see the
[README](../README.md).

## Requirements

- Zig 0.17.0 and [uv](https://docs.astral.sh/uv/) (runs the Python build helpers)
- Git, rsync, and network access to GitHub, Chromium's source/toolchain servers, and
  pkg.lightpanda.io for the first build. No credentials are needed.
- macOS: Xcode or Command Line Tools. GN picks the SDK from `xcode-select` /
  `DEVELOPER_DIR`; do not pass an absolute `-Dmac_sdk_path`.
- Rust (rustup; `rust/rust-toolchain.toml` pins the toolchain). Rust is part of the core;
  the first build fetches its crates (oxc today) from crates.io. Build without network with
  `-Dcargo-offline`.
- Optional: [just](https://github.com/casey/just) for the shortcuts below.

The first build downloads depot_tools and V8 15.8.30 into `lib/v8_zig/.lp-cache/`
and compiles V8: expect 20+ minutes. Later builds reuse that V8 archive; rebuild it
with `zig build build-v8` after changing V8 or its patches.

Release desktop V8 builds use Google's exact-version builtin PGO baseline.
The downloader verifies its source revision and records a SHA-256 receipt. V8
checks graph hashes. macOS aarch64 uses a separately merged overlay containing
measured profiles for 16 configuration-specific builtins, with strict rejection
of hash mismatches. Other targets retain Google's baseline, explicitly exclude
those 16 names, and discard other incompatible entries with warnings. See the
[profile policy and acceptance report](../lib/v8_zig/docs/builtin-pgo.md).
Matching entries still guide branch optimization. Use `-Dbuiltin_pgo=false` for an
unprofiled comparison build. This is builtin PGO, not C++ compiler PGO.

## Everyday commands

Run from the repository root.

```sh
zig build                  # build zig-out/bin/origine (debug app, release V8)
zig build run              # run the REPL (zig build run -- <args>, e.g. an init file)
zig build -Doptimize=small # small release app
zig build test             # V8 package tests and the managed runtime tests
zig build test-io          # event loop tests; needs no V8
```

`just build [debug|release] [debug|release]` (app mode, V8 mode), `just run`, `just test`
wrap the same commands. `just` with no arguments lists every recipe.

## Checks

| Recipe | What it does |
| --- | --- |
| `just check` | Everything CI-style: `check-contracts`, `check-rust`, `check-format` |
| `just check-contracts` | Regenerates cross-language files into a temp tree and fails on drift; runs `zig build test-io -Dtypescript=false` ([contracts](contracts.md)) |
| `just check-rust` | `zig build clippy` (warnings denied; every `unsafe` needs a `// SAFETY:` comment), then Miri over the V8-free crates ([rust overview](../rust/docs/README.md)) |
| `just check-format` | `cargo fmt --check`, `oxfmt --check` and `oxlint` over `bench examples src/js src/repl` |
| `just format` | Applies the formatters |
| `just gen-contracts` | Rewrites the committed generated files |
| `just test-repl` | Drives the REPL in a pseudo-terminal ([repl](repl.md)) |

`oxfmt` and `oxlint` run through `vpx` at the versions pinned in the `justfile`.

## Release V8 by default

V8 is built in **release** mode for every application mode. `-Doptimize` only controls
the Zig executable; a debug V8 would make the shell slow. Release V8 uses ThinLTO and
omits unwind tables. On macOS, release app builds link with V8's matching `ld64.lld`
(ThinLTO, identical-code folding); debug app builds convert the V8 archive to native
objects, cached.

## Engine Patches

We patch the V8 Engine (e.g. V8, ICU, and PartitionAlloc)

Patches are applied by ordered series in
`lib/v8_zig/build-tools/patches/{v8,icu,partition_alloc}/`. The first `zig build`, and every
`zig build build-v8` (plain builds otherwise reuse the last archive), does:

1. fetches V8 if missing,
2. syncs each checkout with its series (`scripts/apply-patches.sh`): only the first changed
   patch and those after it are reverted and reapplied,
3. runs `gn` and incremental `ninja`.

Nothing is copied or installed by hand: edit or add a patch and run
`zig build build-v8`. A patch that no longer applies stops the build and names the file. The V8 series currently
removes `Date` except `Date.now()` (Temporal replaces it), hardens the intrinsics, and
routes allocations through mimalloc; see `lib/v8_zig/build-tools/README.md`. mimalloc itself is the `lib/mimalloc` package (Zig and, in `rust/crates/origine_alloc`, Rust bindings; `zig build test-alloc` tests the Rust ones) (pinned upstream plus its own patch series, applied by the Zig build); see its README.

## Working on V8: debug V8

While changing V8 or its patches, use a debug V8 for quick incremental compiles. Plain
builds do not re-run ninja, so rebuild V8 explicitly after each change:

```sh
zig build build-v8 -Dv8_debug=true
zig build run -Dv8_debug=true     # both steps: just v8-dev
```

Debug and release V8 use separate GN output directories (`.lp-cache/v8-*/out/`), so
switching back and forth never rebuilds the other. Return to the default release V8 once
the change is done.

Editing loop:

```sh
zig build patch-v8                # fetch V8 and apply patches, no compile (just patch-v8)
# edit files in lib/v8_zig/.lp-cache/v8-15.8.30/
cd lib/v8_zig
just new-patch v8 my-change       # diff against the patched baseline -> next numbered patch
cd ../.. && zig build run -Dv8_debug=true
```

`new-patch` writes `patches/v8/NNNN-my-change.patch` and reverts the edits in the
checkout, so the next build applies the patch through the series. Series names are
`v8`, `icu` (checkout `third_party/icu`), and `partition_alloc`. Pass paths of newly
created files as extra arguments. To change an existing patch, edit the patch file; the
applier reverts and reapplies from there.

## Build options

Pass these to `zig build` at the root unless noted.

| Option | Meaning |
| --- | --- |
| `-Doptimize=debug\|safe\|fast\|small` | Zig executable mode (default debug) |
| `-Dv8_debug=true` | Debug V8 (default release) |
| `-Dprebuilt_v8_path=/abs/libv8_zig.a` | Skip building V8 and link an existing archive. The Rust workspace cannot be built against it (no GN output for bindgen), so use it only where a Rust archive is not needed |
| `-Dcache_root=<dir>` | V8 / depot_tools checkout cache (default `lib/v8_zig/.lp-cache`) |
| `-Dv8_clang_dir=<llvm/bin>` | Override the matching LLVM toolchain |
| `-Dtypescript=false` | Build the Rust library without the oxc transformer (no `.ts/.tsx/.jsx` support; default true) |
| `-Dcargo-offline` | Pass `--offline` to cargo |
| `-Dbuiltin_pgo=false` | Skip Google's builtin PGO baseline (default on for non-debug desktop V8) |
| `-Dv8_sandbox=false` | Build V8 without the sandbox (default on). A sandboxed V8 gets ArrayBuffer memory from a mimalloc arena inside the sandbox; without it, from the Zig allocator. Also turns builtin PGO off. Exported to Zig as `build_options.v8_sandbox` |

`lib/v8_zig` additionally accepts `-Dthin_lto`, `-Dexclude_unwind_tables`,
`-Dtemporal`, `-Dsymbol_level`, `-Dis_asan`, `-Dis_tsan`,
`-Doptimize_for_size`, and `-Druntime_call_stats` (see `zig build --help` there). Each
distinct GN configuration gets its own output directory, named by a hash of its
arguments. `-Dtemporal=false` disables Temporal, leaving no date functionality beyond
`Date.now()`.

## Steps

| Step | Where | Purpose |
| --- | --- | --- |
| `run`, `shell` | root | Build and run origine (REPL, or an init file passed after `--`) |
| `build-shell` | root | Build and install `zig-out/bin/origine` |
| `test` | root, `lib/v8_zig` | Root: V8 package and managed runtime tests. Package: library tests |
| `test-io` | root | `src/io` and `src/safe.zig` tests, no V8 |
| `clippy` | root | Clippy over the Rust workspace with the V8 environment |
| `patch-v8` | both | Fetch V8 and apply patches only |
| `build-v8` | root, `lib/v8_zig` | Rebuild V8 (plain builds reuse the last archive) |
| `gen`, `check-generated`, `check-bindings` | `lib/v8_zig` | Regenerate / verify bindings |
| `test-icu-lazy` | `lib/v8_zig` | Deferred ICU loading, in a fresh process |

Run package-specific steps from `lib/v8_zig`. `lib/v8_zig` has its own `justfile`
(`just build`, `just rebuild`, `just dev`, `just patch`, `just new-patch`, `just test`, `just test-dev`).

## Upgrading V8

1. Change `version` in `lib/v8_zig/build/v8.build.zig` (and the checkout path in
   `lib/v8_zig/justfile`'s `new-patch` recipe).
2. Run the build. The first patch that no longer applies stops it; rebase that patch against
   the new tree, regenerate it with `new-patch`, and repeat for later patches.
3. Run `zig build gen`, `zig build check-generated`, and `zig build test` in `lib/v8_zig`,
   and update the intrinsic inventory (see `lib/v8_zig/docs/intrinsics.md`).

## Housekeeping

- Keep `.lp-cache/`, `.zig-cache/`, `zig-pkg/`, and `zig-out/` local; do not commit them.
- Each GN configuration leaves a directory in `.lp-cache/v8-*/out/`. Delete ones you no
  longer use to reclaim disk space; they are rebuilt on demand.
- If a checkout was modified outside the patch tooling and a revert fails, reset the
  checkout to pristine upstream and delete its `.zig-patches/` directory.

## Rust and TypeScript support

All Rust code lives in one Cargo workspace, `rust/`. The root package `origine_native`
builds a single `staticlib` (ThinLTO, `opt-level = "z"`, with the hot crates at `opt-level = 3`, see `[profile.release.package.*]`) that re-exports the member crates
(`rust/crates/origine_oxc` today). `zig build` runs cargo and links the archive into
`origine`; there is no shared library to ship.

Symbol collisions: the archive embeds Rust's std, and V8's archive embeds Chromium's.
Both define `rust_eh_personality` and friends. In macOS non-debug builds (V8's `ld64.lld`
external link) `build.zig` first runs `clang -r -exported_symbols_list <generated list>`
so only the prefixes in `kept_symbol_prefixes` (`build.zig`: `origine_*`, `crdtp__*`, `v8_inspector__*`) stay global
(docs/contracts.md, surface F). Debug builds and tests link the plain archive (a
pre-linked object breaks Mach-O thread-locals there). Linux has an `ld -r` + `objcopy`
equivalent in `build.zig` that is not exercised yet. Cross builds (`-Dtarget` other than native)
cannot run the snapshot tool and fall back to V8's built-in startup seed.

### Size overhead (macOS arm64, `-Doptimize=small`)

Rust is always linked; `-Dtypescript=false` only leaves oxc out of it.

| Measurement | Bytes |
| --- | --- |
| `origine`, all `z` (first measurement), `-Dtypescript=false` / TypeScript | 34,859,008 (no Rust linked) / 36,560,448 |
| `origine`, hot crates at O3, `-Dtypescript=false` (Rust runtime only) | 35,158,048 |
| `origine`, hot crates at O3, TypeScript | 37,477,888 (+2,319,840 over the Rust-only build) |

The O3 crates (parser, semantic, transformer, traverse, codegen, AST, allocator, memchr, ...)
cost about 0.6 MB over the all-`z` build; move a crate out of
`[profile.release.package.*]` in `rust/Cargo.toml` to trade speed back for size.

Rust object before final dead-stripping (pre-linked, `_origine_*` exported only):

| Profile | Object bytes | gzip -9 |
| --- | --- | --- |
| ThinLTO, z, cgu 16 (default) | 5,201,864 | 1,231,109 |
| ThinLTO, s | 4,966,528 | 1,241,668 |
| ThinLTO, z, cgu 1 | 4,563,344 | 1,124,319 |
| ThinLTO, z, `panic=abort` | 4,891,256 | 1,159,934 |
| fat LTO, z | 4,034,832 | 1,102,359 |
| ThinLTO, opt-level 3 | 5,062,880 | 1,443,630 |
| ThinLTO, z with hot crates at 3 (current) | 5,011,824 | 1,397,714 |

`panic = "unwind"` is kept so a parser bug becomes an error result instead of aborting
the shell. Fat LTO or `codegen-units = 1` would save roughly 10-20% of the object at a
cost in build time; the final executable delta is smaller than the object because the
linker strips unused code.
