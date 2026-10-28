//! Structured-clone messages between isolates: a value serialized by V8's `ValueSerializer`, with
//! `SharedArrayBuffer`s carried by reference and everything in the transfer list moved: listed
//! `ArrayBuffer`s and listed ports (the ends of a channel, see `channel.rs`).
//!
//! A [`Message`] holds no V8 handle, only bytes, refcounted backing stores and port handles, so it
//! is `Send` and may be created on one isolate's thread and opened on another's.

use std::cell::RefCell;
use std::rc::Rc;

use origine_api_core::{NativeError, errno};
use v8::{ValueDeserializerHelper, ValueSerializerHelper};

use crate::channel;
use crate::host::HostState;

type Store = v8::SharedRef<v8::BackingStore>;

/// The private symbol that marks a JS object as a port: its value is `[tx, rx, mode]`, the two
/// channel handles it sends and receives on and its read mode (0 pull, 1 event).
const BRAND: &str = "origine.port";

/// One thing moved with a message, in transfer-list order.
pub enum Item {
    /// A moved `ArrayBuffer`.
    Buffer(Store),
    /// A moved port, now owned by nobody until a receiver takes it over.
    Port(Port),
}

/// The in-flight handles of a moved port. Dropped without being taken over (a message nobody
/// opens), they are closed so that the peer is not left waiting.
pub struct Port {
    tx: u32,
    rx: u32,
    mode: u32,
    live: bool,
}

impl Drop for Port {
    fn drop(&mut self) {
        if self.live {
            channel::close_handle(self.tx);
            channel::close_handle(self.rx);
        }
    }
}

/// A serialized value. `shared` backs the `SharedArrayBuffer`s the value references (shared with
/// the sender, not copied); `items` are the transferred buffers and ports.
pub struct Message {
    data: Vec<u8>,
    shared: Vec<Store>,
    items: Vec<Item>,
    /// The sending isolate's identity (`event.identity`).
    identity: u32,
}

// SAFETY: a `Message` owns plain bytes, `std::shared_ptr<BackingStore>` handles and integers. V8
// backing stores are reference counted atomically and are designed to be shared between isolates on
// different threads; the allocator behind them is the process-wide thread-safe one.
unsafe impl Send for Message {}

/// What `decode` rebuilds: the value, the transferred objects (in transfer-list order) and the sender.
pub struct Received<'s> {
    pub identity: u32,
    pub data: v8::Local<'s, v8::Value>,
    pub transfer: v8::Local<'s, v8::Array>,
}

fn brand_key<'s>(scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Private>, NativeError> {
    let name = v8::String::new(scope, BRAND).ok_or_else(|| NativeError::error("cannot create a symbol name"))?;
    Ok(v8::Private::for_api(scope, Some(name)))
}

/// `(tx, rx, mode)` of a port object, if `object` is one.
pub fn brand_of<'s>(scope: &mut v8::PinScope<'s, '_>, object: v8::Local<'s, v8::Object>) -> Option<(u32, u32, u32)> {
    let key = brand_key(scope).ok()?;
    let value = object.get_private(scope, key)?;
    let array = v8::Local::<v8::Array>::try_from(value).ok()?;
    let mut parts = [0u32; 3];
    for (index, part) in parts.iter_mut().enumerate() {
        let item = array.get_index(scope, u32::try_from(index).ok()?)?;
        *part = item.uint32_value(scope)?;
    }
    Some((parts[0], parts[1], parts[2]))
}

/// Marks `object` as a port over the handles `tx`/`rx` with read mode `mode`.
pub fn brand<'s>(scope: &mut v8::PinScope<'s, '_>, object: v8::Local<'s, v8::Object>, tx: u32, rx: u32, mode: u32) -> Result<(), NativeError> {
    let key = brand_key(scope)?;
    let elements = [v8::Number::new(scope, f64::from(tx)).into(), v8::Number::new(scope, f64::from(rx)).into(), v8::Number::new(scope, f64::from(mode)).into()];
    let array = v8::Array::new_with_elements(scope, &elements);
    object.set_private(scope, key, array.into());
    Ok(())
}

/// Collects the `SharedArrayBuffer`s a value references, the ports it writes and why it cannot be cloned.
struct Writer {
    shared: Rc<RefCell<Vec<Store>>>,
    refusal: Rc<RefCell<Option<String>>>,
    /// The listed ports: `(tx, rx)` by transfer-list index.
    ports: Vec<(usize, u32, u32)>,
}

