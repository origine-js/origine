use crate::error::H2Error;
use crate::event::{Event, HeaderKind, Limits, Pseudo, Role};
use crate::fields::FieldList;
use crate::sys;
use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::ffi::{c_int, c_void};
use std::{ptr, slice};

/// The error code sent when a header block is over the limit (`ENHANCE_YOUR_CALM`).
const ENHANCE_YOUR_CALM: u32 = 11;
/// RFC 9113 counts 32 bytes of overhead per field in the header list size.
const FIELD_OVERHEAD: usize = 32;

/// Whether a message has a body the caller feeds with [`Session::send_data`] and [`Session::finish`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Body {
    /// No body: the head carries END_STREAM.
    None,
    /// A body follows (possibly empty), then `finish`.
    Stream,
}

/// The pseudo headers of a request.
#[derive(Clone, Copy, Debug)]
pub struct RequestHead<'a> {
    pub method: &'a str,
    pub scheme: &'a str,
    pub authority: &'a str,
    pub path: &'a str,
}

/// One HTTP/2 connection, as a state machine over bytes. Not `Send`: it lives on the loop thread.
pub struct Session {
    raw: *mut sys::nghttp2_session,
    // Dropped after `raw` is deleted (see `Drop`); callbacks reach it through a shared reference.
    state: Box<RefCell<State>>,
}

struct State {
    role: Role,
    limits: Limits,
    events: VecDeque<Event>,
    streams: HashMap<i32, Stream>,
    /// Window to give back for data of streams that closed with bytes nobody consumed.
    connection_credit: usize,
}

#[derive(Default)]
struct Stream {
    kind: Option<HeaderKind>,
    pseudo: Pseudo,
    pending: FieldList,
    header_bytes: usize,
    final_seen: bool,
    /// Received and not yet handed back with `consume`.
    unconsumed: usize,
    out: Option<OutBody>,
}

struct OutBody {
    chunks: VecDeque<Vec<u8>>,
    front_off: usize,
    queued: usize,
    eof: bool,
    trailers: Option<FieldList>,
}

fn ok(code: c_int) -> Result<(), H2Error> {
    if code < 0 { Err(H2Error::from_code(code)) } else { Ok(()) }
}

fn nv(name: &[u8], value: &[u8]) -> sys::Nv {
    // nghttp2 copies the bytes (flags 0) and never writes through these pointers.
    sys::Nv { name: name.as_ptr().cast_mut(), value: value.as_ptr().cast_mut(), namelen: name.len(), valuelen: value.len(), flags: 0 }
}

fn nvs<'a>(pseudo: &'a [(&'static str, &'a [u8])], fields: &'a FieldList) -> Vec<sys::Nv> {
    pseudo.iter().map(|(n, v)| nv(n.as_bytes(), v)).chain(fields.iter().map(|(n, v)| nv(n, v))).collect()
}

fn check_pseudo(name: &str, value: &str) -> Result<(), H2Error> {
    if value.is_empty() || value.bytes().any(|b| b <= b' ' || b == 0x7f) {
        return Err(H2Error::InvalidField(format!("bad {name}")));
    }
    Ok(())
}

