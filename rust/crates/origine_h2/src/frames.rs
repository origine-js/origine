//! HTTP/2 at the frame level, over nghttp2: what `api.http.protocols.h2` exposes.
//!
//! A [`FrameSession`] is sans-io like [`crate::Session`], but it reports every frame it receives as a
//! [`FrameEvent`] (SETTINGS, HEADERS in batches, DATA, PRIORITY, RST_STREAM, PUSH_PROMISE, PING, GOAWAY,
//! WINDOW_UPDATE, ALTSVC, ORIGIN and the extension frame types the caller registered) and lets the caller submit
//! each frame kind itself. Nothing is implied: PINGs are not answered (`ping(data, true)` is the answer), window
//! updates follow [`FrameSession::consume`] or are submitted, and SETTINGS are the caller's, every field explicit.
//!
//! Header blocks keep their pseudo header fields: a received block's [`FieldList`] starts with `:status` (or
//! `:method`, ...) in wire order, and a submitted one carries them the same way.

use crate::error::H2Error;
use crate::event::Role;
use crate::fields::FieldList;
use crate::sys;
use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::ffi::{c_int, c_void};
use std::{ptr, slice};

/// The error code sent when a header block is over `max_header_list_size` (`ENHANCE_YOUR_CALM`).
const ENHANCE_YOUR_CALM: u32 = 11;
/// RFC 9113 counts 32 bytes of overhead per field in the header list size.
const FIELD_OVERHEAD: usize = 32;
/// The largest window and window increment (2^31 - 1).
const MAX_WINDOW: u32 = i32::MAX as u32;

/// A SETTINGS parameter.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SettingId {
    HeaderTableSize,
    EnablePush,
    MaxConcurrentStreams,
    InitialWindowSize,
    MaxFrameSize,
    MaxHeaderListSize,
    EnableConnectProtocol,
    NoRfc7540Priorities,
    /// A parameter this crate has no name for (received only).
    Other(u16),
}

impl SettingId {
    pub const ALL: [SettingId; 8] = [
        SettingId::HeaderTableSize,
        SettingId::EnablePush,
        SettingId::MaxConcurrentStreams,
        SettingId::InitialWindowSize,
        SettingId::MaxFrameSize,
        SettingId::MaxHeaderListSize,
        SettingId::EnableConnectProtocol,
        SettingId::NoRfc7540Priorities,
    ];

    fn code(self) -> i32 {
        match self {
            SettingId::HeaderTableSize => sys::SETTINGS_HEADER_TABLE_SIZE,
            SettingId::EnablePush => sys::SETTINGS_ENABLE_PUSH,
            SettingId::MaxConcurrentStreams => sys::SETTINGS_MAX_CONCURRENT_STREAMS,
            SettingId::InitialWindowSize => sys::SETTINGS_INITIAL_WINDOW_SIZE,
            SettingId::MaxFrameSize => sys::SETTINGS_MAX_FRAME_SIZE,
            SettingId::MaxHeaderListSize => sys::SETTINGS_MAX_HEADER_LIST_SIZE,
            SettingId::EnableConnectProtocol => sys::SETTINGS_ENABLE_CONNECT_PROTOCOL,
            SettingId::NoRfc7540Priorities => sys::SETTINGS_NO_RFC7540_PRIORITIES,
            SettingId::Other(code) => i32::from(code),
        }
    }

    fn of(code: i32) -> SettingId {
        SettingId::ALL.into_iter().find(|id| id.code() == code).unwrap_or(SettingId::Other(code as u16))
    }
}

/// Every SETTINGS parameter, each one explicit (the caller's SETTINGS frame at the start).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Settings {
    pub header_table_size: u32,
    pub enable_push: bool,
    pub max_concurrent_streams: u32,
    pub initial_window_size: u32,
    pub max_frame_size: u32,
    pub max_header_list_size: u32,
    pub enable_connect_protocol: bool,
    pub no_rfc7540_priorities: bool,
}

impl Settings {
    /// The parameters as SETTINGS entries.
    pub fn entries(&self) -> Vec<(SettingId, u32)> {
        vec![
            (SettingId::HeaderTableSize, self.header_table_size),
            (SettingId::EnablePush, u32::from(self.enable_push)),
            (SettingId::MaxConcurrentStreams, self.max_concurrent_streams),
            (SettingId::InitialWindowSize, self.initial_window_size),
            (SettingId::MaxFrameSize, self.max_frame_size),
            (SettingId::MaxHeaderListSize, self.max_header_list_size),
            (SettingId::EnableConnectProtocol, u32::from(self.enable_connect_protocol)),
            (SettingId::NoRfc7540Priorities, u32::from(self.no_rfc7540_priorities)),
        ]
    }

    fn read(get: impl Fn(i32) -> u32) -> Settings {
        Settings {
            header_table_size: get(sys::SETTINGS_HEADER_TABLE_SIZE),
            enable_push: get(sys::SETTINGS_ENABLE_PUSH) != 0,
            max_concurrent_streams: get(sys::SETTINGS_MAX_CONCURRENT_STREAMS),
            initial_window_size: get(sys::SETTINGS_INITIAL_WINDOW_SIZE),
            max_frame_size: get(sys::SETTINGS_MAX_FRAME_SIZE),
            max_header_list_size: get(sys::SETTINGS_MAX_HEADER_LIST_SIZE),
            enable_connect_protocol: get(sys::SETTINGS_ENABLE_CONNECT_PROTOCOL) != 0,
            no_rfc7540_priorities: get(sys::SETTINGS_NO_RFC7540_PRIORITIES) != 0,
        }
    }
}

/// Whether nghttp2 applies the HTTP messaging rules of RFC 9113 section 8 to received frames.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Messaging {
    /// Header blocks must be valid requests or responses (pseudo headers, `content-length`): `frames: 'parsed'`.
    Http,
    /// Frames as they come, any header block accepted: `frames: 'raw'`.
    Raw,
}

/// How a [`FrameSession`] is made.
#[derive(Clone, Debug)]
pub struct FrameOptions {
    pub settings: Settings,
    /// The connection's receive window (at least 65535).
    pub window: u32,
    /// A header block is delivered in batches of about this many bytes.
    pub batch: u32,
    /// Bytes of padding added to every HEADERS and DATA frame (0: none); a submit can say otherwise.
    pub padding: u32,
    /// Extension frame types (not 0 to 9) received as [`FrameEvent::Unknown`]; others are dropped by nghttp2.
    pub extensions: Vec<u8>,
    pub messaging: Messaging,
}

