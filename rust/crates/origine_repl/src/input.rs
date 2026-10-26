//! REPL-owned pending source and bounded, in-memory history.

pub const MAX_SOURCE: usize = 64 * 1024;
pub const MAX_HISTORY: usize = 100;

#[derive(Debug, PartialEq, Eq)]
pub struct TooLong;

#[derive(Debug, PartialEq, Eq)]
pub struct NoEntry;

#[derive(Default)]
pub struct Input {
    source: String,
    history: Vec<String>,
}

impl Input {
    pub fn source(&self) -> &str {
        &self.source
    }

    pub fn history(&self) -> &[String] {
        &self.history
    }

    pub fn clear(&mut self) {
        self.source.clear();
    }

    /// Adds a line, with a newline separating it from prior lines. Bytes that are not UTF-8 become
    /// U+FFFD, as V8 would read them.
    pub fn append(&mut self, line: &[u8]) -> Result<(), TooLong> {
        let line = String::from_utf8_lossy(line);
        let separator = usize::from(!self.source.is_empty());
        if separator + line.len() > MAX_SOURCE - self.source.len() {
            return Err(TooLong);
        }
        if separator != 0 {
            self.source.push('\n');
        }
        self.source.push_str(&line);
        Ok(())
    }

    /// Stores the pending source; consecutive duplicates share one entry.
    pub fn remember(&mut self) {
        if self.history.last().is_some_and(|last| *last == self.source) {
            return;
        }
        if self.history.len() == MAX_HISTORY {
            self.history.remove(0);
        }
        self.history.push(self.source.clone());
    }

    /// Replaces the pending source by a one-based history entry (`None` selects the latest).
    pub fn recall(&mut self, number: Option<usize>) -> Result<(), NoEntry> {
        let n = number.unwrap_or(self.history.len());
        let entry = n.checked_sub(1).and_then(|at| self.history.get(at)).ok_or(NoEntry)?;
        self.source.clone_from(entry);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multiline_source_and_bounded_history_own_their_copies() {
        let mut input = Input::default();
        input.append(b"({").unwrap();
        input.append(b" answer: 42 })").unwrap();
        input.remember();
        input.clear();
        input.recall(None).unwrap();
        assert_eq!(input.source(), "({\n answer: 42 })");
        input.remember();
        assert_eq!(input.history().len(), 1);
        assert_eq!(input.recall(Some(0)), Err(NoEntry));
        assert_eq!(input.recall(Some(2)), Err(NoEntry));
        for n in 0..MAX_HISTORY + 5 {
            input.clear();
            input.append(n.to_string().as_bytes()).unwrap();
            input.remember();
        }
        assert_eq!(input.history().len(), MAX_HISTORY);
        assert_eq!(input.history()[0], "5");
    }

    #[test]
    fn input_is_bounded() {
        let mut input = Input::default();
        input.append(&vec![b'x'; MAX_SOURCE]).unwrap();
        assert_eq!(input.append(b""), Err(TooLong));
        assert_eq!(input.append(b"x"), Err(TooLong));
        input.clear();
        input.append(&vec![b'x'; MAX_SOURCE - 1]).unwrap();
        assert_eq!(input.append(b"x"), Err(TooLong), "the separator counts");
    }

    #[test]
    fn invalid_utf8_becomes_replacement_characters() {
        let mut input = Input::default();
        input.append(b"a\xffb").unwrap();
        assert_eq!(input.source(), "a\u{fffd}b");
    }
}
