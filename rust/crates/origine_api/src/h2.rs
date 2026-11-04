//! `api.http.protocols.h2`: frame-level HTTP/2 sessions as Rust-defined classes, over `origine_h2::FrameSession`.
//!
//! `native.http.h2Client(stream, options)` / `h2Server` take a stream (`sockstream::StreamArg`: a native stream,
//! consumed, or a duck-typed one with `options.io`) and return an `H2SessionUnshaped`, which flows nothing (its
//! SETTINGS are queued, nothing is read or written). `.pulling()` / `.evented()` consume it and start the driver task
//! on the session's runtime: a `PullH2Session` answers `next()` with one frame event per call, an `EventH2Session`
//! calls the handlers `register`ed per event type, from the loop, one event at a time, in order (a returned promise
//! is not awaited, as for the net classes). Both shapes have the same submits (`submitHeaders`, `submitData`, ...,
//! all stateless calls on the session) and the same info. Frame events are frozen plain objects (`type` names the
//! frame); DATA carries its payload as a `Lease` made by the glue's lease maker (`native.http.link`), one copy into
//! V8 memory per frame.
//!
//! `close()` ends the session now (no GOAWAY: submit one first for a graceful end), the runtime's `close()` too;
//! the object stays and answers `BadHandle`.

use std::cell::{Cell, RefCell};
use std::future::Future;
use std::rc::{Rc, Weak};

use origine_api_core::{ArgError, NativeError, errno};
use origine_h2::{
    Category, ConnError, FrameConn, FrameDriver, FrameEvent, FrameOptions, H2Error, Messaging, Next, Role, SettingId, Settings,
    StreamState, frame_connect,
};
use origine_io::rt::AbortHandle;

use crate::decode::ArrayBufferArg;
use crate::fields::HeaderList;
use crate::io::{Closable, Io, IoCore};
use crate::native::{Op, host_mut, host_ref};
use crate::sockstream::{StreamArg, Under};
use crate::{FromJs, HostState, IntoJs, class, native};

fn h2_error(e: H2Error) -> NativeError {
    crate::http::h2_error(e)
}

fn conn_error(e: ConnError) -> NativeError {
    crate::http::conn_error(e)
}

// ---- options ----

/// Every SETTINGS parameter, each required (`options.settings`).
#[derive(FromJs)]
struct SettingsArg {
    header_table_size: u32,
    enable_push: bool,
    max_concurrent_streams: u32,
    initial_window_size: u32,
    max_frame_size: u32,
    max_header_list_size: u32,
    enable_connect_protocol: bool,
    #[js(name = "noRfc7540Priorities")]
    no_rfc7540_priorities: bool,
}

/// Some SETTINGS parameters (`submitSettings`): at least one.
#[derive(FromJs)]
struct SettingsUpdate {
    header_table_size: Option<u32>,
    enable_push: Option<bool>,
    max_concurrent_streams: Option<u32>,
    initial_window_size: Option<u32>,
    max_frame_size: Option<u32>,
    max_header_list_size: Option<u32>,
    enable_connect_protocol: Option<bool>,
    #[js(name = "noRfc7540Priorities")]
    no_rfc7540_priorities: Option<bool>,
}

/// `frames: 'parsed' | 'raw'`.
struct Frames(Messaging);

impl<'s> FromJs<'s> for Frames {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        match String::from_js(scope, value, index).as_deref() {
            Ok("parsed") => Ok(Frames(Messaging::Http)),
            Ok("raw") => Ok(Frames(Messaging::Raw)),
            _ => Err(ArgError::new(index, "'parsed' or 'raw'")),
        }
    }
}

/// The options of `h2.client` / `h2.server`; all required but `io`.
#[derive(FromJs)]
struct SessionOptions<'s> {
    settings: SettingsArg,
    window: u32,
    batch: u32,
    padding: u32,
    extensions: Vec<u32>,
    frames: Frames,
    io: Option<&'s Io>,
}

impl SessionOptions<'_> {
    fn frame_options(&self) -> Result<FrameOptions, NativeError> {
        let s = &self.settings;
        let extensions = self
            .extensions
            .iter()
            .map(|&kind| {
                u8::try_from(kind).map_err(|_| NativeError::from(ArgError::new(1, "property `extensions` to hold frame types (0 to 255)")))
            })
            .collect::<Result<Vec<u8>, _>>()?;
        Ok(FrameOptions {
            settings: Settings {
                header_table_size: s.header_table_size,
                enable_push: s.enable_push,
                max_concurrent_streams: s.max_concurrent_streams,
                initial_window_size: s.initial_window_size,
                max_frame_size: s.max_frame_size,
                max_header_list_size: s.max_header_list_size,
                enable_connect_protocol: s.enable_connect_protocol,
                no_rfc7540_priorities: s.no_rfc7540_priorities,
            },
            window: self.window,
            batch: self.batch,
            padding: self.padding,
            extensions,
            messaging: self.frames.0,
        })
    }
}

/// `{ endStream, padding? }` of `submitHeaders` / `submitData`.
#[derive(FromJs)]
struct SendOptions {
    end_stream: bool,
    padding: Option<u32>,
}

/// `{ ack }` of `submitPing`.
#[derive(FromJs)]
struct PingOptions {
    ack: bool,
}

// ---- the session ----

/// The state of one session, shared by its guest object, its driver task and its event hub.
pub(crate) struct H2Core {
    io: Rc<IoCore>,
    conn: FrameConn,
    driver: RefCell<Option<FrameDriver<Rc<Under>>>>,
    under: Rc<Under>,
    abort: RefCell<Option<AbortHandle>>,
    closed: Cell<bool>,
    /// The event hub of an event-mode session, and whether a delivery is scheduled.
    hub: Cell<Option<u32>>,
    scheduled: Rc<Cell<bool>>,
}

