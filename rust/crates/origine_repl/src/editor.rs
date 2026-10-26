//! Interactive line editing with readline-style keys, as a state machine: the caller feeds the
//! bytes read from the terminal and writes `output()` back after every call. The editor never
//! touches the terminal itself (raw mode, reads and writes belong to the host), and gets
//! completions through a callback because they come from live objects.

use crate::complete;
use crate::edit::{self, Line, next, previous};
use crate::keys::{Decoder, Key};
use crate::render;

/// What a call to the editor ended with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    /// Keep reading.
    Continue,
    /// A line is ready (`Editor::line`).
    Line,
    /// End of input with nothing typed.
    Eof,
    /// Ctrl-C.
    Canceled,
}

/// What the editor needs to know about its surroundings on each call.
pub struct Context<'a> {
    /// Terminal columns.
    pub width: usize,
    /// Earlier evaluations, oldest first.
    pub history: &'a [String],
    /// Source of the multiline input typed so far.
    pub pending: &'a str,
    /// Completion list (newline separated names) for a prefix; None when it failed.
    pub complete: &'a mut dyn FnMut(&str) -> Option<String>,
}

#[derive(Default)]
struct Search {
    query: String,
    /// History index of the current match.
    found: Option<usize>,
    failed: bool,
}

const MAX_QUERY: usize = 256;

#[derive(Default)]
pub struct Editor {
    line: Line,
    colors: bool,
    suggestion: String,
    draft: String,
    history_position: usize,
    prompt: String,
    search: Option<Search>,
    decoder: Decoder,
    out: Vec<u8>,
}

impl Editor {
    pub fn new(colors: bool) -> Self {
        Editor { colors, ..Editor::default() }
    }

    /// Bytes to write to the terminal after the last call.
    pub fn output(&self) -> &[u8] {
        &self.out
    }

    /// The finished line (after `Event::Line`).
    pub fn line(&self) -> &str {
        &self.line.text
    }

    /// Whether the next read should time out: inside an escape sequence, a pause means Escape.
    pub fn in_sequence(&self) -> bool {
        self.decoder.in_sequence()
    }

    /// Starts a new line; the prompt is part of `output()`.
    pub fn begin(&mut self, prompt: &str, history_len: usize) {
        self.line.reset();
        self.suggestion.clear();
        self.draft.clear();
        self.history_position = history_len;
        self.prompt = prompt.to_owned();
        self.search = None;
        self.decoder = Decoder::default();
        self.out.clear();
        self.write(prompt);
    }

    pub fn feed(&mut self, byte: u8, ctx: &mut Context) -> Event {
        self.out.clear();
        match self.decoder.feed(byte) {
            Some(key) => self.key(key, ctx),
            None => Event::Continue,
        }
    }

    /// A read timed out.
    pub fn timeout(&mut self, ctx: &mut Context) -> Event {
        self.out.clear();
        match self.decoder.timeout() {
            Some(key) => self.key(key, ctx),
            None => Event::Continue,
        }
    }

    /// End of input. What was typed is still handed over as a line.
    pub fn eof(&mut self) -> Event {
        self.out.clear();
        if self.line.text.is_empty() {
            return Event::Eof;
        }
        self.write("\n");
        Event::Line
    }

    fn write(&mut self, text: &str) {
        self.out.extend_from_slice(text.as_bytes());
    }

