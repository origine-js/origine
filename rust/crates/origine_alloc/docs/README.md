# origine_alloc

`MiMalloc`, a `#[global_allocator]`-ready `GlobalAlloc` that forwards to mimalloc's `mi_*` API
(`mi_malloc_aligned`, `mi_zalloc_aligned`, `mi_realloc_aligned`, `mi_free`). Rust, Zig and V8 then
share one allocator implementation in the process. Source: `src/lib.rs` (about 50 lines).

## Linking

The crate declares the four `extern "C"` symbols and **links nothing itself**: the mimalloc static
library is built by the Zig build (`dep.artifact("mimalloc")` of the V8 dependency; it only defines
`mi_*`: libc `malloc` and the macOS malloc zones are not overridden) and is linked into the final
executable by Zig. For cargo builds that go through `rust/scripts/cargo-v8.sh` the archive path is
passed as `V8_ZIG_MIMALLOC` (consumed by the vendored `v8` crate's build script). Any binary or
test that installs `MiMalloc` as its global allocator must be linked with mimalloc, or it will
fail to link with undefined `mi_*` symbols.

## Where it is installed

Only in the root crate `origine_native` (`rust/src/lib.rs`):

```rust
#[cfg(not(miri))]
#[global_allocator]
static GLOBAL: origine_alloc::MiMalloc = origine_alloc::MiMalloc;
```

* Member crates (`origine_io`, `origine_api_core`, ...) never install it, so their `cargo test`
  runs use the system allocator and need no mimalloc.
* **Not under Miri**: Miri cannot call foreign allocators, hence the `cfg(not(miri))`.
* The static library carries Rust's own `std`; the allocator is process-wide for the Rust code in
  `liborigine_native.a`, including the `v8` crate's Rust side.

## Caveats

* Alignment: every method passes `layout.align()`; the `*_aligned` functions handle any power of
  two. Zero-sized allocations never reach the allocator (`GlobalAlloc` contract).
* `realloc` uses `mi_realloc_aligned` and preserves contents up to the smaller size; there is no
  `mi_usable_size` use, no statistics, no custom options.
* mimalloc is thread-safe; no extra locking here.
* Memory allocated by Rust must be freed by Rust (it comes from the same allocator, but handing
  Rust-allocated blocks to Zig/V8 or the reverse is not part of any interface here). V8 sandbox
  memory (ArrayBuffers) is separate and never exposed as Rust allocations
  ([origine_api buffers](../../origine_api/docs/README.md#buffers-and-copy-semantics)).
* There is no allocation-failure hook: on failure mimalloc returns null and std aborts via
  `handle_alloc_error`.
