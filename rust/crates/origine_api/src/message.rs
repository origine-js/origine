//! Structured-clone messages between isolates: a value serialized by V8's `ValueSerializer`, with
//! `SharedArrayBuffer`s carried by reference and explicitly listed `ArrayBuffer`s moved.
//!
//! A [`Message`] holds no V8 handle, only bytes and refcounted backing stores, so it is `Send` and
//! may be created on one isolate's thread and opened on another's. The channels (`channel.rs`)
//! carry them.

use std::cell::RefCell;
use std::rc::Rc;

use origine_api_core::{NativeError, errno};
use v8::{ValueDeserializerHelper, ValueSerializerHelper};

type Store = v8::SharedRef<v8::BackingStore>;

/// A serialized value. `shared` backs the `SharedArrayBuffer`s the value references (shared with the
/// sender, not copied); `moved` backs the `ArrayBuffer`s that were transferred (detached at the sender).
pub struct Message {
    data: Vec<u8>,
    shared: Vec<Store>,
    moved: Vec<Store>,
}

// SAFETY: a `Message` owns plain bytes and `std::shared_ptr<BackingStore>` handles. V8 backing
// stores are reference counted atomically and are designed to be shared between isolates on
// different threads; the allocator behind them is the process-wide thread-safe one.
unsafe impl Send for Message {}

impl Message {
    /// Bytes of the serialized form (without the backing stores), for limits and accounting.
    pub fn len(&self) -> usize {
        self.data.len()
    }

    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }
}

/// Collects the `SharedArrayBuffer`s a value references and the reason a value cannot be cloned.
struct Writer {
    shared: Rc<RefCell<Vec<Store>>>,
    refusal: Rc<RefCell<Option<String>>>,
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
}

/// Resolves the ids written by [`Writer`] back to `SharedArrayBuffer`s over the same stores.
struct Reader {
    shared: Vec<Store>,
}

impl v8::ValueDeserializerImpl for Reader {
    fn get_shared_array_buffer_from_id<'s>(&self, scope: &mut v8::PinScope<'s, '_>, id: u32) -> Option<v8::Local<'s, v8::SharedArrayBuffer>> {
        let store = self.shared.get(usize::try_from(id).ok()?)?;
        Some(v8::SharedArrayBuffer::with_backing_store(scope, store))
    }
}

/// Serializes `value`. Each buffer of `transfer` is moved: its store goes into the message and the
/// buffer is detached here once the whole value was written (a failure leaves every buffer intact).
/// Errors: `Unsupported` for a buffer that cannot be detached (shared, resizable, wasm memory), a
/// `TypeError` naming the reason for a value that cannot be cloned (a function, a symbol).
pub fn encode<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    value: v8::Local<'s, v8::Value>,
    transfer: &[v8::Local<'s, v8::ArrayBuffer>],
) -> Result<Message, NativeError> {
    let shared = Rc::new(RefCell::new(Vec::new()));
    let refusal = Rc::new(RefCell::new(None));
    let serializer = v8::ValueSerializer::new(scope, Box::new(Writer { shared: shared.clone(), refusal: refusal.clone() }));
    serializer.write_header();
    for (index, buffer) in transfer.iter().enumerate() {
        if !buffer.is_detachable() {
            return Err(NativeError::Errno(errno::UNSUPPORTED));
        }
        if transfer[..index].iter().any(|earlier| std::ptr::eq(&*earlier.get_backing_store(), &*buffer.get_backing_store())) {
            return Err(NativeError::type_error("the transfer list names a buffer twice"));
        }
        let id = u32::try_from(index).map_err(|_| NativeError::range_error("too many buffers to transfer"))?;
        serializer.transfer_array_buffer(id, *buffer);
    }
    let context = scope.get_current_context();
    if serializer.write_value(context, value) != Some(true) {
        let reason = refusal.borrow_mut().take();
        return Err(NativeError::type_error(reason.unwrap_or_else(|| "the value could not be cloned".to_string())));
    }
    let data = serializer.release();
    let moved: Vec<Store> = transfer.iter().map(|buffer| buffer.get_backing_store()).collect();
    for buffer in transfer {
        buffer.detach(None);
    }
    let shared = shared.take();
    Ok(Message { data, shared, moved })
}

/// Rebuilds the value of `message` in this isolate and context. The message is consumed: moved
/// buffers become `ArrayBuffer`s over the original stores, shared ones `SharedArrayBuffer`s over
/// the sender's. Errors: `InvalidInput` for bytes V8 cannot read.
pub fn decode<'s>(scope: &mut v8::PinScope<'s, '_>, message: Message) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let Message { data, shared, moved } = message;
    let deserializer = v8::ValueDeserializer::new(scope, Box::new(Reader { shared }), &data);
    let context = scope.get_current_context();
    let invalid = || NativeError::Errno(errno::INVALID_INPUT);
    if deserializer.read_header(context) != Some(true) {
        return Err(invalid());
    }
    for (index, store) in moved.iter().enumerate() {
        let buffer = v8::ArrayBuffer::with_backing_store(scope, store);
        deserializer.transfer_array_buffer(u32::try_from(index).map_err(|_| invalid())?, buffer);
    }
    deserializer.read_value(context).ok_or_else(invalid)
}