    fn key(&mut self, key: Key, ctx: &mut Context) -> Event {
        if let Some(mut search) = self.search.take() {
            if self.search_key(&mut search, key, ctx.history) {
                // Any key that ends the search is then handled as an ordinary key, except the
                // ones that only cancel it.
                if matches!(key, Key::Ctrl(b'g' | b'c')) {
                    self.redraw(ctx);
                    return Event::Continue;
                }
            } else {
                self.redraw_search(&search, ctx);
                self.search = Some(search);
                return Event::Continue;
            }
        }
        match key {
            Key::Enter => {
                self.suggestion.clear();
                self.redraw(ctx);
                self.write("\n");
                return Event::Line;
            }
            Key::Ctrl(b'c') => {
                self.write("^C\n");
                return Event::Canceled;
            }
            Key::Ctrl(b'd') => {
                if self.line.text.is_empty() {
                    self.write("\n");
                    return Event::Eof;
                }
                self.line.checkpoint();
                self.line.delete();
            }
            Key::Ctrl(b'r') => {
                let search = Search::default();
                self.redraw_search(&search, ctx);
                self.search = Some(search);
                return Event::Continue;
            }
            Key::Ctrl(b'l') => {
                self.write("\x1b[H\x1b[2J");
                self.update_suggestion(ctx);
                self.redraw(ctx);
                return Event::Continue;
            }
            Key::Ctrl(letter) => self.control(letter),
            Key::Tab => {
                if !self.accept_suggestion() {
                    let head = &self.line.text[..self.line.cursor];
                    if complete::inside_text(&[ctx.pending, head]) {
                        self.line.checkpoint();
                        self.line.insert("  ");
                    } else {
                        self.complete(ctx);
                    }
                }
            }
            Key::Up => self.history(ctx.history, true),
            Key::Down => self.history(ctx.history, false),
            Key::Right => {
                if self.line.cursor != self.line.text.len() || !self.accept_suggestion() {
                    self.line.cursor = next(&self.line.text, self.line.cursor);
                }
            }
            Key::End => {
                self.accept_suggestion();
                self.line.cursor = self.line.text.len();
            }
            other => self.apply(other),
        }
        self.update_suggestion(ctx);
        self.redraw(ctx);
        Event::Continue
    }

    /// Applies a key that edits the line or moves the cursor without needing the terminal.
    fn apply(&mut self, key: Key) {
        let line = &mut self.line;
        match key {
            Key::Text(ch) => {
                if !line.typing {
                    line.checkpoint();
                }
                line.insert(ch.encode_utf8(&mut [0; 4]));
                line.typing = true;
                return;
            }
            Key::Left => line.cursor = previous(&line.text, line.cursor),
            Key::Home => line.cursor = 0,
            Key::WordLeft => line.cursor = edit::word_start(&line.text, line.cursor),
            Key::WordRight => line.cursor = edit::word_end(&line.text, line.cursor),
            Key::Backspace => {
                line.checkpoint();
                line.backspace();
            }
            Key::Delete => {
                line.checkpoint();
                line.delete();
            }
            Key::AltBackspace => line.kill(edit::word_start(&line.text, line.cursor), line.cursor),
            Key::Undo => line.undo(),
            Key::Alt(ch) => match ch {
                b'b' => line.cursor = edit::word_start(&line.text, line.cursor),
                b'f' => line.cursor = edit::word_end(&line.text, line.cursor),
                b'd' => line.kill(line.cursor, edit::word_end(&line.text, line.cursor)),
                b'u' | b'l' | b'c' => line.change_case(ch),
                _ => {}
            },
            Key::Ctrl(letter) => return self.control(letter),
            _ => {}
        }
        self.line.typing = false;
    }

    /// Ctrl-letter editing commands (the ones that are not terminal-level actions).
    fn control(&mut self, letter: u8) {
        let line = &mut self.line;
        match letter {
            b'a' => line.cursor = 0,
            b'e' => line.cursor = line.text.len(),
            b'b' => line.cursor = previous(&line.text, line.cursor),
            b'f' => line.cursor = next(&line.text, line.cursor),
            b'h' => {
                line.checkpoint();
                line.backspace();
            }
            b'k' => line.kill(line.cursor, line.text.len()),
            b'u' => line.kill(0, line.cursor),
            b'w' => line.kill(edit::space_start(&line.text, line.cursor), line.cursor),
            b'y' => {
                line.checkpoint();
                let killed = line.killed.clone();
                line.insert(&killed);
            }
            b't' => {
                line.checkpoint();
                line.transpose();
            }
            b'_' | b'/' => line.undo(),
            _ => {}
        }
        line.typing = false;
    }

    fn history(&mut self, entries: &[String], backwards: bool) {
        if backwards {
            if self.history_position == 0 {
                return;
            }
            if self.history_position == entries.len() {
                self.draft.clone_from(&self.line.text);
            }
            self.history_position -= 1;
        } else {
            if self.history_position >= entries.len() {
                return;
            }
            self.history_position += 1;
        }
        let shown = entries.get(self.history_position).unwrap_or(&self.draft);
        self.line.set(shown);
    }

