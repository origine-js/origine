//! Turns one REPL entry into something V8 can run, or says why not.
//!
//! The input is parsed as a TypeScript (or, without the `typescript` feature, JavaScript) module
//! first. When that works, types are erased and top-level `await` / `import` are rewritten into
//! an async function (`rewrite`). When it does not, sloppy-mode JavaScript that only a script can
//! express (`with`, legacy octal, ...) runs as written. Otherwise a parse error at the very end
//! of the input means the entry stops mid-construct and the REPL should read another line.

use oxc_allocator::Allocator;
use oxc_diagnostics::OxcDiagnostic;
use oxc_parser::Parser;
use oxc_span::SourceType;

use crate::rewrite;

#[cfg(feature = "typescript")]
pub const FILENAME: &str = "repl.ts";
#[cfg(not(feature = "typescript"))]
pub const FILENAME: &str = "repl.js";

/// Whitespace the REPL ignores at the end of its input.
const BLANKS: [char; 4] = [' ', '\t', '\r', '\n'];

#[derive(Debug, PartialEq, Eq)]
pub enum Prepared {
    Ready {
        /// What to run.
        code: String,
        /// The JavaScript before the async rewrite (what completion tracks as declared names).
        plain: String,
        /// `code` is an async function call whose promise must be awaited.
        asynchronous: bool,
    },
    /// The input stops mid-construct; the diagnostics are those of the parse error.
    Incomplete(String),
    /// Wrong input; `file:line:col: error: message` lines.
    Error(String),
}

struct Failure {
    diagnostics: String,
    /// The input stops mid-construct rather than being wrong.
    at_end: bool,
}

#[cfg(feature = "typescript")]
fn module_type() -> SourceType {
    SourceType::ts().with_module(true)
}

#[cfg(not(feature = "typescript"))]
fn module_type() -> SourceType {
    SourceType::mjs()
}

pub fn prepare(source: &str) -> Prepared {
    // A leading `{` is an object literal when that grammar parses, like plain JavaScript input.
    let trimmed = source.trim_matches(BLANKS);
    let literal = trimmed.starts_with('{').then(|| {
        let body = trimmed.strip_suffix(';').unwrap_or(trimmed);
        format!("({body}\n)")
    });
    if let Some(literal) = &literal
        && check(literal, module_type()).is_ok()
        && let Ok(prepared) = finish(literal)
    {
        return prepared;
    }
    let failure = match check(source, module_type()) {
        Ok(()) => match finish(source) {
            Ok(prepared) => return prepared,
            Err(diagnostics) => Failure { diagnostics, at_end: false },
        },
        Err(failure) => failure,
    };
    // Sloppy-mode JavaScript is not a module, but V8 runs it as a script.
    for candidate in literal.iter().map(String::as_str).chain([source]) {
        if check(candidate, SourceType::script()).is_ok() {
            let code = candidate.to_owned();
            return Prepared::Ready { plain: code.clone(), code, asynchronous: false };
        }
    }
    let script_at_end = check(source, SourceType::script()).is_err_and(|failure| failure.at_end);
    // `{a: 1,` may be the start of an object literal: judge it without a closing parenthesis.
    let literal_at_end = trimmed.starts_with('{') && check(&format!("({source}"), module_type()).is_err_and(|failure| failure.at_end);
    if failure.at_end || script_at_end || literal_at_end {
        Prepared::Incomplete(failure.diagnostics)
    } else {
        Prepared::Error(failure.diagnostics)
    }
}

/// Erases types, then rewrites top-level `await` and `import`. Err: the transformer's diagnostics.
fn finish(source: &str) -> Result<Prepared, String> {
    #[cfg(feature = "typescript")]
    let js = origine_oxc::erase_types(source, FILENAME, true)?;
    #[cfg(not(feature = "typescript"))]
    let js = source.to_owned();
    // A rewrite that does not parse falls through to the plain text, so V8 reports the error of
    // what the user typed.
    Ok(match rewrite::rewrite(&js) {
        Some(code) if check(&code, SourceType::script()).is_ok() => Prepared::Ready { code, plain: js, asynchronous: true },
        _ => Prepared::Ready { code: js.clone(), plain: js, asynchronous: false },
    })
}

fn check(source: &str, source_type: SourceType) -> Result<(), Failure> {
    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, source, source_type).parse();
    if parsed.diagnostics.is_empty() {
        return Ok(());
    }
    let end = source.trim_end_matches(BLANKS).len();
    let first = parsed.diagnostics.first();
    let offset = first.map_or(0, offset);
    // An unfinished comment or template is reported where it starts, not where the input ends.
    let unterminated = first.is_some_and(|d| {
        let message = d.message.to_lowercase();
        message.contains("unterminated") && (message.contains("comment") || message.contains("template"))
    });
    Err(Failure { diagnostics: render(source, parsed.diagnostics.into_iter()), at_end: offset >= end || unterminated })
}

fn offset(diagnostic: &OxcDiagnostic) -> usize {
    diagnostic.labels.iter().next().map_or(0, |label| label.offset() as usize)
}

