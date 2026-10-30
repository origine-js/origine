use oxc_allocator::Allocator;
use oxc_codegen::{Codegen, CodegenOptions};
use oxc_parser::Parser;
use oxc_semantic::SemanticBuilder;
use oxc_span::SourceType;
use oxc_transformer::{JsxRuntime, TransformOptions, Transformer};
use std::{path::Path, slice};
/// Benchmark-only ABI; valid input/output pointers and lengths are required.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bench_transform(
    src: *const u8,
    len: usize,
    kind: u32,
    out: *mut u8,
    cap: usize,
) -> i64 {
    let source = unsafe { std::str::from_utf8_unchecked(slice::from_raw_parts(src, len)) };
    let filename = match kind {
        0 => "input.ts",
        1 => "input.tsx",
        _ => "input.jsx",
    };
    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, source, SourceType::from_path(filename).unwrap()).parse();
    if !parsed.diagnostics.is_empty() {
        return -1;
    }
    let mut program = parsed.program;
    let semantic = SemanticBuilder::new()
        .with_check_syntax_error(true)
        .with_enum_eval(true)
        .build(&program);
    if !semantic.diagnostics.is_empty() {
        return -1;
    }
    let mut options = TransformOptions::default();
    options.jsx.runtime = JsxRuntime::Classic;
    options.typescript.only_remove_type_imports = true;
    let transformed = Transformer::new(&allocator, Path::new(filename), &options)
        .build_with_scoping(semantic.semantic.into_scoping(), &mut program);
    if !transformed.diagnostics.is_empty() {
        return -2;
    }
    let code = Codegen::new()
        .with_options(CodegenOptions {
            comments: oxc_codegen::CommentOptions::disabled(),
            ..Default::default()
        })
        .build(&program)
        .code;
    if code.len() > cap {
        return -4;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(code.as_ptr(), out, code.len());
    }
    code.len() as i64
}