/// What a header block is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Category {
    Request,
    Response,
    /// The response to a pushed request.
    PushResponse,
    /// Any other block: trailers, a 1xx after the first, or a block when messaging is raw.
    Headers,
    /// The request of a PUSH_PROMISE (the block is on the associated stream).
    PushPromise,
}

/// An RFC 7540 priority, as received (a PRIORITY frame, or the priority fields of HEADERS). nghttp2 1.68 sends
/// none: priorities are sent as RFC 9218 PRIORITY_UPDATE ([`FrameSession::priority_update`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Priority {
    pub depends_on: u32,
    /// 1 to 256.
    pub weight: u16,
    pub exclusive: bool,
}

impl Priority {
    fn of(spec: &sys::PrioritySpec) -> Priority {
        Priority { depends_on: spec.stream_id as u32, weight: spec.weight.clamp(1, 256) as u16, exclusive: spec.exclusive != 0 }
    }
}

/// A stream's state (RFC 9113 section 5.1).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StreamState {
    Idle,
    Open,
    ReservedLocal,
    ReservedRemote,
    HalfClosedLocal,
    HalfClosedRemote,
    Closed,
}

/// One received frame (or the end of a stream). See the module docs.
#[derive(Debug, PartialEq, Eq)]
pub enum FrameEvent {
    Settings {
        ack: bool,
        entries: Vec<(SettingId, u32)>,
    },
    /// A batch of a header block (HEADERS with its CONTINUATIONs, or PUSH_PROMISE). `last` ends the block;
    /// `end_stream`, `priority` and `padding` come with the last batch.
    Headers {
        stream: u32,
        category: Category,
        fields: FieldList,
        last: bool,
        end_stream: bool,
        priority: Option<Priority>,
        padding: usize,
    },
    /// One DATA frame's payload. Give it back with [`FrameSession::consume`] once used.
    Data {
        stream: u32,
        data: Vec<u8>,
        end_stream: bool,
        padding: usize,
    },
    Priority {
        stream: u32,
        priority: Priority,
    },
    /// RFC 9218: the priority of `stream` as a Priority field value (`u=3, i`).
    PriorityUpdate {
        stream: u32,
        value: Vec<u8>,
    },
    RstStream {
        stream: u32,
        code: u32,
    },
    /// After its header block (`Headers` with [`Category::PushPromise`] on `stream`).
    PushPromise {
        stream: u32,
        promised: u32,
    },
    Ping {
        data: [u8; 8],
        ack: bool,
    },
    GoAway {
        last_stream: u32,
        code: u32,
        debug: Vec<u8>,
    },
    WindowUpdate {
        stream: u32,
        increment: u32,
    },
    Altsvc {
        stream: u32,
        origin: Vec<u8>,
        value: Vec<u8>,
    },
    Origin {
        origins: Vec<Vec<u8>>,
    },
    /// A frame of a type registered in [`FrameOptions::extensions`].
    Unknown {
        kind: u8,
        flags: u8,
        stream: u32,
        payload: Vec<u8>,
    },
    /// A frame nghttp2 refused (it answered as RFC 9113 says); `reason` is nghttp2's text.
    Invalid {
        kind: u8,
        stream: u32,
        reason: String,
    },
    /// The stream is over: 0 normally, else the error code of the reset.
    Closed {
        stream: u32,
        code: u32,
    },
}

/// One frame-level HTTP/2 connection, as a state machine over bytes.
pub struct FrameSession {
    raw: *mut sys::nghttp2_session,
    // Dropped after `raw` is deleted (see `Drop`); callbacks reach it through a shared reference.
    state: Box<RefCell<State>>,
}

/// A header block being received (header blocks are never interleaved on a connection).
struct Block {
    stream: i32,
    category: Category,
    fields: FieldList,
    bytes: usize,
}

/// The DATA a stream sends: what `submit_data` queued, in order.
#[derive(Default)]
struct Out {
    chunks: VecDeque<Vec<u8>>,
    front_off: usize,
    /// Bytes ever queued and bytes ever packed into DATA frames.
    queued_total: u64,
    sent_total: u64,
    /// A data provider is attached in nghttp2 (until it answered EOF).
    active: bool,
    /// END_STREAM once the queue is empty.
    end: bool,
    /// A header block (trailers) to send once the queue is empty, ending the stream.
    trailers: Option<FieldList>,
    padding: Option<usize>,
    closed: bool,
}

struct State {
    events: VecDeque<FrameEvent>,
    limit: usize,
    batch: usize,
    padding: usize,
    block: Option<Block>,
    /// Payload of the DATA frame being received, per stream.
    data_in: HashMap<i32, Vec<u8>>,
    /// Received and not yet handed back with `consume`.
    unconsumed: HashMap<i32, usize>,
    /// Window to give back for data of streams that closed with bytes nobody consumed.
    connection_credit: usize,
    out: HashMap<i32, Out>,
    /// Padding asked for the next HEADERS frame of a stream.
    header_padding: HashMap<i32, usize>,
    ext_in: Vec<u8>,
    ext_out: HashMap<usize, Vec<u8>>,
    next_ext: usize,
}

fn ok(code: c_int) -> Result<(), H2Error> {
    if code < 0 { Err(H2Error::from_code(code)) } else { Ok(()) }
}

fn nvs(fields: &FieldList) -> Vec<sys::Nv> {
    // nghttp2 copies the bytes (flags 0) and never writes through these pointers.
    fields
        .iter()
        .map(|(n, v)| sys::Nv { name: n.as_ptr().cast_mut(), value: v.as_ptr().cast_mut(), namelen: n.len(), valuelen: v.len(), flags: 0 })
        .collect()
}

fn stream_id(stream: u32) -> Result<i32, H2Error> {
    i32::try_from(stream).map_err(|_| H2Error::InvalidState("a stream id is below 2^31"))
}

fn bytes_at<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        return &[];
    }
    // SAFETY: nghttp2 gives `len` readable bytes at `ptr`, valid for the callback that hands them over.
    unsafe { slice::from_raw_parts(ptr, len) }
}