impl Session {
    /// Creates a session and queues our SETTINGS (the client preface goes out first). Call
    /// [`Session::send`] to get the bytes.
    pub fn new(role: Role, limits: Limits) -> Result<Session, H2Error> {
        if limits.connection < 65535 || limits.connection > i32::MAX as u32 || limits.window > i32::MAX as u32 {
            return Err(H2Error::InvalidState("connection window below 65535, or a window above 2^31-1"));
        }
        let state = Box::new(RefCell::new(State { role, limits, events: VecDeque::new(), streams: HashMap::new(), connection_credit: 0 }));
        let user_data = (&*state as *const RefCell<State>).cast_mut().cast::<c_void>();

        let mut callbacks: *mut sys::nghttp2_session_callbacks = ptr::null_mut();
        // SAFETY: `callbacks` is a valid out pointer.
        ok(unsafe { sys::nghttp2_session_callbacks_new(&mut callbacks) })?;
        // SAFETY: `callbacks` was just created; each setter stores a function pointer of the right type.
        unsafe { sys::nghttp2_session_callbacks_set_on_begin_headers_callback(callbacks, on_begin_headers) };
        // SAFETY: as above.
        unsafe { sys::nghttp2_session_callbacks_set_on_header_callback(callbacks, on_header) };
        // SAFETY: as above.
        unsafe { sys::nghttp2_session_callbacks_set_on_frame_recv_callback(callbacks, on_frame_recv) };
        // SAFETY: as above.
        unsafe { sys::nghttp2_session_callbacks_set_on_data_chunk_recv_callback(callbacks, on_data_chunk) };
        // SAFETY: as above.
        unsafe { sys::nghttp2_session_callbacks_set_on_stream_close_callback(callbacks, on_stream_close) };
        let mut option: *mut sys::nghttp2_option = ptr::null_mut();
        // SAFETY: `option` is a valid out pointer.
        let option_rc = unsafe { sys::nghttp2_option_new(&mut option) };
        if option_rc == 0 {
            // SAFETY: `option` was just created.
            unsafe { sys::nghttp2_option_set_no_auto_window_update(option, 1) };
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

        let mut session = Session { raw, state };
        session.submit_initial_settings()?;
        Ok(session)
    }

    fn submit_initial_settings(&mut self) -> Result<(), H2Error> {
        let limits = self.state.borrow().limits;
        let mut iv = Vec::with_capacity(4);
        if self.state.borrow().role == Role::Client {
            iv.push(sys::SettingsEntry { id: sys::SETTINGS_ENABLE_PUSH, value: 0 });
        }
        iv.push(sys::SettingsEntry { id: sys::SETTINGS_MAX_CONCURRENT_STREAMS, value: limits.streams });
        iv.push(sys::SettingsEntry { id: sys::SETTINGS_INITIAL_WINDOW_SIZE, value: limits.window });
        iv.push(sys::SettingsEntry { id: sys::SETTINGS_MAX_HEADER_LIST_SIZE, value: limits.headers });
        // SAFETY: `self.raw` is live and `iv` outlives the call, which copies it.
        ok(unsafe { sys::nghttp2_submit_settings(self.raw, 0, iv.as_ptr(), iv.len()) })?;
        // SAFETY: `self.raw` is live; stream 0 is the connection.
        ok(unsafe { sys::nghttp2_session_set_local_window_size(self.raw, 0, 0, limits.connection as i32) })
    }

    /// Feeds bytes received from the peer. Events are queued; read them with [`Session::next_event`].
    /// An error is fatal: send what is queued (a GOAWAY) and drop the transport.
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

    /// The next thing that happened, if any.
    pub fn next_event(&mut self) -> Option<Event> {
        self.state.borrow_mut().events.pop_front()
    }

    /// The session can still read from the peer.
    pub fn wants_read(&self) -> bool {
        // SAFETY: `self.raw` is live.
        unsafe { sys::nghttp2_session_want_read(self.raw) != 0 }
    }

    /// The session has bytes to send, or will have after more input.
    pub fn wants_write(&self) -> bool {
        // SAFETY: `self.raw` is live.
        unsafe { sys::nghttp2_session_want_write(self.raw) != 0 }
    }

    /// Opens a request stream and queues its head. Returns the stream id. A request over the peer's
    /// concurrency limit waits inside nghttp2 until a slot frees.
    pub fn submit_request(&mut self, head: &RequestHead<'_>, fields: &FieldList, body: Body) -> Result<u32, H2Error> {
        check_pseudo(":method", head.method)?;
        check_pseudo(":scheme", head.scheme)?;
        check_pseudo(":authority", head.authority)?;
        check_pseudo(":path", head.path)?;
        let pseudo: [(&'static str, &[u8]); 4] = [
            (":method", head.method.as_bytes()),
            (":scheme", head.scheme.as_bytes()),
            (":authority", head.authority.as_bytes()),
            (":path", head.path.as_bytes()),
        ];
        let list = nvs(&pseudo, fields);
        let provider = sys::DataProvider2 { source: sys::DataSource { ptr: ptr::null_mut() }, read_callback: read_body };
        let provider_ptr = if body == Body::Stream { &provider as *const sys::DataProvider2 } else { ptr::null() };
        // SAFETY: `self.raw` is live; `list` and the slices it points into outlive the call, which copies them.
        let id = unsafe { sys::nghttp2_submit_request2(self.raw, ptr::null(), list.as_ptr(), list.len(), provider_ptr, ptr::null_mut()) };
        ok(id)?;
        let stream = Stream { out: (body == Body::Stream).then(OutBody::new), ..Stream::default() };
        self.state.borrow_mut().streams.insert(id, stream);
        Ok(id as u32)
    }

    /// Queues the response head of a request stream.
    pub fn submit_response(&mut self, stream: u32, status: u16, fields: &FieldList, body: Body) -> Result<(), H2Error> {
        let id = stream as i32;
        if !self.state.borrow().streams.contains_key(&id) {
            return Err(H2Error::InvalidState("no such stream"));
        }
        let status_text = status.to_string();
        let pseudo: [(&'static str, &[u8]); 1] = [(":status", status_text.as_bytes())];
        let list = nvs(&pseudo, fields);
        if body == Body::Stream
            && let Some(s) = self.state.borrow_mut().streams.get_mut(&id)
        {
            s.out = Some(OutBody::new());
        }
        let provider = sys::DataProvider2 { source: sys::DataSource { ptr: ptr::null_mut() }, read_callback: read_body };
        let provider_ptr = if body == Body::Stream { &provider as *const sys::DataProvider2 } else { ptr::null() };
        // SAFETY: as in `submit_request`.
        ok(unsafe { sys::nghttp2_submit_response2(self.raw, id, list.as_ptr(), list.len(), provider_ptr) })
    }

    /// Queues body bytes of a stream opened with [`Body::Stream`].
    pub fn send_data(&mut self, stream: u32, data: Vec<u8>) -> Result<(), H2Error> {
        {
            let mut state = self.state.borrow_mut();
            let out = state
                .streams
                .get_mut(&(stream as i32))
                .and_then(|s| s.out.as_mut())
                .ok_or(H2Error::InvalidState("stream has no body to feed"))?;
            if out.eof {
                return Err(H2Error::InvalidState("body already finished"));
            }
            if !data.is_empty() {
                out.queued += data.len();
                out.chunks.push_back(data);
            }
        }
        self.resume(stream)
    }

    /// Bytes accepted by `send_data` that nghttp2 has not sent yet: the caller's backpressure signal.
    pub fn queued(&self, stream: u32) -> usize {
        self.state.borrow().streams.get(&(stream as i32)).and_then(|s| s.out.as_ref()).map_or(0, |o| o.queued)
    }

    /// Ends a body, optionally followed by trailing fields.
    pub fn finish(&mut self, stream: u32, trailers: Option<FieldList>) -> Result<(), H2Error> {
        {
            let mut state = self.state.borrow_mut();
            let out = state
                .streams
                .get_mut(&(stream as i32))
                .and_then(|s| s.out.as_mut())
                .ok_or(H2Error::InvalidState("stream has no body to finish"))?;
            if out.eof {
                return Err(H2Error::InvalidState("body already finished"));
            }
            out.eof = true;
            out.trailers = trailers.filter(|t| !t.is_empty());
        }
        self.resume(stream)
    }

    fn resume(&mut self, stream: u32) -> Result<(), H2Error> {
        // SAFETY: `self.raw` is live.
        let rc = unsafe { sys::nghttp2_session_resume_data(self.raw, stream as i32) };
        // nghttp2.h documents -501 as "the stream does not exist; or no deferred data exist" (the code
        // returns it when the stream is missing or nothing is deferred). Callers checked above that the
        // stream is one of ours, so what is left is "nothing deferred": the head is still queued in
        // nghttp2 (it has no stream object yet) or data is already flowing, and the read callback picks
        // the new bytes up when it next runs.
        if rc == sys::ERR_INVALID_ARGUMENT { Ok(()) } else { ok(rc) }
    }

    /// Tells the session that `bytes` of received data on `stream` were used, returning that window to
    /// the peer. Bytes beyond what was received and not yet consumed are ignored.
    pub fn consume(&mut self, stream: u32, bytes: usize) -> Result<(), H2Error> {
        let id = stream as i32;
        let n = {
            let mut state = self.state.borrow_mut();
            let Some(s) = state.streams.get_mut(&id) else { return Ok(()) };
            let n = bytes.min(s.unconsumed);
            s.unconsumed -= n;
            n
        };
        if n == 0 {
            return Ok(());
        }
        // SAFETY: `self.raw` is live.
        ok(unsafe { sys::nghttp2_session_consume(self.raw, id, n) })
    }

    /// Resets a stream (RST_STREAM) with an HTTP/2 error code.
    pub fn reset(&mut self, stream: u32, code: u32) -> Result<(), H2Error> {
        // SAFETY: `self.raw` is live.
        ok(unsafe { sys::nghttp2_submit_rst_stream(self.raw, 0, stream as i32, code) })
    }

    /// The peer's SETTINGS_MAX_CONCURRENT_STREAMS as last received; `u32::MAX` while the peer set none.
    pub fn peer_streams(&self) -> u32 {
        // SAFETY: `self.raw` is live.
        unsafe { sys::nghttp2_session_get_remote_settings(self.raw, sys::SETTINGS_MAX_CONCURRENT_STREAMS) }
    }

    /// Starts closing the connection: queues GOAWAY with `code`; streams already processed finish.
    pub fn goaway(&mut self, code: u32) -> Result<(), H2Error> {
        // SAFETY: `self.raw` is live.
        ok(unsafe { sys::nghttp2_session_terminate_session(self.raw, code) })
    }

    /// Queues a PING; the reply arrives as [`Event::PingAck`] with the same bytes.
    pub fn ping(&mut self, data: [u8; 8]) -> Result<(), H2Error> {
        // SAFETY: `self.raw` is live and `data` is 8 readable bytes.
        ok(unsafe { sys::nghttp2_submit_ping(self.raw, 0, data.as_ptr()) })
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        // SAFETY: `self.raw` was created by nghttp2 and is deleted once; `state` (the callbacks' user
        // data) is still alive here and is dropped after this returns.
        unsafe { sys::nghttp2_session_del(self.raw) };
    }
}

impl OutBody {
    fn new() -> OutBody {
        OutBody { chunks: VecDeque::new(), front_off: 0, queued: 0, eof: false, trailers: None }
    }
}

// ---- callbacks: nghttp2 calls these from inside recv / send, on the caller's thread ----

/// # Safety
/// `user_data` is the pointer `Session::new` gave nghttp2: a live `RefCell<State>`.
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

fn frame_hd(frame: &sys::Frame) -> sys::FrameHd {
    // SAFETY: every frame starts with its header, so this member is always initialised.
    unsafe { frame.hd }
}

unsafe extern "C" fn on_begin_headers(_session: *mut sys::nghttp2_session, frame: *const sys::Frame, user_data: *mut c_void) -> c_int {
    // SAFETY: nghttp2 passes a valid frame.
    let frame = unsafe { frame_ref(frame) };
    let hd = frame_hd(frame);
    if hd.kind != sys::HEADERS {
        return 0;
    }
    // SAFETY: a HEADERS frame, so this member is the one nghttp2 filled.
    let cat = unsafe { frame.headers.cat };
    // SAFETY: the user data is our state.
    let Ok(mut state) = (unsafe { state(user_data) }).try_borrow_mut() else { return sys::ERR_CALLBACK_FAILURE };
    let role = state.role;
    let stream = state.streams.entry(hd.stream_id).or_default();
    let kind = match (cat, role) {
        (sys::HCAT_REQUEST, _) => HeaderKind::Request,
        (sys::HCAT_RESPONSE, _) => HeaderKind::Response,
        (sys::HCAT_HEADERS, Role::Client) if !stream.final_seen => HeaderKind::Response,
        (sys::HCAT_HEADERS, _) => HeaderKind::Trailers,
        // We never enable push; refuse a promised stream.
        _ => return sys::ERR_TEMPORAL_CALLBACK_FAILURE,
    };
    stream.kind = Some(kind);
    stream.pseudo = Pseudo::default();
    stream.pending = FieldList::new();
    stream.header_bytes = 0;
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
    let hd = frame_hd(unsafe { frame_ref(frame) });
    // SAFETY: `name` and `value` point at the given lengths, valid for this call.
    let name = unsafe { slice::from_raw_parts(name, name_len) };
    // SAFETY: as above.
    let value = unsafe { slice::from_raw_parts(value, value_len) };
    // SAFETY: the user data is our state.
    let Ok(mut state) = (unsafe { state(user_data) }).try_borrow_mut() else { return sys::ERR_CALLBACK_FAILURE };
    let (limit, batch) = (state.limits.headers as usize, state.limits.batch as usize);
    let Some(stream) = state.streams.get_mut(&hd.stream_id) else { return sys::ERR_TEMPORAL_CALLBACK_FAILURE };
    stream.header_bytes += name.len() + value.len() + FIELD_OVERHEAD;
    if stream.header_bytes > limit {
        drop(state);
        // SAFETY: `session` is the live session this callback runs in.
        let _ = unsafe { sys::nghttp2_submit_rst_stream(session, 0, hd.stream_id, ENHANCE_YOUR_CALM) };
        return sys::ERR_TEMPORAL_CALLBACK_FAILURE;
    }
    if name.first() == Some(&b':') {
        let text = || String::from_utf8_lossy(value).into_owned();
        match name {
            b":method" => stream.pseudo.method = Some(text()),
            b":scheme" => stream.pseudo.scheme = Some(text()),
            b":authority" => stream.pseudo.authority = Some(text()),
            b":path" => stream.pseudo.path = Some(text()),
            b":status" => stream.pseudo.status = text().parse().ok(),
            _ => {}
        }
    } else {
        stream.pending.push_unchecked(name, value);
    }
    if stream.pending.as_bytes().len() >= batch {
        flush(&mut state, hd.stream_id, false, false);
    }
    0
}

/// Moves what the stream collected so far into a `Headers` event.
fn flush(state: &mut State, stream_id: i32, last: bool, end_stream: bool) {
    let Some(stream) = state.streams.get_mut(&stream_id) else { return };
    let Some(kind) = stream.kind else { return };
    let fields = std::mem::take(&mut stream.pending);
    let pseudo = std::mem::take(&mut stream.pseudo);
    if last && kind == HeaderKind::Response && pseudo.status.is_some_and(|s| s >= 200) {
        stream.final_seen = true;
    }
    state.events.push_back(Event::Headers { stream: stream_id as u32, kind, pseudo, fields, last, end_stream });
}

unsafe extern "C" fn on_frame_recv(_session: *mut sys::nghttp2_session, frame: *const sys::Frame, user_data: *mut c_void) -> c_int {
    // SAFETY: nghttp2 passes a valid frame.
    let frame = unsafe { frame_ref(frame) };
    let hd = frame_hd(frame);
    // SAFETY: the user data is our state.
    let Ok(mut state) = (unsafe { state(user_data) }).try_borrow_mut() else { return sys::ERR_CALLBACK_FAILURE };
    let ended = hd.flags & sys::FLAG_END_STREAM != 0;
    match hd.kind {
        sys::HEADERS => flush(&mut state, hd.stream_id, true, ended),
        sys::DATA if ended => state.events.push_back(Event::End { stream: hd.stream_id as u32 }),
        sys::SETTINGS if hd.flags & sys::FLAG_ACK == 0 => state.events.push_back(Event::Settings),
        sys::PING if hd.flags & sys::FLAG_ACK != 0 => {
            // SAFETY: a PING frame, so this member is the one nghttp2 filled.
            let data = unsafe { frame.ping.opaque_data };
            state.events.push_back(Event::PingAck { data });
        }
        sys::GOAWAY => {
            // SAFETY: a GOAWAY frame, so this member is the one nghttp2 filled.
            let goaway = unsafe { frame.goaway };
            let debug = if goaway.opaque_data.is_null() || goaway.opaque_data_len == 0 {
                Vec::new()
            } else {
                // SAFETY: nghttp2 gives `opaque_data_len` readable bytes.
                unsafe { slice::from_raw_parts(goaway.opaque_data, goaway.opaque_data_len) }.to_vec()
            };
            state.events.push_back(Event::GoAway { last_stream: goaway.last_stream_id as u32, code: goaway.error_code, debug });
        }
        _ => {}
    }
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
    // SAFETY: `data` points at `len` bytes valid for this call.
    let data = unsafe { slice::from_raw_parts(data, len) }.to_vec();
    // SAFETY: the user data is our state.
    let Ok(mut state) = (unsafe { state(user_data) }).try_borrow_mut() else { return sys::ERR_CALLBACK_FAILURE };
    let Some(stream) = state.streams.get_mut(&stream_id) else { return sys::ERR_TEMPORAL_CALLBACK_FAILURE };
    stream.unconsumed += len;
    state.events.push_back(Event::Data { stream: stream_id as u32, data });
    0
}

unsafe extern "C" fn on_stream_close(_session: *mut sys::nghttp2_session, stream_id: i32, code: u32, user_data: *mut c_void) -> c_int {
    // SAFETY: the user data is our state.
    let Ok(mut state) = (unsafe { state(user_data) }).try_borrow_mut() else { return sys::ERR_CALLBACK_FAILURE };
    if let Some(stream) = state.streams.remove(&stream_id) {
        state.connection_credit += stream.unconsumed;
    }
    state.events.push_back(Event::Closed { stream: stream_id as u32, code });
    0
}

unsafe extern "C" fn read_body(
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
    // SAFETY: the user data is our state.
    let Ok(mut state) = (unsafe { state(user_data) }).try_borrow_mut() else { return sys::ERR_CALLBACK_FAILURE as isize };
    let Some(out) = state.streams.get_mut(&stream_id).and_then(|s| s.out.as_mut()) else {
        return sys::ERR_TEMPORAL_CALLBACK_FAILURE as isize;
    };
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
    out.queued -= n;
    if !out.chunks.is_empty() || !out.eof {
        return if n == 0 { sys::ERR_DEFERRED } else { n as isize };
    }
    // SAFETY: `flags` is a valid out pointer.
    unsafe { *flags |= sys::DATA_FLAG_EOF };
    if let Some(trailers) = out.trailers.take() {
        // The DATA frame must not end the stream: the trailers do.
        // SAFETY: as above.
        unsafe { *flags |= sys::DATA_FLAG_NO_END_STREAM };
        drop(state);
        let list = nvs(&[], &trailers);
        // SAFETY: `session` is the live session this callback runs in; `list` outlives the call, which copies it.
        let rc = unsafe { sys::nghttp2_submit_trailer(session, stream_id, list.as_ptr(), list.len()) };
        if rc < 0 {
            return sys::ERR_TEMPORAL_CALLBACK_FAILURE as isize;
        }
    }
    n as isize
}