impl Closable for H2Core {
    fn close_now(&self) {
        self.close();
    }
}

impl H2Core {
    fn close(&self) {
        if self.closed.replace(true) {
            return;
        }
        self.conn.close();
        if let Some(abort) = self.abort.borrow_mut().take() {
            abort.abort();
        }
        self.driver.borrow_mut().take();
        self.under.shutdown();
    }

    /// The live connection; `BadHandle` once closed (or the runtime is).
    fn live(&self, host: &HostState) -> Result<&FrameConn, NativeError> {
        if self.closed.get() || !self.io.open(host) {
            return Err(NativeError::Errno(errno::BAD_HANDLE));
        }
        Ok(&self.conn)
    }

    /// Starts the driver task (the session flows from now on).
    fn start(self: &Rc<Self>, host: &HostState) -> Result<(), NativeError> {
        let driver = self.driver.borrow_mut().take().ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
        let under = Rc::clone(&self.under);
        let handle = host.spawn_detached(
            self.io.runtime,
            Box::pin(async move {
                let _ = driver.run().await;
                under.shutdown();
            }),
        )?;
        *self.abort.borrow_mut() = Some(handle);
        Ok(())
    }
}

/// Makes a session over `stream` (see the module docs).
fn session<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    role: Role,
    stream: StreamArg<'s>,
    options: SessionOptions<'s>,
) -> Result<H2SessionUnshaped, NativeError> {
    let frame_options = options.frame_options()?;
    let (io, under) = stream.transport(scope, options.io)?;
    let under = Rc::new(under);
    let (conn, driver) = match frame_connect(role, &frame_options, Rc::clone(&under)) {
        Ok(pair) => pair,
        Err(e) => {
            under.shutdown();
            return Err(h2_error(e));
        }
    };
    let core = Rc::new(H2Core {
        io: Rc::clone(&io),
        conn,
        driver: RefCell::new(Some(driver)),
        under,
        abort: RefCell::new(None),
        closed: Cell::new(false),
        hub: Cell::new(None),
        scheduled: Rc::new(Cell::new(false)),
    });
    let weak: Weak<dyn Closable> = Rc::downgrade(&core) as Weak<dyn Closable>;
    io.adopt_closer(weak);
    Ok(H2SessionUnshaped(RefCell::new(Some(core))))
}

/// `native.http.h2Client(stream, options)`: a client session over `stream` (see the module docs).
#[native(side_effect = "any", path = "http.h2Client", needs = "runtime")]
fn h2_client<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    stream: StreamArg<'s>,
    options: SessionOptions<'s>,
) -> Result<H2SessionUnshaped, NativeError> {
    session(scope, Role::Client, stream, options)
}

/// `native.http.h2Server(stream, options)`: a server session over `stream`.
#[native(side_effect = "any", path = "http.h2Server", needs = "runtime")]
fn h2_server<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    stream: StreamArg<'s>,
    options: SessionOptions<'s>,
) -> Result<H2SessionUnshaped, NativeError> {
    session(scope, Role::Server, stream, options)
}

/// The lease maker of the realm (`native.http.link`), a private of the global.
const LEASE: &str = "origine:http.lease";

/// `native.http.link(lease)`: `lease(arrayBuffer)` makes the `Lease` a DATA event carries. Called once per realm.
#[native(side_effect = "any", path = "http.link", needs = "runtime")]
fn http_link<'s>(scope: &mut v8::PinScope<'s, '_>, lease: v8::Local<'s, v8::Function>) -> Result<(), NativeError> {
    let name = v8::String::new(scope, LEASE).ok_or(NativeError::Errno(errno::UNEXPECTED))?;
    let key = v8::Private::for_api(scope, Some(name));
    let global = scope.get_current_context().global(scope);
    global.set_private(scope, key, lease.into());
    Ok(())
}

/// `bytes` as a `Lease` (one copy into V8 memory).
fn lease<'s>(scope: &mut v8::PinScope<'s, '_>, bytes: &[u8]) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let buffer = v8::ArrayBuffer::new(scope, bytes.len());
    crate::native::copy_into(buffer.into(), 0, bytes.len(), bytes)?;
    let name = v8::String::new(scope, LEASE).ok_or(NativeError::Errno(errno::UNEXPECTED))?;
    let key = v8::Private::for_api(scope, Some(name));
    let global = scope.get_current_context().global(scope);
    let maker = global
        .get_private(scope, key)
        .and_then(|f| v8::Local::<v8::Function>::try_from(f).ok())
        .ok_or(NativeError::Errno(errno::UNEXPECTED))?;
    let undefined = v8::undefined(scope).into();
    maker.call(scope, undefined, &[buffer.into()]).ok_or(NativeError::Errno(errno::UNEXPECTED))
}

// ---- events as JS values ----

fn setting_name(id: SettingId) -> Option<&'static str> {
    Some(match id {
        SettingId::HeaderTableSize => "headerTableSize",
        SettingId::EnablePush => "enablePush",
        SettingId::MaxConcurrentStreams => "maxConcurrentStreams",
        SettingId::InitialWindowSize => "initialWindowSize",
        SettingId::MaxFrameSize => "maxFrameSize",
        SettingId::MaxHeaderListSize => "maxHeaderListSize",
        SettingId::EnableConnectProtocol => "enableConnectProtocol",
        SettingId::NoRfc7540Priorities => "noRfc7540Priorities",
        SettingId::Other(_) => return None,
    })
}

/// Every setting as a frozen object.
fn settings_value<'s>(scope: &mut v8::PinScope<'s, '_>, settings: Settings) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let object = crate::encode::new_object(scope);
    for (id, value) in settings.entries() {
        let name = setting_name(id).unwrap_or_default();
        match id {
            SettingId::EnablePush | SettingId::EnableConnectProtocol | SettingId::NoRfc7540Priorities => {
                crate::encode::set(scope, object, name, value != 0)?
            }
            _ => crate::encode::set(scope, object, name, value)?,
        }
    }
    crate::encode::freeze(scope, object)
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