impl FrameSession {
    /// Creates a session and queues its SETTINGS (the client preface goes out first).
    pub fn new(role: Role, options: &FrameOptions) -> Result<FrameSession, H2Error> {
        if options.window < 65535 || options.window > MAX_WINDOW || options.settings.initial_window_size > MAX_WINDOW {
            return Err(H2Error::InvalidState("window below 65535, or a window above 2^31-1"));
        }
        if options.batch == 0 {
            return Err(H2Error::InvalidState("batch is at least 1"));
        }
        if let Some(kind) = options.extensions.iter().find(|&&kind| kind <= sys::CONTINUATION || kind == sys::ALTSVC || kind == sys::ORIGIN)
        {
            return Err(H2Error::InvalidField(format!("frame type {kind} is not an extension")));
        }
        let state = Box::new(RefCell::new(State {
            events: VecDeque::new(),
            limit: options.settings.max_header_list_size as usize,
            batch: options.batch as usize,
            padding: options.padding as usize,
            block: None,
            data_in: HashMap::new(),
            unconsumed: HashMap::new(),
            connection_credit: 0,
            out: HashMap::new(),
            header_padding: HashMap::new(),
            ext_in: Vec::new(),
            ext_out: HashMap::new(),
            next_ext: 1,
        }));
        let user_data = (&*state as *const RefCell<State>).cast_mut().cast::<c_void>();

        let mut callbacks: *mut sys::nghttp2_session_callbacks = ptr::null_mut();
        // SAFETY: `callbacks` is a valid out pointer.
        ok(unsafe { sys::nghttp2_session_callbacks_new(&mut callbacks) })?;
        // SAFETY: `callbacks` was just created; the setter stores a function pointer of the right type.
        unsafe {
            sys::nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, on_begin_headers);
        };
        // SAFETY: `callbacks` was just created; the setter stores a function pointer of the right type.
        unsafe {
            sys::nghttp2_session_callbacks_set_on_header_callback(callbacks, on_header);
        };
        // SAFETY: `callbacks` was just created; the setter stores a function pointer of the right type.
        unsafe {
            sys::nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, on_frame_recv);
        };
        // SAFETY: `callbacks` was just created; the setter stores a function pointer of the right type.
        unsafe {
            sys::nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, on_data_chunk);
        };
        // SAFETY: `callbacks` was just created; the setter stores a function pointer of the right type.
        unsafe {
            sys::nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, on_stream_close);
        };
        // SAFETY: `callbacks` was just created; the setter stores a function pointer of the right type.
        unsafe {
            sys::nghttp2_session_callbacks_set_on_invalid_frame_recv_callback(callbacks, on_invalid_frame);
        };
        // SAFETY: `callbacks` was just created; the setter stores a function pointer of the right type.
        unsafe {
            sys::nghttp2_session_callbacks_set_select_padding_callback2(callbacks, select_padding);
        };
        // SAFETY: `callbacks` was just created; the setter stores a function pointer of the right type.
        unsafe {
            sys::nghttp2_session_callbacks_set_pack_extension_callback2(callbacks, pack_extension);
        };
        // SAFETY: `callbacks` was just created; the setter stores a function pointer of the right type.
        unsafe {
            sys::nghttp2_session_callbacks_set_unpack_extension_callback(callbacks, unpack_extension);
        };
        // SAFETY: `callbacks` was just created; the setter stores a function pointer of the right type.
        unsafe {
            sys::nghttp2_session_callbacks_set_on_extension_chunk_recv_callback(callbacks, on_extension_chunk);
        };
        let mut option: *mut sys::nghttp2_option = ptr::null_mut();
        // SAFETY: `option` is a valid out pointer.
        let option_rc = unsafe { sys::nghttp2_option_new(&mut option) };
        if option_rc == 0 {
            // SAFETY: `option` was just created and is live.
            unsafe {
                sys::nghttp2_option_set_no_auto_window_update(option, 1);
            };
            // SAFETY: `option` was just created and is live.
            unsafe {
                sys::nghttp2_option_set_no_auto_ping_ack(option, 1);
            };
            // SAFETY: `option` was just created and is live.
            unsafe {
                sys::nghttp2_option_set_no_http_messaging(option, c_int::from(options.messaging == Messaging::Raw));
            };
            // SAFETY: `option` was just created and is live.
            unsafe {
                sys::nghttp2_option_set_builtin_recv_extension_type(option, sys::ALTSVC);
            };
            // SAFETY: `option` was just created and is live.
            unsafe {
                sys::nghttp2_option_set_builtin_recv_extension_type(option, sys::ORIGIN);
            };
            // SAFETY: `option` was just created and is live.
            unsafe {
                sys::nghttp2_option_set_builtin_recv_extension_type(option, sys::PRIORITY_UPDATE);
            };
            for &kind in &options.extensions {
                // SAFETY: as above.
                unsafe { sys::nghttp2_option_set_user_recv_extension_type(option, kind) };
            }
        }
        let mut raw: *mut sys::nghttp2_session = ptr::null_mut();
        let rc = if option_rc != 0 {
            option_rc
        } else if role == Role::Client {
            // SAFETY: valid out pointer, callbacks and option; `user_data` outlives the session (see `Drop`).
            unsafe { sys::nghttp2_session_client_new2(&mut raw, callbacks, user_data, option) }
        } else {
            // SAFETY: as above.
            unsafe { sys::nghttp2_session_server_new2(&mut raw, callbacks, user_data, option) }
        };
        // SAFETY: nghttp2 copied what it needs; both objects are ours to free, whether or not it succeeded.
        unsafe { sys::nghttp2_session_callbacks_del(callbacks) };
        if !option.is_null() {
            // SAFETY: created above, freed once.
            unsafe { sys::nghttp2_option_del(option) };
        }
        ok(rc)?;
        let mut session = FrameSession { raw, state };
        session.settings(&options.settings.entries())?;
        // SAFETY: `session.raw` is live; stream 0 is the connection.
        ok(unsafe { sys::nghttp2_session_set_local_window_size(session.raw, 0, 0, options.window as i32) })?;
        Ok(session)
    }

    /// Feeds bytes received from the peer. Events are queued; read them with [`FrameSession::next_event`]. An
    /// error is fatal: send what is queued (a GOAWAY) and drop the transport.
    pub fn recv(&mut self, input: &[u8]) -> Result<(), H2Error> {
        let mut rest = input;
        while !rest.is_empty() {
            // SAFETY: `self.raw` is live; `rest` is a valid slice for the call.
            let used = unsafe { sys::nghttp2_session_mem_recv2(self.raw, rest.as_ptr(), rest.len()) };
            if used < 0 {
                return Err(H2Error::from_code(used as i32));
            }
            if used == 0 {
                return Err(H2Error::InvalidState("nghttp2 stopped reading"));
            }
            rest = &rest[used as usize..];
        }
        let credit = std::mem::take(&mut self.state.borrow_mut().connection_credit);
        if credit > 0 {
            // SAFETY: `self.raw` is live.
            ok(unsafe { sys::nghttp2_session_consume_connection(self.raw, credit) })?;
        }
        Ok(())
    }

    /// Appends every byte the session wants to send to `out` and returns how many.
    pub fn send(&mut self, out: &mut Vec<u8>) -> Result<usize, H2Error> {
        let mut total = 0;
        loop {
            let mut data: *const u8 = ptr::null();
            // SAFETY: `self.raw` is live and `data` is a valid out pointer.
            let n = unsafe { sys::nghttp2_session_mem_send2(self.raw, &mut data) };
            if n < 0 {
                return Err(H2Error::from_code(n as i32));
            }
            if n == 0 {
                return Ok(total);
            }
            // SAFETY: nghttp2 returned `n` readable bytes at `data`, valid until the next call.
            out.extend_from_slice(unsafe { slice::from_raw_parts(data, n as usize) });
            total += n as usize;
        }
    }

    pub fn next_event(&mut self) -> Option<FrameEvent> {
        self.state.borrow_mut().events.pop_front()
    }

    pub fn wants_read(&self) -> bool {
        // SAFETY: `self.raw` is live.
        unsafe { sys::nghttp2_session_want_read(self.raw) != 0 }
    }

    pub fn wants_write(&self) -> bool {
        // SAFETY: `self.raw` is live.
        unsafe { sys::nghttp2_session_want_write(self.raw) != 0 }
    }

    // ---- submits ----

    /// Queues a header block on `stream`, or (`stream` 0, a client) on a new stream; returns the stream id. A
    /// block that does not end the stream (but a 1xx response) opens the stream's DATA, which `data` feeds; a block
    /// on a stream whose DATA is still queued goes out after it, as trailers, and must end the stream.
    pub fn headers(&mut self, stream: u32, fields: &FieldList, end_stream: bool, padding: Option<usize>) -> Result<u32, H2Error> {
        let id = stream_id(stream)?;
        if id == 0 && !self.is_client() {
            return Err(H2Error::InvalidState("a server opens streams with push, not headers"));
        }
        if id != 0 {
            let mut state = self.state.borrow_mut();
            if let Some(out) = state.out.get_mut(&id).filter(|out| out.active) {
                if !end_stream {
                    return Err(H2Error::InvalidState("a header block after queued data is trailers: it ends the stream"));
                }
                if out.end || out.trailers.is_some() {
                    return Err(H2Error::InvalidState("the stream already ends"));
                }
                out.trailers = Some(fields.clone());
                if let Some(padding) = padding {
                    state.header_padding.insert(id, padding);
                }
                drop(state);
                self.resume(id)?;
                return Ok(stream);
            }
        }
        let list = nvs(fields);
        let informational = fields.get(":status").is_some_and(|status| status.first() == Some(&b'1'));
        let has_data = self.state.borrow().out.contains_key(&id);
        let opens_data = !end_stream && !informational && !has_data;
        let provider = sys::DataProvider2 { source: sys::DataSource { ptr: ptr::null_mut() }, read_callback: read_data };
        let id = if opens_data && id == 0 {
            // SAFETY: `self.raw` is live; `list` and the slices it points into outlive the call, which copies them.
            unsafe { sys::nghttp2_submit_request2(self.raw, ptr::null(), list.as_ptr(), list.len(), &provider, ptr::null_mut()) }
        } else if opens_data && !self.is_client() {
            // SAFETY: as above.
            let rc = unsafe { sys::nghttp2_submit_response2(self.raw, id, list.as_ptr(), list.len(), &provider) };
            if rc < 0 { rc } else { id }
        } else {
            let flags = if end_stream { sys::FLAG_END_STREAM } else { sys::FLAG_NONE };
            let target = if id == 0 { -1 } else { id };
            // SAFETY: as above.
            unsafe { sys::nghttp2_submit_headers(self.raw, flags, target, ptr::null(), list.as_ptr(), list.len(), ptr::null_mut()) }
        };
        ok(id)?;
        if opens_data {
            self.state.borrow_mut().out.insert(id, Out { active: true, ..Out::default() });
        }
        if let Some(padding) = padding {
            self.state.borrow_mut().header_padding.insert(id, padding);
        }
        Ok(id as u32)
    }

    /// Queues DATA on `stream`; with `end_stream` the stream ends once this is out. Returns the byte offset
    /// the stream's DATA reaches once this chunk was packed into frames (see [`FrameSession::sent`]).
    pub fn data(&mut self, stream: u32, data: Vec<u8>, end_stream: bool, padding: Option<usize>) -> Result<u64, H2Error> {
        let id = stream_id(stream)?;
        if id == 0 {
            return Err(H2Error::InvalidState("DATA is on a stream, not 0"));
        }
        let attach = {
            let mut state = self.state.borrow_mut();
            let out = state.out.entry(id).or_default();
            if out.closed || out.end || out.trailers.is_some() {
                return Err(H2Error::InvalidState("stream closed"));
            }
            out.queued_total += data.len() as u64;
            if !data.is_empty() {
                out.chunks.push_back(data);
            }
            out.end = end_stream;
            if padding.is_some() {
                out.padding = padding;
            }
            !std::mem::replace(&mut out.active, true)
        };
        let target = self.state.borrow().out.get(&id).map_or(0, |out| out.queued_total);
        if attach {
            let provider = sys::DataProvider2 { source: sys::DataSource { ptr: ptr::null_mut() }, read_callback: read_data };
            // SAFETY: `self.raw` is live; nghttp2 copies the provider.
            let rc = unsafe { sys::nghttp2_submit_data2(self.raw, sys::FLAG_END_STREAM, id, &provider) };
            if rc < 0 {
                let mut state = self.state.borrow_mut();
                if let Some(out) = state.out.get_mut(&id) {
                    out.active = false;
                    out.chunks.clear();
                    out.closed = true;
                }
                return Err(H2Error::from_code(rc));
            }
        } else {
            self.resume(id)?;
        }
        Ok(target)
    }

    /// Bytes of `stream`'s DATA packed into frames so far, and whether the stream can send no more (closed).
    pub fn sent(&self, stream: u32) -> (u64, bool) {
        let state = self.state.borrow();
        match state.out.get(&(stream as i32)) {
            Some(out) => (out.sent_total, out.closed),
            None => (0, true),
        }
    }

    fn resume(&mut self, id: i32) -> Result<(), H2Error> {
        // SAFETY: `self.raw` is live.
        let rc = unsafe { sys::nghttp2_session_resume_data(self.raw, id) };
        // -501: nothing is deferred (data is flowing, or the frame is still queued); the provider picks the
        // new bytes up when it next runs.
        if rc == sys::ERR_INVALID_ARGUMENT { Ok(()) } else { ok(rc) }
    }

    /// A client's RFC 9218 PRIORITY_UPDATE for `stream` (`value` a Priority field value, `u=3, i`). It needs the
    /// peer's `SETTINGS_NO_RFC7540_PRIORITIES` = 1 (`InvalidState` otherwise, rather than sending nothing).
    pub fn priority_update(&mut self, stream: u32, value: &[u8]) -> Result<(), H2Error> {
        if !self.is_client() {
            return Err(H2Error::InvalidState("only a client sends PRIORITY_UPDATE"));
        }
        if !self.remote_settings().no_rfc7540_priorities {
            return Err(H2Error::InvalidState("the peer has not set SETTINGS_NO_RFC7540_PRIORITIES"));
        }
        // SAFETY: `self.raw` is live and `value` outlives the call, which copies it.
        ok(unsafe { sys::nghttp2_submit_priority_update(self.raw, 0, stream_id(stream)?, value.as_ptr(), value.len()) })
    }

    pub fn rst(&mut self, stream: u32, code: u32) -> Result<(), H2Error> {
        // SAFETY: `self.raw` is live.
        ok(unsafe { sys::nghttp2_submit_rst_stream(self.raw, 0, stream_id(stream)?, code) })
    }

    /// Queues a SETTINGS frame with `entries` (any of them, any time).
    pub fn settings(&mut self, entries: &[(SettingId, u32)]) -> Result<(), H2Error> {
        let iv: Vec<sys::SettingsEntry> = entries.iter().map(|&(id, value)| sys::SettingsEntry { id: id.code(), value }).collect();
        // SAFETY: `self.raw` is live and `iv` outlives the call, which copies it.
        ok(unsafe { sys::nghttp2_submit_settings(self.raw, 0, iv.as_ptr(), iv.len()) })?;
        if let Some(&(_, limit)) = entries.iter().find(|(id, _)| *id == SettingId::MaxHeaderListSize) {
            self.state.borrow_mut().limit = limit as usize;
        }
        Ok(())
    }

    /// Queues a PING, or with `ack` the answer to one.
    pub fn ping(&mut self, data: [u8; 8], ack: bool) -> Result<(), H2Error> {
        let flags = if ack { sys::FLAG_ACK } else { sys::FLAG_NONE };
        // SAFETY: `self.raw` is live and `data` is 8 readable bytes.
        ok(unsafe { sys::nghttp2_submit_ping(self.raw, flags, data.as_ptr()) })
    }

    pub fn goaway(&mut self, last_stream: u32, code: u32, debug: &[u8]) -> Result<(), H2Error> {
        // SAFETY: `self.raw` is live and `debug` outlives the call, which copies it.
        ok(unsafe { sys::nghttp2_submit_goaway(self.raw, 0, stream_id(last_stream)?, code, debug.as_ptr(), debug.len()) })
    }

    /// Queues a WINDOW_UPDATE of `increment` (1 to 2^31-1) for `stream` (0: the connection).
    pub fn window_update(&mut self, stream: u32, increment: u32) -> Result<(), H2Error> {
        if increment == 0 || increment > MAX_WINDOW {
            return Err(H2Error::InvalidState("a window increment is 1 to 2^31-1"));
        }
        // SAFETY: `self.raw` is live.
        ok(unsafe { sys::nghttp2_submit_window_update(self.raw, 0, stream_id(stream)?, increment as i32) })
    }

    /// A server's PUSH_PROMISE on `stream` with the promised request; returns the promised stream id.
    pub fn push(&mut self, stream: u32, fields: &FieldList) -> Result<u32, H2Error> {
        let list = nvs(fields);
        // SAFETY: `self.raw` is live; `list` outlives the call, which copies it.
        let id = unsafe { sys::nghttp2_submit_push_promise(self.raw, 0, stream_id(stream)?, list.as_ptr(), list.len(), ptr::null_mut()) };
        ok(id)?;
        Ok(id as u32)
    }

    pub fn altsvc(&mut self, stream: u32, origin: &[u8], value: &[u8]) -> Result<(), H2Error> {
        // SAFETY: `self.raw` is live; both slices outlive the call, which copies them.
        ok(unsafe {
            sys::nghttp2_submit_altsvc(self.raw, 0, stream_id(stream)?, origin.as_ptr(), origin.len(), value.as_ptr(), value.len())
        })
    }

    pub fn origin(&mut self, origins: &[Vec<u8>]) -> Result<(), H2Error> {
        let ov: Vec<sys::OriginEntry> =
            origins.iter().map(|origin| sys::OriginEntry { origin: origin.as_ptr().cast_mut(), origin_len: origin.len() }).collect();
        // SAFETY: `self.raw` is live; `ov` and the origins outlive the call, which copies them.
        ok(unsafe { sys::nghttp2_submit_origin(self.raw, 0, ov.as_ptr(), ov.len()) })
    }

    /// Queues a frame of an extension type (not 0 to 9, ALTSVC or ORIGIN).
    pub fn extension(&mut self, kind: u8, flags: u8, stream: u32, payload: Vec<u8>) -> Result<(), H2Error> {
        if kind <= sys::CONTINUATION || kind == sys::ALTSVC || kind == sys::ORIGIN {
            return Err(H2Error::InvalidField(format!("frame type {kind} is not an extension")));
        }
        let key = {
            let mut state = self.state.borrow_mut();
            let key = state.next_ext;
            state.next_ext += 1;
            state.ext_out.insert(key, payload);
            key
        };
        // SAFETY: `self.raw` is live; the payload pointer is a key into our table (see `pack_extension`).
        let rc = unsafe { sys::nghttp2_submit_extension(self.raw, kind, flags, stream_id(stream)?, key as *mut c_void) };
        if rc < 0 {
            self.state.borrow_mut().ext_out.remove(&key);
        }
        ok(rc)
    }

    /// Gives `bytes` of received DATA on `stream` back to the peer's windows (the stream's and the connection's).
    pub fn consume(&mut self, stream: u32, bytes: usize) -> Result<(), H2Error> {
        let id = stream_id(stream)?;
        let n = {
            let mut state = self.state.borrow_mut();
            let Some(left) = state.unconsumed.get_mut(&id) else { return Ok(()) };
            let n = bytes.min(*left);
            *left -= n;
            n
        };
        if n == 0 {
            return Ok(());
        }
        // SAFETY: `self.raw` is live.
        ok(unsafe { sys::nghttp2_session_consume(self.raw, id, n) })
    }

    // ---- info ----

    fn is_client(&self) -> bool {
        // A client's next stream id is odd.
        self.next_stream_id() % 2 == 1
    }

    /// Our settings as the peer acknowledged them.
    pub fn local_settings(&self) -> Settings {
        // SAFETY: `self.raw` is live.
        Settings::read(|id| unsafe { sys::nghttp2_session_get_local_settings(self.raw, id) })
    }

    /// The peer's settings as last received.
    pub fn remote_settings(&self) -> Settings {
        // SAFETY: `self.raw` is live.
        Settings::read(|id| unsafe { sys::nghttp2_session_get_remote_settings(self.raw, id) })
    }

    pub fn stream_state(&self, stream: u32) -> StreamState {
        let Ok(id) = stream_id(stream) else { return StreamState::Idle };
        // SAFETY: `self.raw` is live; the stream pointer is used at once.
        let found = unsafe { sys::nghttp2_session_find_stream(self.raw, id) };
        if found.is_null() {
            return if id != 0 && (id as u32) < self.next_stream_id() || self.state.borrow().out.get(&id).is_some_and(|o| o.closed) {
                StreamState::Closed
            } else {
                StreamState::Idle
            };
        }
        // SAFETY: a live stream of this session.
        match unsafe { sys::nghttp2_stream_get_state(found) } {
            sys::STREAM_STATE_OPEN => StreamState::Open,
            sys::STREAM_STATE_RESERVED_LOCAL => StreamState::ReservedLocal,
            sys::STREAM_STATE_RESERVED_REMOTE => StreamState::ReservedRemote,
            sys::STREAM_STATE_HALF_CLOSED_LOCAL => StreamState::HalfClosedLocal,
            sys::STREAM_STATE_HALF_CLOSED_REMOTE => StreamState::HalfClosedRemote,
            sys::STREAM_STATE_CLOSED => StreamState::Closed,
            _ => StreamState::Idle,
        }
    }

    /// The windows of `stream` (0: the connection): bytes we may send, and bytes the peer may send us.
    pub fn windows(&self, stream: u32) -> (i32, i32) {
        let id = stream as i32;
        if id <= 0 {
            // SAFETY: `self.raw` is live.
            let send = unsafe { sys::nghttp2_session_get_remote_window_size(self.raw) };
            // SAFETY: as above.
            let receive = unsafe { sys::nghttp2_session_get_effective_local_window_size(self.raw) };
            return (send, receive);
        }
        // SAFETY: as above; it answers -1 for an unknown stream.
        let send = unsafe { sys::nghttp2_session_get_stream_remote_window_size(self.raw, id) };
        // SAFETY: as above.
        let receive = unsafe { sys::nghttp2_session_get_stream_effective_local_window_size(self.raw, id) };
        (send, receive)
    }

    pub fn next_stream_id(&self) -> u32 {
        // SAFETY: `self.raw` is live.
        unsafe { sys::nghttp2_session_get_next_stream_id(self.raw) }
    }
}

