# mimalloc

mimalloc 3.6.0 built by the Zig build system, plus its Zig bindings. `zig build` here installs
`libmimalloc.a`; `lib/v8_zig` depends on this package and re-exports the `@mimalloc` module.

- `build.zig.zon` pins the upstream release (`source`).
- `patches/` is a unified-diff series applied, in order, to a copy of that source at build time by
  `tools/patch.zig` (a hunk that does not match exactly fails the build and names the file):
  - `0001-enable-arena-unload` turns on `mi_arena_unload` (upstream has it commented out). A heap's
    exclusive arena over external memory keeps its metadata inside that memory, so it must leave
    mimalloc before the memory is unmapped. V8 unmaps its sandbox at `V8.dispose`.
  - `0002-no-cache-for-arena-theaps` keeps the per-thread data of such heaps out of mimalloc's
    thread-local "last used" cache, which another thread could otherwise still point into the
    unmapped arena with.
- `src/` is the `@mimalloc` module (the Rust mirror is `rust/crates/origine_alloc`): `c.zig` the raw C
  ABI, `mimalloc.zig` the wrappers (`allocator`, `Heap`, `Theap`, `Arena`, `alloc`/`allocZeroed`/`allocSmall`,
  `processInfo`), `options.zig` the typed `Option` and `Tuning`, `stats.zig` statistics.
  `tests/abi.c` static-asserts the option numbers and size constants against `mimalloc.h`, so a version
  bump that renumbers an option fails `zig build test` instead of silently changing a setting.
- Performance, per upstream's "getting the best performance": built with `-Dopt_arch`; small blocks take
  the `*_small` path; zeroed memory comes from the zeroing calls; `Theap.default()` once per thread for
  runtimes with per-thread state; `Tuning` for large/huge pages, `purge_delay` and transparent huge pages.
  `freeSized` exists but is only valid for the exact allocation size, so the allocators use plain `free`.

Options: `-Dtarget`, `-Doptimize`, `-Dlto`. `zig build test` tests the patch tool.

To change a patch, edit a copy of the source (`zig fetch` prints where the cache holds it), write the
diff with `diff -u a/<path> b/<path>`, and keep the `a/`, `b/` prefixes.