fn frozen_array<'s>(scope: &mut v8::PinScope<'s, '_>, items: &[v8::Local<'s, v8::Value>]) -> v8::Local<'s, v8::Value> {
    let array = v8::Array::new_with_elements(scope, items);
    array.set_integrity_level(scope, v8::IntegrityLevel::Frozen);
    array.into()
}

fn category(category: Category) -> &'static str {
    match category {
        Category::Request => "request",
        Category::Response => "response",
        Category::PushResponse => "push_response",
        Category::Headers => "headers",
        Category::PushPromise => "push_promise",
    }
}

/// A frame event as the guest sees it: a frozen object whose `type` names it.
pub(crate) struct JsFrame(FrameEvent);

impl<'s> IntoJs<'s> for JsFrame {
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        use crate::encode::set;
        let object = crate::encode::new_object(scope);
        let kind = match self.0 {
            FrameEvent::Settings { ack, entries } => {
                set(scope, object, "ack", ack)?;
                let mut pairs = Vec::with_capacity(entries.len());
                for (id, value) in entries {
                    let name: v8::Local<v8::Value> = match setting_name(id) {
                        Some(name) => name.into_js(scope)?,
                        None => u32::from(match id {
                            SettingId::Other(code) => code,
                            _ => 0,
                        })
                        .into_js(scope)?,
                    };
                    let value = value.into_js(scope)?;
                    pairs.push(frozen_array(scope, &[name, value]));
                }
                let entries = frozen_array(scope, &pairs);
                set(scope, object, "entries", entries)?;
                "settings"
            }
            FrameEvent::Headers { stream, category: c, fields, last, end_stream, priority, padding } => {
                set(scope, object, "streamId", stream)?;
                set(scope, object, "category", category(c))?;
                let headers = crate::class::wrap(scope, HeaderList::received(fields))?;
                set(scope, object, "headers", headers)?;
                set(scope, object, "last", last)?;
                set(scope, object, "endStream", end_stream)?;
                set(scope, object, "padding", padding)?;
                if let Some(p) = priority {
                    let value = crate::encode::new_object(scope);
                    set(scope, value, "dependsOn", p.depends_on)?;
                    set(scope, value, "weight", u32::from(p.weight))?;
                    set(scope, value, "exclusive", p.exclusive)?;
                    let value = crate::encode::freeze(scope, value)?;
                    set(scope, object, "priority", value)?;
                }
                "headers"
            }
            FrameEvent::Data { stream, data, end_stream, padding } => {
                set(scope, object, "streamId", stream)?;
                let data = lease(scope, &data)?;
                set(scope, object, "data", data)?;
                set(scope, object, "endStream", end_stream)?;
                set(scope, object, "padding", padding)?;
                "data"
            }
            FrameEvent::Priority { stream, priority } => {
                set(scope, object, "streamId", stream)?;
                set(scope, object, "dependsOn", priority.depends_on)?;
                set(scope, object, "weight", u32::from(priority.weight))?;
                set(scope, object, "exclusive", priority.exclusive)?;
                "priority"
            }
            FrameEvent::PriorityUpdate { stream, value } => {
                set(scope, object, "streamId", stream)?;
                set(scope, object, "value", text(&value))?;
                "priority_update"
            }
            FrameEvent::RstStream { stream, code } => {
                set(scope, object, "streamId", stream)?;
                set(scope, object, "code", code)?;
                "rst_stream"
            }
            FrameEvent::PushPromise { stream, promised } => {
                set(scope, object, "streamId", stream)?;
                set(scope, object, "promisedStreamId", promised)?;
                "push_promise"
            }
            FrameEvent::Ping { data, ack } => {
                set(scope, object, "data", data.to_vec())?;
                set(scope, object, "ack", ack)?;
                "ping"
            }
            FrameEvent::GoAway { last_stream, code, debug } => {
                set(scope, object, "lastStreamId", last_stream)?;
                set(scope, object, "code", code)?;
                set(scope, object, "debug", debug)?;
                "goaway"
            }
            FrameEvent::WindowUpdate { stream, increment } => {
                set(scope, object, "streamId", stream)?;
                set(scope, object, "increment", increment)?;
                "window_update"
            }
            FrameEvent::Altsvc { stream, origin, value } => {
                set(scope, object, "streamId", stream)?;
                set(scope, object, "origin", text(&origin))?;
                set(scope, object, "value", text(&value))?;
                "altsvc"
            }
            FrameEvent::Origin { origins } => {
                let mut items = Vec::with_capacity(origins.len());
                for origin in origins {
                    items.push(text(&origin).into_js(scope)?);
                }
                let origins = frozen_array(scope, &items);
                set(scope, object, "origins", origins)?;
                "origin"
            }
            FrameEvent::Unknown { kind, flags, stream, payload } => {
                set(scope, object, "frameType", u32::from(kind))?;
                set(scope, object, "flags", u32::from(flags))?;
                set(scope, object, "streamId", stream)?;
                set(scope, object, "payload", payload)?;
                "unknown"
            }
            FrameEvent::Invalid { kind, stream, reason } => {
                set(scope, object, "frameType", u32::from(kind))?;
                set(scope, object, "streamId", stream)?;
                set(scope, object, "reason", reason)?;
                "invalid"
            }
            FrameEvent::Closed { stream, code } => {
                set(scope, object, "streamId", stream)?;
                set(scope, object, "code", code)?;
                "closed"
            }
        };
        set(scope, object, "type", kind)?;
        crate::encode::freeze(scope, object)
    }
}

