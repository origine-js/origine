# origine_oxc

TypeScript / JSX to JavaScript for origine, behind a small C ABI. Built on the oxc crates
(`oxc_parser`, `oxc_semantic`, `oxc_transformer`, `oxc_codegen`, pinned `=0.155.0` in
`rust/Cargo.toml`). Optional in the staticlib: the root crate re-exports it under the default
`typescript` cargo feature (`zig build -Dtypescript=false` turns it off). Source: `src/lib.rs`;
header: `include/origine_oxc.h`. The Zig side that calls it is `src/api/transform/oxc.zig`.

## Pipeline

`origine_oxc_transform(source, filename, options)`:

1. Inputs must be valid UTF-8 (else `SYNTAX_ERROR` with "input is not valid UTF-8").
2. `SourceType::from_path(filename)` decides TS/TSX/JS/JSX; an unsupported extension is a
   syntax-error result `"<file>:1:1: error: unsupported file extension"`. The source is always
   treated as an **ES module** (`with_module(true)`).
3. Parse, then semantic analysis with syntax-error checking, then the oxc transformer
   (TypeScript and JSX; no downleveling), then codegen.
4. Any diagnostic stops the pipeline and is rendered as lines `file:line:col: error: message`
   (first label's position; `1:1` without labels; columns count UTF-16 code units and lines
   follow JS terminators `\n`, `\r\n`, `\r`, U+2028, U+2029).

## C ABI (`include/origine_oxc.h`)

```c
#define ORIGINE_OXC_ABI_VERSION 1u
uint32_t   origine_oxc_abi_version(void);
OxcResult *origine_oxc_transform(const uint8_t *source, size_t source_len,
                                 const uint8_t *filename, size_t filename_len,
                                 const OxcOptions *options);   /* options may be NULL */
void       origine_oxc_result_free(OxcResult *result);         /* NULL is fine */
```

* Inputs are borrowed for the call only. `origine_oxc_transform` never returns NULL; free every
  result with `origine_oxc_result_free` exactly once. All pointers inside an `OxcResult` are owned
  by it and valid until it is freed.
* The C struct `OxcResult` exposes only the leading fields; the Rust struct has a private owner
  field after them.
* Every entry point is wrapped in `catch_unwind`: a panic becomes status `INTERNAL_ERROR`.

### Statuses

| Constant | Value | `code` | `diagnostics` |
|---|---:|---|---|
| `ORIGINE_OXC_OK` | 0 | transformed module (UTF-8) | empty |
| `ORIGINE_OXC_SYNTAX_ERROR` | 1 | empty | `file:line:col: error: message` lines |
| `ORIGINE_OXC_INTERNAL_ERROR` | 2 | empty | "internal error: the transformer panicked" |

### Options (`OxcOptions`)

| Field | Meaning |
|---|---|
| `jsx_runtime` | `ORIGINE_OXC_JSX_AUTOMATIC` (0, default) or `ORIGINE_OXC_JSX_CLASSIC` (1; any other value acts as automatic) |
| `flags & ORIGINE_OXC_JSX_DEVELOPMENT` | development JSX transform |
| `flags & ORIGINE_OXC_VERBATIM_IMPORTS` | keep imports that only carry types (`only_remove_type_imports`) |
| `flags & ORIGINE_OXC_INLINE_SOURCE_MAP` | append `//# sourceMappingURL=data:...` with the map |
| `import_source` | JSX automatic runtime import source (UTF-8) |
| `pragma`, `pragma_frag` | classic runtime factory / fragment (UTF-8) |

String options: a NULL pointer or length 0 means "default"; non-UTF-8 text is ignored. With
`options == NULL` everything is default.

## Testing

Unit tests in `src/lib.rs` (positions, enum lowering, error locations, classic JSX) run with plain
cargo and under Miri: `cargo test -p origine_oxc`; Miri is part of `just check-rust`.