/// One `file:line:col: error: message` line per diagnostic (first label's position; 1:1 without
/// labels). Columns count UTF-16 code units, like V8.
fn render(source: &str, diagnostics: impl Iterator<Item = OxcDiagnostic>) -> String {
    let mut out = String::new();
    for diagnostic in diagnostics {
        let (line, column) = position(source, offset(&diagnostic));
        out.push_str(&format!("{FILENAME}:{line}:{column}: error: {}\n", diagnostic.message));
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

    fn incomplete(source: &str) -> bool {
        matches!(prepare(source), Prepared::Incomplete(_))
    }

    fn code(source: &str) -> String {
        match prepare(source) {
            Prepared::Ready { code, .. } => code,
            other => panic!("{source:?}: {other:?}"),
        }
    }

    #[test]
    fn unfinished_javascript_asks_for_more() {
        assert!(incomplete("function add(a, b) {"));
        assert!(incomplete("({ answer:"));
        assert!(incomplete("`hello ${"));
        assert!(incomplete("/* unfinished comment"));
        assert!(incomplete("globalThis.probeCount = 1; if (true) {"));
        assert!(incomplete("{a:123,\nb:"));
        assert!(incomplete("const x = 1 +"));
        assert!(incomplete("class A {\n  m() {\n"));
        assert!(incomplete("import { a,"));
        assert!(incomplete("await foo("));
    }

    #[test]
    fn real_syntax_errors_are_reported_at_once() {
        for source in ["const bad = ; {", "'unterminated string", "{a: ,b:}", "let y: = 1"] {
            assert!(matches!(prepare(source), Prepared::Error(_)), "{source}: {:?}", prepare(source));
        }
        let Prepared::Error(text) = prepare("let = = 1") else { panic!() };
        assert!(text.starts_with(&format!("{FILENAME}:1:")), "{text}");
    }

    #[test]
    fn complete_input_is_ready() {
        assert!(matches!(prepare("const complete = 42; complete"), Prepared::Ready { asynchronous: false, .. }));
        assert!(matches!(prepare("persistent + 1"), Prepared::Ready { .. }));
        assert!(matches!(prepare(""), Prepared::Ready { .. }));
    }

    #[test]
    fn leading_brace_is_an_object_literal_first() {
        for source in ["{a:123,b:234}", "{a:123,b:234};", "{\na:123,\nb:234\n}"] {
            assert!(code(source).starts_with("({"), "{source}");
        }
        // Not an expression: a block.
        let block = code("{ executions++; executions; }");
        assert!(!block.starts_with("({"), "{block}");
    }

    #[test]
    fn sloppy_mode_javascript_runs_as_written() {
        assert_eq!(code("with (Math) { max(1, 2) }"), "with (Math) { max(1, 2) }");
        assert_eq!(code("010 + 1"), "010 + 1");
    }

    #[test]
    fn top_level_await_and_import_become_an_async_function() {
        let Prepared::Ready { code, plain, asynchronous } = prepare("const { a, b: [c] } = await load()\nc") else { panic!() };
        assert!(asynchronous);
        assert!(code.starts_with("(async () => {"), "{code}");
        assert!(code.contains("[\"a\",\"c\"]"), "{code}");
        assert!(code.contains("return (c)"), "{code}");
        assert!(!plain.starts_with("(async"), "{plain}");
        assert!(matches!(prepare("import fs from 'node:fs'"), Prepared::Ready { asynchronous: true, .. }));
        assert!(matches!(prepare("const f = async () => 1"), Prepared::Ready { asynchronous: false, .. }));
        assert!(matches!(prepare("await (x)"), Prepared::Ready { asynchronous: true, .. }));
    }

    #[test]
    fn positions_count_utf16_units_and_js_line_terminators() {
        assert_eq!(position("ab\ncd", 4), (2, 2));
        assert_eq!(position("a😀b", 5), (1, 4)); // the emoji is two UTF-16 units
        assert_eq!(position("a\r\nb", 3), (2, 1));
        assert_eq!(position("a\u{2028}b", 4), (2, 1));
    }

    #[cfg(feature = "typescript")]
    mod typescript {
        use super::*;

        #[test]
        fn types_are_erased_and_imports_kept() {
            let js = code("const x: number = 1 as number");
            assert!(js.contains("const x = 1"), "{js}");
            assert!(code("{ a: 1 as number }").starts_with("({"));
            assert!(code("import { unused } from './x.js'").contains("unused"));
            assert!(code("enum E { A = 1 }").contains("E[E[\"A\"] = 1]"));
        }

        #[test]
        fn unfinished_typescript_asks_for_more() {
            for source in ["function f(a: number) {", "const x: number = 1 +", "interface A {"] {
                assert!(incomplete(source), "{source}");
            }
            assert!(!incomplete("let y: = 1"));
        }

        #[test]
        fn awaiting_typed_code_is_rewritten_after_erasure() {
            let Prepared::Ready { code, .. } = prepare("const n: number = await f()") else { panic!() };
            assert!(code.contains("n = await f()"), "{code}");
            assert!(!code.contains(": number"), "{code}");
        }
    }
}