// ---- the members both shapes share ----

fn stream_of(value: f64) -> Result<u32, NativeError> {
    if value.fract() != 0.0 || !(0.0..=2_147_483_647.0).contains(&value) {
        return Err(NativeError::type_error("a stream id is an integer in 0..2**31-1"));
    }
    Ok(value as u32)
}

fn submit_headers(host: &HostState, core: &H2Core, stream: f64, headers: &HeaderList, options: SendOptions) -> Result<u32, NativeError> {
    let stream = stream_of(stream)?;
    let fields = headers.fields();
    let padding = options.padding.map(|p| p as usize);
    core.live(host)?.with(|s| s.headers(stream, &fields, options.end_stream, padding)).map_err(h2_error)
}

fn submit_data(
    host: &HostState,
    core: &H2Core,
    stream: f64,
    data: ArrayBufferArg<'_>,
    options: SendOptions,
) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
    let stream = stream_of(stream)?;
    let padding = options.padding.map(|p| p as usize);
    let sent = core.live(host)?.data(stream, data.to_vec(), options.end_stream, padding).map_err(h2_error)?;
    Ok(Op::new(core.io.runtime, async move { sent.await.map_err(h2_error) }))
}

fn settings_update(update: SettingsUpdate) -> Result<Vec<(SettingId, u32)>, NativeError> {
    let mut entries = Vec::new();
    let mut add = |id, value: Option<u32>| {
        if let Some(value) = value {
            entries.push((id, value));
        }
    };
    add(SettingId::HeaderTableSize, update.header_table_size);
    add(SettingId::EnablePush, update.enable_push.map(u32::from));
    add(SettingId::MaxConcurrentStreams, update.max_concurrent_streams);
    add(SettingId::InitialWindowSize, update.initial_window_size);
    add(SettingId::MaxFrameSize, update.max_frame_size);
    add(SettingId::MaxHeaderListSize, update.max_header_list_size);
    add(SettingId::EnableConnectProtocol, update.enable_connect_protocol.map(u32::from));
    add(SettingId::NoRfc7540Priorities, update.no_rfc7540_priorities.map(u32::from));
    if entries.is_empty() {
        return Err(ArgError::new(0, "at least one setting").into());
    }
    Ok(entries)
}

fn ping_bytes(data: &ArrayBufferArg<'_>) -> Result<[u8; 8], NativeError> {
    <[u8; 8]>::try_from(data.to_vec().as_slice()).map_err(|_| NativeError::type_error("a PING carries exactly 8 bytes"))
}

fn state_name(state: StreamState) -> &'static str {
    match state {
        StreamState::Idle => "idle",
        StreamState::Open => "open",
        StreamState::ReservedLocal => "reserved_local",
        StreamState::ReservedRemote => "reserved_remote",
        StreamState::HalfClosedLocal => "half_closed_local",
        StreamState::HalfClosedRemote => "half_closed_remote",
        StreamState::Closed => "closed",
    }
}

fn windows<'s>(scope: &mut v8::PinScope<'s, '_>, core: &H2Core, stream: f64) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let stream = stream_of(stream)?;
    let (send, receive) = core.live(host_ref(scope)?)?.read(|s| s.windows(stream));
    let object = crate::encode::new_object(scope);
    crate::encode::set(scope, object, "send", send)?;
    crate::encode::set(scope, object, "receive", receive)?;
    crate::encode::freeze(scope, object)
}

/// A session that flows nothing yet.
pub(crate) struct H2SessionUnshaped(RefCell<Option<Rc<H2Core>>>);

impl H2SessionUnshaped {
    fn take(&self, host: &HostState) -> Result<Rc<H2Core>, NativeError> {
        let core = self.0.borrow().clone().ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
        core.live(host)?;
        self.0.borrow_mut().take();
        Ok(core)
    }
}

#[class(path = "http.H2SessionUnshaped", side_effect = "any", needs = "runtime")]
impl H2SessionUnshaped {
    /// Consumes this object: a `PullH2Session`, flowing.
    fn pulling(&self, host: &mut HostState) -> Result<PullH2Session, NativeError> {
        let core = self.take(host)?;
        core.start(host)?;
        Ok(PullH2Session(core))
    }

    /// Consumes this object: an `EventH2Session`, flowing; events wait for their handlers.
    fn evented(&self, host: &mut HostState) -> Result<EventH2Session, NativeError> {
        let core = self.take(host)?;
        let completions = host.completions();
        let (scheduled, weak) = (Rc::clone(&core.scheduled), Rc::downgrade(&core));
        core.conn.set_notify(Box::new(move || {
            if scheduled.replace(true) {
                return;
            }
            let weak = weak.clone();
            let run: crate::host::Completion = Box::new(move |scope| deliver(scope, &weak));
            if let Ok(mut completions) = completions.try_borrow_mut() {
                completions.push(run);
            }
        }));
        core.start(host)?;
        Ok(EventH2Session(core))
    }

    fn close<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        if let Some(core) = self.0.borrow_mut().take() {
            core.close();
        }
        crate::stream::resolved(scope)
    }

    #[getter]
    fn closed(&self, host: &HostState) -> bool {
        self.0.borrow().as_ref().is_none_or(|core| core.closed.get() || !core.io.open(host))
    }
}

/// A session read with promises: `next()`.
pub(crate) struct PullH2Session(Rc<H2Core>);