impl Drop for FrameSession {
    fn drop(&mut self) {
        // SAFETY: `self.raw` was created by nghttp2 and is deleted once; `state` is still alive here.
        unsafe { sys::nghttp2_session_del(self.raw) };
    }
}

// ---- callbacks: nghttp2 calls these from inside recv / send, on the caller's thread ----

/// # Safety
/// `user_data` is the pointer `FrameSession::new` gave nghttp2: a live `RefCell<State>`.
unsafe fn state<'a>(user_data: *mut c_void) -> &'a RefCell<State> {
    // SAFETY: by the contract above.
    unsafe { &*user_data.cast::<RefCell<State>>() }
}

/// # Safety
/// `frame` is the frame nghttp2 passed to a callback, valid for the whole callback.
unsafe fn frame_ref<'a>(frame: *const sys::Frame) -> &'a sys::Frame {
    // SAFETY: by the contract above.
    unsafe { &*frame }
}

fn hd_of(frame: &sys::Frame) -> sys::FrameHd {
    // SAFETY: every frame starts with its header.
    unsafe { frame.hd }
}

unsafe extern "C" fn on_begin_headers(_session: *mut sys::nghttp2_session, frame: *const sys::Frame, user_data: *mut c_void) -> c_int {
    // SAFETY: nghttp2 passes a valid frame.
    let frame = unsafe { frame_ref(frame) };
    // SAFETY: the user data is our state.
    let cell = unsafe { state(user_data) };
    let hd = hd_of(frame);
    let category = if hd.kind == sys::PUSH_PROMISE {
        Category::PushPromise
    } else {
        // SAFETY: a HEADERS frame, so this member is the one nghttp2 filled.
        match unsafe { frame.headers.cat } {
            sys::HCAT_REQUEST => Category::Request,
            sys::HCAT_RESPONSE => Category::Response,
            sys::HCAT_PUSH_RESPONSE => Category::PushResponse,
            _ => Category::Headers,
        }
    };
    let Ok(mut state) = cell.try_borrow_mut() else { return sys::ERR_CALLBACK_FAILURE };
    state.block = Some(Block { stream: hd.stream_id, category, fields: FieldList::new(), bytes: 0 });
    0
}

