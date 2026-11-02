//! Native values owned by the garbage collector: a Rust value wrapped in a JS object whose lifetime it follows.
//!
//! V8 gives every isolate a cppgc heap, so a value is allocated there (`make_garbage_collected`) and the JS
//! object that wraps it holds the only reference: when the object is collected the heap runs the Rust `Drop`.
//! Anything else that needs the value takes its own copy (`Clone`: the values are `Arc`-backed handles to
//! immutable data), so a collected `RootPki` never takes a live `TlsClient` down with it.
//!
//! A value's `Drop` runs inside a collection, at any allocation point, possibly while a native holds
//! `&mut HostState`: it must not touch the Host state, V8 or any scope table. Values are therefore plain
//! self-contained data. Wrapped objects must not be reachable when a snapshot is built (the snapshot has no
//! serializer for them); they are only made by natives at run time.

use std::any::TypeId;
use std::ffi::CStr;

use origine_api_core::{ArgError, NativeError};

use crate::native::host_mut;
use crate::{FromJs, IntoJs};

/// The tag every origine wrapper carries; the `TypeId` inside tells the types apart.
const TAG: u16 = 1;

#[repr(C)]
struct Cell<T> {
    kind: TypeId,
    value: T,
}

// SAFETY: a `Cell` holds no cppgc pointers (`Member` and the like), so there is nothing to trace.
unsafe impl<T: 'static> v8::cppgc::GarbageCollected for Cell<T> {
    fn trace(&self, _: &mut v8::cppgc::Visitor) {}

    fn get_name(&self) -> &'static CStr {
        c"origine native value"
    }
}

/// An object made from the wrapper template (created once per isolate, on first use).
fn blank<'s>(scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Object>, NativeError> {
    let unavailable = || NativeError::error("cannot create a native value wrapper");
    let existing = host_mut(scope)?.wrapper.clone();
    let template = match existing {
        Some(global) => v8::Local::new(scope, &global),
        None => {
            let template =
                v8::FunctionTemplate::new(scope, |_: &mut v8::PinScope, _: v8::FunctionCallbackArguments, _: v8::ReturnValue| {});
            let global = v8::Global::new(scope, template);
            host_mut(scope)?.wrapper = Some(global);
            template
        }
    };
    let function = template.get_function(scope).ok_or_else(unavailable)?;
    function.new_instance(scope, &[]).ok_or_else(unavailable)
}

/// Wraps `value` in a new JS object; the value is dropped when the object is collected.
pub(crate) fn wrap<'s, T: 'static>(scope: &mut v8::PinScope<'s, '_>, value: T) -> Result<v8::Local<'s, v8::Object>, NativeError> {
    let object = blank(scope)?;
    let isolate: &mut v8::Isolate = scope;
    let heap = isolate.get_cpp_heap().ok_or_else(|| NativeError::error("the isolate has no cppgc heap"))?;
    // SAFETY: the pointer goes straight into `wrap`, which stores it in the object's embedder fields.
    let member = unsafe { v8::cppgc::make_garbage_collected(heap, Cell { kind: TypeId::of::<T>(), value }) };
    // SAFETY: `TAG` is the only tag this crate wraps with; `object` was made from our template.
    unsafe { v8::Object::wrap::<TAG, Cell<T>>(isolate, object, &member) };
    Ok(object)
}

/// A copy of the `T` wrapped in `value`, or `None` for anything else (including a wrapper of another type).
pub(crate) fn unwrap<T: Clone + 'static>(isolate: &mut v8::Isolate, value: v8::Local<'_, v8::Value>) -> Option<T> {
    let object = v8::Local::<v8::Object>::try_from(value).ok()?;
    if !object.is_api_wrapper() {
        return None;
    }
    // SAFETY: every wrapper of this crate is a `Cell<_>` whose first field is the `TypeId`, which is checked
    // before the value is read as a `T`.
    let found = unsafe { v8::Object::unwrap::<TAG, Cell<T>>(isolate, object) }?;
    // SAFETY: as above; the reference does not outlive this call.
    let cell = unsafe { found.as_ref() };
    (cell.kind == TypeId::of::<T>()).then(|| cell.value.clone())
}

/// A native value as an argument or a result: wrapped in an object on its way out, copied out on its way in.
pub struct Gc<T>(pub T);

impl<'s, T: 'static> IntoJs<'s> for Gc<T> {
    fn into_js(self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        wrap(scope, self.0).map(Into::into)
    }
}

impl<'s, T: Clone + 'static> FromJs<'s> for Gc<T> {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        let isolate: &mut v8::Isolate = scope;
        unwrap::<T>(isolate, value).map(Gc).ok_or_else(|| ArgError::new(index, "a native value of the right kind"))
    }
}

/// An array of native values.
impl<'s, T: Clone + 'static> FromJs<'s> for Vec<Gc<T>> {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        let bad = || ArgError::new(index, "an array of native values of the right kind");
        let array = v8::Local::<v8::Array>::try_from(value).map_err(|_| bad())?;
        let mut out = Vec::new();
        for at in 0..array.length() {
            let item = array.get_index(scope, at).ok_or_else(bad)?;
            out.push(Gc::<T>::from_js(scope, item, index).map_err(|_| bad())?);
        }
        Ok(out)
    }
}