#[class(path = "http.PullH2Session", side_effect = "any", needs = "runtime")]
impl PullH2Session {
    /// The next frame event, `undefined` once the session is over; rejects once with the failure of a session
    /// that failed.
    #[method(promise)]
    fn next(
        &self,
        host: &mut HostState,
    ) -> Result<Op<'static, impl Future<Output = Result<Option<JsFrame>, NativeError>> + use<>>, NativeError> {
        if !self.0.io.open(host) {
            return Err(NativeError::Errno(errno::BAD_HANDLE));
        }
        let conn = self.0.conn.clone();
        Ok(Op::new(self.0.io.runtime, async move {
            match conn.next().await {
                Next::Event(event) => Ok(Some(JsFrame(event))),
                Next::Failed(e) => Err(conn_error(e)),
                Next::End => Ok(None),
            }
        }))
    }

    /// Queues a header block (pseudo header fields first) on `streamId`, or on a new stream (`0`, a client);
    /// returns the stream id.
    #[method(name = "submitHeaders")]
    fn submit_headers(&self, host: &HostState, stream: f64, headers: &HeaderList, options: SendOptions) -> Result<u32, NativeError> {
        submit_headers(host, &self.0, stream, headers, options)
    }

    /// Queues DATA (copied now); resolves once it was packed into frames (inside the peer's windows).
    #[method(promise, name = "submitData")]
    fn submit_data(
        &self,
        host: &mut HostState,
        stream: f64,
        data: ArrayBufferArg<'_>,
        options: SendOptions,
    ) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
        submit_data(host, &self.0, stream, data, options)
    }

    /// A client's RFC 9218 PRIORITY_UPDATE (`value` a Priority field value, `u=3, i`).
    #[method(name = "submitPriority")]
    fn submit_priority(&self, host: &HostState, stream: f64, value: String) -> Result<(), NativeError> {
        let stream = stream_of(stream)?;
        self.0.live(host)?.with(|s| s.priority_update(stream, value.as_bytes())).map_err(h2_error)
    }

    #[method(name = "submitRst")]
    fn submit_rst(&self, host: &HostState, stream: f64, code: u32) -> Result<(), NativeError> {
        let stream = stream_of(stream)?;
        self.0.live(host)?.with(|s| s.rst(stream, code)).map_err(h2_error)
    }

    /// A SETTINGS frame with the given parameters, any time.
    #[method(name = "submitSettings")]
    fn submit_settings(&self, host: &HostState, update: SettingsUpdate) -> Result<(), NativeError> {
        let entries = settings_update(update)?;
        self.0.live(host)?.with(|s| s.settings(&entries)).map_err(h2_error)
    }

    /// A PING of 8 bytes, or with `ack` the answer to one (PINGs are not answered for you).
    #[method(name = "submitPing")]
    fn submit_ping(&self, host: &HostState, data: ArrayBufferArg<'_>, options: PingOptions) -> Result<(), NativeError> {
        let data = ping_bytes(&data)?;
        self.0.live(host)?.with(|s| s.ping(data, options.ack)).map_err(h2_error)
    }

    #[method(name = "submitGoaway")]
    fn submit_goaway(&self, host: &HostState, last: f64, code: u32, debug: ArrayBufferArg<'_>) -> Result<(), NativeError> {
        let last = stream_of(last)?;
        let debug = debug.to_vec();
        self.0.live(host)?.with(|s| s.goaway(last, code, &debug)).map_err(h2_error)
    }

    #[method(name = "submitWindowUpdate")]
    fn submit_window_update(&self, host: &HostState, stream: f64, increment: u32) -> Result<(), NativeError> {
        let stream = stream_of(stream)?;
        self.0.live(host)?.with(|s| s.window_update(stream, increment)).map_err(h2_error)
    }

    /// A server's PUSH_PROMISE on `streamId`: returns the promised stream id.
    #[method(name = "submitPush")]
    fn submit_push(&self, host: &HostState, stream: f64, headers: &HeaderList) -> Result<u32, NativeError> {
        let stream = stream_of(stream)?;
        let fields = headers.fields();
        self.0.live(host)?.with(|s| s.push(stream, &fields)).map_err(h2_error)
    }

    #[method(name = "submitAltsvc")]
    fn submit_altsvc(&self, host: &HostState, stream: f64, origin: String, value: String) -> Result<(), NativeError> {
        let stream = stream_of(stream)?;
        self.0.live(host)?.with(|s| s.altsvc(stream, origin.as_bytes(), value.as_bytes())).map_err(h2_error)
    }

    #[method(name = "submitOrigin")]
    fn submit_origin(&self, host: &HostState, origins: Vec<String>) -> Result<(), NativeError> {
        let origins: Vec<Vec<u8>> = origins.into_iter().map(String::into_bytes).collect();
        self.0.live(host)?.with(|s| s.origin(&origins)).map_err(h2_error)
    }

    /// A frame of an extension type.
    #[method(name = "submitExtension")]
    fn submit_extension(
        &self,
        host: &HostState,
        kind: u32,
        flags: u32,
        stream: f64,
        payload: ArrayBufferArg<'_>,
    ) -> Result<(), NativeError> {
        let stream = stream_of(stream)?;
        let kind = u8::try_from(kind).map_err(|_| NativeError::type_error("a frame type is 0 to 255"))?;
        let flags = u8::try_from(flags).map_err(|_| NativeError::type_error("frame flags are 0 to 255"))?;
        let payload = payload.to_vec();
        self.0.live(host)?.with(|s| s.extension(kind, flags, stream, payload)).map_err(h2_error)
    }

    /// Gives `bytes` of received DATA back to the stream's and the connection's windows.
    fn consume(&self, host: &HostState, stream: f64, bytes: f64) -> Result<(), NativeError> {
        let stream = stream_of(stream)?;
        if bytes.fract() != 0.0 || bytes < 0.0 {
            return Err(NativeError::type_error("bytes is a non-negative integer"));
        }
        self.0.live(host)?.with(|s| s.consume(stream, bytes as usize)).map_err(h2_error)
    }

    #[getter(name = "localSettings")]
    fn local_settings<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        let settings = self.0.live(host_ref(scope)?)?.read(|s| s.local_settings());
        settings_value(scope, settings)
    }

    #[getter(name = "remoteSettings")]
    fn remote_settings<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        let settings = self.0.live(host_ref(scope)?)?.read(|s| s.remote_settings());
        settings_value(scope, settings)
    }

    #[method(name = "streamState")]
    fn stream_state(&self, host: &HostState, stream: f64) -> Result<&'static str, NativeError> {
        let stream = stream_of(stream)?;
        Ok(state_name(self.0.live(host)?.read(|s| s.stream_state(stream))))
    }

    /// `{ send, receive }`: the windows of `streamId` (0: the connection).
    fn windows<'s>(&self, scope: &mut v8::PinScope<'s, '_>, stream: f64) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        windows(scope, &self.0, stream)
    }

    #[getter(name = "nextStreamId")]
    fn next_stream_id(&self, host: &HostState) -> Result<u32, NativeError> {
        Ok(self.0.live(host)?.read(|s| s.next_stream_id()))
    }

    #[getter]
    fn closed(&self, host: &HostState) -> bool {
        self.0.closed.get() || self.0.conn.is_done() || !self.0.io.open(host)
    }

    /// Ends the session now (no GOAWAY; submit one first for a graceful end). Idempotent.
    fn close<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        self.0.close();
        crate::stream::resolved(scope)
    }
}

