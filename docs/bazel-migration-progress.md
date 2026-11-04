# Bazel migration progress

Checkpoint: 2026-11-04 (Asia/Taipei). First checkpoint: 2026-11-03.

The migration is **in progress, before cutover**. The bootstrap graph and several
Rust/native libraries build and test with Bazel. `@v8//:icu/v8` now compiles and
links `mksnapshot` and generates the snapshot (not yet linked into or run by anything). The Origine executable, application snapshots, editor integration, and full
acceptance matrix have not been completed. Existing build orchestration must
remain until those gates pass.

## Requirements and implementation constraints

- Initial platform: macOS arm64.
- Zig: exactly 0.17.0; patches based on this version are allowed.
- Rust: at least 1.100; currently pinned to `nightly-2026-10-19` (1.101).
- C/C++ and release linking: V8's matching LLVM revision.
- Bazel must eventually own individual compilation and generation actions,
  including V8. Normal builds must not use `.lp-cache`, Cargo builds, `zig build`,
  GN, Ninja, or depot_tools. Cargo remains available for Miri and maintenance.
- Release acceptance requires Zig/Rust/V8 cross-language ThinLTO, including
  evidence of optimization; native Zig objects alone do not satisfy it.
- Snapshot seed must become an explicit build setting, default `0x3c3d6918`.
- Preserve features, allocator ownership, ABI contracts, runtime behavior,
  compression choices, and the 70 MB small-release budget.
- Zed must support Bazel-backed ZLS and rust-analyzer with generated sources
  and proc macros.

User feedback incorporated:

- Local Rust crates compile independently through `rules_rust`. The temporary
  Cargo manifest rewriting workaround was removed. Original Cargo manifests and
  lockfile were not changed for the migration.
- SDK framework globbing and filtering were removed. SDK discovery uses `xcrun`;
  the toolchain treats SDK paths as system inputs and tracks SDK identity.
  Full SDK-change invalidation still needs acceptance testing.
- Reduce helper proliferation: reuse upstream BUILD targets and plain target
  declarations where possible. The generated Rust dependency module was reduced
  from 1,422 lines to 38 lines of direct dependency specifications.

## Working-tree preservation

Before migration work, the checkout already had changes in `build.zig`,
`rust/build.zig`, `src/main.zig`, and `src/snapshot_tool.zig`, plus an untracked
`docs/build-graph.md`. Those changes have been preserved without editing them.

The justfile keeps the Zig build's recipes (`build`, `run`, `test`, `check`, ...) unchanged; the Bazel ones are
prefixed `bazel-` beside them. Added
BUILD files under `lib/aws-lc` and `lib/v8_zig` are currently untracked changes
inside those submodules. They must be included in the eventual delivery rather
than lost when updating submodules. No migration commit or cutover has occurred.

## Implemented graph

### Workspace and compilers

- Added `.bazelversion` (8.4.2), `.bazelrc`, `MODULE.bazel`, module lockfile,
  root BUILD targets, and Bazel output ignores.
- Registered a macOS arm64 platform and pinned `rules_zig` 0.17.0,
  `rules_rust` 0.75.0, and supporting rule sets/dependencies.
- Configured Zig 0.17.0 and the Rust nightly distribution with integrity pins.
- Pinned V8 LLVM revision `e063be79adf127cce301fe5948273102a33012b6`
  (Clang 24) and its distribution checksum.
- Added the custom LLVM C/C++ toolchain, SDK discovery/identity repository, and
  source-pinned libc++, libc++abi, LLVM-libc headers, and Chromium configuration.
- Added `debug`, `safe`, `fast`, and `small` configurations. These are currently
  compiler configurations, not proof that the full application works in each.
- Patched `rules_zig` to declare individual SDK library files as action inputs
  instead of a directory input; bootstrap tests pass with this patch.

### ThinLTO compatibility probe

`//build/bazel/probe:thin_lto_test` builds a controlled Zig → Rust → C++ call
chain with the pinned compilers and links using V8's LLVM linker.

- Zig emits LLVM bitcode; pinned Clang converts it into ThinLTO input.
- Rust uses linker-plugin LTO; C++ uses ThinLTO.
- The test saves linker intermediates in a declared output tree and checks
  imported IR for Rust/C++ definitions and optimized IR for removal of their
  calls. The executable's result is also checked.
