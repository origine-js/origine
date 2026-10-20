//! Encoding Rust values as JS results (the counterpart of `encode` in `src/api/binding.zig`).

use origine_api_core::NativeError;
use origine_api_core::arg;

/// A type a native can return. Encodes to a JS value, or fails with the error to throw/reject.
pub trait IntoJs<'s> {
    /// Builds the JS value.
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError>;
}

impl<'s> IntoJs<'s> for () {
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        Ok(v8::undefined(scope).into())
    }
}

impl<'s> IntoJs<'s> for bool {
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        Ok(v8::Boolean::new(scope, self).into())
    }
}

impl<'s> IntoJs<'s> for u32 {
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        Ok(v8::Integer::new_from_unsigned(scope, self).into())
    }
}

impl<'s> IntoJs<'s> for i32 {
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        Ok(v8::Integer::new(scope, self).into())
    }
}

impl<'s> IntoJs<'s> for f64 {
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        Ok(v8::Number::new(scope, self).into())
    }
}

impl<'s> IntoJs<'s> for u64 {
    /// Fails with a `RangeError` above 2^53 - 1, which a JS number cannot hold exactly.
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        let number = arg::u64_to_f64(self).ok_or_else(|| NativeError::range_error("result exceeds the largest safe integer"))?;
        number.into_js(scope)
    }
}

impl<'s> IntoJs<'s> for usize {
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        (self as u64).into_js(scope)
    }
}

impl<'s> IntoJs<'s> for &str {
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        v8::String::new(scope, self).map(Into::into).ok_or_else(|| NativeError::range_error("string too long"))
    }
}

impl<'s> IntoJs<'s> for String {
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        self.as_str().into_js(scope)
    }
}

impl<'s> IntoJs<'s> for Vec<u8> {
    /// A `Uint8Array` over a copy in a V8-allocated `ArrayBuffer` (sandbox rule: no external memory).
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        let buffer = v8::ArrayBuffer::new(scope, self.len());
        if let Some(data) = buffer.data().filter(|_| !self.is_empty()) {
            // SAFETY: `data` is the fresh buffer's `self.len()` writable bytes; `self` is Rust
            // memory, so the ranges cannot overlap.
            unsafe { std::ptr::copy_nonoverlapping(self.as_ptr(), data.as_ptr().cast::<u8>(), self.len()) };
        }
        v8::Uint8Array::new(scope, buffer, 0, self.len()).map(Into::into).ok_or_else(|| NativeError::range_error("buffer too large"))
    }
}

impl<'s, T> IntoJs<'s> for v8::Local<'s, T>
where
    v8::Local<'s, T>: Into<v8::Local<'s, v8::Value>>,
{
    fn into_js(self, _: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        Ok(self.into())
    }
}

impl<'s, T: IntoJs<'s>> IntoJs<'s> for Option<T> {
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        match self {
            Some(value) => value.into_js(scope),
            None => ().into_js(scope),
        }
    }
}

impl<'s, T: IntoJs<'s>, E: Into<NativeError>> IntoJs<'s> for Result<T, E> {
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        self.map_err(Into::into).and_then(|value| value.into_js(scope))
    }
}

/// A new empty plain object (for `#[derive(IntoJs)]`).
pub fn new_object<'s>(scope: &mut v8::PinScope<'s, '_>) -> v8::Local<'s, v8::Object> {
    v8::Object::new(scope)
}

/// Defines the data property `name` on `object` (for `#[derive(IntoJs)]`).
pub fn set<'s, T: IntoJs<'s>>(
    scope: &mut v8::PinScope<'s, '_>,
    object: v8::Local<'s, v8::Object>,
    name: &str,
    value: T,
) -> Result<(), NativeError> {
    let value = value.into_js(scope)?;
    let key = v8::String::new(scope, name).ok_or_else(|| NativeError::range_error("property name too long"))?;
    object.create_data_property(scope, key.into(), value);
    Ok(())
}

/// Freezes `object` and returns it as a value (for `#[derive(IntoJs)]`).
pub fn freeze<'s>(scope: &mut v8::PinScope<'s, '_>, object: v8::Local<'s, v8::Object>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    object.set_integrity_level(scope, v8::IntegrityLevel::Frozen);
    Ok(object.into())
}

impl<'s> IntoJs<'s> for origine_api_fs::Stat {
    /// `[kind, size]`.
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        let kind = self.kind.into_js(scope)?;
        let size = self.size.into_js(scope)?;
        Ok(v8::Array::new_with_elements(scope, &[kind, size]).into())
    }
}

impl<'s> IntoJs<'s> for origine_api_fs::DirListing {
    /// Flat `[name0, kind0, name1, kind1, ...]`.
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        let mut elements = Vec::with_capacity(self.0.len() * 2);
        for (name, kind) in self.0 {
            elements.push(name.into_js(scope)?);
            elements.push(kind.into_js(scope)?);
        }
        Ok(v8::Array::new_with_elements(scope, &elements).into())
    }
}
