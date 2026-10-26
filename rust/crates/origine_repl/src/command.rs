//! Dot-commands (`.help`, `.again 2`, ...) as the REPL reads them from a line.

#[derive(Debug, PartialEq, Eq)]
pub enum Command<'a> {
    /// Not a command: JavaScript (or TypeScript) source.
    Source,
    Help,
    Exit,
    Clear,
    History,
    /// `.again [number]`: one-based history entry, latest when absent.
    Again(Option<usize>),
    /// `.complete [prefix]`.
    Complete(&'a [u8]),
    /// A known command with bad arguments.
    Invalid,
}

const KNOWN: [&[u8]; 7] = [b".again", b".complete", b".help", b".exit", b".clear", b".break", b".history"];

/// Returned arguments borrow `line`.
pub fn parse(line: &[u8]) -> Command<'_> {
    let text = line.trim_ascii_start_matches(b" \r\t");
    let text = text.trim_ascii_end_matches(b" \r\t");
    if text.len() < 2 || text[0] != b'.' || !text[1].is_ascii_alphabetic() {
        return Command::Source;
    }
    let mut words = text.split(|b| matches!(b, b' ' | b'\t')).filter(|word| !word.is_empty());
    let name = words.next().unwrap_or_default();
    // Dotted property continuations inside multiline JavaScript stay source.
    if !KNOWN.contains(&name) {
        return Command::Source;
    }
    let argument = words.next();
    if words.next().is_some() {
        return Command::Invalid;
    }
    match name {
        b".again" => match argument {
            None => Command::Again(None),
            Some(arg) => match std::str::from_utf8(arg).ok().and_then(|arg| arg.parse::<usize>().ok()) {
                Some(n) if n > 0 => Command::Again(Some(n)),
                _ => Command::Invalid,
            },
        },
        b".complete" => Command::Complete(argument.unwrap_or_default()),
        _ if argument.is_some() => Command::Invalid,
        b".help" => Command::Help,
        b".exit" => Command::Exit,
        b".clear" | b".break" => Command::Clear,
        _ => Command::History,
    }
}

trait TrimMatches {
    fn trim_ascii_start_matches(&self, set: &[u8]) -> &[u8];
    fn trim_ascii_end_matches(&self, set: &[u8]) -> &[u8];
}

impl TrimMatches for [u8] {
    fn trim_ascii_start_matches(&self, set: &[u8]) -> &[u8] {
        let start = self.iter().position(|b| !set.contains(b)).unwrap_or(self.len());
        &self[start..]
    }

    fn trim_ascii_end_matches(&self, set: &[u8]) -> &[u8] {
        let end = self.iter().rposition(|b| !set.contains(b)).map_or(0, |at| at + 1);
        &self[..end]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commands_preserve_decimal_javascript_and_validate_arguments() {
        assert_eq!(parse(b" .help "), Command::Help);
        assert_eq!(parse(b".5 + .2"), Command::Source);
        assert_eq!(parse(b".map(x => x)"), Command::Source);
        assert_eq!(parse(b".again 0"), Command::Invalid);
        assert_eq!(parse(b".again 1 extra"), Command::Invalid);
        assert_eq!(parse(b".again 2"), Command::Again(Some(2)));
        assert_eq!(parse(b".again"), Command::Again(None));
        assert_eq!(parse(b".again x"), Command::Invalid);
        assert_eq!(parse(b".complete Math.ma"), Command::Complete(b"Math.ma"));
        assert_eq!(parse(b".complete"), Command::Complete(b""));
        assert_eq!(parse(b".break"), Command::Clear);
        assert_eq!(parse(b".exit now"), Command::Invalid);
        assert_eq!(parse(b"1 + 1"), Command::Source);
    }
}