impl v8::ValueSerializerImpl for Writer {
    fn throw_data_clone_error<'s>(&self, scope: &mut v8::PinScope<'s, '_>, message: v8::Local<'s, v8::String>) {
        *self.refusal.borrow_mut() = Some(message.to_rust_string_lossy(scope));
    }

    fn get_shared_array_buffer_id<'s>(&self, _: &mut v8::PinScope<'s, '_>, buffer: v8::Local<'s, v8::SharedArrayBuffer>) -> Option<u32> {
        let mut shared = self.shared.borrow_mut();
        shared.push(buffer.get_backing_store());
        u32::try_from(shared.len() - 1).ok()
    }

    fn has_custom_host_object(&self, _: &v8::Isolate) -> bool {
        true
    }

    fn is_host_object<'s>(&self, scope: &mut v8::PinScope<'s, '_>, object: v8::Local<'s, v8::Object>) -> Option<bool> {
        Some(brand_of(scope, object).is_some())
    }

    fn write_host_object<'s>(&self, scope: &mut v8::PinScope<'s, '_>, object: v8::Local<'s, v8::Object>, helper: &dyn v8::ValueSerializerHelper) -> Option<bool> {
        let Some((tx, rx, _)) = brand_of(scope, object) else { return Some(false) };
        match self.ports.iter().find(|(_, t, r)| *t == tx && *r == rx) {
            Some((index, _, _)) => {
                helper.write_uint32(u32::try_from(*index).ok()?);
                Some(true)
            }
            None => {
                // V8 needs a pending exception to stop; `encode` turns the refusal into the TypeError.
                let reason = "a port must be listed in the transfer list to be sent";
                *self.refusal.borrow_mut() = Some(reason.to_string());
                let message = v8::String::new(scope, reason)?;
                let error = v8::Exception::error(scope, message);
                scope.throw_exception(error);
                None
            }
        }
    }
}

/// Resolves the ids written by [`Writer`] back to objects: `SharedArrayBuffer`s over the sender's
/// stores and the ports built from the transfer list.
struct Reader {
    shared: Vec<Store>,
    ports: Vec<(usize, v8::Global<v8::Object>)>,
}

impl v8::ValueDeserializerImpl for Reader {
    fn get_shared_array_buffer_from_id<'s>(&self, scope: &mut v8::PinScope<'s, '_>, id: u32) -> Option<v8::Local<'s, v8::SharedArrayBuffer>> {
        let store = self.shared.get(usize::try_from(id).ok()?)?;
        Some(v8::SharedArrayBuffer::with_backing_store(scope, store))
    }

    fn read_host_object<'s>(&self, scope: &mut v8::PinScope<'s, '_>, helper: &dyn v8::ValueDeserializerHelper) -> Option<v8::Local<'s, v8::Object>> {
        let mut index = 0u32;
        if !helper.read_uint32(&mut index) {
            return None;
        }
        let (_, port) = self.ports.iter().find(|(at, _)| *at == index as usize)?;
        Some(v8::Local::new(scope, port))
    }
}