unsafe extern "C" fn on_header(
    session: *mut sys::nghttp2_session,
    frame: *const sys::Frame,
    name: *const u8,
    name_len: usize,
    value: *const u8,
    value_len: usize,
    _flags: u8,
    user_data: *mut c_void,
) -> c_int {
    // SAFETY: nghttp2 passes a valid frame.
    let frame = unsafe { frame_ref(frame) };
    // SAFETY: the user data is our state.
    let cell = unsafe { state(user_data) };
    let hd = hd_of(frame);
    let (name, value) = (bytes_at(name, name_len), bytes_at(value, value_len));
    let Ok(mut state) = cell.try_borrow_mut() else { return sys::ERR_CALLBACK_FAILURE };
    let (limit, batch) = (state.limit, state.batch);
    let Some(block) = state.block.as_mut() else { return sys::ERR_TEMPORAL_CALLBACK_FAILURE };
    block.bytes += name.len() + value.len() + FIELD_OVERHEAD;
    if block.bytes > limit {
        state.block = None;
        drop(state);
        // SAFETY: `session` is the live session this callback runs in.
        let _ = unsafe { sys::nghttp2_submit_rst_stream(session, 0, hd.stream_id, ENHANCE_YOUR_CALM) };
        return sys::ERR_TEMPORAL_CALLBACK_FAILURE;
    }
    block.fields.push_unchecked(name, value);
    if block.fields.as_bytes().len() >= batch {
        flush(&mut state, false, false, None, 0);
    }
    0
}

