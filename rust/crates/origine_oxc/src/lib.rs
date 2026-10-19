//! TypeScript / JSX to JavaScript for origine, behind a small C ABI (include/origine_oxc.h).
//! Pipeline: parse, semantic analysis, oxc transformer (TypeScript + JSX, no downleveling),
//! codegen. Every entry point is panic-safe: a panic becomes `ORIGINE_OXC_INTERNAL_ERROR`.

use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;

use oxc_allocator::Allocator;
use oxc_codegen::{Codegen, CodegenOptions, CodegenReturn};
use oxc_diagnostics::OxcDiagnostic;
use oxc_parser::Parser;
use oxc_semantic::SemanticBuilder;
use oxc_span::SourceType;
use oxc_transformer::{JsxRuntime, TransformOptions, Transformer};

const ABI_VERSION: u32 = 1;
const STATUS_OK: u32 = 0;
const STATUS_SYNTAX_ERROR: u32 = 1;
const STATUS_INTERNAL_ERROR: u32 = 2;

const FLAG_JSX_DEVELOPMENT: u32 = 1 << 0;
const FLAG_VERBATIM_IMPORTS: u32 = 1 << 1;
const FLAG_INLINE_SOURCE_MAP: u32 = 1 << 2;

/// Mirrors `OxcOptions` in include/origine_oxc.h.
#[repr(C)]
pub struct OxcOptions {
    jsx_runtime: u32,
    flags: u32,
    import_source: *const u8,
    import_source_len: usize,
    pragma: *const u8,
    pragma_len: usize,
    pragma_frag: *const u8,
    pragma_frag_len: usize,
}

/// Mirrors `OxcResult`; the C side sees only the leading fields. `owned` keeps the buffers
/// the pointers refer to alive until `origine_oxc_result_free`.
#[repr(C)]
pub struct OxcResult {
    status: u32,
    code: *const u8,
    code_len: usize,
    diagnostics: *const u8,
    diagnostics_len: usize,
    owned: Box<Owned>,
}

struct Owned {
    code: Vec<u8>,
    diagnostics: Vec<u8>,
}

impl OxcResult {
    fn new(status: u32, code: String, diagnostics: String) -> *mut OxcResult {
        let owned = Box::new(Owned { code: code.into_bytes(), diagnostics: diagnostics.into_bytes() });
        Box::into_raw(Box::new(OxcResult {
            status,
            code: owned.code.as_ptr(),
            code_len: owned.code.len(),
            diagnostics: owned.diagnostics.as_ptr(),
            diagnostics_len: owned.diagnostics.len(),
            owned,
        }))
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn origine_oxc_abi_version() -> u32 {
    ABI_VERSION
}

/// # Safety
/// `source` and `filename` must be valid for `*_len` bytes, `options` null or valid, and all
/// borrowed only for this call. The result must be released with `origine_oxc_result_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_oxc_transform(
    source: *const u8,
    source_len: usize,
    filename: *const u8,
    filename_len: usize,
    options: *const OxcOptions,
) -> *mut OxcResult {
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller guarantees the pointers and lengths (see above).
        let (source, filename) = unsafe { (bytes(source, source_len), bytes(filename, filename_len)) };
        let options = unsafe { options.as_ref() };
        match (std::str::from_utf8(source), std::str::from_utf8(filename)) {
            (Ok(source), Ok(filename)) => transform(source, filename, options),
            _ => Err(String::from("input is not valid UTF-8")),
        }
    }));
    match outcome {
        Ok(Ok(code)) => OxcResult::new(STATUS_OK, code, String::new()),
        Ok(Err(diagnostics)) => OxcResult::new(STATUS_SYNTAX_ERROR, String::new(), diagnostics),
        Err(_) => OxcResult::new(STATUS_INTERNAL_ERROR, String::new(), String::from("internal error: the transformer panicked")),
    }
}

/// # Safety
/// `result` must come from `origine_oxc_transform` and not have been freed already.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_oxc_result_free(result: *mut OxcResult) {
    if !result.is_null() {
        // SAFETY: allocated by `OxcResult::new` through `Box::into_raw`, freed exactly once.
        drop(unsafe { Box::from_raw(result) });
    }
}

/// # Safety
/// `ptr` must be valid for `len` bytes when `len > 0`.
unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if len == 0 { &[] } else { unsafe { std::slice::from_raw_parts(ptr, len) } }
}

fn text(ptr: *const u8, len: usize) -> Option<String> {
    // SAFETY: option strings are valid for the call, per the header.
    let raw = unsafe { bytes(ptr, len) };
    if raw.is_empty() { None } else { std::str::from_utf8(raw).ok().map(str::to_owned) }
}

