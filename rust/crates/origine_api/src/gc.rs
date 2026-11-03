//! Native values owned by the garbage collector: a Rust value wrapped in a JS object whose lifetime it follows.
//!
//! V8 gives every isolate a cppgc heap, so a value is allocated there (`make_garbage_collected`) and the JS
//! object that wraps it holds the only reference: when the object is collected the heap runs the Rust `Drop`.
//! Anything else that needs the value takes its own copy (`Clone`: the values are `Arc`-backed handles to
//! immutable data), so a collected `RootPki` never takes a live `TlsClient` down with it.
//!
//! The objects are instances of Rust-defined classes (`class.rs`, `#[class]`): an object is made from its
//! class's own template, so it has the class's prototype, and [`attach`] gives it its value.
//!
//! A value's `Drop` runs inside a collection, at any allocation point, possibly while a native holds
//! `&mut HostState`: it must not touch the Host state, V8 or any scope table. Values are therefore plain
//! self-contained data. Wrapped objects must not be reachable when a snapshot is built (the snapshot has no
//! serializer for them); they are only made by natives at run time, and the templates are made on first use.

use std::any::TypeId;
use std::ffi::CStr;

use crate::class::ClassError;

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

/// Moves `value` into the cppgc heap and makes `object` (an instance of an API template) its owner.
pub(crate) fn attach<T: 'static>(isolate: &mut v8::Isolate, object: v8::Local<'_, v8::Object>, value: T) -> Result<(), ClassError> {
    let heap = isolate.get_cpp_heap().ok_or(ClassError::NoHeap)?;
    // SAFETY: the pointer goes straight into `wrap`, which stores it in the object's embedder fields.
    let member = unsafe { v8::cppgc::make_garbage_collected(heap, Cell { kind: TypeId::of::<T>(), value }) };
    // SAFETY: `TAG` is the only tag this crate wraps with; `object` was made from one of our templates.
    unsafe { v8::Object::wrap::<TAG, Cell<T>>(isolate, object, &member) };
    Ok(())
}

/// The `T` wrapped in `value`, borrowed for as long as the handle lives, or `None` for anything else
/// (including a wrapper of another type).
///
/// The borrow is sound because the object `value` points to keeps the cppgc value alive while the handle
/// exists (the handle is a root), cppgc never moves objects, and an object is wrapped exactly once, when it
/// is made. Never keep the reference past the call: an `async` native clones what it needs first.
pub(crate) fn unwrap_ref<'s, T: 'static>(isolate: &mut v8::Isolate, value: v8::Local<'s, v8::Value>) -> Option<&'s T> {
    let object = v8::Local::<v8::Object>::try_from(value).ok()?;
    if !object.is_api_wrapper() {
        return None;
    }
    // SAFETY: every wrapper of this crate is a `Cell<_>` whose first field is the `TypeId`, which is checked
    // before the value is read as a `T`.
    let found = unsafe { v8::Object::unwrap::<TAG, Cell<T>>(isolate, object) }?;
    // SAFETY: as above.
    let pointer = std::ptr::from_ref(unsafe { found.as_ref() });
    // SAFETY: the object, and with it the cell, stays alive and in place for `'s` (see the doc comment).
    let cell: &'s Cell<T> = unsafe { &*pointer };
    (cell.kind == TypeId::of::<T>()).then_some(&cell.value)
}
