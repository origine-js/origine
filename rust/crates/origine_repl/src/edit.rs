//! The line being edited: text, cursor, kill buffer and undo. Plain functions of the line and
//! cursor, so they are tested without a terminal. Cursors are byte offsets on character
//! boundaries.

use crate::input::MAX_SOURCE;

const MAX_UNDO: usize = 64;

#[derive(Default)]
pub struct Line {
    pub text: String,
    pub cursor: usize,
    /// Text removed by the last kill command; Ctrl-Y inserts it again. Survives across lines.
    pub killed: String,
    undo: Vec<(String, usize)>,
    /// True while consecutive typing is folded into one undo step.
    pub typing: bool,
}

impl Line {
    /// Starts a new line; the kill buffer survives.
    pub fn reset(&mut self) {
        self.text.clear();
        self.cursor = 0;
        self.undo.clear();
        self.typing = false;
    }

    pub fn set(&mut self, text: &str) {
        self.text.clear();
        self.text.push_str(text);
        self.cursor = self.text.len();
        self.typing = false;
    }

    pub fn insert(&mut self, text: &str) {
        if text.len() > MAX_SOURCE - self.text.len() {
            return;
        }
        self.text.insert_str(self.cursor, text);
        self.cursor += text.len();
    }

    pub fn delete(&mut self) {
        let end = next(&self.text, self.cursor);
        self.text.replace_range(self.cursor..end, "");
    }

    pub fn backspace(&mut self) {
        let before = previous(&self.text, self.cursor);
        self.text.replace_range(before..self.cursor, "");
        self.cursor = before;
    }

    /// Cuts [from, to) into the kill buffer. Killing nothing keeps the previous contents.
    pub fn kill(&mut self, from: usize, to: usize) {
        if from >= to {
            return;
        }
        self.checkpoint();
        self.killed = self.text[from..to].to_owned();
        self.text.replace_range(from..to, "");
        self.cursor = from;
    }

    /// Swaps the characters around the cursor (or the last two at the end of the line).
    pub fn transpose(&mut self) {
        let text = &self.text;
        if text.len() < 2 || self.cursor == 0 {
            return;
        }
        let right = if self.cursor == text.len() { previous(text, text.len()) } else { self.cursor };
        let left = previous(text, right);
        let after = next(text, right);
        let swapped = format!("{}{}", &text[right..after], &text[left..right]);
        self.text.replace_range(left..after, &swapped);
        self.cursor = after;
    }

    /// Alt-u / Alt-l / Alt-c: upper-case, lower-case or capitalise the word at the cursor.
    pub fn change_case(&mut self, mode: u8) {
        self.checkpoint();
        let end = word_end(&self.text, self.cursor);
        let mut started = false;
        let changed: String = self.text[self.cursor..end]
            .chars()
            .map(|ch| {
                let first = !started && word_char(ch);
                started |= first;
                match mode {
                    b'u' => ch.to_ascii_uppercase(),
                    b'l' => ch.to_ascii_lowercase(),
                    _ if first => ch.to_ascii_uppercase(),
                    _ => ch.to_ascii_lowercase(),
                }
            })
            .collect();
        self.text.replace_range(self.cursor..end, &changed);
        self.cursor = end;
    }

    /// Remembers the current line so Ctrl-_ can restore it.
    pub fn checkpoint(&mut self) {
        self.typing = false;
        if self.undo.len() == MAX_UNDO {
            self.undo.remove(0);
        }
        self.undo.push((self.text.clone(), self.cursor));
    }

    pub fn undo(&mut self) {
        if let Some((text, cursor)) = self.undo.pop() {
            self.text = text;
            self.cursor = cursor;
        }
    }
}

pub fn previous(text: &str, cursor: usize) -> usize {
    text[..cursor].char_indices().next_back().map_or(0, |(at, _)| at)
}

pub fn next(text: &str, cursor: usize) -> usize {
    text[cursor..].chars().next().map_or(cursor, |ch| cursor + ch.len_utf8())
}

/// Characters that make up a word for Alt-b/f/d: identifier characters and any non-ASCII.
fn word_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || ch == '_' || ch == '$' || !ch.is_ascii()
}

