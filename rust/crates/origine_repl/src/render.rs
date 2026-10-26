//! What the editor shows: control-character masking and syntax colors for the line.

use unicode_width::UnicodeWidthChar;

/// Terminal cells taken by `ch`.
pub fn cells(ch: char) -> usize {
    ch.width().unwrap_or(0)
}

/// Replaces control characters, so typed text cannot inject terminal escapes: newline becomes
/// `↵`, every other control character a space.
pub fn sanitize(text: &str) -> String {
    text.chars()
        .map(|ch| match ch {
            '\n' => '↵',
            '\0'..='\x1f' | '\x7f' => ' ',
            _ => ch,
        })
        .collect()
}

const KEYWORDS: [&str; 25] = [
    "true",
    "false",
    "null",
    "undefined",
    "const",
    "let",
    "var",
    "function",
    "return",
    "class",
    "new",
    "throw",
    "await",
    "async",
    "import",
    "export",
    "from",
    "if",
    "else",
    "for",
    "while",
    "of",
    "in",
    "typeof",
    "yield",
];

fn regex_word(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_'
}

/// Colors strings, numbers, keywords and `[Name ...]` markers (the line highlighter of the
/// editor). `text` has been through `sanitize`.
pub fn highlight(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len() + 16);
    let mut plain = 0;
    let mut i = 0;
    while i < bytes.len() {
        let found = match bytes[i] {
            quote @ (b'"' | b'\'' | b'`') => string_end(bytes, i, quote).map(|end| (end, 32)),
            b'[' if bytes.get(i + 1).is_some_and(u8::is_ascii_alphabetic) => {
                bytes[i..].iter().position(|&b| b == b']').map(|at| (i + at + 1, 36))
            }
            lead if regex_word(lead) && (i == 0 || !regex_word(bytes[i - 1])) => {
                word_end(bytes, i).map(|end| (end, if lead.is_ascii_digit() { 33 } else { 35 }))
            }
            _ => None,
        };
        match found {
            Some((end, color)) => {
                out.push_str(&text[plain..i]);
                out.push_str(&format!("\x1b[{color}m{}\x1b[0m", &text[i..end]));
                plain = end;
                i = end;
            }
            None => i += 1,
        }
    }
    out.push_str(&text[plain..]);
    out
}

/// End of the string literal opening at `start`, if it is closed. A backslash escapes the next byte.
fn string_end(bytes: &[u8], start: usize, quote: u8) -> Option<usize> {
    let mut i = start + 1;
    while i < bytes.len() {
        match bytes[i] {
            b'\\' => i += 2,
            b if b == quote => return Some(i + 1),
            _ => i += 1,
        }
    }
    None
}

/// End of the number or keyword starting at `start` (which follows a word boundary).
fn word_end(bytes: &[u8], start: usize) -> Option<usize> {
    let run = start + bytes[start..].iter().take_while(|&&b| regex_word(b)).count();
    if !bytes[start].is_ascii_digit() {
        return KEYWORDS.contains(&std::str::from_utf8(&bytes[start..run]).ok()?).then_some(run);
    }
    // digits, then an optional fraction and an optional `n`, ending at a word boundary
    let digits = start + bytes[start..].iter().take_while(|b| b.is_ascii_digit()).count();
    let fraction = (bytes.get(digits) == Some(&b'.'))
        .then(|| digits + 1 + bytes[digits + 1..].iter().take_while(|b| b.is_ascii_digit()).count())
        .filter(|&end| end > digits + 1);
    let boundary = |end: usize| bytes.get(end).is_none_or(|&b| !regex_word(b));
    for base in fraction.into_iter().chain([digits]) {
        if bytes.get(base) == Some(&b'n') && boundary(base + 1) {
            return Some(base + 1);
        }
        if boundary(base) {
            return Some(base);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn colored(text: &str) -> String {
        highlight(&sanitize(text))
    }

    #[test]
    fn sanitize_masks_controls() {
        assert_eq!(sanitize("a\nb\x1b[31m\x7f"), "a↵b [31m ");
    }

    #[test]
    fn strings_numbers_keywords_and_markers_are_colored() {
        assert_eq!(colored("const x = 1"), "\x1b[35mconst\x1b[0m x = \x1b[33m1\x1b[0m");
        assert_eq!(colored("'a\\'b' + \"c\""), "\x1b[32m'a\\'b'\x1b[0m + \x1b[32m\"c\"\x1b[0m");
        assert_eq!(colored("12n 1.5 1.x"), "\x1b[33m12n\x1b[0m \x1b[33m1.5\x1b[0m \x1b[33m1\x1b[0m.x");
        assert_eq!(colored("[Function: f]"), "\x1b[36m[Function: f]\x1b[0m");
        assert_eq!(colored("[1, 2]"), "[\x1b[33m1\x1b[0m, \x1b[33m2\x1b[0m]");
    }

    #[test]
    fn words_must_match_whole_and_unclosed_strings_stay_plain() {
        assert_eq!(colored("constant letter 10x ifx"), "constant letter 10x ifx");
        assert_eq!(colored("'open const"), "'open \x1b[35mconst\x1b[0m");
        assert_eq!(colored("a.if"), "a.\x1b[35mif\x1b[0m");
    }

    #[test]
    fn wide_characters_take_two_cells() {
        assert_eq!(cells('a'), 1);
        assert_eq!(cells('貓'), 2);
        assert_eq!(cells('\u{301}'), 0);
    }
}