- The probe passes, demonstrating compatibility and cross-language optimization
  on this small case without patching Zig itself.
- This does **not** yet prove participation of production V8 modules or the
  correctness of the final application's Rust runtime and thread-local behavior.

### Source repositories, V8, and native libraries

- Bazel fetches V8 15.8.30, applies the existing ordered 11-patch series, and
  fetches pinned supporting sources directly (`just bazel-patch-v8` fetches it alone). Normal repository rules do not read or modify `.lp-cache`.
- Extended V8's existing Bazel graph for this configuration, ICU, Temporal,
  private libc++, mimalloc, compiler headers, and generated inspector sources.
- Added source builds for LZ4, mimalloc, nghttp2, AWS-LC, ICU, libc++, and
  libc++abi, plus the Temporal static library needed by V8 build tools.
- AWS-LC source lists follow the existing Zig source lists, including Apple
  arm64 assembly and its symbol prefix. Its jitter implementation stays outside
  LTO and uses the required compilation flags.
- Existing mimalloc patch hunks are unchanged; `diff --git` headers were added
  so Bazel's patch parser accepts the files.
- V8 configuration parity is incomplete: PGO/profile handling, partition_alloc,
  and the complete option matrix still need implementation/verification.

### Rust and Zig libraries

- Added independent Rust targets for `origine_alloc`, `origine_api_core`,
  `origine_api_fs`, `origine_io`, `origine_oxc`, `origine_dns`,
  `origine_transport`, `origine_tls`, and `origine_h2`.
- Native linkage is expressed as Bazel dependencies for the migrated crates,
  including mimalloc, the Zig I/O library, AWS-LC, and nghttp2.
- Added local Bazel targets for `aws-lc-rs` and `aws-lc-sys`, bypassing their
  native-library build scripts. Both explicitly use Rust edition 2021.
- Test-specific transport/TLS variants share the same transport crate identity;
  this fixed the H2 test trait/type mismatch.
- Added Zig I/O and safety module/test targets, an I/O native library, and the
  LZ4 wrapper/test.
- `build/bazel/sync-rust-deps.py` reads locked Cargo metadata and generates
  registry dependency specifications and local feature mappings. It supports
  `--check` and uses the original lockfile; it does not rewrite manifests.
- `origine_repl`, API proc macros, Rusty V8/generated bindings, the native
  aggregate, and the main Zig module graph are not yet migrated.

### Commands and justfile

Homebrew Bazelisk is installed. `.bazelversion` selects Bazel 8.4.2. The `justfile` keeps every
Zig build recipe (`build`, `run`, `test`, `check`, ...) and adds, prefixed `bazel-`:

- `just bazel-patch-v8`, `just bazel-build-v8`.
- `just bazel-test-bootstrap`, `just bazel-test-io`, `just bazel-test-core`, `just bazel-test-net`,
  `just bazel-test-oxc`, and `just bazel-test-lto`.
- `just bazel-sync-rust-deps` and `just bazel-check-rust-deps`.
- `just bazel-bump-v8 <version>`.

Application build/run and the full runtime checks stay on the Zig recipes until cutover.
There is no `//:origine`, `//:origine-snapshot`, `//:deps`, or complete root test
suite yet. Do not document these as working commands.

## Verification completed

| Check | Result and scope |
| --- | --- |
| Homebrew Bazelisk | Selected/downloaded Bazel 8.4.2 successfully. |
| `just bazel-test-bootstrap` | All 8 targets passed through Homebrew Bazelisk: ThinLTO probe, LZ4, Rust allocator/core/fs/I/O, Zig I/O, Zig safety. |
| Networking | TLS, H2, and DNS tests passed together; transport test also passed separately. |
| OXC | Its Bazel test passed. |
| Native libraries | AWS-LC crypto and nghttp2 builds passed; libc++/libc++abi archives built. Full V8 linkage remains unverified. |
| Rust dependency metadata | Generator `--check` passed. |
| Local disk cache | A separate fresh output base restored 38 bootstrap actions from disk cache, with no spawned build/test actions. This predates later graph edits and covers only bootstrap targets. |
| Recipe hygiene | `just --list`, recipe dry runs, `just --fmt --check`, and whitespace checks passed. |
| Existing binary smoke test | Existing `zig-out/bin/origine` ran `examples/io/timers/init.js` with a temporary runtime cache. This is not a Bazel-built application. |