/// A session that calls handlers held natively.
pub(crate) struct EventH2Session(Rc<H2Core>);

#[class(path = "http.EventH2Session", side_effect = "any", needs = "runtime")]
impl EventH2Session {
    /// Subscribes `handler` to a frame event type (`headers`, `data`, ..., `closed`), `error` or `close`; returns an
    /// `H2Registration`.
    fn register<'s>(
        &self,
        scope: &mut v8::PinScope<'s, '_>,
        event: String,
        handler: v8::Local<'s, v8::Function>,
    ) -> Result<H2Registration, NativeError> {
        if !EVENTS.contains(&event.as_str()) {
            return Err(NativeError::type_error(format!("unknown event: {event}")));
        }
        self.0.live(host_ref(scope)?)?;
        let hub = ensure_hub(scope, &self.0)?;
        let function = v8::Global::new(scope, handler);
        let host = host_mut(scope)?;
        let hub_ref = host.h2_hubs.get_mut(&hub).ok_or(NativeError::Errno(errno::BAD_HANDLE))?;
        let entry = hub_ref.next_entry;
        hub_ref.next_entry += 1;
        hub_ref.handlers.push((event, entry, function));
        schedule(host, &self.0);
        Ok(H2Registration { hub, entry })
    }

    fn pause(&self, scope: &mut v8::PinScope<'_, '_>) -> Result<(), NativeError> {
        let hub = ensure_hub(scope, &self.0)?;
        if let Some(hub) = host_mut(scope)?.h2_hubs.get_mut(&hub) {
            hub.paused = true;
        }
        Ok(())
    }

    fn resume(&self, scope: &mut v8::PinScope<'_, '_>) -> Result<(), NativeError> {
        let hub = ensure_hub(scope, &self.0)?;
        let host = host_mut(scope)?;
        if let Some(hub) = host.h2_hubs.get_mut(&hub) {
            hub.paused = false;
        }
        schedule(host, &self.0);
        Ok(())
    }

    #[getter]
    fn paused(&self, host: &HostState) -> bool {
        self.0.hub.get().and_then(|hub| host.h2_hubs.get(&hub)).is_none_or(|hub| hub.paused || hub.handlers.is_empty())
    }

    /// Queues a header block (pseudo header fields first) on `streamId`, or on a new stream (`0`, a client);
    /// returns the stream id.
    #[method(name = "submitHeaders")]
    fn submit_headers(&self, host: &HostState, stream: f64, headers: &HeaderList, options: SendOptions) -> Result<u32, NativeError> {
        submit_headers(host, &self.0, stream, headers, options)
    }

    /// Queues DATA (copied now); resolves once it was packed into frames (inside the peer's windows).
    #[method(promise, name = "submitData")]
    fn submit_data(
        &self,
        host: &mut HostState,
        stream: f64,
        data: ArrayBufferArg<'_>,
        options: SendOptions,
    ) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
        submit_data(host, &self.0, stream, data, options)
    }

    /// A client's RFC 9218 PRIORITY_UPDATE (`value` a Priority field value, `u=3, i`).
    #[method(name = "submitPriority")]
    fn submit_priority(&self, host: &HostState, stream: f64, value: String) -> Result<(), NativeError> {
        let stream = stream_of(stream)?;
        self.0.live(host)?.with(|s| s.priority_update(stream, value.as_bytes())).map_err(h2_error)
    }

    #[method(name = "submitRst")]
    fn submit_rst(&self, host: &HostState, stream: f64, code: u32) -> Result<(), NativeError> {
        let stream = stream_of(stream)?;
        self.0.live(host)?.with(|s| s.rst(stream, code)).map_err(h2_error)
    }

    /// A SETTINGS frame with the given parameters, any time.
    #[method(name = "submitSettings")]
    fn submit_settings(&self, host: &HostState, update: SettingsUpdate) -> Result<(), NativeError> {
        let entries = settings_update(update)?;
        self.0.live(host)?.with(|s| s.settings(&entries)).map_err(h2_error)
    }

    /// A PING of 8 bytes, or with `ack` the answer to one (PINGs are not answered for you).
    #[method(name = "submitPing")]
    fn submit_ping(&self, host: &HostState, data: ArrayBufferArg<'_>, options: PingOptions) -> Result<(), NativeError> {
        let data = ping_bytes(&data)?;
        self.0.live(host)?.with(|s| s.ping(data, options.ack)).map_err(h2_error)
    }

    #[method(name = "submitGoaway")]
    fn submit_goaway(&self, host: &HostState, last: f64, code: u32, debug: ArrayBufferArg<'_>) -> Result<(), NativeError> {
        let last = stream_of(last)?;
        let debug = debug.to_vec();
        self.0.live(host)?.with(|s| s.goaway(last, code, &debug)).map_err(h2_error)
    }

    #[method(name = "submitWindowUpdate")]
    fn submit_window_update(&self, host: &HostState, stream: f64, increment: u32) -> Result<(), NativeError> {
        let stream = stream_of(stream)?;
        self.0.live(host)?.with(|s| s.window_update(stream, increment)).map_err(h2_error)
    }

    /// A server's PUSH_PROMISE on `streamId`: returns the promised stream id.
    #[method(name = "submitPush")]
    fn submit_push(&self, host: &HostState, stream: f64, headers: &HeaderList) -> Result<u32, NativeError> {
        let stream = stream_of(stream)?;
        let fields = headers.fields();
        self.0.live(host)?.with(|s| s.push(stream, &fields)).map_err(h2_error)
    }

    #[method(name = "submitAltsvc")]
    fn submit_altsvc(&self, host: &HostState, stream: f64, origin: String, value: String) -> Result<(), NativeError> {
        let stream = stream_of(stream)?;
        self.0.live(host)?.with(|s| s.altsvc(stream, origin.as_bytes(), value.as_bytes())).map_err(h2_error)
    }

    #[method(name = "submitOrigin")]
    fn submit_origin(&self, host: &HostState, origins: Vec<String>) -> Result<(), NativeError> {
        let origins: Vec<Vec<u8>> = origins.into_iter().map(String::into_bytes).collect();
        self.0.live(host)?.with(|s| s.origin(&origins)).map_err(h2_error)
    }

    /// A frame of an extension type.
    #[method(name = "submitExtension")]
    fn submit_extension(
        &self,
        host: &HostState,
        kind: u32,
        flags: u32,
        stream: f64,
        payload: ArrayBufferArg<'_>,
    ) -> Result<(), NativeError> {
        let stream = stream_of(stream)?;
        let kind = u8::try_from(kind).map_err(|_| NativeError::type_error("a frame type is 0 to 255"))?;
        let flags = u8::try_from(flags).map_err(|_| NativeError::type_error("frame flags are 0 to 255"))?;
        let payload = payload.to_vec();
        self.0.live(host)?.with(|s| s.extension(kind, flags, stream, payload)).map_err(h2_error)
    }

    /// Gives `bytes` of received DATA back to the stream's and the connection's windows.
    fn consume(&self, host: &HostState, stream: f64, bytes: f64) -> Result<(), NativeError> {
        let stream = stream_of(stream)?;
        if bytes.fract() != 0.0 || bytes < 0.0 {
            return Err(NativeError::type_error("bytes is a non-negative integer"));
        }
        self.0.live(host)?.with(|s| s.consume(stream, bytes as usize)).map_err(h2_error)
    }

    #[getter(name = "localSettings")]
    fn local_settings<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        let settings = self.0.live(host_ref(scope)?)?.read(|s| s.local_settings());
        settings_value(scope, settings)
    }

    #[getter(name = "remoteSettings")]
    fn remote_settings<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        let settings = self.0.live(host_ref(scope)?)?.read(|s| s.remote_settings());
        settings_value(scope, settings)
    }

    #[method(name = "streamState")]
    fn stream_state(&self, host: &HostState, stream: f64) -> Result<&'static str, NativeError> {
        let stream = stream_of(stream)?;
        Ok(state_name(self.0.live(host)?.read(|s| s.stream_state(stream))))
    }

    /// `{ send, receive }`: the windows of `streamId` (0: the connection).
    fn windows<'s>(&self, scope: &mut v8::PinScope<'s, '_>, stream: f64) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        windows(scope, &self.0, stream)
    }

    #[getter(name = "nextStreamId")]
    fn next_stream_id(&self, host: &HostState) -> Result<u32, NativeError> {
        Ok(self.0.live(host)?.read(|s| s.next_stream_id()))
    }

    #[getter]
    fn closed(&self, host: &HostState) -> bool {
        self.0.closed.get() || self.0.conn.is_done() || !self.0.io.open(host)
    }

    /// Ends the session now (no GOAWAY; submit one first for a graceful end). Idempotent.
    fn close<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        self.0.close();
        crate::stream::resolved(scope)
    }
}

