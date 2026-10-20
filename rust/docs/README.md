# Rust workspace overview (`rust/`)

All Rust code of origine is one cargo workspace (`rust/Cargo.toml`, resolver 3, edition 2024) that
is built into **one static library**, `liborigine_native.a`, so the executable links a single Rust
runtime. The root package `origine_native` (`rust/src/lib.rs`) only re-exports the member crates
(`pub use origine_api::*;`, and `origine_oxc::*` under the `typescript` feature) so their
`#[unsafe(no_mangle)] extern "C"` items reach the archive, and installs the global allocator.

## Crates

| Crate | Docs | V8? | Miri? | Purpose |
|---|---|---|---|---|
| `origine_native` (root) | this page | via `origine_api` | no | staticlib; re-exports; installs `origine_alloc::MiMalloc` (`cfg(not(miri))`) |
| `origine_alloc` | [docs](../crates/origine_alloc/docs/README.md) | no | no (not used under Miri) | mimalloc `GlobalAlloc` |
| `origine_io` | [docs](../crates/origine_io/docs/README.md) | no | yes (mock of the C ABI) | op futures, `rt` runtime, `fs` over the Zig loop |
| `origine_api_core` | [docs](../crates/origine_api_core/docs/README.md) | no | yes | errno tables, arg rules, `NativeError`, handle tables, ceiling |
| `origine_api_macros` | [docs](../crates/origine_api_macros/docs/README.md) | no | yes | `#[native]`, `derive(FromJs/IntoJs)` |
| `origine_api_fs` | `crates/origine_api_fs/src/lib.rs` (crate docs) | no | capable, not in the `justfile` list | async fs `Grant` (handles + ops) over `origine_io::fs` |
| `origine_api` | [docs](../crates/origine_api/docs/README.md) | yes (`v8` fork) | no | V8 natives, Host state, C entry points |
| `origine_oxc` | [docs](../crates/origine_oxc/docs/README.md) | no | yes | TypeScript/JSX transform C ABI |

## Dependency graph

```
origine_native ──► origine_api ──► origine_api_macros ──► origine_api_core
      │               │  ├──────► origine_api_fs ───────► origine_api_core, origine_io
      │               │  ├──────► origine_api_core
      │               │  ├──────► origine_io            (calls the oio_* C ABI, from Zig)
      │               │  └──────► v8 (lib/v8_zig/rusty_v8, built against the Zig V8 archive)
      ├──► origine_alloc          (extern mi_* from the Zig-linked mimalloc)
      └──► origine_oxc  [feature `typescript`, default]  ──► oxc_* =0.155.0
```

Two external C ABIs: Rust calls Zig's `oio_*` (`src/io/c_api.zig`, header
`src/io/include/origine_io.h`; see [`src/io/docs`](../../src/io/docs/README.md)), and Zig calls
Rust's `origine_api_*` (including the natives registry) and `origine_oxc_*`.

## Toolchain

`rust/rust-toolchain.toml` pins `channel = "nightly-2026-10-19"` with components `rustfmt`,
`clippy`, `miri`, `rust-src` (Rust 1.101). Reasons from the file: Miri runs on the same toolchain
as the build, `!` is stable, the allocator API is stable, and Rust's LLVM (23.1.x) has the same
major version as V8's bundled clang (23); the staticlib is linked as native code, so cross-language
LTO is not used. Bump deliberately:
`rustup toolchain install nightly-YYYY-MM-DD -c rustfmt -c clippy -c miri -c rust-src`. Formatting:
`rust/rustfmt.toml` (`max_width = 140`, `use_small_heuristics = "Max"`).

Release profile: `lto = "thin"`, `opt-level = "z"` (size first), `codegen-units = 16`,
`strip = true`, `panic = "unwind"` (the natives and tasks rely on `catch_unwind`). Hot-path crates
(oxc parser/semantic/transformer/traverse/codegen/ast/allocator/span/str/syntax/ecmascript/...,
`memchr`) override to `opt-level = 3`.