/// Moves what the header block collected so far into a `Headers` event.
fn flush(state: &mut State, last: bool, end_stream: bool, priority: Option<Priority>, padding: usize) {
    let Some(block) = state.block.as_mut() else { return };
    let fields = std::mem::take(&mut block.fields);
    let (stream, category) = (block.stream as u32, block.category);
    if last {
        state.block = None;
    }
    state.events.push_back(FrameEvent::Headers { stream, category, fields, last, end_stream, priority, padding });
}

unsafe extern "C" fn on_frame_recv(_session: *mut sys::nghttp2_session, frame: *const sys::Frame, user_data: *mut c_void) -> c_int {
    // SAFETY: nghttp2 passes a valid frame.
    let frame = unsafe { frame_ref(frame) };
    // SAFETY: the user data is our state.
    let cell = unsafe { state(user_data) };
    let hd = hd_of(frame);
    let Ok(mut state) = cell.try_borrow_mut() else { return sys::ERR_CALLBACK_FAILURE };
    let stream = hd.stream_id as u32;
    let end_stream = hd.flags & sys::FLAG_END_STREAM != 0;
    let ack = hd.flags & sys::FLAG_ACK != 0;
    // In each arm, the union member read is the one nghttp2 filled for this frame type.
    let event = match hd.kind {
        sys::DATA => {
            let data = state.data_in.remove(&hd.stream_id).unwrap_or_default();
            // SAFETY: a DATA frame.
            let padding = unsafe { frame.data }.padlen;
            FrameEvent::Data { stream, data, end_stream, padding }
        }
        sys::HEADERS => {
            // SAFETY: a HEADERS frame.
            let headers = unsafe { frame.headers };
            let priority = (hd.flags & sys::FLAG_PRIORITY != 0).then(|| Priority::of(&headers.pri_spec));
            flush(&mut state, true, end_stream, priority, headers.padlen);
            return 0;
        }
        sys::PRIORITY => {
            // SAFETY: a PRIORITY frame.
            let priority = unsafe { frame.priority };
            FrameEvent::Priority { stream, priority: Priority::of(&priority.pri_spec) }
        }
        sys::RST_STREAM => {
            // SAFETY: a RST_STREAM frame.
            let rst = unsafe { frame.rst_stream };
            FrameEvent::RstStream { stream, code: rst.error_code }
        }
        sys::SETTINGS => {
            // SAFETY: a SETTINGS frame.
            let settings = unsafe { frame.settings };
            let iv: &[sys::SettingsEntry] = if settings.iv.is_null() || settings.niv == 0 {
                &[]
            } else {
                // SAFETY: nghttp2 gives `niv` entries at `iv` for this callback.
                unsafe { slice::from_raw_parts(settings.iv, settings.niv) }
            };
            FrameEvent::Settings { ack, entries: iv.iter().map(|e| (SettingId::of(e.id), e.value)).collect() }
        }
        sys::PUSH_PROMISE => {
            // SAFETY: a PUSH_PROMISE frame.
            let push = unsafe { frame.push_promise };
            flush(&mut state, true, false, None, push.padlen);
            FrameEvent::PushPromise { stream, promised: push.promised_stream_id as u32 }
        }
        sys::PING => {
            // SAFETY: a PING frame.
            let ping = unsafe { frame.ping };
            FrameEvent::Ping { data: ping.opaque_data, ack }
        }
        sys::GOAWAY => {
            // SAFETY: a GOAWAY frame.
            let goaway = unsafe { frame.goaway };
            FrameEvent::GoAway {
                last_stream: goaway.last_stream_id as u32,
                code: goaway.error_code,
                debug: bytes_at(goaway.opaque_data, goaway.opaque_data_len).to_vec(),
            }
        }
        sys::WINDOW_UPDATE => {
            // SAFETY: a WINDOW_UPDATE frame.
            let update = unsafe { frame.window_update };
            FrameEvent::WindowUpdate { stream, increment: update.window_size_increment as u32 }
        }
        sys::ALTSVC => {
            // SAFETY: an extension frame.
            let payload = unsafe { frame.ext }.payload.cast::<sys::ExtAltsvc>();
            if payload.is_null() {
                return 0;
            }
            // SAFETY: nghttp2 unpacked an ALTSVC payload there.
            let altsvc = unsafe { &*payload };
            FrameEvent::Altsvc {
                stream,
                origin: bytes_at(altsvc.origin, altsvc.origin_len).to_vec(),
                value: bytes_at(altsvc.field_value, altsvc.field_value_len).to_vec(),
            }
        }
        sys::PRIORITY_UPDATE => {
            // SAFETY: an extension frame.
            let payload = unsafe { frame.ext }.payload.cast::<sys::ExtPriorityUpdate>();
            if payload.is_null() {
                return 0;
            }
            // SAFETY: nghttp2 unpacked a PRIORITY_UPDATE payload there.
            let update = unsafe { &*payload };
            FrameEvent::PriorityUpdate {
                stream: update.stream_id as u32,
                value: bytes_at(update.field_value, update.field_value_len).to_vec(),
            }
        }
        sys::ORIGIN => {
            // SAFETY: an extension frame.
            let payload = unsafe { frame.ext }.payload.cast::<sys::ExtOrigin>();
            if payload.is_null() {
                return 0;
            }
            // SAFETY: nghttp2 unpacked an ORIGIN payload there.
            let origin = unsafe { &*payload };
            let entries: &[sys::OriginEntry] = if origin.ov.is_null() || origin.nov == 0 {
                &[]
            } else {
                // SAFETY: nghttp2 gives `nov` entries at `ov` for this callback.
                unsafe { slice::from_raw_parts(origin.ov, origin.nov) }
            };
            FrameEvent::Origin { origins: entries.iter().map(|e| bytes_at(e.origin, e.origin_len).to_vec()).collect() }
        }
        kind => FrameEvent::Unknown { kind, flags: hd.flags, stream, payload: std::mem::take(&mut state.ext_in) },
    };
    state.events.push_back(event);
    0
}