/// Ok(js) or Err(rendered diagnostics).
fn transform(source: &str, filename: &str, options: Option<&OxcOptions>) -> Result<String, String> {
    let path = Path::new(filename);
    let Ok(source_type) = SourceType::from_path(path) else {
        return Err(format!("{filename}:1:1: error: unsupported file extension"));
    };
    // origine only runs ES modules.
    let source_type = source_type.with_module(true);

    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, source, source_type).parse();
    if !parsed.diagnostics.is_empty() {
        return Err(render(filename, source, parsed.diagnostics.into_iter()));
    }
    let mut program = parsed.program;

    let semantic = SemanticBuilder::new()
        .with_check_syntax_error(true)
        .with_excess_capacity(2.0)
        .with_enum_eval(true)
        .build(&program);
    if !semantic.diagnostics.is_empty() {
        return Err(render(filename, source, semantic.diagnostics.into_iter()));
    }
    let scoping = semantic.semantic.into_scoping();

    let mut transform_options = TransformOptions::default();
    let mut inline_source_map = false;
    if let Some(options) = options {
        let jsx = &mut transform_options.jsx;
        jsx.runtime = if options.jsx_runtime == 1 { JsxRuntime::Classic } else { JsxRuntime::Automatic };
        jsx.development = options.flags & FLAG_JSX_DEVELOPMENT != 0;
        jsx.import_source = text(options.import_source, options.import_source_len);
        jsx.pragma = text(options.pragma, options.pragma_len);
        jsx.pragma_frag = text(options.pragma_frag, options.pragma_frag_len);
        transform_options.typescript.only_remove_type_imports = options.flags & FLAG_VERBATIM_IMPORTS != 0;
        inline_source_map = options.flags & FLAG_INLINE_SOURCE_MAP != 0;
    }

    let transformed = Transformer::new(&allocator, path, &transform_options).build_with_scoping(scoping, &mut program);
    if !transformed.diagnostics.is_empty() {
        return Err(render(filename, source, transformed.diagnostics.into_iter()));
    }

    let CodegenReturn { code, map, .. } = Codegen::new()
        .with_options(CodegenOptions { source_map_path: inline_source_map.then(|| path.to_path_buf()), ..CodegenOptions::default() })
        .build(&program);
    Ok(match (inline_source_map, map) {
        (true, Some(map)) => format!("{code}//# sourceMappingURL={}\n", map.to_data_url()),
        _ => code,
    })
}

/// One `file:line:col: error: message` line per diagnostic (first label's position; 1:1
/// without labels). Columns count UTF-16 code units, like V8.
fn render(filename: &str, source: &str, diagnostics: impl Iterator<Item = OxcDiagnostic>) -> String {
    let mut out = String::new();
    for diagnostic in diagnostics {
        let offset = diagnostic.labels.iter().next().map_or(0, |label| label.offset() as usize);
        let (line, column) = position(source, offset);
        out.push_str(&format!("{filename}:{line}:{column}: error: {}\n", diagnostic.message));
    }
    out
}

/// 1-based line and UTF-16 column of the byte `offset`. Line terminators follow JavaScript:
/// `\n`, `\r\n`, lone `\r`, U+2028 and U+2029.
fn position(source: &str, offset: usize) -> (usize, usize) {
    let end = offset.min(source.len());
    let end = (0..=end).rev().find(|&at| source.is_char_boundary(at)).unwrap_or(0);
    let (mut line, mut column) = (1, 1);
    let mut chars = source[..end].chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                }
                line += 1;
                column = 1;
            }
            '\n' | '\u{2028}' | '\u{2029}' => {
                line += 1;
                column = 1;
            }
            _ => column += ch.len_utf16(),
        }
    }
    (line, column)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn positions_count_utf16_units_and_js_line_terminators() {
        assert_eq!(position("ab\ncd", 4), (2, 2));
        assert_eq!(position("a😀b", 5), (1, 4)); // the emoji is two UTF-16 units
        assert_eq!(position("a\r\nb", 3), (2, 1));
        assert_eq!(position("a\u{2028}b", 4), (2, 1));
    }

    #[test]
    fn strips_types_and_lowers_enums() {
        let js = transform("enum E { A = 1 }\nconst x: number = E.A;\nexport { x };", "a.ts", None).unwrap();
        assert!(!js.contains(": number"), "{js}");
        assert!(js.contains("E[E[\"A\"] = 1] = \"A\""), "{js}");
    }

    #[test]
    fn reports_syntax_errors_with_a_location() {
        let err = transform("const = 1;", "bad.ts", None).unwrap_err();
        assert!(err.starts_with("bad.ts:1:"), "{err}");
    }

    #[test]
    fn transforms_jsx_with_the_classic_runtime() {
        let options = OxcOptions {
            jsx_runtime: 1,
            flags: 0,
            import_source: std::ptr::null(),
            import_source_len: 0,
            pragma: b"h".as_ptr(),
            pragma_len: 1,
            pragma_frag: std::ptr::null(),
            pragma_frag_len: 0,
        };
        let js = transform("export const a = <div id=\"x\" />;", "a.tsx", Some(&options)).unwrap();
        assert!(js.contains("h(\"div\""), "{js}");
    }
}
