//! The C ABI of rust/crates/origine_oxc as Zig sees it (std only, so `src/gen_contracts.zig` can
//! import it).
//!
//! CONTRACT (docs/contracts.md, surface E): `rust/crates/origine_oxc/include/origine_oxc.h` is
//! the source of truth. `just gen-contracts` writes `rust/crates/origine_oxc/include/zig_abi_check.c`
//! from the declarations below (layouts and prototypes as C `_Static_assert`s/declarations), and
//! `just check-contracts` compiles it against the header with clang: any difference in a struct
//! layout, a field type or a function prototype fails. The Rust side (`origine_oxc/src/lib.rs`)
//! is checked against the same header through the generated `header_abi.rs`.
//! Changing the ABI: edit the header, bump `ORIGINE_OXC_ABI_VERSION` and `abi_version` here and
//! in lib.rs, update the declarations here and in lib.rs, then `just gen-contracts`.

pub const abi_version = 1;

/// Mirrors `OxcOptions` in origine_oxc.h.
pub const COptions = extern struct {
    jsx_runtime: u32,
    flags: u32,
    import_source: ?[*]const u8,
    import_source_len: usize,
    pragma: ?[*]const u8,
    pragma_len: usize,
    pragma_frag: ?[*]const u8,
    pragma_frag_len: usize,
};

/// Mirrors the public prefix of `OxcResult`; the Rust side owns what the pointers refer to.
pub const CResult = extern struct {
    status: u32,
    code: ?[*]const u8,
    code_len: usize,
    diagnostics: ?[*]const u8,
    diagnostics_len: usize,
};

pub extern fn origine_oxc_abi_version() u32;
pub extern fn origine_oxc_transform(source: ?[*]const u8, source_len: usize, filename: ?[*]const u8, filename_len: usize, options: ?*const COptions) *CResult;
pub extern fn origine_oxc_result_free(result: *CResult) void;