Temporary logs currently available on this machine:

- `/private/tmp/origine-just-bootstrap.log`: all 8 bootstrap tests passed.
- `/private/tmp/origine-net-bazel.log`: TLS, H2, and DNS passed.
- `/private/tmp/origine-v8-bazel.log`: latest V8 failure.

These temporary files are diagnostic conveniences, not durable acceptance
artifacts. The existing binary measured 89,528,632 bytes; it is a debug baseline,
not a small-release budget measurement. A complete baseline of tests, startup,
configuration, and release size has not yet been captured.

## Dependency pins (revised 2026-11-04, branch `bazel-cleanup`)

Every external pin is written once, in `MODULE.bazel`. The earlier `pins.py` derived them from
`build.zig.zon` and `lib/v8_zig/build/v8.build.zig`, which made the Bazel build depend on the Zig build it
replaces (those files go away at cutover). It, `pins.bzl`, `toolchains.MODULE.bazel`, the `deps.bzl`
extension, `repositories.bzl`, `icu_rules.bzl` and `platform_config.bzl` are removed.

| Pin | Where, and how it moves |
| --- | --- |
| V8, ICU, libc++, libc++abi, LLVM libc, buildtools, dragonbox, fp16, fast_float, simdutf; the Clang bundle | `git_source`/`http_archive` in `MODULE.bazel`. `just bazel-bump-v8 <version>` (`build/bazel/bump_v8.py`, a uv script) rewrites every `chromium.googlesource.com/<repo>@<commit>` there from V8's `DEPS` at that tag, and the Clang URL and digest. Run against 15.8.30 it leaves the file unchanged. |
| Rust toolchain and digests | `rust.toolchain` in `MODULE.bazel`; keep it in step with `rust/rust-toolchain.toml` (Cargo still uses it). |
| Zig, lz4, mimalloc, nghttp2, `temporal_capi` headers | Literal in `MODULE.bazel`. During migration the Zig build still pins its own copies. |
| `aws-lc-sys` symbol prefix | Literal in `lib/aws-lc/aws-lc-sys/BUILD.bazel`, next to the vendored crate it names. |
| Registry crates and features | `rust/Cargo.lock` through `sync-rust-deps.py` (unchanged). |

`git_source` (`build/bazel/git_source.bzl`) is the one custom fetch rule: Git checkouts by commit, then
patch series applied in name order from workspace directories, which it watches (`watch_tree`), so the
submodule patch directories need no `BUILD.bazel`. V8 fetches its own `third_party/llvm-libc/src` at the DEPS
commit instead of symlinking into `@libcxx`. ICU's upstream `BUILD.bazel` files under `source/` are removed and
one root `icu.BUILD.bazel` builds the libraries. `just bazel-patch-v8` is `bazel fetch --repo=@v8` and prints the path.

### V8 overlay patch (revised 2026-11-04)

`build/bazel/patches/v8/` holds the overlay series (`0001-bazel-overlay`, `0002-cppgc-caged-heap`,
`0003-mksnapshot-icu`). Removed from it:

- Changed flag defaults: `.bazelrc` sets `--@v8//:v8_use_metagen=false` and
  `--@v8//:v8_typed_array_max_size_in_heap=0`.
- The ThinLTO `select` in `defs.bzl`: the repository writes `REPO.bazel` with
  `repo(features = ["origine_thin_lto"])`, and the toolchain feature `requires` `opt`.
- The mksnapshot `--icu-data-file` hunks, which `0003` replaced anyway.

Checked with `bazel aquery --config=fast 'deps(@v8//:icu/v8)'` before and after (normalizing repository and
configuration names): the same 9,318 actions with identical command lines, except ICU objects moving package
and V8's `simdutf` (a plain `cc_library` the macro never reached) now getting `-flto=thin` in opt. The fetched
V8, ICU and libc++ trees are byte-identical apart from the overlay lines above. No compile was run: the
`.bazelrc` V8 flags change the configuration hash, so the next build recompiles everything once.

### Review of earlier decisions

- **googlesource `+archive` digests were wrong.** Those tarballs differ byte-for-byte per download
  (verified: three fetches, three digests, also after decompression). The old pins only worked from a warm
  repository cache and would fail on a clean machine or CI. Sources are now fetched with Git at the commit
  DEPS names (`<repository>@<commit>`); Git verifies content. A clean fetch of V8 plus patches takes under a minute.
