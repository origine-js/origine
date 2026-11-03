use crate::fields::FieldList;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Client,
    Server,
}

/// Every number is a size in bytes (docs/api-guidelines.md: limits are numbers the caller sets).
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    /// Streams the peer may have open at once (`SETTINGS_MAX_CONCURRENT_STREAMS`).
    pub streams: u32,
    /// Largest header block we accept per message, counted like RFC 9113 (name + value + 32 per field).
    pub headers: u32,
    /// Window per stream (`SETTINGS_INITIAL_WINDOW_SIZE`).
    pub window: u32,
    /// Window for the whole connection.
    pub connection: u32,
    /// A header block is delivered in batches of about this many bytes.
    pub batch: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HeaderKind {
    /// A request head (server side).
    Request,
    /// A response head (client side), including a 1xx one.
    Response,
    /// Trailing fields after the body.
    Trailers,
}

/// The pseudo header fields of a message. Only the first batch of a block carries them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Pseudo {
    pub method: Option<String>,
    pub scheme: Option<String>,
    pub authority: Option<String>,
    pub path: Option<String>,
    pub status: Option<u16>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Event {
    /// The peer's SETTINGS arrived (the connection is usable).
    Settings,
    /// A batch of a header block. `last` ends the block; `end_stream` (only with `last`) means the peer
    /// sends nothing more on the stream.
    Headers {
        stream: u32,
        kind: HeaderKind,
        pseudo: Pseudo,
        fields: FieldList,
        last: bool,
        end_stream: bool,
    },
    /// Body bytes. Hand them back with `Session::consume` once used, or the peer stops sending.
    Data {
        stream: u32,
        data: Vec<u8>,
    },
    /// The peer finished its side of the stream with a DATA frame.
    End {
        stream: u32,
    },
    /// The stream is over, normally (`code` 0) or reset.
    Closed {
        stream: u32,
        code: u32,
    },
    GoAway {
        last_stream: u32,
        code: u32,
        debug: Vec<u8>,
    },
    PingAck {
        data: [u8; 8],
    },
}