// ---- event delivery ----

/// The events `register` takes.
const EVENTS: [&str; 17] = [
    "settings",
    "headers",
    "data",
    "priority",
    "priority_update",
    "rst_stream",
    "push_promise",
    "ping",
    "goaway",
    "window_update",
    "altsvc",
    "origin",
    "unknown",
    "invalid",
    "closed",
    "error",
    "close",
];

/// The handlers of an event-mode session, in the Host.
pub(crate) struct H2Hub {
    core: Rc<H2Core>,
    context: v8::Global<v8::Context>,
    handlers: Vec<(String, u64, v8::Global<v8::Function>)>,
    next_entry: u64,
    paused: bool,
}

impl H2Hub {
    pub(crate) fn runtime(&self) -> u32 {
        self.core.io.runtime
    }
}

fn ensure_hub(scope: &mut v8::PinScope<'_, '_>, core: &Rc<H2Core>) -> Result<u32, NativeError> {
    if let Some(hub) = core.hub.get() {
        return Ok(hub);
    }
    let current = scope.get_current_context();
    let context = v8::Global::new(scope, current);
    let host = host_mut(scope)?;
    let id = host.next_h2_hub;
    host.next_h2_hub = id.checked_add(1).ok_or(NativeError::Errno(errno::UNSUPPORTED))?;
    host.h2_hubs.insert(id, H2Hub { core: Rc::clone(core), context, handlers: Vec::new(), next_entry: 0, paused: false });
    core.hub.set(Some(id));
    Ok(id)
}

