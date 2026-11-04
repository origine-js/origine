//! The bridge from the guest's stream objects to the Rust [`Transport`] the protocol engines (`origine_tls`,
//! `origine_h2`, the DNS exchanges) run over.
//!
//! A native stream (a `TcpStreamUnshaped` or `TlsStreamUnshaped`, or a shaped stream nothing is using) is
//! recognised by its class (the cppgc `TypeId`) and **consumed**: its socket leaves the object (which answers
//! `BadHandle` afterwards) and the engine reads and writes it on the loop, without entering JS.
//!
//! Any other object is a **duck-typed stream** ([`JsStream`], `api.tls` only for now): the engine reads and writes it
//! by calling its JS methods, `read(length)` (or `readInto(buffer)`), `queued.put(bytes)` and `queued.drained()`,
//! `end('write')` and `close()`. It is slower (one turn of the loop and a copy per call) and it runs on the `io` the
//! caller names, since it has no runtime of its own.

use std::future::{Future, poll_fn};
use std::io;
use std::rc::Rc;

use origine_api_core::{ArgError, NativeError};
use origine_io::Loop;
use origine_transport::Transport;

use crate::FromJs;
use crate::conn::{Conn, Front};
use crate::gc;
use crate::io::IoCore;
use crate::net::Socket;
use crate::stream::{EventTcpStream, PullTcpStream, TcpStreamUnshaped};

/// The bytes under a TLS stream or an HTTP/2 session: a socket (plain or TLS), read and written through its loop.
/// Holds the socket, so closing the guest's object cannot free the descriptor under a running op.
pub(crate) struct SocketTransport {
    pub(crate) socket: Rc<Socket>,
    pub(crate) lp: Rc<Loop>,
}

impl Transport for SocketTransport {
    fn read(&self, buf: Vec<u8>) -> impl Future<Output = (io::Result<usize>, Vec<u8>)> {
        let (socket, lp) = (Rc::clone(&self.socket), Rc::clone(&self.lp));
        // Boxed: a socket may itself be a TLS stream over this transport.
        Box::pin(async move { socket.recv(&lp, buf).await })
    }

    fn write_all(&self, buf: Vec<u8>) -> impl Future<Output = (io::Result<()>, Vec<u8>)> {
        let (socket, lp) = (Rc::clone(&self.socket), Rc::clone(&self.lp));
        Box::pin(async move {
            let mut buf = buf;
            while !buf.is_empty() {
                let (result, back) = socket.send(&lp, buf).await;
                buf = back;
                match result {
                    Ok(0) => return (Err(io::Error::from(io::ErrorKind::WriteZero)), buf),
                    Ok(n) => {
                        buf.drain(..n);
                    }
                    Err(e) => return (Err(e), buf),
                }
            }
            (Ok(()), buf)
        })
    }
}

/// A stream argument of a protocol engine: a native stream, or any other object (a duck-typed stream, checked by
/// the engine that accepts one).
pub(crate) enum StreamArg<'s> {
    Native(NativeStream<'s>),
    Js(v8::Local<'s, v8::Object>),
}

/// One of the native stream classes (TCP or TLS, any shape), borrowed for the call.
pub(crate) struct NativeStream<'s>(&'s Front);

impl<'s> FromJs<'s> for StreamArg<'s> {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        let isolate: &mut v8::Isolate = scope;
        if let Some(front) = native_front(isolate, value) {
            return Ok(StreamArg::Native(NativeStream(front)));
        }
        v8::Local::<v8::Object>::try_from(value)
            .map(StreamArg::Js)
            .map_err(|_| ArgError::new(index, "a stream (a native stream, or an object with read, queued, end and close)"))
    }
}

/// The [`Front`] of a native stream object, whatever its shape.
pub(crate) fn native_front<'s>(isolate: &mut v8::Isolate, value: v8::Local<'s, v8::Value>) -> Option<&'s Front> {
    if let Some(stream) = gc::unwrap_ref::<TcpStreamUnshaped>(isolate, value) {
        return Some(&stream.0);
    }
    if let Some(stream) = gc::unwrap_ref::<PullTcpStream>(isolate, value) {
        return Some(stream.front());
    }
    if let Some(stream) = gc::unwrap_ref::<EventTcpStream>(isolate, value) {
        return Some(stream.front());
    }
    #[cfg(feature = "tls")]
    {
        use crate::tls::{EventTlsStream, PullTlsStream, TlsStreamUnshaped};
        if let Some(stream) = gc::unwrap_ref::<TlsStreamUnshaped>(isolate, value) {
            return Some(&stream.0);
        }
        if let Some(stream) = gc::unwrap_ref::<PullTlsStream>(isolate, value) {
            return Some(&stream.0);
        }
        if let Some(stream) = gc::unwrap_ref::<EventTlsStream>(isolate, value) {
            return Some(&stream.0);
        }
    }
    None
}

