# Building origine

`origine` is a Zig application embedding V8. The root package builds the shell;
`lib/v8_zig` is a local package that fetches, patches, and builds V8 and exposes the
`@v8`, `@engine`, `@managed`, `@util`, `@mimalloc`, and `@diagnostics` modules.

## Requirements

- Zig 0.17.0 and [uv](https://docs.astral.sh/uv/) (runs the Python build helpers)
- Git, rsync, and network access to GitHub, Chromium's source/toolchain servers, and
  pkg.lightpanda.io for the first build. No credentials are needed.
- macOS: Xcode or Command Line Tools. GN picks the SDK from `xcode-select` /
  `DEVELOPER_DIR`; do not pass an absolute `-Dmac_sdk_path`.
- Optional: [just](https://github.com/casey/just) for the shortcuts below.

The first build downloads depot_tools and V8 15.2.124.1 into `lib/v8_zig/.lp-cache/`
and compiles V8: expect 20+ minutes. Later builds are incremental.

## Everyday commands

Run from the repository root.

```sh
zig build                  # build zig-out/bin/origine (debug app, release V8)
zig build run              # run the REPL (zig build run -- <args>)
zig build -Doptimize=small # small release app
zig build test             # V8 package tests
```

`just build`, `just run`, `just test` wrap the same commands.

## Release V8 by default

V8 is built in **release** mode for every application mode. `-Doptimize` only controls
the Zig executable; a debug V8 would make the shell slow. Release V8 uses ThinLTO and
omits unwind tables. On macOS, release app builds link with V8's matching `ld64.lld`
(ThinLTO, identical-code folding); debug app builds convert the V8 archive to native
objects, cached.

## Engine Patches

We patch the V8 Engine (e.g. V8, ICU, and PartitionAlloc)

Patches are applied by ordered series in
`lib/v8_zig/build-tools/patches/{v8,icu,partition_alloc}/`. Every `zig build`:

1. fetches V8 if missing,
2. syncs each checkout with its series (`scripts/apply-patches.sh`): only the first changed
   patch and those after it are reverted and reapplied,
3. runs `gn` and incremental `ninja`.

Nothing is copied or installed by hand: edit or add a patch and run `zig build`. A patch
that no longer applies stops the build and names the file. The V8 series currently
removes `Date` except `Date.now()` (Temporal replaces it), hardens the intrinsics, and
routes allocations through mimalloc; see `lib/v8_zig/build-tools/README.md`.

## Working on V8: debug V8

While changing V8 or its patches, use a debug V8 for quick incremental compiles:

```sh
zig build run -Dv8_debug=true     # or: just v8-dev
```

Debug and release V8 use separate GN output directories (`.lp-cache/v8-*/out/`), so
switching back and forth never rebuilds the other. Return to the default release V8 once
the change is done.

Editing loop:

```sh
zig build patch-v8                # fetch V8 and apply patches, no compile (just patch-v8)
# edit files in lib/v8_zig/.lp-cache/v8-15.2.124.1/
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
| `-Dprebuilt_v8_path=/abs/libv8_zig.a` | Skip building V8 and link an existing archive |
| `-Dcache_root=<dir>` | V8 / depot_tools checkout cache (default `lib/v8_zig/.lp-cache`) |
| `-Dv8_clang_dir=<llvm/bin>` | Override the matching LLVM toolchain |

`lib/v8_zig` additionally accepts `-Dthin_lto`, `-Dexclude_unwind_tables`,
`-Dtemporal`, `-Dsymbol_level`, `-Dis_asan`, `-Dis_tsan`, `-Dv8_enable_sandbox`,
`-Doptimize_for_size`, and `-Druntime_call_stats` (see `zig build --help` there). Each
distinct GN configuration gets its own output directory, named by a hash of its
arguments. `-Dtemporal=false` disables Temporal, leaving no date functionality beyond
`Date.now()`.

## Steps

| Step | Where | Purpose |
| --- | --- | --- |
| `run`, `shell` | root | Build and run the REPL |
| `build-shell` | root | Build and install the REPL |
| `test` | root, `lib/v8_zig` | Library tests |
| `patch-v8` | both | Fetch V8 and apply patches only |
| `build-v8` | `lib/v8_zig` | Build the V8 static library |
| `gen`, `check-generated`, `check-bindings` | `lib/v8_zig` | Regenerate / verify bindings |
| `test-icu-lazy` | `lib/v8_zig` | Deferred ICU loading, in a fresh process |

Run package-specific steps from `lib/v8_zig`. `lib/v8_zig` has its own `justfile`
(`just build`, `just dev`, `just patch`, `just new-patch`, `just test-dev`).

## Upgrading V8

1. Change `version` in `lib/v8_zig/build/v8.build.zig`.
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