## Lints policy

`[workspace.lints]` (every crate has `[lints] workspace = true`), enforced by clippy with
`-D warnings`:

* `unsafe_op_in_unsafe_fn = "deny"`;
* clippy `undocumented_unsafe_blocks` (every `unsafe` block needs a `// SAFETY:` comment),
  `missing_safety_doc` (every `pub unsafe fn` needs a `# Safety` section),
  `multiple_unsafe_ops_per_block` (one unsafe operation per block), `unnecessary_safety_comment`,
  `unnecessary_safety_doc`.

Prefer pushing logic into V8-free crates so Miri can check it, and keep `unsafe` small and local.

## Checking

| Command | What |
|---|---|
| `just check` | `check-rust` + `check-format` |
| `just check-rust` | `zig build clippy -Dcargo-offline=true`, then `cd rust && MIRIFLAGS="-Zmiri-disable-isolation" cargo miri test --offline --locked -p origine_io -p origine_oxc -p origine_api_core -p origine_api_macros` |
| `just check-format` | `cargo fmt --all --check` (in `rust/`), oxfmt and oxlint over `bench examples src/js` |
| `just format` | apply formatters |

Clippy goes through Zig because the `v8` crate's build script needs the `V8_ZIG_*` environment
(`rust/scripts/cargo-v8.sh`); plain `cargo clippy --workspace` fails. Crates without V8 can use
plain cargo. Tests that call the real loop need `ORIGINE_IO_LIB` ([origine_io docs](../crates/origine_io/docs/testing.md)).

## How Rust links into the executable

1. `build.zig` `rustLibrary()` runs `cargo build --release --locked --target <triple>
   --target-dir rust/target` (through `cargo-v8.sh`, with `--no-default-features` when
   `-Dtypescript=false`) and copies `liborigine_native.a` (`origine_native.lib` on Windows MSVC)
   into the build cache. `crate-type = ["staticlib"]`.
2. **Partial link / symbol hiding.** The archive carries its own copy of Rust's `std`, which
   defines symbols (`rust_eh_personality`, ...) that V8's bundled Rust code also defines. So the
   whole archive is pre-linked into one relocatable object that exports **only** `origine_*`:
   * macOS: `clang -r -nostdlib -Wl,-exported_symbols_list,<list> -Wl,-all_load
     <archive> -o origine_native.o`. The list (and the Linux `objcopy --wildcard --keep-global-symbol=...`
     patterns) is generated by `build.zig` from `kept_symbol_prefixes` (`origine_*`, `crdtp__*`,
     `v8_inspector__*`); see docs/contracts.md surface F.
   * Linux: `ld -r --whole-archive` then `objcopy` with the same prefixes.
   * Other targets (Windows): the archive is linked as is.
3. Zig links `origine_native.o` with V8, mimalloc and the Zig modules. Because the exports lists
   are wildcards, a new `#[no_mangle] extern "C" fn origine_...` needs no list change; a symbol
   that does not start with `origine_` is not visible to Zig.
4. The Zig side must provide what Rust imports: `mi_*` (mimalloc), V8's C++ symbols, and the
   `oio_*` functions (the `@io` module's `c_api` is referenced from a `comptime` block so the
   `export fn`s are kept; see [async-host-contract](../../docs/async-host-contract.md) "Linking").
5. The vendored `v8` crate does not bundle libv8/mimalloc into the archive; Zig supplies them once.
   With `-Dprebuilt_v8_path` the Rust workspace cannot be built (no GN output for bindgen).

`rust/target/` is cargo's incremental state (gitignored); the step always runs and is cheap when
nothing changed.

## Adding a crate

Create it under `rust/crates/`, add it to `[workspace.dependencies]`, set `[lints] workspace =
true`, and re-export it from `rust/src/lib.rs` if it has C exports. If it must be Miri-checked add
it to the `-p` list of `check-rust` in the `justfile`. If it needs a Rust-side symbol hidden/visible
differently, update the exports handling in `build.zig`.