unsafe extern "C" fn on_data_chunk(
    _session: *mut sys::nghttp2_session,
    _flags: u8,
    stream_id: i32,
    data: *const u8,
    len: usize,
    user_data: *mut c_void,
) -> c_int {
    // SAFETY: our state.
    let cell = unsafe { state(user_data) };
    let Ok(mut state) = cell.try_borrow_mut() else { return sys::ERR_CALLBACK_FAILURE };
    state.data_in.entry(stream_id).or_default().extend_from_slice(bytes_at(data, len));
    *state.unconsumed.entry(stream_id).or_default() += len;
    0
}

unsafe extern "C" fn on_stream_close(_session: *mut sys::nghttp2_session, stream_id: i32, code: u32, user_data: *mut c_void) -> c_int {
    // SAFETY: our state.
    let cell = unsafe { state(user_data) };
    let Ok(mut state) = cell.try_borrow_mut() else { return sys::ERR_CALLBACK_FAILURE };
    if let Some(left) = state.unconsumed.remove(&stream_id) {
        state.connection_credit += left;
    }
    state.data_in.remove(&stream_id);
    state.header_padding.remove(&stream_id);
    if let Some(out) = state.out.get_mut(&stream_id) {
        out.closed = true;
        out.active = false;
        out.chunks.clear();
    }
    state.events.push_back(FrameEvent::Closed { stream: stream_id as u32, code });
    0
}