/// Serializes `value`, moving everything in `transfer`: an `ArrayBuffer` is detached here once the
/// whole value was written, a port stops working here (its peer then talks to the receiver). A
/// failure leaves everything intact. Errors: `Unsupported` for a buffer that cannot be detached
/// (shared, resizable, wasm memory), a `TypeError` for an item that is neither a buffer nor a port, a
/// port named twice, a port in `value` that is not listed, or a value that cannot be cloned (a
/// function, a symbol); `BadHandle` for a closed port.
pub fn encode<'s>(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, transfer: &[v8::Local<'s, v8::Value>]) -> Result<Message, NativeError> {
    let identity = scope.get_slot::<HostState>().map_or(0, |host| host.identity);
    let shared = Rc::new(RefCell::new(Vec::new()));
    let refusal = Rc::new(RefCell::new(None));
    let mut buffers = Vec::new();
    let mut ports = Vec::new();
    for (index, item) in transfer.iter().enumerate() {
        let object = v8::Local::<v8::Object>::try_from(*item).map_err(|_| NativeError::type_error("the transfer list holds only ArrayBuffers and ports"))?;
        if let Ok(buffer) = v8::Local::<v8::ArrayBuffer>::try_from(*item) {
            if !buffer.is_detachable() {
                return Err(NativeError::Errno(errno::UNSUPPORTED));
            }
            if buffers.iter().any(|(_, earlier): &(usize, v8::Local<v8::ArrayBuffer>)| std::ptr::eq(&*earlier.get_backing_store(), &*buffer.get_backing_store())) {
                return Err(NativeError::type_error("the transfer list names a buffer twice"));
            }
            buffers.push((index, buffer));
        } else if let Some((tx, rx, _)) = brand_of(scope, object) {
            if ports.iter().any(|(_, t, r)| *t == tx && *r == rx) {
                return Err(NativeError::type_error("the transfer list names a port twice"));
            }
            channel::check_port(tx, rx)?;
            ports.push((index, tx, rx));
        } else {
            return Err(NativeError::type_error("the transfer list holds only ArrayBuffers and ports"));
        }
    }
    let serializer = v8::ValueSerializer::new(scope, Box::new(Writer { shared: shared.clone(), refusal: refusal.clone(), ports: ports.clone() }));
    serializer.write_header();
    for (index, buffer) in &buffers {
        serializer.transfer_array_buffer(u32::try_from(*index).map_err(|_| NativeError::range_error("too many items to transfer"))?, *buffer);
    }
    let context = scope.get_current_context();
    if serializer.write_value(context, value) != Some(true) {
        let reason = refusal.borrow_mut().take();
        return Err(NativeError::type_error(reason.unwrap_or_else(|| "the value could not be cloned".to_string())));
    }
    let data = serializer.release();
    // The whole value was written: from here on the transfer cannot fail half way for lack of a clone.
    let mut items = Vec::with_capacity(transfer.len());
    for (index, item) in transfer.iter().enumerate() {
        if let Some((_, buffer)) = buffers.iter().find(|(at, _)| *at == index) {
            items.push(Item::Buffer(buffer.get_backing_store()));
        } else if let Some((_, tx, rx)) = ports.iter().find(|(at, _, _)| *at == index) {
            let mode = v8::Local::<v8::Object>::try_from(*item).ok().and_then(|object| brand_of(scope, object)).map_or(0, |(_, _, mode)| mode);
            let (new_tx, new_rx) = channel::move_out(*tx, *rx)?;
            items.push(Item::Port(Port { tx: new_tx, rx: new_rx, mode, live: true }));
        }
    }
    for (_, buffer) in &buffers {
        buffer.detach(None);
    }
    let shared = shared.take();
    Ok(Message { data, shared, items, identity })
}

/// Rebuilds the message in this isolate and context, consuming it: moved buffers become
/// `ArrayBuffer`s over the original stores, ports are taken over by this isolate and rebuilt with the
/// port factory the glue registered, shared buffers become `SharedArrayBuffer`s over the sender's.
/// Errors: `InvalidInput` for bytes V8 cannot read; `Unsupported` when no port factory was registered.
pub fn decode<'s>(scope: &mut v8::PinScope<'s, '_>, message: Message) -> Result<Received<'s>, NativeError> {
    let Message { data, shared, items, identity } = message;
    let invalid = || NativeError::Errno(errno::INVALID_INPUT);
    let (owner, factory) = match scope.get_slot::<HostState>() {
        Some(host) => (host.isolate, host.port_factory.clone()),
        None => (0, None),
    };
    let mut transfer = Vec::with_capacity(items.len());
    let mut ports = Vec::new();
    let mut buffers = Vec::new();
    for (index, item) in items.into_iter().enumerate() {
        match item {
            Item::Buffer(store) => {
                let buffer = v8::ArrayBuffer::with_backing_store(scope, &store);
                buffers.push((index, buffer));
                transfer.push(v8::Local::<v8::Value>::from(buffer));
            }
            Item::Port(mut port) => {
                let factory = factory.as_ref().ok_or(NativeError::Errno(errno::UNSUPPORTED))?;
                channel::adopt_id(port.tx, owner);
                channel::adopt_id(port.rx, owner);
                port.live = false;
                let function = v8::Local::new(scope, &**factory);
                let args = [
                    v8::Number::new(scope, f64::from(port.tx)).into(),
                    v8::Number::new(scope, f64::from(port.rx)).into(),
                    v8::Number::new(scope, f64::from(port.mode)).into(),
                ];
                let undefined: v8::Local<v8::Value> = v8::undefined(scope).into();
                let built = function.call(scope, undefined, &args).ok_or_else(|| NativeError::error("the port factory failed"))?;
                let object = v8::Local::<v8::Object>::try_from(built).map_err(|_| NativeError::error("the port factory must return an object"))?;
                ports.push((index, v8::Global::new(scope, object)));
                transfer.push(built);
            }
        }
    }
    let deserializer = v8::ValueDeserializer::new(scope, Box::new(Reader { shared, ports }), &data);
    let context = scope.get_current_context();
    if deserializer.read_header(context) != Some(true) {
        return Err(invalid());
    }
    for (index, buffer) in buffers {
        deserializer.transfer_array_buffer(u32::try_from(index).map_err(|_| invalid())?, buffer);
    }
    let value = deserializer.read_value(context).ok_or_else(invalid)?;
    let transfer = v8::Array::new_with_elements(scope, &transfer);
    Ok(Received { identity, data: value, transfer })
}