/// Queues a delivery of `core`'s waiting events (once).
fn schedule(host: &HostState, core: &Rc<H2Core>) {
    if core.scheduled.replace(true) {
        return;
    }
    let weak = Rc::downgrade(core);
    let run: crate::host::Completion = Box::new(move |scope| deliver(scope, &weak));
    host.completions().borrow_mut().push(run);
}

/// Delivers the waiting events of a session to its handlers (isolate thread): one at a time, a microtask
/// checkpoint after each. Events wait while the session is paused or has no handler.
fn deliver(scope: &mut v8::PinScope<'_, '_, ()>, core: &Weak<H2Core>) {
    let Some(core) = core.upgrade() else { return };
    core.scheduled.set(false);
    let Some(id) = core.hub.get() else { return };
    loop {
        let Some(host) = scope.get_slot::<HostState>() else { return };
        let Some(hub) = host.h2_hubs.get(&id) else { return };
        if hub.paused || hub.handlers.is_empty() {
            return;
        }
        let context = hub.context.clone();
        let Some(next) = core.conn.try_next() else { return };
        let context = v8::Local::new(scope, context);
        let scope = &mut v8::ContextScope::new(scope, context);
        let (kind, value): (&str, Option<v8::Local<v8::Value>>) = match next {
            Next::Event(event) => {
                let kind = event_type(&event);
                (kind, JsFrame(event).into_js(scope).ok())
            }
            Next::Failed(e) => ("error", Some(crate::class::guest_error(scope, conn_error(e)))),
            Next::End => ("close", None),
        };
        fire(scope, id, kind, value);
        scope.perform_microtask_checkpoint();
        if kind == "close" {
            if let Some(host) = scope.get_slot_mut::<HostState>() {
                host.h2_hubs.remove(&id);
            }
            core.hub.set(None);
            return;
        }
    }
}

fn event_type(event: &FrameEvent) -> &'static str {
    match event {
        FrameEvent::Settings { .. } => "settings",
        FrameEvent::Headers { .. } => "headers",
        FrameEvent::Data { .. } => "data",
        FrameEvent::Priority { .. } => "priority",
        FrameEvent::PriorityUpdate { .. } => "priority_update",
        FrameEvent::RstStream { .. } => "rst_stream",
        FrameEvent::PushPromise { .. } => "push_promise",
        FrameEvent::Ping { .. } => "ping",
        FrameEvent::GoAway { .. } => "goaway",
        FrameEvent::WindowUpdate { .. } => "window_update",
        FrameEvent::Altsvc { .. } => "altsvc",
        FrameEvent::Origin { .. } => "origin",
        FrameEvent::Unknown { .. } => "unknown",
        FrameEvent::Invalid { .. } => "invalid",
        FrameEvent::Closed { .. } => "closed",
    }
}

fn handlers(scope: &mut v8::PinScope<'_, '_>, id: u32, kind: &str) -> Vec<v8::Global<v8::Function>> {
    scope
        .get_slot::<HostState>()
        .and_then(|host| host.h2_hubs.get(&id))
        .map(|hub| hub.handlers.iter().filter(|(k, _, _)| k == kind).map(|(_, _, f)| f.clone()).collect())
        .unwrap_or_default()
}

/// Calls the handlers of `kind`; one that throws goes to the `error` handlers, else (or from one of them) it is an
/// unhandled rejection. A returned promise is not awaited.
fn fire(scope: &mut v8::PinScope<'_, '_>, id: u32, kind: &str, arg: Option<v8::Local<'_, v8::Value>>) {
    for function in handlers(scope, id, kind) {
        if let Err(thrown) = call(scope, &function, arg) {
            let errors = if kind == "error" { Vec::new() } else { handlers(scope, id, "error") };
            if errors.is_empty() {
                unhandled(scope, &thrown);
            }
            let value = v8::Local::new(scope, &thrown);
            for function in errors {
                if let Err(again) = call(scope, &function, Some(value)) {
                    unhandled(scope, &again);
                }
            }
        }
    }
}

fn call(
    scope: &mut v8::PinScope<'_, '_>,
    function: &v8::Global<v8::Function>,
    arg: Option<v8::Local<'_, v8::Value>>,
) -> Result<(), v8::Global<v8::Value>> {
    v8::tc_scope!(let tc, scope);
    let function = v8::Local::new(tc, function);
    let receiver: v8::Local<v8::Value> = v8::undefined(tc).into();
    let args: Vec<v8::Local<v8::Value>> = arg.map(|arg| v8::Local::new(tc, arg)).into_iter().collect();
    match function.call(tc, receiver, &args) {
        Some(_) => Ok(()),
        None => {
            let exception = tc.exception().unwrap_or_else(|| v8::undefined(tc).into());
            Err(v8::Global::new(tc, exception))
        }
    }
}

fn unhandled(scope: &mut v8::PinScope<'_, '_>, exception: &v8::Global<v8::Value>) {
    let value = v8::Local::new(scope, exception);
    if let Some(resolver) = v8::PromiseResolver::new(scope) {
        resolver.reject(scope, value);
    }
}

/// What `EventH2Session.register` returns.
pub(crate) struct H2Registration {
    hub: u32,
    entry: u64,
}

#[class(path = "http.H2Registration", side_effect = "any", needs = "runtime")]
impl H2Registration {
    /// Removes the handler; `true` if it was registered.
    fn unregister(&self, host: &mut HostState) -> bool {
        let Some(hub) = host.h2_hubs.get_mut(&self.hub) else { return false };
        let before = hub.handlers.len();
        hub.handlers.retain(|(_, entry, _)| *entry != self.entry);
        hub.handlers.len() != before
    }
}