impl StreamArg<'_> {
    /// The native stream; a `TypeError` for a duck-typed one (what an engine without the JS adapter answers).
    pub(crate) fn native(&self) -> Result<&NativeStream<'_>, NativeError> {
        match self {
            StreamArg::Native(stream) => Ok(stream),
            StreamArg::Js(_) => {
                Err(NativeError::type_error("expected a native stream (TcpStreamUnshaped, TlsStreamUnshaped or an idle shaped one)"))
            }
        }
    }
}

impl NativeStream<'_> {
    /// The conn of the stream, if nothing is using it (no read in flight, nothing queued, no handler, neither side
    /// ended); `WouldBlock` / `Unsupported` / `BadHandle` otherwise, leaving the object usable.
    pub(crate) fn conn(&self) -> Result<Rc<Conn>, NativeError> {
        let conn = self.0.get()?;
        conn.idle()?;
        Ok(conn)
    }

    /// Takes the stream's socket out (the object is consumed), with its runtime.
    pub(crate) fn take(&self) -> Result<(Rc<IoCore>, Rc<Socket>), NativeError> {
        let conn = self.0.take(Conn::idle)?;
        let socket = conn.detach()?;
        Ok((Rc::clone(&conn.io), socket))
    }
}

#[cfg(feature = "tls")]
pub(crate) use js::{JsStream, JsStreamError, JsStreams, Under};

/// The duck-typed stream adapter and what a TLS stream runs over.
#[cfg(feature = "tls")]
mod js {
    use std::cell::{Cell, RefCell};
    use std::collections::BTreeMap;
    use std::fmt;
    use std::pin::Pin;
    use std::task::{Poll, Waker};

    use origine_api_core::errno;

    use super::*;
    use crate::HostState;
    use crate::decode::ArrayBufferArg;
    use crate::host::{Completion, CompletionQueue};

    /// The transport under a TLS stream: a native socket (plain or TLS), or a duck-typed JS stream.
    pub(crate) enum Under {
        Socket(SocketTransport),
        Js(Rc<JsStream>),
    }

    type Boxed<'a, T> = Pin<Box<dyn Future<Output = T> + 'a>>;

    impl Transport for Under {
        fn read(&self, buf: Vec<u8>) -> impl Future<Output = (io::Result<usize>, Vec<u8>)> {
            let future: Boxed<'_, (io::Result<usize>, Vec<u8>)> = match self {
                Under::Socket(socket) => Box::pin(socket.read(buf)),
                Under::Js(stream) => Box::pin(Rc::clone(stream).read(buf)),
            };
            future
        }

