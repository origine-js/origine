use std::slice;
use swc_next_allocator::Allocator;
use swc_next_ecma_ast::{Lang, SourceType};
use swc_next_ecma_parser::{CommentMode, NoTokenParserConfig, Options, Parser};
use swc_next_ecma_semantic::{AnalyzeOptions, SyntaxChecks, analyze};
use swc_next_ecma_transformer::{
    normalize::Normalizer,
    typescript::{self, TypeScriptOptions},
};

/// Benchmark-only ABI: borrow UTF-8 input, allocate temporary AST/code, copy JS to caller storage.
/// Returns output byte count; -1 means syntax/semantic error, -4 means insufficient output capacity.
/// JSX is preserved by the upstream pipeline and must be rejected by a downstream JS validator.
/// # Safety
/// Input must be valid UTF-8 of `len` bytes; output must be writable for `cap` bytes, without overlap.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bench_transform(
    src: *const u8,
    len: usize,
    kind: u32,
    out: *mut u8,
    cap: usize,
) -> i64 {
    let source = unsafe { std::str::from_utf8_unchecked(slice::from_raw_parts(src, len)) };
    let allocator = Allocator::new();
    let parsed = Parser::init(
        &allocator,
        source,
        Options {
            lang: match kind {
                0 => Lang::Ts,
                1 => Lang::Tsx,
                _ => Lang::Jsx,
            },
            source_type: SourceType::Module,
            comments: CommentMode::Flat,
            ..Default::default()
        },
        NoTokenParserConfig,
    )
    .parse();
    if !parsed.diagnostics.is_empty() {
        return -1;
    }
    let mut ast = parsed.ast;
    Normalizer::normalize_runtime(ast.root_program(), &mut ast);
    let analyzed = analyze(
        &ast,
        AnalyzeOptions {
            check_syntax: SyntaxChecks::all(),
        },
    );
    if !analyzed.diagnostics.is_empty() {
        return -1;
    }
    if kind != 2 {
        typescript::transform(
            ast.root_program(),
            &mut ast,
            &analyzed.semantic,
            TypeScriptOptions {
                verbatim_module_syntax: true,
                ..Default::default()
            },
        );
    }
    let code = swc_next_ecma_codegen::print(
        &ast,
        swc_next_ecma_codegen::Options {
            comments: false,
            ..Default::default()
        },
    )
    .code;
    if code.len() > cap {
        return -4;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(code.as_ptr(), out, code.len());
    }
    code.len() as i64
}
