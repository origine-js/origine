// C ABI of the origine_oxc crate (TypeScript/JSX transform). Linked from liborigine_native.a.
// Ownership: every pointer in an OxcResult is owned by the result and valid until
// origine_oxc_result_free; inputs are borrowed for the duration of the call.
#ifndef ORIGINE_OXC_H
#define ORIGINE_OXC_H
#include <stddef.h>
#include <stdint.h>

#define ORIGINE_OXC_ABI_VERSION 1u

enum { ORIGINE_OXC_JSX_AUTOMATIC = 0, ORIGINE_OXC_JSX_CLASSIC = 1 };
enum {
  ORIGINE_OXC_JSX_DEVELOPMENT = 1u << 0,
  ORIGINE_OXC_VERBATIM_IMPORTS = 1u << 1,  // keep imports that only carry types
  ORIGINE_OXC_INLINE_SOURCE_MAP = 1u << 2  // append //# sourceMappingURL=data:...
};
enum { ORIGINE_OXC_OK = 0, ORIGINE_OXC_SYNTAX_ERROR = 1, ORIGINE_OXC_INTERNAL_ERROR = 2 };

typedef struct OxcOptions {
  uint32_t jsx_runtime;
  uint32_t flags;
  // UTF-8, ptr may be null (len 0) for "default".
  const uint8_t *import_source;
  size_t import_source_len;
  const uint8_t *pragma;
  size_t pragma_len;
  const uint8_t *pragma_frag;
  size_t pragma_frag_len;
} OxcOptions;

typedef struct OxcResult {
  uint32_t status;
  // status OK: the transformed module. Otherwise empty.
  const uint8_t *code;
  size_t code_len;
  // status SYNTAX_ERROR / INTERNAL_ERROR: "file:line:col: error: message" lines, UTF-8.
  const uint8_t *diagnostics;
  size_t diagnostics_len;
  // (the Rust side keeps private fields after these)
} OxcResult;

uint32_t origine_oxc_abi_version(void);
// Never returns null. Free with origine_oxc_result_free.
OxcResult *origine_oxc_transform(const uint8_t *source, size_t source_len,
                                 const uint8_t *filename, size_t filename_len,
                                 const OxcOptions *options);
void origine_oxc_result_free(OxcResult *result);
#endif
