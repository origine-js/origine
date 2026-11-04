//! HTTP/2 as a sans-io state machine over nghttp2.
//!
//! A [`Session`] never touches a socket: the caller passes received bytes to [`Session::recv`],
//! collects bytes to send with [`Session::send`], and reads what happened from
//! [`Session::next_event`]. Requests, responses, bodies, trailers and resets are submitted with the
//! other methods. Header fields travel as a [`FieldList`]: an ordered, packed sequence of
//! name/value pairs (not a map), so the layer above crosses into JS once per batch.
//!
//! Flow control is the caller's: received data stays unacknowledged until [`Session::consume`] says
//! it was used, so a slow reader slows the peer.

mod driver;
mod error;
mod event;
mod fields;
mod frame_driver;
mod frames;
mod session;
mod sys;

#[cfg(test)]
mod driver_tests;
#[cfg(test)]
mod frames_tests;
#[cfg(test)]
mod tests;

pub use driver::{ConnError, Connection, Driver, Exchange, StreamEvent, connect};
pub use error::H2Error;
pub use event::{Event, HeaderKind, Limits, Pseudo, Role};
pub use fields::{FieldList, Fields};
pub use frame_driver::{FrameConn, FrameDriver, Next, frame_connect};
pub use frames::{Category, FrameEvent, FrameOptions, FrameSession, Messaging, Priority, SettingId, Settings, StreamState};
pub use session::{Body, RequestHead, Session};
