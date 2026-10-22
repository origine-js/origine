//! Decoding JS arguments into Rust values (the counterpart of `decode` in `src/api/binding.zig`).

use std::ptr::NonNull;
use std::sync::atomic::{AtomicU8, Ordering};

use origine_api_core::Backend;
use origine_api_core::arg::{self, ArgError};

pub use origine_api_core::arg::MAX_SAFE_INTEGER;

/// A type a native can take as a parameter. `#[native]` calls [`FromJs::from_args`] with the
/// position of the next unread JS argument and then advances by [`FromJs::ARITY`].
pub trait FromJs<'s>: Sized {
    /// How many JS arguments this type consumes (default 1).
    const ARITY: usize = 1;

    /// Decodes one JS value; `index` is its 0-based argument position, used in error messages.
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError>;

    /// Decodes starting at argument `index`. Types with `ARITY > 1` override this to read more
    /// than one argument; the default reads one value (missing arguments are `undefined`).
    fn from_args(scope: &mut v8::PinScope<'s, '_>, args: &v8::FunctionCallbackArguments<'s>, index: usize) -> Result<Self, ArgError> {
        Self::from_js(scope, args.get(index as i32), index)
    }
}

/// [`FromJs::ARITY`] of the type of `_` (lets generated code ask without naming the type).
pub fn arity_of<'s, T: FromJs<'s>>(_: &T) -> usize {
    T::ARITY
}

fn number<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    value: v8::Local<'s, v8::Value>,
    index: usize,
    expected: &'static str,
) -> Result<f64, ArgError> {
    if !value.is_number() {
        return Err(ArgError::new(index, expected));
    }
    value.number_value(scope).ok_or_else(|| ArgError::new(index, expected))
}

impl<'s> FromJs<'s> for u32 {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        const EXPECTED: &str = "an integer in 0..=4294967295";
        arg::f64_to_u32(number(scope, value, index, EXPECTED)?).ok_or_else(|| ArgError::new(index, EXPECTED))
    }
}

impl<'s> FromJs<'s> for u64 {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        const EXPECTED: &str = "an integer in 0..=9007199254740991";
        arg::f64_to_u64(number(scope, value, index, EXPECTED)?).ok_or_else(|| ArgError::new(index, EXPECTED))
    }
}

impl<'s> FromJs<'s> for f64 {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        number(scope, value, index, "a number")
    }
}

impl<'s> FromJs<'s> for bool {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        if value.is_boolean() { Ok(value.boolean_value(scope)) } else { Err(ArgError::new(index, "a boolean")) }
    }
}

impl<'s> FromJs<'s> for String {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        let string = v8::Local::<v8::String>::try_from(value).map_err(|_| ArgError::new(index, "a string"))?;
        Ok(string.to_rust_string_lossy(scope))
    }
}

impl<'s> FromJs<'s> for Backend {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        const EXPECTED: &str = "one of \"auto\", \"uring\", \"kqueue\", \"threaded\"";
        let name = String::from_js(scope, value, index).map_err(|_| ArgError::new(index, EXPECTED))?;
        Backend::parse(&name).ok_or_else(|| ArgError::new(index, EXPECTED))
    }
}

macro_rules! local_arg {
    ($($ty:ident => $expected:literal),* $(,)?) => {$(
        impl<'s> FromJs<'s> for v8::Local<'s, v8::$ty> {
            fn from_js(_: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
                v8::Local::<v8::$ty>::try_from(value).map_err(|_| ArgError::new(index, $expected))
            }
        }
    )*};
}

local_arg! {
    Object => "an object",
    Function => "a function",
    ArrayBuffer => "an ArrayBuffer",
    Array => "an array",
}

impl<'s> FromJs<'s> for v8::Local<'s, v8::Value> {
    fn from_js(_: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, _: usize) -> Result<Self, ArgError> {
        Ok(value)
    }
}

impl<'s, T: FromJs<'s>> FromJs<'s> for Option<T> {
    const ARITY: usize = T::ARITY;

    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        if value.is_null_or_undefined() { Ok(None) } else { T::from_js(scope, value, index).map(Some) }
    }

    fn from_args(scope: &mut v8::PinScope<'s, '_>, args: &v8::FunctionCallbackArguments<'s>, index: usize) -> Result<Self, ArgError> {
        if args.get(index as i32).is_null_or_undefined() { Ok(None) } else { T::from_args(scope, args, index).map(Some) }
    }
}