        fn write_all(&self, buf: Vec<u8>) -> impl Future<Output = (io::Result<()>, Vec<u8>)> {
            let future: Boxed<'_, (io::Result<()>, Vec<u8>)> = match self {
                Under::Socket(socket) => Box::pin(socket.write_all(buf)),
                Under::Js(stream) => Box::pin(Rc::clone(stream).write_all(buf)),
            };
            future
        }
    }

    impl Under {
        /// The descriptor of a socket underneath (-1 for a JS stream: it has none).
        pub(crate) fn fd(&self) -> isize {
            match self {
                Under::Socket(socket) => socket.socket.fd(),
                Under::Js(_) => -1,
            }
        }

        pub(crate) fn addrs(&self) -> (Option<std::net::SocketAddr>, Option<std::net::SocketAddr>) {
            match self {
                Under::Socket(socket) => socket.socket.addrs(),
                Under::Js(_) => (None, None),
            }
        }

        /// The FIN after `close_notify`: `shutdown(SHUT_WR)`, or `end('write')` of a JS stream.
        pub(crate) fn shutdown_write(&self) {
            match self {
                Under::Socket(socket) => socket.socket.shutdown_write(),
                Under::Js(stream) => stream.end(),
            }
        }

        /// Closes what is underneath: pending reads end.
        pub(crate) fn shutdown(&self) {
            match self {
                Under::Socket(socket) => socket.socket.shutdown(),
                Under::Js(stream) => stream.close(),
            }
        }
    }

    /// How a duck-typed stream failed the engine. The guest sees the stream's own errno when its promise rejected
    /// with an `IoError` / `HostError`, else `Unexpected` (a rejection without one) or `InvalidData` (a bad value),
    /// with the method as `subject`.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub(crate) enum JsStreamError {
        /// The method threw, or its promise rejected; `errno` is the code the error carried, if any.
        Rejected { method: Method, errno: Option<u32> },
        /// The method answered something that is not what the stream contract says.
        BadValue { method: Method },
    }

    /// A method of the duck-typed stream contract.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub(crate) enum Method {
        Read,
        ReadInto,
        Put,
        Drained,
    }

    impl Method {
        pub(crate) fn name(self) -> &'static str {
            match self {
                Method::Read => "read",
                Method::ReadInto => "readInto",
                Method::Put => "queued.put",
                Method::Drained => "queued.drained",
            }
        }
    }

    impl fmt::Display for JsStreamError {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            match self {
                JsStreamError::Rejected { method, errno: Some(code) } => {
                    write!(f, "stream.{} failed: {}", method.name(), errno::name_of(*code))
                }
                JsStreamError::Rejected { method, errno: None } => write!(f, "stream.{} failed", method.name()),
                JsStreamError::BadValue { method } => write!(f, "stream.{} answered an unexpected value", method.name()),
            }
        }
    }

    impl std::error::Error for JsStreamError {}

    impl JsStreamError {
        fn into_io(self) -> io::Error {
            let kind = match self {
                JsStreamError::Rejected { .. } => io::ErrorKind::Other,
                JsStreamError::BadValue { .. } => io::ErrorKind::InvalidData,
            };
            io::Error::new(kind, self)
        }

        /// The errno and subject the guest gets.
        pub(crate) fn native(&self) -> NativeError {
            let (code, method) = match *self {
                JsStreamError::Rejected { method, errno } => (errno.unwrap_or(errno::UNEXPECTED), method),
                JsStreamError::BadValue { method } => (errno::INVALID_DATA, method),
            };
            NativeError::Errno(code).with_subject(method.name().to_owned())
        }
    }

    /// One operation of a stream in flight, as the engine waits on it.
    enum Slot<T> {
        Idle,
        Pending(Option<Waker>),
        Ready(T),
    }

    impl<T> Slot<T> {
        fn finish(&mut self, value: T) {
            if let Slot::Pending(waker) = std::mem::replace(self, Slot::Ready(value))
                && let Some(waker) = waker
            {
                waker.wake();
            }
        }
    }

    /// The Rust side of a duck-typed stream: no V8 in it. The JS object lives in the Host ([`JsStreams`]) and is
    /// reached by `id` from completions run on the isolate thread.
    pub(crate) struct JsStream {
        id: u32,
        completions: CompletionQueue,
        read: RefCell<Slot<Result<Vec<u8>, JsStreamError>>>,
        write: RefCell<Slot<Result<(), JsStreamError>>>,
        /// Bytes a `read` answered beyond what was asked, served first.
        leftover: RefCell<Vec<u8>>,
        closed: Cell<bool>,
    }

    impl JsStream {
        fn schedule(&self, run: impl for<'s, 'i> FnOnce(&mut v8::PinScope<'s, 'i, ()>) + 'static) {
            let completion: Completion = Box::new(run);
            if let Ok(mut completions) = self.completions.try_borrow_mut() {
                completions.push(completion);
            }
        }

        async fn read(self: Rc<Self>, mut buf: Vec<u8>) -> (io::Result<usize>, Vec<u8>) {
            {
                let mut leftover = self.leftover.borrow_mut();
                if !leftover.is_empty() {
                    let n = leftover.len().min(buf.len());
                    buf[..n].copy_from_slice(&leftover[..n]);
                    leftover.drain(..n);
                    return (Ok(n), buf);
                }
            }
            let len = buf.len();
            if len == 0 || self.closed.get() {
                return (Ok(0), buf);
            }
            // A read abandoned earlier may still be in flight: its bytes are this read's.
            if matches!(*self.read.borrow(), Slot::Idle) {
                *self.read.borrow_mut() = Slot::Pending(None);
                let id = self.id;
                self.schedule(move |scope| call_read(scope, id, len));
            }
            let result = poll_fn(|cx| {
                let mut slot = self.read.borrow_mut();
                match std::mem::replace(&mut *slot, Slot::Idle) {
                    Slot::Ready(result) => Poll::Ready(Some(result)),
                    Slot::Pending(_) if self.closed.get() => {
                        *slot = Slot::Pending(None);
                        Poll::Ready(None)
                    }
                    _ => {
                        *slot = Slot::Pending(Some(cx.waker().clone()));
                        Poll::Pending
                    }
                }
            })
            .await;
            match result {
                None => (Ok(0), buf),
                Some(Ok(bytes)) => {
                    let n = bytes.len().min(len);
                    buf[..n].copy_from_slice(&bytes[..n]);
                    self.leftover.borrow_mut().extend_from_slice(&bytes[n..]);
                    (Ok(n), buf)
                }
                Some(Err(error)) => (Err(error.into_io()), buf),
            }
        }

        async fn write_all(self: Rc<Self>, buf: Vec<u8>) -> (io::Result<()>, Vec<u8>) {
            // A write abandoned earlier finishes first: bytes leave in order.
            poll_fn(|cx| {
                let mut slot = self.write.borrow_mut();
                match &mut *slot {
                    Slot::Pending(waker) if !self.closed.get() => {
                        *waker = Some(cx.waker().clone());
                        Poll::Pending
                    }
                    _ => {
                        *slot = Slot::Idle;
                        Poll::Ready(())
                    }
                }
            })
            .await;
            if self.closed.get() {
                return (Err(io::ErrorKind::BrokenPipe.into()), buf);
            }
            if buf.is_empty() {
                return (Ok(()), buf);
            }
            *self.write.borrow_mut() = Slot::Pending(None);
            let (id, bytes) = (self.id, buf.clone());
            self.schedule(move |scope| call_write(scope, id, bytes));
            let result = poll_fn(|cx| {
                let mut slot = self.write.borrow_mut();
                match std::mem::replace(&mut *slot, Slot::Idle) {
                    Slot::Ready(result) => Poll::Ready(Some(result)),
                    Slot::Pending(_) if self.closed.get() => {
                        *slot = Slot::Pending(None);
                        Poll::Ready(None)
                    }
                    _ => {
                        *slot = Slot::Pending(Some(cx.waker().clone()));
                        Poll::Pending
                    }
                }
            })
            .await;
            match result {
                Some(Ok(())) => (Ok(()), buf),
                Some(Err(error)) => (Err(error.into_io()), buf),
                None => (Err(io::ErrorKind::BrokenPipe.into()), buf),
            }
        }

        /// `end('write')` of the JS stream (its result is not awaited).
        fn end(&self) {
            if !self.closed.get() {
                let id = self.id;
                self.schedule(move |scope| call_simple(scope, id, "end", true));
            }
        }

        /// `close()` of the JS stream (not awaited); reads and writes waiting on it end now.
        fn close(&self) {
            if self.closed.replace(true) {
                return;
            }
            self.read.borrow_mut().wake();
            self.write.borrow_mut().wake();
            let id = self.id;
            self.schedule(move |scope| call_simple(scope, id, "close", false));
        }
    }

    impl<T> Slot<T> {
        /// Wakes whoever waits on the slot (it stays pending).
        fn wake(&mut self) {
            if let Slot::Pending(waker) = self
                && let Some(waker) = waker.take()
            {
                waker.wake();
            }
        }
    }

    impl Drop for JsStream {
        fn drop(&mut self) {
            // The JS object is released on the isolate thread (a `Global` must not be dropped from a task).
            let id = self.id;
            self.schedule(move |scope| {
                if let Some(host) = scope.get_slot_mut::<HostState>() {
                    host.js_streams.entries.remove(&id);
                }
            });
        }
    }

    /// A duck-typed stream as the Host keeps it.
    pub(crate) struct JsEntry {
        object: v8::Global<v8::Object>,
        context: v8::Global<v8::Context>,
        runtime: u32,
        stream: std::rc::Weak<JsStream>,
        /// The write being put, and how much of it the stream took.
        writing: Option<(v8::Global<v8::Uint8Array>, usize)>,
    }

    /// The Host's duck-typed streams, by an id that never reaches JS.
    #[derive(Default)]
    pub(crate) struct JsStreams {
        entries: BTreeMap<u32, JsEntry>,
        next: u32,
    }

    impl JsStreams {
        /// Forgets the streams of a runtime that is closing.
        pub(crate) fn drop_runtime(&mut self, runtime: u32) {
            self.entries.retain(|_, entry| entry.runtime != runtime);
        }

        pub(crate) fn clear(&mut self) {
            self.entries.clear();
        }
    }

    fn function<'s>(
        scope: &mut v8::PinScope<'s, '_>,
        object: v8::Local<'s, v8::Object>,
        name: &str,
    ) -> Option<v8::Local<'s, v8::Function>> {
        let key = v8::String::new(scope, name)?;
        object.get(scope, key.into()).and_then(|value| v8::Local::<v8::Function>::try_from(value).ok())
    }

    fn property<'s>(scope: &mut v8::PinScope<'s, '_>, object: v8::Local<'s, v8::Object>, name: &str) -> Option<v8::Local<'s, v8::Object>> {
        let key = v8::String::new(scope, name)?;
        object.get(scope, key.into()).and_then(|value| v8::Local::<v8::Object>::try_from(value).ok())
    }

    impl JsStream {
        /// Adopts `object` as a stream running on `io`: `TypeError` unless it has `read(length)` or
        /// `readInto(buffer)`, `queued.put(bytes)`, `queued.drained()`, `end(side)` and `close()`.
        pub(crate) fn adopt<'s>(
            scope: &mut v8::PinScope<'s, '_>,
            object: v8::Local<'s, v8::Object>,
            io: &IoCore,
        ) -> Result<Rc<JsStream>, NativeError> {
            let readable = function(scope, object, "read").is_some() || function(scope, object, "readInto").is_some();
            let queued = property(scope, object, "queued");
            let writable =
                queued.is_some_and(|queued| function(scope, queued, "put").is_some() && function(scope, queued, "drained").is_some());
            if !readable || !writable || function(scope, object, "end").is_none() || function(scope, object, "close").is_none() {
                return Err(NativeError::type_error(
                    "a stream that is not native must have read(length) or readInto(buffer), queued.put(bytes), queued.drained(), end(side) and close()",
                ));
            }
            let host = crate::native::host_mut(scope)?;
            let id = host.js_streams.next;
            host.js_streams.next = id.checked_add(1).ok_or(NativeError::Errno(errno::UNSUPPORTED))?;
            let stream = Rc::new(JsStream {
                id,
                completions: host.completions(),
                read: RefCell::new(Slot::Idle),
                write: RefCell::new(Slot::Idle),
                leftover: RefCell::default(),
                closed: Cell::new(false),
            });
            let object = v8::Global::new(scope, object);
            let current = scope.get_current_context();
            let context = v8::Global::new(scope, current);
            let entry = JsEntry { object, context, runtime: io.runtime, stream: Rc::downgrade(&stream), writing: None };
            crate::native::host_mut(scope)?.js_streams.entries.insert(id, entry);
            Ok(stream)
        }
    }

    /// The object and context of stream `id`, if it is still known (its Rust side may be gone: an `end` or `close`
    /// it scheduled still runs).
    fn lookup(scope: &mut v8::PinScope<'_, '_, ()>, id: u32) -> Option<(v8::Global<v8::Object>, v8::Global<v8::Context>)> {
        let entry = scope.get_slot::<HostState>()?.js_streams.entries.get(&id)?;
        Some((entry.object.clone(), entry.context.clone()))
    }

    /// The code an error value carries (`errno` of an `IoError` / `HostError`), if it is a known one.
    fn errno_of<'s>(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>) -> Option<u32> {
        let object = v8::Local::<v8::Object>::try_from(value).ok()?;
        let key = v8::String::new(scope, "errno")?;
        let code = object.get(scope, key.into())?;
        if !code.is_number() {
            return None;
        }
        let code = code.uint32_value(scope)?;
        errno::ALL.iter().any(|(known, _)| *known == code).then_some(code)
    }

    /// `value` as a promise (a non-promise is one already resolved with it).
    fn promise_of<'s>(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>) -> Option<v8::Local<'s, v8::Promise>> {
        if let Ok(promise) = v8::Local::<v8::Promise>::try_from(value) {
            return Some(promise);
        }
        let resolver = v8::PromiseResolver::new(scope)?;
        resolver.resolve(scope, value);
        Some(resolver.get_promise(scope))
    }

    /// Calls `method` of `receiver` with `args`: its result as a promise, or the error it threw.
    fn invoke<'s>(
        scope: &mut v8::PinScope<'s, '_>,
        receiver: v8::Local<'s, v8::Object>,
        function: v8::Local<'s, v8::Function>,
        args: &[v8::Local<'s, v8::Value>],
    ) -> Result<v8::Local<'s, v8::Value>, Option<u32>> {
        v8::tc_scope!(let tc, scope);
        match function.call(tc, receiver.into(), args) {
            Some(value) => Ok(value),
            None => {
                let exception = tc.exception();
                Err(exception.and_then(|exception| errno_of(tc, exception)))
            }
        }
    }

    /// Attaches `fulfilled` / `rejected` (native callbacks told the stream id) to `promise`.
    fn then(
        scope: &mut v8::PinScope<'_, '_>,
        promise: v8::Local<'_, v8::Promise>,
        id: u32,
        fulfilled: impl v8::MapFnTo<v8::FunctionCallback>,
        rejected: impl v8::MapFnTo<v8::FunctionCallback>,
    ) -> bool {
        let data = v8::Integer::new_from_unsigned(scope, id).into();
        let fulfilled = v8::Function::builder(fulfilled).data(data).build(scope);
        let rejected = v8::Function::builder(rejected).data(data).build(scope);
        match (fulfilled, rejected) {
            (Some(fulfilled), Some(rejected)) => promise.then2(scope, fulfilled, rejected).is_some(),
            _ => false,
        }
    }

    fn id_of<'s>(scope: &mut v8::PinScope<'s, '_>, args: &v8::FunctionCallbackArguments<'s>) -> Option<u32> {
        args.data().uint32_value(scope)
    }

    /// Finishes the pending read of stream `id`.
    fn read_done(scope: &mut v8::PinScope<'_, '_>, id: u32, result: Result<Vec<u8>, JsStreamError>) {
        let stream =
            scope.get_slot::<HostState>().and_then(|host| host.js_streams.entries.get(&id)).and_then(|entry| entry.stream.upgrade());
        if let Some(stream) = stream {
            stream.read.borrow_mut().finish(result);
        }
    }

    /// Finishes the pending write of stream `id`.
    fn write_done(scope: &mut v8::PinScope<'_, '_>, id: u32, result: Result<(), JsStreamError>) {
        let host = scope.get_slot_mut::<HostState>();
        let Some(entry) = host.and_then(|host| host.js_streams.entries.get_mut(&id)) else { return };
        entry.writing = None;
        if let Some(stream) = entry.stream.upgrade() {
            stream.write.borrow_mut().finish(result);
        }
    }

    /// `read(length)`, else `readInto(new Uint8Array(length))`, of stream `id`.
    fn call_read(scope: &mut v8::PinScope<'_, '_, ()>, id: u32, len: usize) {
        let Some((object, context)) = lookup(scope, id) else { return };
        let context = v8::Local::new(scope, context);
        let scope = &mut v8::ContextScope::new(scope, context);
        let object = v8::Local::new(scope, object);
        let (method, callee, arg) = match function(scope, object, "read") {
            Some(read) => (Method::Read, read, v8::Number::new(scope, len as f64).into()),
            None => {
                let Some(read_into) = function(scope, object, "readInto") else {
                    return read_done(scope, id, Err(JsStreamError::BadValue { method: Method::Read }));
                };
                let buffer = v8::ArrayBuffer::new(scope, len);
                let Some(view) = v8::Uint8Array::new(scope, buffer, 0, len) else {
                    return read_done(scope, id, Err(JsStreamError::Rejected { method: Method::ReadInto, errno: None }));
                };
                (Method::ReadInto, read_into, view.into())
            }
        };
        let promise = invoke(scope, object, callee, &[arg]).map_err(|errno| JsStreamError::Rejected { method, errno });
        let promise = promise.and_then(|value| promise_of(scope, value).ok_or(JsStreamError::Rejected { method, errno: None }));
        match promise {
            Ok(promise) => {
                let attached = match method {
                    Method::ReadInto => then(scope, promise, id, read_into_fulfilled, read_into_rejected),
                    _ => then(scope, promise, id, read_fulfilled, read_rejected),
                };
                if !attached {
                    read_done(scope, id, Err(JsStreamError::Rejected { method, errno: None }));
                }
            }
            Err(error) => read_done(scope, id, Err(error)),
        }
    }

    /// The bytes a `read` answered: a typed array or `ArrayBuffer`; for `readInto`, `{ bytes, buffer }`.
    fn bytes_of<'s>(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, method: Method) -> Result<Vec<u8>, JsStreamError> {
        let bad = JsStreamError::BadValue { method };
        if method == Method::Read {
            return ArrayBufferArg::from_js(scope, value, 0).map(|bytes| bytes.to_vec()).map_err(|_| bad);
        }
        let object = v8::Local::<v8::Object>::try_from(value).map_err(|_| bad)?;
        let bytes_key = v8::String::new(scope, "bytes").ok_or(bad)?;
        let count =
            object.get(scope, bytes_key.into()).filter(|count| count.is_number()).and_then(|count| count.uint32_value(scope)).ok_or(bad)?;
        let buffer_key = v8::String::new(scope, "buffer").ok_or(bad)?;
        let buffer = object.get(scope, buffer_key.into()).ok_or(bad)?;
        let buffer = ArrayBufferArg::from_js(scope, buffer, 0).map_err(|_| bad)?;
        let count = count as usize;
        if count > buffer.len() {
            return Err(bad);
        }
        Ok(ArrayBufferArg::from_parts(buffer.buffer(), buffer.offset(), count).to_vec())
    }

    fn read_fulfilled<'s>(scope: &mut v8::PinScope<'s, '_>, args: v8::FunctionCallbackArguments<'s>, _: v8::ReturnValue<'s, v8::Value>) {
        let Some(id) = id_of(scope, &args) else { return };
        let bytes = bytes_of(scope, args.get(0), Method::Read);
        read_done(scope, id, bytes);
    }

    fn read_rejected<'s>(scope: &mut v8::PinScope<'s, '_>, args: v8::FunctionCallbackArguments<'s>, _: v8::ReturnValue<'s, v8::Value>) {
        let Some(id) = id_of(scope, &args) else { return };
        let errno = errno_of(scope, args.get(0));
        read_done(scope, id, Err(JsStreamError::Rejected { method: Method::Read, errno }));
    }

    fn read_into_fulfilled<'s>(
        scope: &mut v8::PinScope<'s, '_>,
        args: v8::FunctionCallbackArguments<'s>,
        _: v8::ReturnValue<'s, v8::Value>,
    ) {
        let Some(id) = id_of(scope, &args) else { return };
        let bytes = bytes_of(scope, args.get(0), Method::ReadInto);
        read_done(scope, id, bytes);
    }

    fn read_into_rejected<'s>(
        scope: &mut v8::PinScope<'s, '_>,
        args: v8::FunctionCallbackArguments<'s>,
        _: v8::ReturnValue<'s, v8::Value>,
    ) {
        let Some(id) = id_of(scope, &args) else { return };
        let errno = errno_of(scope, args.get(0));
        read_done(scope, id, Err(JsStreamError::Rejected { method: Method::ReadInto, errno }));
    }

    /// Starts writing `bytes` to stream `id`: `queued.put` as long as it takes some, `queued.drained()` between.
    fn call_write(scope: &mut v8::PinScope<'_, '_, ()>, id: u32, bytes: Vec<u8>) {
        let Some((_, context)) = lookup(scope, id) else { return };
        let context = v8::Local::new(scope, context);
        let scope = &mut v8::ContextScope::new(scope, context);
        let len = bytes.len();
        // Allocated by the isolate (inside the V8 sandbox when there is one), then filled.
        let buffer = v8::ArrayBuffer::new(scope, len);
        if crate::native::copy_into(buffer.into(), 0, len, &bytes).is_err() {
            return write_done(scope, id, Err(JsStreamError::Rejected { method: Method::Put, errno: None }));
        }
        let Some(view) = v8::Uint8Array::new(scope, buffer, 0, len) else {
            return write_done(scope, id, Err(JsStreamError::Rejected { method: Method::Put, errno: None }));
        };
        let view = v8::Global::new(scope, view);
        if let Some(entry) = scope.get_slot_mut::<HostState>().and_then(|host| host.js_streams.entries.get_mut(&id)) {
            entry.writing = Some((view, 0));
        }
        put_more(scope, id);
    }

    /// Puts what is left of the write of stream `id`; waits for `queued.drained()` when the stream took less.
    fn put_more(scope: &mut v8::PinScope<'_, '_>, id: u32) {
        let entry = scope.get_slot::<HostState>().and_then(|host| host.js_streams.entries.get(&id));
        let Some((object, Some((view, offset)))) = entry.map(|entry| (entry.object.clone(), entry.writing.clone())) else { return };
        let object = v8::Local::new(scope, object);
        let view = v8::Local::new(scope, view);
        let len = view.byte_length();
        let fail = |method| JsStreamError::Rejected { method, errno: None };
        let Some(queued) = property(scope, object, "queued") else { return write_done(scope, id, Err(fail(Method::Put))) };
        let Some(put) = function(scope, queued, "put") else { return write_done(scope, id, Err(fail(Method::Put))) };
        let Some(buffer) = view.buffer(scope) else { return write_done(scope, id, Err(fail(Method::Put))) };
        let Some(rest) = v8::Uint8Array::new(scope, buffer, offset, len - offset) else {
            return write_done(scope, id, Err(fail(Method::Put)));
        };
        let taken = match invoke(scope, queued, put, &[rest.into()]) {
            Ok(taken) => taken,
            Err(errno) => return write_done(scope, id, Err(JsStreamError::Rejected { method: Method::Put, errno })),
        };
        let taken = match taken.number_value(scope) {
            Some(n) if taken.is_number() && n.fract() == 0.0 && n >= 0.0 && n <= (len - offset) as f64 => n as usize,
            _ => return write_done(scope, id, Err(JsStreamError::BadValue { method: Method::Put })),
        };
        let offset = offset + taken;
        if offset == len {
            return write_done(scope, id, Ok(()));
        }
        if let Some(entry) = scope.get_slot_mut::<HostState>().and_then(|host| host.js_streams.entries.get_mut(&id))
            && let Some((_, at)) = entry.writing.as_mut()
        {
            *at = offset;
        }
        let Some(drained) = function(scope, queued, "drained") else { return write_done(scope, id, Err(fail(Method::Drained))) };
        let promise = invoke(scope, queued, drained, &[]).map_err(|errno| JsStreamError::Rejected { method: Method::Drained, errno });
        let promise = promise.and_then(|value| promise_of(scope, value).ok_or(fail(Method::Drained)));
        match promise {
            Ok(promise) => {
                if !then(scope, promise, id, drained_fulfilled, drained_rejected) {
                    write_done(scope, id, Err(fail(Method::Drained)));
                }
            }
            Err(error) => write_done(scope, id, Err(error)),
        }
    }

    fn drained_fulfilled<'s>(scope: &mut v8::PinScope<'s, '_>, args: v8::FunctionCallbackArguments<'s>, _: v8::ReturnValue<'s, v8::Value>) {
        if let Some(id) = id_of(scope, &args) {
            put_more(scope, id);
        }
    }

    fn drained_rejected<'s>(scope: &mut v8::PinScope<'s, '_>, args: v8::FunctionCallbackArguments<'s>, _: v8::ReturnValue<'s, v8::Value>) {
        let Some(id) = id_of(scope, &args) else { return };
        let errno = errno_of(scope, args.get(0));
        write_done(scope, id, Err(JsStreamError::Rejected { method: Method::Drained, errno }));
    }

    fn ignore(_: &mut v8::PinScope<'_, '_>, _: v8::FunctionCallbackArguments<'_>, _: v8::ReturnValue<'_, v8::Value>) {}

    /// `end('write')` or `close()` of stream `id`; what it answers (or throws) is ignored.
    fn call_simple(scope: &mut v8::PinScope<'_, '_, ()>, id: u32, name: &str, write_side: bool) {
        let Some((object, context)) = lookup(scope, id) else { return };
        let context = v8::Local::new(scope, context);
        let scope = &mut v8::ContextScope::new(scope, context);
        let object = v8::Local::new(scope, object);
        let Some(method) = function(scope, object, name) else { return };
        let args: Vec<v8::Local<v8::Value>> = match write_side {
            true => v8::String::new(scope, "write").map(Into::into).into_iter().collect(),
            false => Vec::new(),
        };
        if let Ok(value) = invoke(scope, object, method, &args)
            && let Ok(promise) = v8::Local::<v8::Promise>::try_from(value)
        {
            then(scope, promise, id, ignore, ignore);
        }
    }
}