- **`crate_universe` `from_cargo` was tried and does not work**: it splices the workspace into a temporary
  directory, so the `../lib/v8_zig/rusty_v8` and `../lib/aws-lc` path dependencies stop resolving. Generated
  specs from `Cargo.lock` stay, but are derived, checked (`--check`) and regenerated by one command.
- **Toolchain flags.** Target triple, CPU and SDK now live in `platform.bzl`; the LLVM major version comes from
  the pin (no `clang/24`, no `llvm24` identifiers); libc++ defines and language modes exist once in
  `cxx_runtime.bzl`, read by both the toolchain and the runtime targets; `-Os` moved from the lz4 target to
  `--config=small`. The deployment floor (`15.0`) is in `platform_config.bzl` and overridable with
  `MACOSX_DEPLOYMENT_TARGET`.
- **Inspector generator blocker fixed.** The patch passed `$(execpath ...)/..` as `--inspector_protocol_dir`, but
  the generator uses that value only as the logical include prefix (`.crdtp.dir`) and finds its templates
  from its own location. The patch keeps the original `third_party/inspector_protocol`; generated headers now
  include `third_party/inspector_protocol/crdtp/...`. 
- **`@v8//:icu/v8` now builds** (`just bazel-build-v8`, ~6,180 actions, from a clean fetch). Two more gaps in upstream's
  Bazel overlay were fixed with small patches (`v8-cppgc-caged-heap.patch` adds the caged-heap sources GN compiles
  but `BUILD.bazel` omits; `v8-mksnapshot-icu.patch` runs mksnapshot with `icudtl.dat` beside it, as V8 expects).
  Upstream's `BUILD.bazel` is not kept at parity with `BUILD.gn`; compare their source lists on every V8 bump.

### Still hardcoded, deliberately or not yet fixed

- libc++ hardening mode is `EXTENSIVE` for every configuration; Chromium selects it by build mode.
- Zig and Rust objects target the host's default macOS version (27.2 in the probe), not the 15.0 floor
  the C/C++ toolchain uses. Pass the target to rules_zig and rustc before cutover.
- `highway` and `abseil-cpp` come from the Bazel Central Registry (1.2.0, 20250814.1), not V8's DEPS
  revisions (`third_party/highway` `2607d3b…`, abseil `c9aa3ac…`). Decide whether to pin to DEPS.
- Third-party library flags (`mimalloc`, `nghttp2` `HAVE_*`, ICU, AWS-LC defines) are copied from the Zig
  build files and V8/AWS-LC sources, not derived. They are in BUILD files next to the targets.
- `bazel_dep` versions and the `rules_zig`/`highway` patches are ordinary Bzlmod pins.

## Remaining work and acceptance gates

1. Complete baseline capture without disturbing existing worktree changes.
2. Fix and finish the full V8 graph: generators, ICU, Temporal, Wasm, sandbox,
   debug V8, builtins/PGO, profile integrity and mismatch rejection, and any
   missing dependencies/configuration parity.
3. Re-run the full V8 compile after the inspector fix and fix what remains. Generate a shared compiler manifest from actual Bazel C/C++ inputs for Rust
   bindgen and Zig layout generation. Remove GN-derived binding requirements.
4. Port Rusty V8, C++ shims, API macros, REPL/API crates, native aggregate, main
   Zig modules, and all reusable generators.
5. Implement typed feature/compression settings with existing defaults and
   validation, including QUIC requiring TLS.
6. Implement snapshotter → blob → provider-object dependencies, the explicit
   default seed `0x3c3d6918`, and independent main compilation.
7. Implement one final `ld64.lld` release ThinLTO link preserving Zig bitcode,
   required exports, allocator ownership, Rust runtime, and TLS correctness.
   Keep debug safety/native-object behavior.
8. Add public application/snapshot/dependency targets and complete test/check
   suites. Build and run all four configurations from fresh output bases.
9. Run managed-runtime, V8 bindings, I/O, allocator, networking, REPL, contract,
   generated-file, formatting, type, Clippy, and existing Miri checks. Miri has
   a recipe but has not been validated as part of this migration checkpoint.
10. Save production ThinLTO evidence showing Zig, Rust, and V8/C++ modules in
    addition to the controlled optimization probe.
