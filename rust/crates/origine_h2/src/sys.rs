//! The slice of nghttp2's C ABI (nghttp2/nghttp2.h, 1.68) this crate uses, written by hand. The
//! `layout` test pins every struct to the offsets clang reports for the real header.
#![allow(non_camel_case_types, dead_code)]

use std::ffi::{c_char, c_int, c_void};

macro_rules! opaque {
    ($($name:ident),*) => {$(
        #[repr(C)]
        pub struct $name {
            _private: [u8; 0],
        }
    )*};
}
opaque!(nghttp2_session, nghttp2_session_callbacks, nghttp2_option, nghttp2_stream);

// ---- errors ----
pub const ERR_INVALID_ARGUMENT: c_int = -501;
pub const ERR_DATA_EXIST: c_int = -529;
pub const ERR_CANCEL: isize = -535;
pub const ERR_DEFERRED: isize = -508;
pub const ERR_TEMPORAL_CALLBACK_FAILURE: c_int = -521;
pub const ERR_CALLBACK_FAILURE: c_int = -902;
pub const ERR_BAD_CLIENT_MAGIC: i32 = -903;
pub const ERR_FLOODED: i32 = -904;

// ---- frames ----
pub const DATA: u8 = 0;
pub const HEADERS: u8 = 1;
pub const PRIORITY: u8 = 2;
pub const RST_STREAM: u8 = 3;
pub const SETTINGS: u8 = 4;
pub const PUSH_PROMISE: u8 = 5;
pub const PING: u8 = 6;
pub const GOAWAY: u8 = 7;
pub const WINDOW_UPDATE: u8 = 8;
pub const CONTINUATION: u8 = 9;
pub const ALTSVC: u8 = 0x0a;
pub const ORIGIN: u8 = 0x0c;
pub const PRIORITY_UPDATE: u8 = 0x10;
pub const FLAG_NONE: u8 = 0;
pub const FLAG_END_STREAM: u8 = 1;
pub const FLAG_END_HEADERS: u8 = 4;
pub const FLAG_ACK: u8 = 1;
pub const FLAG_PADDED: u8 = 8;
pub const FLAG_PRIORITY: u8 = 0x20;
pub const HCAT_REQUEST: c_int = 0;
pub const HCAT_RESPONSE: c_int = 1;
pub const HCAT_PUSH_RESPONSE: c_int = 2;
pub const HCAT_HEADERS: c_int = 3;

// ---- settings ----
pub const SETTINGS_HEADER_TABLE_SIZE: i32 = 1;
pub const SETTINGS_ENABLE_PUSH: i32 = 2;
pub const SETTINGS_MAX_CONCURRENT_STREAMS: i32 = 3;
pub const SETTINGS_INITIAL_WINDOW_SIZE: i32 = 4;
pub const SETTINGS_MAX_FRAME_SIZE: i32 = 5;
pub const SETTINGS_MAX_HEADER_LIST_SIZE: i32 = 6;
pub const SETTINGS_ENABLE_CONNECT_PROTOCOL: i32 = 8;
pub const SETTINGS_NO_RFC7540_PRIORITIES: i32 = 9;

// ---- stream states (nghttp2_stream_proto_state) ----
pub const STREAM_STATE_IDLE: c_int = 1;
pub const STREAM_STATE_OPEN: c_int = 2;
pub const STREAM_STATE_RESERVED_LOCAL: c_int = 3;
pub const STREAM_STATE_RESERVED_REMOTE: c_int = 4;
pub const STREAM_STATE_HALF_CLOSED_LOCAL: c_int = 5;
pub const STREAM_STATE_HALF_CLOSED_REMOTE: c_int = 6;
pub const STREAM_STATE_CLOSED: c_int = 7;

// ---- data provider flags ----
pub const DATA_FLAG_EOF: u32 = 1;
pub const DATA_FLAG_NO_END_STREAM: u32 = 2;