unsafe extern "C" fn on_invalid_frame(
    _session: *mut sys::nghttp2_session,
    frame: *const sys::Frame,
    code: c_int,
    user_data: *mut c_void,
) -> c_int {
    // SAFETY: nghttp2 passes a valid frame.
    let frame = unsafe { frame_ref(frame) };
    // SAFETY: the user data is our state.
    let cell = unsafe { state(user_data) };
    let hd = hd_of(frame);
    let Ok(mut state) = cell.try_borrow_mut() else { return sys::ERR_CALLBACK_FAILURE };
    let reason = H2Error::from_code(code).to_string();
    state.events.push_back(FrameEvent::Invalid { kind: hd.kind, stream: hd.stream_id as u32, reason });
    0
}

unsafe extern "C" fn select_padding(
    _session: *mut sys::nghttp2_session,
    frame: *const sys::Frame,
    max: usize,
    user_data: *mut c_void,
) -> isize {
    // SAFETY: nghttp2 passes a valid frame.
    let frame = unsafe { frame_ref(frame) };
    // SAFETY: the user data is our state.
    let cell = unsafe { state(user_data) };
    let hd = hd_of(frame);
    let Ok(mut state) = cell.try_borrow_mut() else { return hd.length as isize };
    let padding = match hd.kind {
        sys::HEADERS => state.header_padding.remove(&hd.stream_id).unwrap_or(state.padding),
        sys::DATA => state.out.get(&hd.stream_id).and_then(|out| out.padding).unwrap_or(state.padding),
        _ => 0,
    };
    hd.length.saturating_add(padding).min(max) as isize
}

unsafe extern "C" fn pack_extension(
    _session: *mut sys::nghttp2_session,
    buf: *mut u8,
    len: usize,
    frame: *const sys::Frame,
    user_data: *mut c_void,
) -> isize {
    // SAFETY: nghttp2 passes a valid frame.
    let frame = unsafe { frame_ref(frame) };
    // SAFETY: the user data is our state.
    let cell = unsafe { state(user_data) };
    // SAFETY: an extension frame we submitted: its payload is the key `extension` stored.
    let key = unsafe { frame.ext }.payload as usize;
    let Ok(mut state) = cell.try_borrow_mut() else { return sys::ERR_CANCEL };
    let Some(payload) = state.ext_out.remove(&key) else { return sys::ERR_CANCEL };
    if payload.len() > len {
        return sys::ERR_CANCEL;
    }
    // SAFETY: nghttp2 gives `len` writable bytes at `buf`.
    unsafe { slice::from_raw_parts_mut(buf, payload.len()) }.copy_from_slice(&payload);
    payload.len() as isize
}

unsafe extern "C" fn unpack_extension(
    _session: *mut sys::nghttp2_session,
    payload: *mut *mut c_void,
    _hd: *const sys::FrameHd,
    _user_data: *mut c_void,
) -> c_int {
    // The bytes stay in our state (`ext_in`); `on_frame_recv` takes them.
    // SAFETY: a valid out pointer.
    unsafe { *payload = ptr::null_mut() };
    0
}

unsafe extern "C" fn on_extension_chunk(
    _session: *mut sys::nghttp2_session,
    _hd: *const sys::FrameHd,
    data: *const u8,
    len: usize,
    user_data: *mut c_void,
) -> c_int {
    // SAFETY: our state.
    let cell = unsafe { state(user_data) };
    let Ok(mut state) = cell.try_borrow_mut() else { return sys::ERR_CALLBACK_FAILURE };
    state.ext_in.extend_from_slice(bytes_at(data, len));
    0
}

unsafe extern "C" fn read_data(
    session: *mut sys::nghttp2_session,
    stream_id: i32,
    buf: *mut u8,
    length: usize,
    flags: *mut u32,
    _source: *mut sys::DataSource,
    user_data: *mut c_void,
) -> isize {
    // SAFETY: nghttp2 gives `length` writable bytes at `buf`.
    let dst = unsafe { slice::from_raw_parts_mut(buf, length) };
    // SAFETY: our state.
    let cell = unsafe { state(user_data) };
    let Ok(mut state) = cell.try_borrow_mut() else { return sys::ERR_CALLBACK_FAILURE as isize };
    let Some(out) = state.out.get_mut(&stream_id) else { return sys::ERR_TEMPORAL_CALLBACK_FAILURE as isize };
    let mut n = 0;
    while n < length {
        let Some(front) = out.chunks.front() else { break };
        let take = (front.len() - out.front_off).min(length - n);
        dst[n..n + take].copy_from_slice(&front[out.front_off..out.front_off + take]);
        n += take;
        out.front_off += take;
        if out.front_off == front.len() {
            out.chunks.pop_front();
            out.front_off = 0;
        }
    }
    out.sent_total += n as u64;
    if !out.chunks.is_empty() || !(out.end || out.trailers.is_some()) {
        return if n == 0 { sys::ERR_DEFERRED } else { n as isize };
    }
    out.active = false;
    // SAFETY: `flags` is a valid out pointer.
    unsafe { *flags |= sys::DATA_FLAG_EOF };
    if let Some(trailers) = out.trailers.take() {
        out.end = true;
        // The DATA frame must not end the stream: the trailers do.
        // SAFETY: as above.
        unsafe { *flags |= sys::DATA_FLAG_NO_END_STREAM };
        drop(state);
        let list = nvs(&trailers);
        // SAFETY: `session` is the live session this callback runs in; `list` outlives the call, which copies it.
        let rc = unsafe { sys::nghttp2_submit_trailer(session, stream_id, list.as_ptr(), list.len()) };
        if rc < 0 {
            return sys::ERR_TEMPORAL_CALLBACK_FAILURE as isize;
        }
    }
    n as isize
}