/// Start of the word before `cursor` (skipping separators first).
pub fn word_start(text: &str, cursor: usize) -> usize {
    let head = &text[..cursor];
    let head = head.trim_end_matches(|ch| !word_char(ch));
    head.trim_end_matches(word_char).len()
}

/// End of the word at or after `cursor` (skipping separators first).
pub fn word_end(text: &str, cursor: usize) -> usize {
    let tail = &text[cursor..];
    let tail = tail.trim_start_matches(|ch| !word_char(ch));
    let tail = tail.trim_start_matches(word_char);
    text.len() - tail.len()
}

/// Start of the whitespace-delimited word before `cursor` (Ctrl-W).
pub fn space_start(text: &str, cursor: usize) -> usize {
    let head = text[..cursor].trim_end_matches(|ch: char| ch.is_ascii_whitespace());
    head.trim_end_matches(|ch: char| !ch.is_ascii_whitespace()).len()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(text: &str) -> Line {
        let mut line = Line::default();
        line.insert(text);
        line
    }

    #[test]
    fn insert_at_cursor_preserves_the_suffix() {
        let mut l = line("Math.ma(1)");
        l.cursor = 7;
        l.insert("x");
        assert_eq!(l.text, "Math.max(1)");
        l.delete();
        assert_eq!(l.text, "Math.max1)");
    }

    #[test]
    fn editing_moves_across_utf8_codepoints() {
        assert_eq!(previous("a貓b", 4), 1);
        assert_eq!(next("a貓b", 1), 4);
        assert_eq!(previous("abc", 0), 0);
        assert_eq!(next("abc", 3), 3);
        let mut l = line("a貓b");
        l.cursor = 4;
        l.backspace();
        assert_eq!(l.text, "ab");
        assert_eq!(l.cursor, 1);
    }

    #[test]
    fn word_motions_skip_separators_and_stay_on_identifier_characters() {
        let text = "foo.bar_baz(qux)";
        assert_eq!(word_start(text, 3), 0);
        assert_eq!(word_start(text, 11), 4);
        assert_eq!(word_end(text, 0), 3);
        assert_eq!(word_end(text, 3), 11);
        assert_eq!(word_end(text, 12), 15);
        assert_eq!(space_start("a  b  ", 4), 3);
        assert_eq!(space_start("a  b  ", 6), 3);
        assert_eq!(word_end("貓 x", 0), 3, "non-ASCII counts as a word");
    }

    #[test]
    fn kill_yank_transpose_and_undo() {
        let mut l = line("hello world");
        let start = space_start(&l.text, l.cursor);
        l.kill(start, l.cursor);
        assert_eq!(l.text, "hello ");
        l.kill(0, l.cursor);
        assert_eq!(l.text, "");
        l.checkpoint();
        let killed = l.killed.clone();
        l.insert(&killed);
        assert_eq!(l.text, "hello ");
        // The yank left the killed text intact, and undo returns to the state before it.
        l.undo();
        assert_eq!(l.text, "");
        l.undo();
        assert_eq!(l.text, "hello ");
        let mut l = line("abc");
        l.transpose();
        assert_eq!(l.text, "acb");
        l.cursor = 1;
        l.transpose();
        assert_eq!(l.text, "cab");
        l.cursor = 0;
        let end = word_end(&l.text, 0);
        l.kill(0, end);
        assert_eq!(l.text, "");
        assert_eq!(l.killed, "cab");
    }

    #[test]
    fn killing_nothing_keeps_the_kill_buffer() {
        let mut l = line("abc");
        l.kill(0, 3);
        l.kill(0, 0);
        assert_eq!(l.killed, "abc");
    }

    #[test]
    fn case_commands_edit_the_word() {
        let mut l = line("foo bar");
        l.cursor = 0;
        l.change_case(b'u');
        assert_eq!(l.text, "FOO bar");
        assert_eq!(l.cursor, 3);
        l.change_case(b'c');
        assert_eq!(l.text, "FOO Bar");
        l.cursor = 4;
        l.change_case(b'l');
        assert_eq!(l.text, "FOO bar");
    }

    #[test]
    fn undo_is_bounded() {
        let mut l = Line::default();
        for _ in 0..MAX_UNDO + 10 {
            l.checkpoint();
        }
        assert_eq!(l.undo.len(), MAX_UNDO);
    }
}