    /// Handles one key during Ctrl-R search; true when the key ended the search (the match, if
    /// any, is then in the line).
    fn search_key(&mut self, search: &mut Search, key: Key, entries: &[String]) -> bool {
        match key {
            Key::Text(ch) => {
                if search.query.len() + ch.len_utf8() > MAX_QUERY {
                    return false;
                }
                search.query.push(ch);
                search.failed = !find_backwards(entries, search, search.found.unwrap_or(entries.len()), true);
                return false;
            }
            Key::Backspace => {
                if search.query.pop().is_some() {
                    search.failed = !find_backwards(entries, search, entries.len(), true);
                }
                return false;
            }
            Key::Ctrl(b'r') => {
                search.failed = !find_backwards(entries, search, search.found.unwrap_or(entries.len()), false);
                return false;
            }
            Key::Ctrl(b'g' | b'c') | Key::Ignored => return true,
            _ => {}
        }
        if let Some(index) = search.found {
            self.line.checkpoint();
            self.line.set(&entries[index]);
            self.history_position = index;
            self.draft.clear();
        }
        true
    }

    fn update_suggestion(&mut self, ctx: &mut Context) {
        self.suggestion.clear();
        let text = &self.line.text;
        if !self.colors || self.line.cursor != text.len() || text.is_empty() || text.starts_with('.') {
            return;
        }
        if complete::inside_text(&[ctx.pending, text]) {
            return;
        }
        let Some(start) = complete::completion_start(text, self.line.cursor) else { return };
        let prefix = &text[start..];
        if let Some(matches) = (ctx.complete)(prefix) {
            self.suggestion = complete::suggestion(&matches, prefix).to_owned();
        }
    }

    fn accept_suggestion(&mut self) -> bool {
        if self.line.cursor != self.line.text.len() || self.suggestion.is_empty() {
            return false;
        }
        self.line.checkpoint();
        let suggestion = std::mem::take(&mut self.suggestion);
        self.line.insert(&suggestion);
        true
    }

    fn complete(&mut self, ctx: &mut Context) {
        let text = &self.line.text;
        if text[self.line.cursor..].bytes().next().is_some_and(complete::word) {
            return;
        }
        let Some(start) = complete::completion_start(text, self.line.cursor) else {
            self.line.checkpoint();
            self.line.insert("  ");
            return;
        };
        let prefix = text[start..self.line.cursor].to_owned();
        let Some(matches) = (ctx.complete)(&prefix) else {
            self.write("\x07");
            return;
        };
        if matches.is_empty() || matches.starts_with('(') || matches.starts_with("Use ") {
            self.write("\x07");
            return;
        }
        let common = complete::common_prefix(&matches);
        if common.len() > prefix.len() {
            self.line.checkpoint();
            self.line.insert(&common[prefix.len()..]);
        } else {
            let prompt = self.prompt.clone();
            self.write("\n");
            self.write(&matches);
            self.write("\n");
            self.write(&prompt);
        }
    }

    // A horizontally scrolling viewport keeps redraws on one terminal row, including long inputs.
    fn redraw(&mut self, ctx: &Context) {
        let text = &self.line.text;
        let cursor = self.line.cursor;
        let prompt = self.prompt.len();
        let budget = if ctx.width > prompt + 4 { ctx.width - prompt - 2 } else { 8 };
        let reserve = self.suggestion.chars().count().min(budget / 3);
        let mut start = cursor;
        let mut count = 0;
        while start > 0 {
            let before = previous(text, start);
            let cells = text[before..].chars().next().map_or(0, render::cells);
            if count + cells > budget - reserve {
                break;
            }
            count += cells;
            start = before;
        }
        let mut end = cursor;
        while end < text.len() {
            let ch = text[end..].chars().next().unwrap_or(' ');
            let cells = render::cells(ch);
            if count + cells > budget {
                break;
            }
            count += cells;
            end += ch.len_utf8();
        }
        let shown = |part: &str| {
            let clean = render::sanitize(part);
            if self.colors { render::highlight(&clean) } else { clean }
        };
        let mut frame = String::from("\r\x1b[2K");
        frame.push_str(&self.prompt);
        if start != 0 {
            frame.push('<');
        }
        frame.push_str(&shown(&text[start..cursor]));
        frame.push_str("\x1b[s");
        frame.push_str(&shown(&text[cursor..end]));
        if self.colors && cursor == text.len() && !self.suggestion.is_empty() && count < budget {
            frame.push_str("\x1b[2m");
            let mut room = budget - count;
            for ch in self.suggestion.chars() {
                let cells = render::cells(ch);
                if cells > room {
                    break;
                }
                room -= cells;
                frame.push(ch);
            }
            frame.push_str("\x1b[0m");
        }
        frame.push_str("\x1b[u");
        self.write(&frame);
    }

