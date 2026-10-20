/* C ABI of the Rust `origine_api` crate (guest API natives written against the `v8` crate), linked
 * from liborigine_native. Zig (src/api/host.zig) calls it; the semantics are in
 * docs/async-host-contract.md.
 *
 * CONTRACT (docs/contracts.md, surfaces B and C): this header is the source of truth.
 *   - Rust: rust/crates/origine_api/src/abi_gen.rs is generated from it (`just gen-contracts`) and
 *     lib.rs / registry.rs use its structs and must define its functions with these exact
 *     signatures (compile-time checked).
 *   - Zig: src/api/api_abi.zig declares the same structs and prototypes; `just check-contracts`
 *     compiles a generated C file (src/api/api_abi_check.c) against this header with clang.
 * Generator rules: name every function parameter; keep one declaration per line. */
#ifndef ORIGINE_API_H
#define ORIGINE_API_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* What the embedder allows (`origine_api_configure`). */
typedef struct origine_api_cfg {
  uint32_t max_runtimes;
  uint32_t backends_mask; /* bit 1 << k allows io backend kind k (1 uring, 2 kqueue, 4 threaded) */
  uint32_t default_entries;
  int32_t fs_root_fd; /* a directory descriptor the Rust side duplicates; -1 = no fs */
  uint8_t fs_write;
  uint8_t fs_async;
} origine_api_cfg;

/* What V8 may assume about a native (mirrors binding.SideEffect in src/api/binding.zig). */
enum origine_api_side_effect { ORIGINE_API_SIDE_NONE = 0, ORIGINE_API_SIDE_RECEIVER = 1, ORIGINE_API_SIDE_ANY = 2 };

/* When a native is installed: always, only with an io runtime configured, or only with async fs. */
enum origine_api_needs { ORIGINE_API_NEEDS_NONE = 0, ORIGINE_API_NEEDS_RUNTIME = 1, ORIGINE_API_NEEDS_ASYNC_FS = 2 };

/* A v8::FunctionCallback: the argument is `const v8::FunctionCallbackInfo *`. */
typedef void (*origine_api_callback)(const void *info);

/* One guest-visible native. `path` is "namespace.name" (static, NUL-terminated); Zig installs
 * `callback` as `native.<namespace>.<name>`. */
typedef struct origine_api_native {
  const char *path;
  origine_api_callback callback;
  uint32_t side_effect; /* enum origine_api_side_effect */
  uint32_t needs;       /* enum origine_api_needs */
} origine_api_native;

/* The natives registry. Written as `#[native(path = "...")]` in Rust; Zig installs whatever it lists. */
size_t origine_api_natives_count(void);
/* Fills `out` with entry `index` (< count); returns 0, or -1 when out of range. */
int origine_api_natives_get(size_t index, origine_api_native *out);

/* Attaches the Rust per-isolate state to a live isolate; false when already attached. */
bool origine_api_attach_isolate(void *isolate);
/* Drops it; call before the isolate is disposed. */
void origine_api_detach_isolate(void *isolate);
/* Sets the ceilings and the fs root of the attached Host (once, after attach). `cfg` is read. */
void origine_api_configure(void *isolate, const origine_api_cfg *cfg);
/* Waits for work and runs it; returns the number of live items or -1 on error. timeout_ns < 0 =
 * forever (still returns on origine_api_wake). */
int64_t origine_api_poll(void *isolate, uint8_t block, int64_t timeout_ns);
/* 1 when any runtime has live tasks or ops, or a promise waits to settle. */
uint8_t origine_api_has_work(void *isolate);
/* An fd that becomes readable when poll(block = 0) would progress; -1 when there is none. */
int64_t origine_api_pollable(void *isolate);
/* Interrupts a blocking origine_api_poll. Thread-safe. */
void origine_api_wake(void *isolate);

#ifdef __cplusplus
}
#endif
#endif
