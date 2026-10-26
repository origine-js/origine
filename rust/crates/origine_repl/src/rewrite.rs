//! Source that uses top-level `await` or static `import` becomes an async IIFE whose declarations
//! turn into global assignments (so they persist between evaluations) and whose last expression
//! is returned. The statements are found with the parser, not guessed from the text.

use oxc_allocator::Allocator;
use oxc_ast::ast::{
    ArrowFunctionExpression, AwaitExpression, Expression, ForOfStatement, Function, ImportDeclaration, ImportDeclarationSpecifier,
    Statement, VariableDeclaration,
};
use oxc_ast_visit::{Visit, walk};
use oxc_parser::Parser;
use oxc_span::{GetSpan, SourceType};
use oxc_syntax::operator::UnaryOperator;
use oxc_syntax::scope::ScopeFlags;

/// Finds `await` outside of any function.
struct TopLevelAwait(bool);

impl<'a> Visit<'a> for TopLevelAwait {
    fn visit_await_expression(&mut self, _: &AwaitExpression<'a>) {
        self.0 = true;
    }

    fn visit_for_of_statement(&mut self, it: &ForOfStatement<'a>) {
        self.0 |= it.r#await;
        walk::walk_for_of_statement(self, it);
    }

    fn visit_function(&mut self, _: &Function<'a>, _: ScopeFlags) {}

    fn visit_arrow_function_expression(&mut self, _: &ArrowFunctionExpression<'a>) {}
}

/// One statement of the rewritten body.
struct Part {
    start: u32,
    text: String,
    /// The statement's value is the result of the whole input.
    value: bool,
}

/// None when `source` needs no rewriting (no top-level `await`, no static `import`) or cannot
/// be rewritten.
pub fn rewrite(source: &str) -> Option<String> {
    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, source, SourceType::mjs()).parse();
    if !parsed.diagnostics.is_empty() {
        return None;
    }
    let program = &parsed.program;
    let mut awaits = TopLevelAwait(false);
    awaits.visit_program(program);
    let imports = program.body.iter().any(|statement| matches!(statement, Statement::ImportDeclaration(_)));
    if !awaits.0 && !imports {
        return None;
    }
    let mut names: Vec<String> = Vec::new();
    let mut parts: Vec<Part> = Vec::new();
    // Directive-looking statements (`"text"`) are values like any other expression.
    for directive in &program.directives {
        let span = directive.span;
        parts.push(Part { start: span.start, text: text(source, span).trim_end_matches(';').to_owned(), value: true });
    }
    for statement in &program.body {
        let span = statement.span();
        let whole = text(source, span).trim_end_matches([';', ' ', '\t', '\r', '\n']);
        let (text, value) = match statement {
            Statement::ImportDeclaration(declaration) => (import(source, declaration, &mut names)?, false),
            Statement::VariableDeclaration(declaration) => (declare(source, declaration, &mut names), false),
            Statement::FunctionDeclaration(function) => match &function.id {
                Some(id) => {
                    names.push(id.name.to_string());
                    (format!("void ({} = {whole})", id.name), false)
                }
                None => (whole.to_owned(), false),
            },
            Statement::ClassDeclaration(class) => match &class.id {
                Some(id) => {
                    names.push(id.name.to_string());
                    (format!("void ({} = {whole})", id.name), false)
                }
                None => (whole.to_owned(), false),
            },
            Statement::ExpressionStatement(expression) => {
                let is_void = matches!(&expression.expression, Expression::UnaryExpression(unary) if unary.operator == UnaryOperator::Void);
                (text(source, expression.expression.span()).to_owned(), !is_void)
            }
            _ => (whole.to_owned(), false),
        };
        parts.push(Part { start: span.start, text, value });
    }
    if parts.is_empty() {
        return None;
    }
    parts.sort_by_key(|part| part.start);
    let last = parts.len() - 1;
    if parts[last].value {
        parts[last].text = format!("return ({})", parts[last].text);
    }
    let mut body: Vec<String> = Vec::new();
    // Declarations become assignments to globals, which must exist first: scripts run strict.
    let mut unique: Vec<&str> = Vec::new();
    for name in &names {
        if !unique.contains(&name.as_str()) {
            unique.push(name);
        }
    }
    if !unique.is_empty() {
        let list = unique.iter().map(|name| json_string(name)).collect::<Vec<_>>().join(",");
        body.push(format!(
            "for (const name of [{list}]) if (!(name in globalThis)) Object.defineProperty(globalThis, name, {{ value: undefined, writable: true, configurable: true, enumerable: true }})"
        ));
    }
    body.extend(parts.into_iter().map(|part| part.text));
    Some(format!("(async () => {{\n{};\n}})()", body.join(";\n")))
}

fn text(source: &str, span: oxc_span::Span) -> &str {
    &source[span.start as usize..span.end as usize]
}

/// `const a = 1, {b} = o` becomes `void (a = 1, {b} = o)`; a declarator without a value gets
/// `undefined`, as `let x;` would.
fn declare(source: &str, declaration: &VariableDeclaration, names: &mut Vec<String>) -> String {
    let mut pieces = Vec::new();
    for declarator in &declaration.declarations {
        names.extend(declarator.id.get_binding_identifiers().iter().map(|id| id.name.to_string()));
        let piece = text(source, declarator.span);
        pieces.push(if declarator.init.is_some() { piece.to_owned() } else { format!("{piece} = undefined") });
    }
    format!("void ({})", pieces.join(", "))
}

/// `import a, { b as c } from "m"` becomes `void ({ default: a, b: c } = await import("m"))`.
fn import(source: &str, declaration: &ImportDeclaration, names: &mut Vec<String>) -> Option<String> {
    let specifier = text(source, declaration.source.span);
    let mut call = format!("await import({specifier}");
    if let Some(clause) = &declaration.with_clause {
        let clause = text(source, clause.span);
        call.push_str(&format!(", {{ with: {} }}", &clause[clause.find('{')?..]));
    }
    call.push(')');
    let mut bindings = Vec::new();
    let mut namespace = None;
    for specifier in declaration.specifiers.iter().flatten() {
        match specifier {
            ImportDeclarationSpecifier::ImportDefaultSpecifier(default) => {
                bindings.insert(0, format!("default: {}", default.local.name));
                names.push(default.local.name.to_string());
            }
            ImportDeclarationSpecifier::ImportSpecifier(named) => {
                let imported = text(source, named.imported.span());
                let local = named.local.name.as_str();
                bindings.push(if imported == local { local.to_owned() } else { format!("{imported}: {local}") });
                names.push(local.to_owned());
            }
            ImportDeclarationSpecifier::ImportNamespaceSpecifier(star) => {
                namespace = Some(star.local.name.to_string());
                names.push(star.local.name.to_string());
            }
        }
    }
    let destructure = bindings.join(", ");
    Some(match (namespace, bindings.is_empty()) {
        (Some(namespace), true) => format!("void ({namespace} = {call})"),
        (Some(namespace), false) => format!("void ({namespace} = {call}, ({{ {destructure} }} = {namespace}))"),
        (None, true) if declaration.specifiers.as_ref().is_none_or(|specifiers| specifiers.is_empty()) => format!("void {call}"),
        (None, _) => format!("void ({{ {destructure} }} = {call})"),
    })
}

fn json_string(text: &str) -> String {
    let mut out = String::from("\"");
    for ch in text.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            ch if ch < ' ' => out.push_str(&format!("\\u{:04x}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_without_await_or_import_is_left_alone() {
        assert_eq!(rewrite("1 + 1"), None);
        assert_eq!(rewrite("const f = async () => { await 1 }"), None);
        assert_eq!(rewrite("async function g() { for await (const x of y) {} }"), None);
        assert_eq!(rewrite(""), None);
        assert_eq!(rewrite("await ("), None, "unparseable input is not rewritten");
    }

    #[test]
    fn declarations_become_globals_and_the_last_expression_is_returned() {
        let wrapped = rewrite("const { a, b: [c] } = await load()\nc").unwrap();
        assert_eq!(
            wrapped,
            "(async () => {\nfor (const name of [\"a\",\"c\"]) if (!(name in globalThis)) Object.defineProperty(globalThis, name, { value: undefined, writable: true, configurable: true, enumerable: true });\nvoid ({ a, b: [c] } = await load());\nreturn (c);\n})()"
        );
    }

    #[test]
    fn declarators_without_values_and_named_declarations() {
        let wrapped = rewrite("let x, y = 1; function f() {} class K {} await x").unwrap();
        assert!(wrapped.contains("void (x = undefined, y = 1)"), "{wrapped}");
        assert!(wrapped.contains("void (f = function f() {})"), "{wrapped}");
        assert!(wrapped.contains("void (K = class K {})"), "{wrapped}");
        assert!(wrapped.contains("[\"x\",\"y\",\"f\",\"K\"]"), "{wrapped}");
        assert!(wrapped.contains("return (await x)"), "{wrapped}");
    }

    #[test]
    fn blocks_and_void_do_not_return_a_value() {
        let wrapped = rewrite("await 1; if (true) { 2 }").unwrap();
        assert!(!wrapped.contains("return"), "{wrapped}");
        let wrapped = rewrite("await 1; void 0").unwrap();
        assert!(!wrapped.contains("return"), "{wrapped}");
        let wrapped = rewrite("\"text\"; await 1").unwrap();
        assert!(wrapped.contains("\"text\";\nreturn (await 1)"), "{wrapped}");
    }

    #[test]
    fn static_imports_become_dynamic() {
        let wrapped = rewrite("import fs, { readFile as rf, stat } from 'node:fs'").unwrap();
        assert!(wrapped.contains("void ({ default: fs, readFile: rf, stat } = await import('node:fs'))"), "{wrapped}");
        assert!(wrapped.contains("[\"fs\",\"rf\",\"stat\"]"), "{wrapped}");
        let wrapped = rewrite("import * as ns from 'm'").unwrap();
        assert!(wrapped.contains("void (ns = await import('m'))"), "{wrapped}");
        let wrapped = rewrite("import d, * as ns from 'm'").unwrap();
        assert!(wrapped.contains("void (ns = await import('m'), ({ default: d } = ns))"), "{wrapped}");
        let wrapped = rewrite("import 'side-effect'").unwrap();
        assert!(wrapped.contains("void await import('side-effect')"), "{wrapped}");
        let wrapped = rewrite("import data from './d.json' with { type: 'json' }").unwrap();
        assert!(wrapped.contains("await import('./d.json', { with: { type: 'json' } })"), "{wrapped}");
    }
}