    fn redraw_search(&mut self, search: &Search, ctx: &Context) {
        let mut query = search.query.as_str();
        while query.len() > 96 {
            let mut cut = query.len() - 1;
            while !query.is_char_boundary(cut) {
                cut -= 1;
            }
            query = &query[..cut];
        }
        let label = format!("({}reverse-i-search)`{query}': ", if search.failed { "failed " } else { "" });
        let budget = if ctx.width > label.len() + 2 { ctx.width - label.len() - 2 } else { 8 };
        let entry = search.found.map_or("", |index| ctx.history[index].as_str());
        let mut shown = String::new();
        let mut count = 0;
        for ch in entry.chars() {
            let cells = render::cells(ch);
            if count + cells > budget {
                break;
            }
            count += cells;
            shown.push(ch);
        }
        let frame = format!("\r\x1b[2K{label}{}", render::sanitize(&shown));
        self.write(&frame);
    }
}

/// Moves `search.found` to the newest history entry older than `before` containing the query
/// (when `inclusive`, `before` itself may match). False when nothing matches; `found` is kept.
fn find_backwards(entries: &[String], search: &mut Search, before: usize, inclusive: bool) -> bool {
    if search.query.is_empty() {
        search.found = None;
        return true;
    }
    let from = if inclusive { (before + 1).min(entries.len()) } else { before };
    match entries[..from].iter().rposition(|entry| entry.contains(&search.query)) {
        Some(index) => {
            search.found = Some(index);
            true
        }
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture {
        editor: Editor,
        history: Vec<String>,
        pending: String,
        names: &'static str,
    }

    impl Fixture {
        fn new(colors: bool) -> Self {
            let mut editor = Editor::new(colors);
            editor.begin("> ", 0);
            Fixture { editor, history: Vec::new(), pending: String::new(), names: "" }
        }

        fn type_bytes(&mut self, bytes: &[u8]) -> Event {
            let names = self.names;
            let mut complete = |prefix: &str| {
                let found: Vec<&str> = names.lines().filter(|name| name.starts_with(prefix)).collect();
                (!found.is_empty()).then(|| found.join("\n"))
            };
            let mut ctx = Context { width: 80, history: &self.history, pending: &self.pending, complete: &mut complete };
            let mut last = Event::Continue;
            for &byte in bytes {
                last = self.editor.feed(byte, &mut ctx);
                if last != Event::Continue {
                    break;
                }
            }
            last
        }

        fn text(&self) -> &str {
            self.editor.line()
        }

        fn shown(&self) -> String {
            String::from_utf8_lossy(self.editor.output()).into_owned()
        }
    }

    #[test]
    fn typing_editing_and_enter() {
        let mut f = Fixture::new(false);
        assert_eq!(f.type_bytes(b"hello wrld"), Event::Continue);
        f.type_bytes(b"\x1b[1;5D\x1b[1;5D"); // two words left
        assert_eq!(f.editor.line.cursor, 0);
        f.type_bytes(b"\x1b[1;5C\x1b[1;5C"); // back to the end of "wrld"
        f.type_bytes(b"\x1b[D\x1b[Do"); // before "ld", insert o
        assert_eq!(f.text(), "hello wrold");
        assert_eq!(f.type_bytes(b"\r"), Event::Line);
        assert!(f.editor.output().ends_with(b"\n"));
    }

    #[test]
    fn ctrl_c_cancels_and_ctrl_d_ends_only_an_empty_line() {
        let mut f = Fixture::new(false);
        assert_eq!(f.type_bytes(b"x\x04"), Event::Continue);
        assert_eq!(f.text(), "x");
        assert_eq!(f.type_bytes(b"\x03"), Event::Canceled);
        let mut f = Fixture::new(false);
        assert_eq!(f.type_bytes(b"\x04"), Event::Eof);
    }

    #[test]
    fn eof_hands_over_a_partial_line() {
        let mut f = Fixture::new(false);
        f.type_bytes(b"abc");
        assert_eq!(f.editor.eof(), Event::Line);
        assert_eq!(f.text(), "abc");
        let mut f = Fixture::new(false);
        assert_eq!(f.editor.eof(), Event::Eof);
    }

    #[test]
    fn history_browsing_restores_the_draft() {
        let mut f = Fixture::new(false);
        f.history = vec!["one".into(), "two".into()];
        f.editor.begin("> ", 2);
        f.type_bytes(b"dra");
        f.type_bytes(b"\x1b[A");
        assert_eq!(f.text(), "two");
        f.type_bytes(b"\x1b[A");
        assert_eq!(f.text(), "one");
        f.type_bytes(b"\x1b[A");
        assert_eq!(f.text(), "one");
        f.type_bytes(b"\x1b[B\x1b[B");
        assert_eq!(f.text(), "dra");
    }

    #[test]
    fn reverse_search_walks_older_matches_and_accepts_with_enter() {
        let mut f = Fixture::new(false);
        f.history = vec!["alpha".into(), "beta".into(), "alphabet".into()];
        f.editor.begin("> ", 3);
        f.type_bytes(b"\x12alpha");
        assert!(f.shown().contains("reverse-i-search)`alpha': alphabet"), "{}", f.shown());
        f.type_bytes(b"\x12");
        assert!(f.shown().ends_with("': alpha"), "{}", f.shown());
        f.type_bytes(b"\x12");
        assert!(f.shown().contains("failed"), "{}", f.shown());
        assert_eq!(f.type_bytes(b"\r"), Event::Line);
        assert_eq!(f.text(), "alpha");
    }

    #[test]
    fn search_cancel_keeps_the_line() {
        let mut f = Fixture::new(false);
        f.history = vec!["alpha".into()];
        f.editor.begin("> ", 1);
        f.type_bytes(b"x\x12alp\x07");
        assert_eq!(f.text(), "x");
    }

    #[test]
    fn tab_completes_common_prefix_or_lists_matches() {
        let mut f = Fixture::new(false);
        f.names = "Math.max\nMath.min";
        f.type_bytes(b"Math.m\t");
        assert_eq!(f.text(), "Math.m");
        assert!(f.shown().contains("Math.max\nMath.min"), "{}", f.shown());
        f.type_bytes(b"a\t");
        assert_eq!(f.text(), "Math.max");
    }

    #[test]
    fn tab_inside_a_string_or_on_a_blank_line_inserts_spaces() {
        let mut f = Fixture::new(false);
        f.type_bytes(b"'ab\t");
        assert_eq!(f.text(), "'ab  ");
        let mut f = Fixture::new(false);
        f.type_bytes(b"\t");
        assert_eq!(f.text(), "  ");
    }

    #[test]
    fn colored_editor_shows_and_accepts_a_suggestion() {
        let mut f = Fixture::new(true);
        f.names = "Math.max\nMath.min";
        f.type_bytes(b"Math.ma");
        assert!(f.shown().contains("\x1b[2mx\x1b[0m"), "{}", f.shown());
        f.type_bytes(b"\x1b[C");
        assert_eq!(f.text(), "Math.max");
    }

    #[test]
    fn long_lines_scroll_inside_one_row() {
        let mut f = Fixture::new(false);
        let long = "x".repeat(200);
        f.type_bytes(long.as_bytes());
        let out = f.shown();
        assert!(out.contains("> <"), "{out}");
        assert!(out.len() < 120, "{out}");
    }

    #[test]
    fn a_lone_escape_is_ignored_after_a_pause() {
        let mut f = Fixture::new(false);
        f.type_bytes(b"a\x1b");
        assert!(f.editor.in_sequence());
        let mut complete = |_: &str| None;
        let mut ctx = Context { width: 80, history: &[], pending: "", complete: &mut complete };
        assert_eq!(f.editor.timeout(&mut ctx), Event::Continue);
        assert!(!f.editor.in_sequence());
        assert_eq!(f.text(), "a");
    }
}