/// An `ArrayBuffer`, typed array or `DataView` argument: gives access to the bytes it covers.
///
/// Holds a handle, so it lives no longer than the call; use [`ArrayBufferArg::backing_store`] to
/// keep the memory alive across an async operation.
#[derive(Clone, Copy)]
pub struct ArrayBufferArg<'s> {
    buffer: v8::Local<'s, v8::ArrayBufferBase>,
    offset: usize,
    len: usize,
}

impl<'s> FromJs<'s> for ArrayBufferArg<'s> {
    /// Borrows local handles during decoding and returns a view valid for this
    /// call's handle scope. Shared buffers use atomic byte copying; failure retains nothing.
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        const EXPECTED: &str = "an ArrayBuffer or typed array";
        if let Ok(buffer) = v8::Local::<v8::ArrayBufferBase>::try_from(value) {
            return Ok(ArrayBufferArg { buffer, offset: 0, len: buffer.byte_length() });
        }
        let view = v8::Local::<v8::ArrayBufferView>::try_from(value).map_err(|_| ArgError::new(index, EXPECTED))?;
        let buffer = view.buffer(scope).ok_or_else(|| ArgError::new(index, EXPECTED))?;
        Ok(ArrayBufferArg { buffer, offset: view.byte_offset(), len: view.byte_length() })
    }
}

impl<'s> ArrayBufferArg<'s> {
    /// Borrows a live buffer local and its valid byte window until the call's handle scope closes.
    pub(crate) fn from_parts(buffer: v8::Local<'s, v8::ArrayBufferBase>, offset: usize, len: usize) -> ArrayBufferArg<'s> {
        ArrayBufferArg { buffer, offset, len }
    }

    /// Returns an ordinary/shared buffer local borrowed until this handle scope closes.
    pub fn buffer(&self) -> v8::Local<'s, v8::ArrayBufferBase> {
        self.buffer
    }
}

impl ArrayBufferArg<'_> {
    /// Number of bytes covered (the view's length, or the whole buffer).
    pub fn len(&self) -> usize {
        self.len
    }

    /// True when no bytes are covered.
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// The start of the covered bytes, `None` when the buffer has no memory (empty or detached).
    fn start(&self) -> Option<NonNull<u8>> {
        if self.len == 0 {
            return None;
        }
        let base = self.buffer.data()?.cast::<u8>();
        // SAFETY: the view lies inside the buffer (V8 guarantees `offset + len <= byte_length`).
        Some(unsafe { base.add(self.offset) })
    }

    /// Borrows the live buffer during copying and returns a caller-owned Vec. Shared
    /// memory uses relaxed atomic bytes; the result need not be a coherent snapshot.
    pub fn to_vec(&self) -> Vec<u8> {
        if self.buffer.is_shared_array_buffer() {
            return match self.start() {
                Some(start) => (0..self.len)
                    .map(|index| {
                        // SAFETY: index is inside the live shared backing-store window.
                        let byte = unsafe { start.as_ptr().add(index) };
                        // SAFETY: every byte is aligned for AtomicU8; no non-atomic Rust alias is formed.
                        unsafe { AtomicU8::from_ptr(byte) }.load(Ordering::Relaxed)
                    })
                    .collect(),
                None => Vec::new(),
            };
        }
        match self.start() {
            // SAFETY: `start` points at `len` initialized bytes of a live backing store, and
            // nothing mutates it while this single-threaded call copies.
            Some(start) => unsafe { std::slice::from_raw_parts(start.as_ptr(), self.len) }.to_vec(),
            None => Vec::new(),
        }
    }

    /// Borrows src through return and copies into the live guest window, using atomic
    /// bytes for shared memory. Returns the copied count; retains no Rust storage.
    pub fn copy_from_slice(&self, src: &[u8]) -> usize {
        let count = src.len().min(self.len);
        if let (Some(start), true) = (self.start(), count > 0) {
            if self.buffer.is_shared_array_buffer() {
                for (index, value) in src[..count].iter().copied().enumerate() {
                    // SAFETY: index is inside the live shared backing-store window.
                    let byte = unsafe { start.as_ptr().add(index) };
                    // SAFETY: every byte is aligned for AtomicU8; no non-atomic Rust alias is formed.
                    unsafe { AtomicU8::from_ptr(byte) }.store(value, Ordering::Relaxed);
                }
                return count;
            }
            // SAFETY: `start` points at `len >= count` writable bytes of a live backing store, and
            // `src` is Rust memory, so the ranges cannot overlap.
            unsafe { std::ptr::copy_nonoverlapping(src.as_ptr(), start.as_ptr(), count) };
        }
        count
    }

    /// A reference-counted handle that keeps the memory alive after the call returns.
    pub fn backing_store(&self) -> v8::SharedRef<v8::BackingStore> {
        self.buffer.get_backing_store()
    }

    /// Byte offset of the covered range inside [`ArrayBufferArg::backing_store`].
    pub fn offset(&self) -> usize {
        self.offset
    }

    /// Borrows the local through return; reports whether the guest can transfer its
    /// memory. Shared buffers cannot transfer. Retains no resources.
    pub fn is_detachable(&self) -> bool {
        v8::Local::<v8::ArrayBuffer>::try_from(self.buffer).is_ok_and(|buffer| buffer.is_detachable())
    }

    /// Borrows the local through return and detaches an ordinary buffer when allowed.
    /// Returns false for shared/non-detachable buffers; retains no resources.
    pub fn detach(&self) -> bool {
        v8::Local::<v8::ArrayBuffer>::try_from(self.buffer)
            .is_ok_and(|buffer| buffer.is_detachable() && buffer.detach(None).unwrap_or(false))
    }
}

