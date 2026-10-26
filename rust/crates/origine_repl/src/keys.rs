//! Terminal input bytes to key presses. An incremental decoder: the caller feeds one byte at a
//! time, and reports a pause (`timeout`) when a read for the next byte timed out, which is how a
//! lone Escape is told from the start of an escape sequence.

/// One decoded key press.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    /// One complete character.
    Text(char),
    /// Ctrl plus a letter, named by the lowercase letter (`Ctrl(b'a')` is Ctrl-A).
    Ctrl(u8),
    /// Alt plus a printable ASCII character.
    Alt(u8),
    Enter,
    Tab,
    Backspace,
    Delete,
    Left,
    Right,
    Up,
    Down,
    Home,
    End,
    WordLeft,
    WordRight,
    AltBackspace,
    Undo,
    /// A lone Escape, or a sequence that is not understood.
    Ignored,
}

#[derive(Default)]
enum State {
    #[default]
    Ground,
    /// Inside a multi-byte UTF-8 character.
    Utf8 { bytes: [u8; 4], have: usize, need: usize },
    /// After Escape.
    Escape,
    /// Inside `Esc [`: up to four numeric parameters.
    Csi { params: [u16; 4], count: usize },
    /// After `Esc O`.
    Ss3,
}

#[derive(Default)]
pub struct Decoder {
    state: State,
}

impl Decoder {
    /// Whether the decoder is inside an escape sequence, so the caller should arm a short timeout.
    pub fn in_sequence(&self) -> bool {
        matches!(self.state, State::Escape | State::Csi { .. } | State::Ss3)
    }

    /// The next byte arrived; returns the key it completes, if any.
    pub fn feed(&mut self, byte: u8) -> Option<Key> {
        match std::mem::take(&mut self.state) {
            State::Ground => self.ground(byte),
            State::Utf8 { mut bytes, have, need } => {
                if byte & 0xc0 != 0x80 {
                    return Some(Key::Ignored); // truncated sequence
                }
                bytes[have] = byte;
                let have = have + 1;
                if have < need {
                    self.state = State::Utf8 { bytes, have, need };
                    return None;
                }
                Some(std::str::from_utf8(&bytes[..have]).ok().and_then(|text| text.chars().next()).map_or(Key::Ignored, Key::Text))
            }
            State::Escape => match byte {
                b'[' => {
                    self.state = State::Csi { params: [0; 4], count: 0 };
                    None
                }
                b'O' => {
                    self.state = State::Ss3;
                    None
                }
                127 | 8 => Some(Key::AltBackspace),
                32..=126 => Some(Key::Alt(byte)),
                _ => Some(Key::Ignored),
            },
            State::Ss3 => Some(csi(byte, 0, 0)),
            State::Csi { mut params, mut count } => match byte {
                b'0'..=b'9' => {
                    if count < params.len() {
                        params[count] = params[count].saturating_mul(10).saturating_add(u16::from(byte - b'0'));
                    }
                    self.state = State::Csi { params, count };
                    None
                }
                b';' => {
                    count = (count + 1).min(params.len() - 1);
                    self.state = State::Csi { params, count };
                    None
                }
                0x40..=0x7e => Some(csi(byte, params[0], params[1])),
                _ => {
                    self.state = State::Csi { params, count };
                    None
                }
            },
        }
    }

    /// A read for the next byte timed out: an unfinished escape sequence is abandoned.
    pub fn timeout(&mut self) -> Option<Key> {
        let pending = self.in_sequence();
        self.state = State::Ground;
        pending.then_some(Key::Ignored)
    }

    fn ground(&mut self, lead: u8) -> Option<Key> {
        Some(match lead {
            27 => {
                self.state = State::Escape;
                return None;
            }
            b'\r' | b'\n' => Key::Enter,
            b'\t' => Key::Tab,
            127 | 8 => Key::Backspace,
            31 => Key::Undo,
            1..=26 => Key::Ctrl(b'a' + lead - 1),
            32..=126 => Key::Text(char::from(lead)),
            0xc2..=0xf4 => {
                let need = if lead >= 0xf0 {
                    4
                } else if lead >= 0xe0 {
                    3
                } else {
                    2
                };
                self.state = State::Utf8 { bytes: [lead, 0, 0, 0], have: 1, need };
                return None;
            }
            _ => Key::Ignored,
        })
    }
}

/// Maps a CSI sequence's final byte and first two numeric parameters to a key.
fn csi(final_byte: u8, first: u16, modifier: u16) -> Key {
    // xterm modifiers: 3 = Alt, 5 = Ctrl; either one turns arrows into word motions.
    let word = modifier == 3 || modifier == 5;
    match final_byte {
        b'A' => Key::Up,
        b'B' => Key::Down,
        b'C' if word => Key::WordRight,
        b'C' => Key::Right,
        b'D' if word => Key::WordLeft,
        b'D' => Key::Left,
        b'H' => Key::Home,
        b'F' => Key::End,
        b'~' => match first {
            1 | 7 => Key::Home,
            3 => Key::Delete,
            4 | 8 => Key::End,
            _ => Key::Ignored,
        },
        _ => Key::Ignored,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keys(bytes: &[u8]) -> Vec<Key> {
        let mut decoder = Decoder::default();
        bytes.iter().filter_map(|&byte| decoder.feed(byte)).collect()
    }

    #[test]
    fn plain_bytes_and_controls() {
        assert_eq!(keys(b"a\r\t\x7f\x01\x1f"), [Key::Text('a'), Key::Enter, Key::Tab, Key::Backspace, Key::Ctrl(b'a'), Key::Undo]);
    }

    #[test]
    fn utf8_sequences_decode_and_truncated_ones_are_ignored() {
        assert_eq!(keys("貓é😀".as_bytes()), [Key::Text('貓'), Key::Text('é'), Key::Text('😀')]);
        assert_eq!(keys(&[0xe8, b'a']), [Key::Ignored]);
        assert_eq!(keys(&[0x80]), [Key::Ignored]);
        assert_eq!(keys(&[0xc0, 0x80]), [Key::Ignored, Key::Ignored], "overlong leads are not accepted");
    }

    #[test]
    fn escape_sequences_map_to_word_motions_home_and_end() {
        assert_eq!(keys(b"\x1b[1;5C"), [Key::WordRight]);
        assert_eq!(keys(b"\x1b[1;3D"), [Key::WordLeft]);
        assert_eq!(keys(b"\x1b[C"), [Key::Right]);
        assert_eq!(keys(b"\x1b[3~"), [Key::Delete]);
        assert_eq!(keys(b"\x1b[1~"), [Key::Home]);
        assert_eq!(keys(b"\x1b[8~"), [Key::End]);
        assert_eq!(keys(b"\x1bOH"), [Key::Home]);
        assert_eq!(keys(b"\x1b[99~"), [Key::Ignored]);
        assert_eq!(keys(b"\x1bb\x1b\x7f"), [Key::Alt(b'b'), Key::AltBackspace]);
    }

    #[test]
    fn a_pause_abandons_an_unfinished_sequence() {
        let mut decoder = Decoder::default();
        assert_eq!(decoder.feed(27), None);
        assert!(decoder.in_sequence());
        assert_eq!(decoder.timeout(), Some(Key::Ignored));
        assert!(!decoder.in_sequence());
        assert_eq!(decoder.timeout(), None);
        assert_eq!(decoder.feed(b'x'), Some(Key::Text('x')));
    }
}