11. Validate unchanged rebuilds execute no compilation, snapshot generation,
    or link actions. Test targeted invalidation for Zig, Rust, V8 patches,
    bindings, profiles, SDK identity, and snapshot seeds; repeat separate-output
    disk-cache restoration for the full application.
12. Add repository ZLS/rust-analyzer launchers, generate editor metadata, and
    verify Zed navigation, completion, diagnostics, generated imports, proc
    macros, and refresh after settings changes.
13. Measure small release against 70 MB and investigate startup regressions
    against the captured baseline.
14. After every gate passes, finish the justfile/docs cutover, update
    `docs/BUILD.md` and `docs/build-graph.md`, and remove obsolete Zig/GN/Ninja/
    depot_tools orchestration. Preserve Cargo manifests, reusable generators,
    and patch-maintenance tooling.

## Notes for resuming implementation

- Primary build definitions live under `build/bazel/`; prefer extending upstream
  targets over adding wrappers/macros without a concrete need.
- `rules_zig` already supports `emit_bin = False`, `emit_llvm_bc = True`, and
  `compiler_runtime = "include"` for static libraries. A new custom Zig object
  rule is likely unnecessary. Its `llvm_bc` output group can feed conversion
  through pinned Clang and then the final C/C++ link.
- Zig's libc-backed `main` can be exported from a library root containing
  `main`; confirm this behavior in the actual application graph.
- Clang's converted ThinLTO input should have an `.o` suffix; `.bc` caused it
  to be reprocessed during the probe link. Consistent Apple M1 target CPU flags
  were needed for the probe's cross-language inlining.
- Keep the build-tool Temporal Rust static library separate from the eventual
  runtime Rust aggregate to avoid duplicate Rust runtimes in one executable.
- C++ binding sources have relative include assumptions from the old staged V8
  checkout. Recreate or adjust those assumptions with declared Bazel inputs.
- Reuse the existing repository cache/distdir rather than downloading compiler
  distributions into a new user root for every test. Temporary locations used:
  `/private/tmp/origine-dist`, `/private/tmp/origine-bazel-user/cache/repos/v1`,
  and `/private/tmp/origine-bazel-disk-cache`.
- Temporary V8 output user root: `/private/tmp/origine-bazel-v8-user`.
  Bootstrap used `/private/tmp/origine-bazel-user`. Availability of these paths
  is machine-local and not required for a clean build.

This checkpoint records partial evidence. A successful probe or library build
does not replace the full migration acceptance gates.

## Status at 2026-11-04

Done since the first checkpoint:

- Pins: first derived by `pins.py`, then (branch `bazel-cleanup`) moved into `MODULE.bazel` with
  `just bazel-bump-v8` (see "Dependency pins").
- Git-by-commit fetches replace googlesource tarball digests (those are not byte-stable).
- Toolchain values centralized (`platform.bzl`, `cxx_runtime.bzl`); the Clang resource directory is found from its headers.
- V8 builds: inspector generator fixed, caged-heap sources added, mksnapshot given its ICU data
  (now `build/bazel/patches/v8/`).
- Verified: `just bazel-test-bootstrap` (8/8) before the V8 patches; `bazel build --config=fast @v8//:icu/v8` succeeds
  (~6,180 actions). Not verified after the V8 patches: networking/OXC tests, the bootstrap suite.

Open decisions and risks:

- Keep the custom libc++ overlay (`libcxx.BUILD.bazel`, mirrors GN `use_custom_libcxx`) or use the SDK's libc++?
- Add a check comparing V8's `BUILD.gn` and `BUILD.bazel` source lists (upstream drifts; caged-heap hit it).
- Zig/Rust objects target the host macOS (27.2 seen), not the 15.0 floor of the C/C++ toolchain.
- libc++ hardening is `EXTENSIVE` in all configurations; highway/abseil come from the BCR, not V8's DEPS revisions.
- Nothing is committed. Changes live in the main checkout (not in the `bazel-migration-progress-b7c7c7` worktree);
  `lib/aws-lc` and `lib/v8_zig` BUILD files are untracked inside their submodules.

Next: link `//:origine` pieces (Rusty V8 and bindings, native aggregate, main Zig modules), snapshotter -> blob ->
provider object, release ThinLTO link; then the remaining gates below.
