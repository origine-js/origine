//! Completion context and string detection.
//!
//! Adapted from Bun's native REPL completion context/string handling at
//! oven-sh/bun 5c6d4e24cd185d5bef8d98e7f1f1e3ef10ac163f, src/runtime/cli/repl.rs.
//! Copyright Bun contributors. MIT license; see BUN-NOTICE.md.

/// Identifier characters, plus any non-ASCII byte (so UTF-8 sequences are never split).
pub fn word(ch: u8) -> bool {
    ch.is_ascii_alphanumeric() || ch == b'_' || ch == b'$' || ch >= 0x80
}

/// Port of parse_completion_context: do not suggest globals after `foo().`, and treat spread
/// (`...args`) separately from member access. `cursor` is a byte index.
pub fn start(line: &str, cursor: usize) -> Option<usize> {
    let line = line.as_bytes();
    let mut i = cursor;
    while i > 0 && word(line[i - 1]) {
        i -= 1;
    }
    if !member_dot(line, i) {
        return if i == cursor { None } else { Some(i) };
    }
    i -= 1;
    loop {
        let end = i;
        while i > 0 && word(line[i - 1]) {
            i -= 1;
        }
        if i == end {
            return None;
        }
        if !member_dot(line, i) {
            break;
        }
        i -= 1;
    }
    Some(i)
}

fn member_dot(line: &[u8], end: usize) -> bool {
    end >= 1 && line[end - 1] == b'.' && (end < 2 || line[end - 2] != b'.')
}

/// What the cursor completes: `.command` names at the start of a line, else `start`.
pub fn completion_start(text: &str, cursor: usize) -> Option<usize> {
    let bytes = text.as_bytes();
    if cursor > 0 && bytes[0] == b'.' && bytes[1..cursor].iter().all(u8::is_ascii_alphabetic) {
        return Some(0);
    }
    start(text, cursor)
}

const MAX_HOLES: usize = 128;

/// Port of ends_inside_string, with comment handling added for Origine. `parts` are the pending
/// multiline source and the current line up to the cursor.
pub fn inside_text(parts: &[&str]) -> bool {
    let mut quote = 0u8;
    let mut holes = [0usize; MAX_HOLES];
    let mut depth = 0usize;
    let mut block_comment = false;
    for part in parts {
        let part = part.as_bytes();
        let mut line_comment = false;
        let mut i = 0;
        while i < part.len() {
            let ch = part[i];
            i += 1;
            let next = part.get(i).copied();
            if line_comment {
                if ch == b'\n' {
                    line_comment = false;
                }
            } else if block_comment {
                if ch == b'*' && next == Some(b'/') {
                    block_comment = false;
                    i += 1;
                }
            } else if quote != 0 {
                if ch == b'\\' {
                    i += 1;
                } else if ch == b'$' && quote == b'`' && next == Some(b'{') {
                    if depth == MAX_HOLES {
                        return true;
                    }
                    holes[depth] = 1;
                    depth += 1;
                    quote = 0;
                    i += 1;
                } else if ch == quote {
                    quote = 0;
                }
            } else {
                match ch {
                    b'\'' | b'"' | b'`' => quote = ch,
                    b'/' => match next {
                        Some(b'/') => {
                            line_comment = true;
                            i += 1;
                        }
                        Some(b'*') => {
                            block_comment = true;
                            i += 1;
                        }
                        _ => {}
                    },
                    b'{' if depth > 0 => holes[depth - 1] += 1,
                    b'}' if depth > 0 => {
                        holes[depth - 1] -= 1;
                        if holes[depth - 1] == 0 {
                            depth -= 1;
                            quote = b'`';
                        }
                    }
                    _ => {}
                }
            }
        }
        if line_comment {
            return true;
        }
    }
    quote != 0 || block_comment
}

/// Port of update_suggestion: the shortest matching name wins, not the longest shared prefix.
/// Returns the part of it after `prefix`.
pub fn suggestion<'a>(matches: &'a str, prefix: &str) -> &'a str {
    let best = matches.lines().filter(|line| line.len() > prefix.len() && line.starts_with(prefix)).min_by_key(|line| line.len());
    best.map_or("", |name| &name[prefix.len()..])
}

/// Longest prefix shared by every line of a completion list; empty for a truncated list (`…`).
pub fn common_prefix(matches: &str) -> &str {
    let mut lines = matches.split('\n');
    let mut common = lines.next().unwrap_or_default();
    for line in lines {
        if line == "…" {
            return "";
        }
        let shared = common.bytes().zip(line.bytes()).take_while(|(a, b)| a == b).count();
        let mut end = shared;
        while !common.is_char_boundary(end) {
            end -= 1;
        }
        common = &common[..end];
    }
    common
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bun_completion_contexts_and_string_suppression() {
        assert_eq!(start("Math.ma", 7), Some(0));
        assert_eq!(start("foo().ba", 8), None);
        assert_eq!(start("[...args", 8), Some(4));
        assert!(inside_text(&["'Math.ma"]));
        assert!(inside_text(&["// Math.ma"]));
        assert!(!inside_text(&["`hello ${Math.ma"]));
        assert!(inside_text(&["`hello ${1} Math.ma"]));
        assert!(!inside_text(&["'closed' Math.ma"]));
        assert!(inside_text(&["/* open", "Math.ma"]));
        assert!(!inside_text(&["// done\n", "Math.ma"]));
        assert_eq!(suggestion("Math.max\nMath.min", "Math.m"), "ax");
        assert_eq!(suggestion("Math.max", "Math.max"), "");
    }

    #[test]
    fn completion_start_handles_commands_and_blanks() {
        assert_eq!(completion_start("( Math.ma(1))", 9), Some(2));
        assert_eq!(completion_start("  ", 2), None);
        assert_eq!(completion_start(".hel", 4), Some(0));
        assert_eq!(completion_start(".5.toF", 6), None, "a number is not a name to complete");
    }

    #[test]
    fn common_prefix_stays_safe() {
        assert_eq!(common_prefix("Math.max"), "Math.max");
        assert_eq!(common_prefix("Object.getOwnPropertyNames\nObject.getOwnPropertySymbols"), "Object.getOwnProperty");
        assert_eq!(common_prefix("Math.max\n…"), "");
        assert_eq!(common_prefix("a貓\na狗"), "a", "never splits a character");
    }

    #[test]
    fn multibyte_words_are_never_split() {
        assert_eq!(start("貓.na", 6), Some(0));
    }
}