#[repr(C)]
pub struct Nv {
    pub name: *mut u8,
    pub value: *mut u8,
    pub namelen: usize,
    pub valuelen: usize,
    pub flags: u8,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct FrameHd {
    pub length: usize,
    pub stream_id: i32,
    pub kind: u8,
    pub flags: u8,
    pub reserved: u8,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PrioritySpec {
    pub stream_id: i32,
    pub weight: i32,
    pub exclusive: u8,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct HeadersFrame {
    pub hd: FrameHd,
    pub padlen: usize,
    pub pri_spec: PrioritySpec,
    pub nva: *mut Nv,
    pub nvlen: usize,
    pub cat: c_int,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PingFrame {
    pub hd: FrameHd,
    pub opaque_data: [u8; 8],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GoawayFrame {
    pub hd: FrameHd,
    pub last_stream_id: i32,
    pub error_code: u32,
    pub opaque_data: *mut u8,
    pub opaque_data_len: usize,
    pub reserved: u8,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct DataFrame {
    pub hd: FrameHd,
    pub padlen: usize,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PriorityFrame {
    pub hd: FrameHd,
    pub pri_spec: PrioritySpec,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct RstStreamFrame {
    pub hd: FrameHd,
    pub error_code: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SettingsFrame {
    pub hd: FrameHd,
    pub niv: usize,
    pub iv: *mut SettingsEntry,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct PushPromiseFrame {
    pub hd: FrameHd,
    pub padlen: usize,
    pub nva: *mut Nv,
    pub nvlen: usize,
    pub promised_stream_id: i32,
    pub reserved: u8,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct WindowUpdateFrame {
    pub hd: FrameHd,
    pub window_size_increment: i32,
    pub reserved: u8,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ExtensionFrame {
    pub hd: FrameHd,
    pub payload: *mut c_void,
}

#[repr(C)]
pub struct ExtAltsvc {
    pub origin: *mut u8,
    pub origin_len: usize,
    pub field_value: *mut u8,
    pub field_value_len: usize,
}

#[repr(C)]
pub struct ExtPriorityUpdate {
    pub stream_id: i32,
    pub field_value: *mut u8,
    pub field_value_len: usize,
}

#[repr(C)]
pub struct OriginEntry {
    pub origin: *mut u8,
    pub origin_len: usize,
}

#[repr(C)]
pub struct ExtOrigin {
    pub nov: usize,
    pub ov: *mut OriginEntry,
}

#[repr(C)]
pub union Frame {
    pub hd: FrameHd,
    pub data: DataFrame,
    pub headers: HeadersFrame,
    pub priority: PriorityFrame,
    pub rst_stream: RstStreamFrame,
    pub settings: SettingsFrame,
    pub push_promise: PushPromiseFrame,
    pub ping: PingFrame,
    pub goaway: GoawayFrame,
    pub window_update: WindowUpdateFrame,
    pub ext: ExtensionFrame,
    // The real union is 64 bytes (its largest member is the HEADERS frame).
    pad: [u64; 8],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SettingsEntry {
    pub id: i32,
    pub value: u32,
}

#[repr(C)]
pub struct DataSource {
    pub ptr: *mut c_void,
}

pub type DataReadCallback2 = unsafe extern "C" fn(
    session: *mut nghttp2_session,
    stream_id: i32,
    buf: *mut u8,
    length: usize,
    data_flags: *mut u32,
    source: *mut DataSource,
    user_data: *mut c_void,
) -> isize;

#[repr(C)]
pub struct DataProvider2 {
    pub source: DataSource,
    pub read_callback: DataReadCallback2,
}

pub type OnBeginHeaders = unsafe extern "C" fn(*mut nghttp2_session, *const Frame, *mut c_void) -> c_int;
pub type OnHeader = unsafe extern "C" fn(*mut nghttp2_session, *const Frame, *const u8, usize, *const u8, usize, u8, *mut c_void) -> c_int;
pub type OnFrameRecv = unsafe extern "C" fn(*mut nghttp2_session, *const Frame, *mut c_void) -> c_int;
pub type OnDataChunk = unsafe extern "C" fn(*mut nghttp2_session, u8, i32, *const u8, usize, *mut c_void) -> c_int;
pub type OnStreamClose = unsafe extern "C" fn(*mut nghttp2_session, i32, u32, *mut c_void) -> c_int;
pub type OnInvalidFrameRecv = unsafe extern "C" fn(*mut nghttp2_session, *const Frame, c_int, *mut c_void) -> c_int;
pub type SelectPadding2 = unsafe extern "C" fn(*mut nghttp2_session, *const Frame, usize, *mut c_void) -> isize;
pub type PackExtension2 = unsafe extern "C" fn(*mut nghttp2_session, *mut u8, usize, *const Frame, *mut c_void) -> isize;
pub type UnpackExtension = unsafe extern "C" fn(*mut nghttp2_session, *mut *mut c_void, *const FrameHd, *mut c_void) -> c_int;
pub type OnExtensionChunk = unsafe extern "C" fn(*mut nghttp2_session, *const FrameHd, *const u8, usize, *mut c_void) -> c_int;

unsafe extern "C" {
    pub fn nghttp2_strerror(code: c_int) -> *const c_char;

    pub fn nghttp2_session_callbacks_new(out: *mut *mut nghttp2_session_callbacks) -> c_int;
    pub fn nghttp2_session_callbacks_del(cbs: *mut nghttp2_session_callbacks);
    pub fn nghttp2_session_callbacks_set_on_begin_headers_callback(cbs: *mut nghttp2_session_callbacks, f: OnBeginHeaders);
    pub fn nghttp2_session_callbacks_set_on_header_callback(cbs: *mut nghttp2_session_callbacks, f: OnHeader);
    pub fn nghttp2_session_callbacks_set_on_frame_recv_callback(cbs: *mut nghttp2_session_callbacks, f: OnFrameRecv);
    pub fn nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs: *mut nghttp2_session_callbacks, f: OnDataChunk);
    pub fn nghttp2_session_callbacks_set_on_stream_close_callback(cbs: *mut nghttp2_session_callbacks, f: OnStreamClose);

    pub fn nghttp2_option_new(out: *mut *mut nghttp2_option) -> c_int;
    pub fn nghttp2_option_del(option: *mut nghttp2_option);
    pub fn nghttp2_option_set_no_auto_window_update(option: *mut nghttp2_option, val: c_int);
    pub fn nghttp2_option_set_no_auto_ping_ack(option: *mut nghttp2_option, val: c_int);
    pub fn nghttp2_option_set_no_http_messaging(option: *mut nghttp2_option, val: c_int);
    pub fn nghttp2_option_set_user_recv_extension_type(option: *mut nghttp2_option, kind: u8);
    pub fn nghttp2_option_set_builtin_recv_extension_type(option: *mut nghttp2_option, kind: u8);
    pub fn nghttp2_session_callbacks_set_on_invalid_frame_recv_callback(cbs: *mut nghttp2_session_callbacks, f: OnInvalidFrameRecv);
    pub fn nghttp2_session_callbacks_set_select_padding_callback2(cbs: *mut nghttp2_session_callbacks, f: SelectPadding2);
    pub fn nghttp2_session_callbacks_set_pack_extension_callback2(cbs: *mut nghttp2_session_callbacks, f: PackExtension2);
    pub fn nghttp2_session_callbacks_set_unpack_extension_callback(cbs: *mut nghttp2_session_callbacks, f: UnpackExtension);
    pub fn nghttp2_session_callbacks_set_on_extension_chunk_recv_callback(cbs: *mut nghttp2_session_callbacks, f: OnExtensionChunk);

    pub fn nghttp2_session_client_new2(
        out: *mut *mut nghttp2_session,
        cbs: *const nghttp2_session_callbacks,
        user_data: *mut c_void,
        option: *const nghttp2_option,
    ) -> c_int;
    pub fn nghttp2_session_server_new2(
        out: *mut *mut nghttp2_session,
        cbs: *const nghttp2_session_callbacks,
        user_data: *mut c_void,
        option: *const nghttp2_option,
    ) -> c_int;
    pub fn nghttp2_session_del(session: *mut nghttp2_session);

    pub fn nghttp2_session_mem_recv2(session: *mut nghttp2_session, input: *const u8, len: usize) -> isize;
    pub fn nghttp2_session_mem_send2(session: *mut nghttp2_session, data: *mut *const u8) -> isize;
    pub fn nghttp2_session_want_read(session: *mut nghttp2_session) -> c_int;
    pub fn nghttp2_session_want_write(session: *mut nghttp2_session) -> c_int;
    pub fn nghttp2_session_resume_data(session: *mut nghttp2_session, stream_id: i32) -> c_int;
    pub fn nghttp2_session_consume(session: *mut nghttp2_session, stream_id: i32, size: usize) -> c_int;
    pub fn nghttp2_session_consume_connection(session: *mut nghttp2_session, size: usize) -> c_int;
    pub fn nghttp2_session_set_local_window_size(session: *mut nghttp2_session, flags: u8, stream_id: i32, window: i32) -> c_int;
    pub fn nghttp2_session_get_remote_settings(session: *const nghttp2_session, id: c_int) -> u32;
    pub fn nghttp2_session_get_local_settings(session: *const nghttp2_session, id: c_int) -> u32;
    pub fn nghttp2_session_get_next_stream_id(session: *const nghttp2_session) -> u32;
    pub fn nghttp2_session_get_remote_window_size(session: *mut nghttp2_session) -> i32;
    pub fn nghttp2_session_get_effective_local_window_size(session: *mut nghttp2_session) -> i32;
    pub fn nghttp2_session_get_stream_remote_window_size(session: *mut nghttp2_session, stream_id: i32) -> i32;
    pub fn nghttp2_session_get_stream_effective_local_window_size(session: *mut nghttp2_session, stream_id: i32) -> i32;
    pub fn nghttp2_session_find_stream(session: *mut nghttp2_session, stream_id: i32) -> *mut nghttp2_stream;
    pub fn nghttp2_stream_get_state(stream: *mut nghttp2_stream) -> c_int;
    pub fn nghttp2_session_terminate_session(session: *mut nghttp2_session, error_code: u32) -> c_int;

    pub fn nghttp2_submit_settings(session: *mut nghttp2_session, flags: u8, iv: *const SettingsEntry, niv: usize) -> c_int;
    pub fn nghttp2_submit_request2(
        session: *mut nghttp2_session,
        pri_spec: *const PrioritySpec,
        nva: *const Nv,
        nvlen: usize,
        data: *const DataProvider2,
        stream_user_data: *mut c_void,
    ) -> i32;
    pub fn nghttp2_submit_response2(
        session: *mut nghttp2_session,
        stream_id: i32,
        nva: *const Nv,
        nvlen: usize,
        data: *const DataProvider2,
    ) -> c_int;
    pub fn nghttp2_submit_trailer(session: *mut nghttp2_session, stream_id: i32, nva: *const Nv, nvlen: usize) -> c_int;
    pub fn nghttp2_submit_rst_stream(session: *mut nghttp2_session, flags: u8, stream_id: i32, error_code: u32) -> c_int;
    pub fn nghttp2_submit_ping(session: *mut nghttp2_session, flags: u8, opaque_data: *const u8) -> c_int;
    pub fn nghttp2_submit_headers(
        session: *mut nghttp2_session,
        flags: u8,
        stream_id: i32,
        pri_spec: *const PrioritySpec,
        nva: *const Nv,
        nvlen: usize,
        stream_user_data: *mut c_void,
    ) -> i32;
    pub fn nghttp2_submit_data2(session: *mut nghttp2_session, flags: u8, stream_id: i32, data: *const DataProvider2) -> c_int;
    pub fn nghttp2_submit_priority(session: *mut nghttp2_session, flags: u8, stream_id: i32, pri_spec: *const PrioritySpec) -> c_int;
    pub fn nghttp2_submit_goaway(
        session: *mut nghttp2_session,
        flags: u8,
        last_stream_id: i32,
        error_code: u32,
        opaque_data: *const u8,
        opaque_data_len: usize,
    ) -> c_int;
    pub fn nghttp2_submit_window_update(session: *mut nghttp2_session, flags: u8, stream_id: i32, increment: i32) -> c_int;
    pub fn nghttp2_submit_push_promise(
        session: *mut nghttp2_session,
        flags: u8,
        stream_id: i32,
        nva: *const Nv,
        nvlen: usize,
        promised_stream_user_data: *mut c_void,
    ) -> i32;
    pub fn nghttp2_submit_altsvc(
        session: *mut nghttp2_session,
        flags: u8,
        stream_id: i32,
        origin: *const u8,
        origin_len: usize,
        field_value: *const u8,
        field_value_len: usize,
    ) -> c_int;
    pub fn nghttp2_submit_priority_update(session: *mut nghttp2_session, flags: u8, stream_id: i32, value: *const u8, len: usize) -> c_int;
    pub fn nghttp2_submit_origin(session: *mut nghttp2_session, flags: u8, ov: *const OriginEntry, nov: usize) -> c_int;
    pub fn nghttp2_submit_extension(session: *mut nghttp2_session, kind: u8, flags: u8, stream_id: i32, payload: *mut c_void) -> c_int;
}

#[cfg(all(test, target_pointer_width = "64"))]
mod layout {
    use super::*;
    use std::mem::{offset_of, size_of};

    #[test]
    fn structs_match_the_c_header() {
        assert_eq!(size_of::<FrameHd>(), 16);
        assert_eq!((size_of::<Nv>(), offset_of!(Nv, namelen), offset_of!(Nv, flags)), (40, 16, 32));
        assert_eq!(size_of::<PrioritySpec>(), 12);
        assert_eq!((size_of::<HeadersFrame>(), offset_of!(HeadersFrame, nva), offset_of!(HeadersFrame, cat)), (64, 40, 56));
        assert_eq!(size_of::<SettingsEntry>(), 8);
        assert_eq!((size_of::<GoawayFrame>(), offset_of!(GoawayFrame, last_stream_id), offset_of!(GoawayFrame, error_code)), (48, 16, 20));
        assert_eq!(size_of::<PingFrame>(), 24);
        assert_eq!(size_of::<DataProvider2>(), 16);
        assert_eq!(size_of::<Frame>(), 64);
        assert_eq!((size_of::<DataFrame>(), offset_of!(DataFrame, padlen)), (24, 16));
        assert_eq!((size_of::<PriorityFrame>(), offset_of!(PriorityFrame, pri_spec)), (32, 16));
        assert_eq!((size_of::<RstStreamFrame>(), offset_of!(RstStreamFrame, error_code)), (24, 16));
        assert_eq!((size_of::<SettingsFrame>(), offset_of!(SettingsFrame, niv), offset_of!(SettingsFrame, iv)), (32, 16, 24));
        assert_eq!(
            (size_of::<PushPromiseFrame>(), offset_of!(PushPromiseFrame, nva), offset_of!(PushPromiseFrame, promised_stream_id)),
            (48, 24, 40)
        );
        assert_eq!((size_of::<WindowUpdateFrame>(), offset_of!(WindowUpdateFrame, window_size_increment)), (24, 16));
        assert_eq!((size_of::<ExtensionFrame>(), offset_of!(ExtensionFrame, payload)), (24, 16));
        assert_eq!((size_of::<ExtAltsvc>(), size_of::<OriginEntry>(), size_of::<ExtOrigin>()), (32, 16, 16));
    }
}
