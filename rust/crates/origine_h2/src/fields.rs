use crate::error::H2Error;

/// An ordered sequence of header fields, packed into one buffer: for each field
/// `name_len: u16 LE | value_len: u32 LE | name | value`. It is a sequence, not a map: duplicates
/// and order are kept. Names are lowercase; pseudo headers (`:method`, `:status`, ...) are not fields
/// and travel separately.
///
/// The packed form is what crosses the JS boundary: one buffer per batch instead of one call per field.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct FieldList {
    buf: Vec<u8>,
    count: usize,
}

const HEAD: usize = 6;

/// Fields HTTP/2 forbids (RFC 9113 section 8.2.2), besides `te` which only allows `trailers`.
const CONNECTION_SPECIFIC: [&str; 5] = ["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade"];

fn token_byte(b: u8) -> bool {
    b.is_ascii_lowercase() || b.is_ascii_digit() || b"!#$%&'*+-.^_`|~".contains(&b)
}

impl FieldList {
    pub fn new() -> FieldList {
        FieldList::default()
    }

    /// Appends a field after checking it. `name` must be lowercase, a token, and not a connection-specific
    /// or pseudo header; `value` must not hold NUL, CR or LF.
    pub fn put(&mut self, name: &[u8], value: &[u8]) -> Result<(), H2Error> {
        if name.is_empty() || name.len() > u16::MAX as usize || !name.iter().copied().all(token_byte) {
            return Err(H2Error::InvalidField(format!("bad name {:?} (lowercase token required)", String::from_utf8_lossy(name))));
        }
        let text = std::str::from_utf8(name).unwrap_or_default();
        if CONNECTION_SPECIFIC.contains(&text) || (text == "te" && value != b"trailers") {
            return Err(H2Error::InvalidField(format!("{text} is not allowed in HTTP/2")));
        }
        if value.len() > u32::MAX as usize || value.iter().any(|&b| b == 0 || b == b'\r' || b == b'\n') {
            return Err(H2Error::InvalidField(format!("bad value for {text}")));
        }
        self.push_unchecked(name, value);
        Ok(())
    }

    /// For fields nghttp2 already validated.
    pub(crate) fn push_unchecked(&mut self, name: &[u8], value: &[u8]) {
        self.buf.extend_from_slice(&(name.len() as u16).to_le_bytes());
        self.buf.extend_from_slice(&(value.len() as u32).to_le_bytes());
        self.buf.extend_from_slice(name);
        self.buf.extend_from_slice(value);
        self.count += 1;
    }

    /// Takes a packed buffer built elsewhere (the JS side), checking only that it is well formed:
    /// names and values are validated when the list is submitted.
    pub fn from_packed(buf: Vec<u8>) -> Result<FieldList, H2Error> {
        let mut at = 0;
        let mut count = 0;
        while at < buf.len() {
            let head = buf.get(at..at + HEAD).ok_or(H2Error::BadPacking)?;
            let name = u16::from_le_bytes([head[0], head[1]]) as usize;
            let value = u32::from_le_bytes([head[2], head[3], head[4], head[5]]) as usize;
            at = at.checked_add(HEAD + name).and_then(|n| n.checked_add(value)).ok_or(H2Error::BadPacking)?;
            if at > buf.len() {
                return Err(H2Error::BadPacking);
            }
            count += 1;
        }
        Ok(FieldList { buf, count })
    }

    /// The same fields, every one checked as [`FieldList::put`] checks it: for a list that came from outside.
    pub fn checked(&self) -> Result<FieldList, H2Error> {
        let mut list = FieldList::new();
        for (name, value) in self.iter() {
            list.put(name, value)?;
        }
        Ok(list)
    }

    pub fn len(&self) -> usize {
        self.count
    }

    pub fn is_empty(&self) -> bool {
        self.count == 0
    }

    /// The packed bytes.
    pub fn as_bytes(&self) -> &[u8] {
        &self.buf
    }

    pub fn into_bytes(self) -> Vec<u8> {
        self.buf
    }

    pub fn iter(&self) -> Fields<'_> {
        Fields { rest: &self.buf }
    }

    /// The first value of `name` (lowercase).
    pub fn get(&self, name: &str) -> Option<&[u8]> {
        self.iter().find(|(n, _)| *n == name.as_bytes()).map(|(_, v)| v)
    }

    /// Every value of `name`, in order.
    pub fn get_all<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a [u8]> + 'a {
        self.iter().filter(move |(n, _)| *n == name.as_bytes()).map(|(_, v)| v)
    }
}

impl std::fmt::Debug for FieldList {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_list().entries(self.iter().map(|(n, v)| (String::from_utf8_lossy(n), String::from_utf8_lossy(v)))).finish()
    }
}

pub struct Fields<'a> {
    rest: &'a [u8],
}

impl<'a> Iterator for Fields<'a> {
    type Item = (&'a [u8], &'a [u8]);

    fn next(&mut self) -> Option<Self::Item> {
        if self.rest.is_empty() {
            return None;
        }
        // The buffer was checked when it was built, so these slices are in range.
        let name = u16::from_le_bytes([self.rest[0], self.rest[1]]) as usize;
        let value = u32::from_le_bytes([self.rest[2], self.rest[3], self.rest[4], self.rest[5]]) as usize;
        let (name_at, value_at, end) = (HEAD, HEAD + name, HEAD + name + value);
        let item = (&self.rest[name_at..value_at], &self.rest[value_at..end]);
        self.rest = &self.rest[end..];
        Some(item)
    }
}

impl<'a> IntoIterator for &'a FieldList {
    type Item = (&'a [u8], &'a [u8]);
    type IntoIter = Fields<'a>;

    fn into_iter(self) -> Fields<'a> {
        self.iter()
    }
}
