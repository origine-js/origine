# origine_alloc

Rust bindings for the mimalloc 3.6.0 that the Zig build links (`lib/mimalloc`), so Rust, Zig and V8
share one allocator in the process. The Zig bindings (`lib/mimalloc/src`) mirror this crate.

| Module | What it is |
|---|---|
| `sys` | The raw C ABI, grouped like `mimalloc.h`. Pure functions are declared `safe`. |
| `MiMalloc` | A `#[global_allocator]`. |
| `Heap`, `Theap` | `Heap`: a first-class heap, `Send + Sync` (any thread may allocate from it or free its blocks). Dropping one hands its live blocks to the main heap; `unsafe destroy` frees them all at once. `Theap`: the calling thread's part of a heap, `!Send`, for allocating without the thread-local lookup. |
| `ArenaId`, `reserve*` | Memory mimalloc allocates from beyond its own OS requests: reserved, huge pages, or a range someone else owns (the V8 sandbox). `unload` takes it back before the range is unmapped. |
| `Setting`, `Tuning` | Typed runtime options (`MIMALLOC_*`), and the ones upstream's performance guide names. `Tuning::apply` uses the `*_default` setters so an environment variable still wins. |
| `stats` | Process info, JSON statistics, printing. |

## Performance

Following upstream's [getting the best performance](https://github.com/microsoft/mimalloc#getting-the-best-performance):

* build flags: `lib/mimalloc` compiles with `-Dopt_arch` (MI_OPT_ARCH) by default;
* `MiMalloc` takes the `*_small` entry points for blocks up to `SMALL_SIZE_MAX` (1 KiB on 64-bit) at word
  alignment, and the zeroing calls for `alloc_zeroed`;
* `Theap::current()` once per thread, then allocate through it, for code that keeps per-thread state;
* tune with `Tuning { large_os_pages, huge_os_pages, transparent_huge_pages, purge_delay_ms, reserve_bytes }`.

`dealloc` calls plain `mi_free`, not `mi_free_size`: the sized fast path treats `size <= SMALL_SIZE_MAX` as
"this block is in a small page", which `realloc` and in-place resizing do not preserve.

## Linking and tests

The crate declares the symbols and **links nothing itself**: the Zig build links the archive into the final
executable. `build.rs` makes the crate's own tests link it when `V8_ZIG_MIMALLOC` is set (exported by
`rust/scripts/cargo-v8.sh`), which turns on `cfg(mimalloc_linked)`; without it a bare `cargo test` skips the
tests that call mimalloc.

```sh
zig build test-alloc    # cargo test -p origine_alloc against the Zig-built mimalloc
zig build clippy        # the whole workspace, -D warnings
```

The option numbers (`Setting`) come from `mimalloc.h`; `lib/mimalloc/tests/abi.c` asserts them on the Zig
side at build time, and a test here pins a sample.

## Where it is installed

Only in the root crate `origine_native` (`rust/src/lib.rs`), `#[cfg(not(miri))]`; Miri cannot call foreign
allocators. Member crates never install it, so their `cargo test` runs use the system allocator.