impl<'s> FromJs<'s> for Vec<u8> {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        ArrayBufferArg::from_js(scope, value, index).map(|buffer| buffer.to_vec())
    }
}

/// `value` as an object, for [`property`] reads (used by `#[derive(FromJs)]`).
pub fn object_arg<'s>(value: v8::Local<'s, v8::Value>, index: usize) -> Result<v8::Local<'s, v8::Object>, ArgError> {
    v8::Local::<v8::Object>::try_from(value).map_err(|_| ArgError::new(index, "an object"))
}

/// Reads and decodes the own data property `name` of `object` (a missing key, an accessor or an
/// inherited property reads as `undefined`, like `own()` in `src/js/glue/util.js`).
pub fn property<'s, T: FromJs<'s>>(
    scope: &mut v8::PinScope<'s, '_>,
    object: v8::Local<'s, v8::Object>,
    name: &str,
    index: usize,
) -> Result<T, ArgError> {
    let value = own_data_property(scope, object, name).ok_or_else(|| ArgError::new(index, format!("property `{name}` to be readable")))?;
    T::from_js(scope, value, index).map_err(|err| err.in_property(name))
}

/// The value of own data property `name`, `undefined` when absent; `None` if V8 threw.
fn own_data_property<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    object: v8::Local<'s, v8::Object>,
    name: &str,
) -> Option<v8::Local<'s, v8::Value>> {
    let key = v8::String::new(scope, name)?;
    let descriptor = object.get_own_property_descriptor(scope, key.into())?;
    let Ok(descriptor) = v8::Local::<v8::Object>::try_from(descriptor) else {
        return Some(v8::undefined(scope).into());
    };
    let value_key = v8::String::new(scope, "value")?;
    if descriptor.has_own_property(scope, value_key.into())? {
        descriptor.get(scope, value_key.into())
    } else {
        Some(v8::undefined(scope).into())
    }
}

/// A `(fs, id)` handle: two JS arguments. Directory id 0 is the grant root.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Handle {
    pub fs: u32,
    pub id: u32,
}

/// A directory handle.
pub type DirRef = Handle;
/// A file handle.
pub type FileRef = Handle;

impl<'s> FromJs<'s> for Handle {
    const ARITY: usize = 2;

    fn from_js(_: &mut v8::PinScope<'s, '_>, _: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        Err(ArgError::new(index, "a handle (two arguments)"))
    }

    fn from_args(scope: &mut v8::PinScope<'s, '_>, args: &v8::FunctionCallbackArguments<'s>, index: usize) -> Result<Self, ArgError> {
        let fs = u32::from_js(scope, args.get(index as i32), index)?;
        let id = u32::from_js(scope, args.get(index as i32 + 1), index + 1)?;
        Ok(Handle { fs, id })
    }
}

/// A byte limit (`std.Io.Limit`): a non-negative number or `Infinity`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limit(pub usize);

impl<'s> FromJs<'s> for Limit {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        const EXPECTED: &str = "a non-negative number or Infinity";
        arg::f64_to_limit(number(scope, value, index, EXPECTED)?).map(Limit).ok_or_else(|| ArgError::new(index, EXPECTED))
    }
}
