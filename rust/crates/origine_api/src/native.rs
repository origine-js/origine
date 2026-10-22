//! Runtime support for `#[native]`: the callback wrapper, the promise form and error conversion.

use std::cell::RefCell;
use std::future::Future;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::pin::{Pin, pin};
use std::rc::Rc;
use std::task::{Context, Poll};

use origine_api_core::{NativeError, errno};

use crate::decode::ArrayBufferArg;
use crate::encode::IntoJs;
use crate::host::{HostState, Pending};

/// Mirrors `binding.SideEffect` and `enum origine_api_side_effect` (origine_api.h): what V8 may
/// assume about a call (`Receiver` = only changes `this`).
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SideEffect {
    None,
    Receiver,
    Any,
}

/// When a native is installed (`enum origine_api_needs`): `#[native(needs = "runtime" | "async_fs")]`.
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Needs {
    /// Always.
    None,
    /// Only when the embedder configured an io runtime.
    Runtime,
    /// Only when the embedder configured async fs.
    AsyncFs,
}

/// A native for the registry (`registry.rs`): the V8 callback, what V8 may assume about it, and
/// where the guest finds it. Produced by `#[native(path = ..)]`.
#[derive(Clone, Copy)]
pub struct RawNative {
    /// The V8 function callback.
    pub callback: unsafe extern "C" fn(*const v8::FunctionCallbackInfo),
    /// Declared per native; there is no default.
    pub side_effect: SideEffect,
    /// `namespace.name`: the native is `native.<namespace>.<name>` in the guest glue.
    pub path: &'static str,
    pub needs: Needs,
}

/// The JS value for `error`: a `TypeError`/`RangeError`/`Error`, or for [`NativeError::Errno`] the
/// frozen `{ errno, name }` that `glue/util.js` `failure(code)` builds.
pub fn error_value<'s>(scope: &mut v8::PinScope<'s, '_>, error: NativeError) -> v8::Local<'s, v8::Value> {
    let message = |scope: &mut v8::PinScope<'s, '_>, text: &str| v8::String::new(scope, text).unwrap_or_else(|| v8::String::empty(scope));
    match error {
        NativeError::Arg(err) => {
            let text = message(scope, &err.to_string());
            v8::Exception::type_error(scope, text)
        }
        NativeError::Type(text) => {
            let text = message(scope, &text);
            v8::Exception::type_error(scope, text)
        }
        NativeError::Range(text) => {
            let text = message(scope, &text);
            v8::Exception::range_error(scope, text)
        }
        NativeError::Error(text) => {
            let text = message(scope, &text);
            v8::Exception::error(scope, text)
        }
        NativeError::Errno(code) => {
            let value = errno_value(scope, code);
            value.unwrap_or_else(|_| v8::undefined(scope).into())
        }
    }
}

fn errno_value<'s>(scope: &mut v8::PinScope<'s, '_>, code: u32) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let object = crate::encode::new_object(scope);
    crate::encode::set(scope, object, "errno", code)?;
    crate::encode::set(scope, object, "name", errno::name_of(code))?;
    crate::encode::freeze(scope, object)
}

/// The Host state of the isolate, mutably. Natives that take `&mut HostState` get it from here;
/// they cannot also take a scope, because running JS could re-enter another native.
pub fn host_mut<'a>(scope: &'a mut v8::PinScope<'_, '_>) -> Result<&'a mut HostState, NativeError> {
    scope.get_slot_mut::<HostState>().ok_or_else(|| NativeError::error("the Rust API is not attached to this isolate"))
}

/// The Host state of the isolate, shared.
pub fn host_ref<'a>(scope: &'a mut v8::PinScope<'_, '_>) -> Result<&'a HostState, NativeError> {
    scope.get_slot::<HostState>().ok_or_else(|| NativeError::error("the Rust API is not attached to this isolate"))
}

/// Runs `body` as the native for `info`: sets its result as the return value or throws its error,
/// and turns a panic into a thrown JS `Error` (never an unwind into C++).
///
/// # Safety
///
/// `info` must be the pointer V8 passed to a function callback and stay valid for the call.
pub unsafe fn run_sync<F>(info: *const v8::FunctionCallbackInfo, body: F)
where
    F: for<'s, 'i> FnOnce(&mut v8::PinScope<'s, 'i>, &v8::FunctionCallbackArguments<'s>) -> Result<v8::Local<'s, v8::Value>, NativeError>,
{
    // SAFETY: V8 passes a valid callback info for the duration of the callback.
    let info = unsafe { &*info };
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: `info` is a function callback info as `CallbackScope::new` requires.
        let storage = unsafe { v8::CallbackScope::new(info) };
        let scope = pin!(storage);
        let mut scope = scope.init();
        let args = v8::FunctionCallbackArguments::from_function_callback_info(info);
        let mut rv = v8::ReturnValue::from_function_callback_info(info);
        match body(&mut scope, &args) {
            Ok(value) => rv.set(value),
            Err(error) => {
                let value = error_value(&mut scope, error);
                scope.throw_exception(value);
            }
        }
    }));
    if outcome.is_err() {
        // SAFETY: as above.
        let storage = unsafe { v8::CallbackScope::new(info) };
        let scope = pin!(storage);
        let scope = scope.init();
        if let Some(message) = v8::String::new(&scope, "internal error in a native function") {
            let error = v8::Exception::error(&scope, message);
            scope.throw_exception(error);
        }
    }
}

/// Which guest scope called a native: the address of the Zig `ScopeState` that is the callback's
/// External data (0 when there is none). Runtimes and grants belong to the scope that made them;
/// another scope presenting the same ids gets `BadHandle`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct ScopeKey(pub usize);

/// The [`ScopeKey`] of the call (for `#[native]`).
pub fn scope_key(args: &v8::FunctionCallbackArguments<'_>) -> ScopeKey {
    match v8::Local::<v8::External>::try_from(args.data()) {
        Ok(external) => ScopeKey(external.value() as usize),
        Err(_) => ScopeKey(0),
    }
}

/// Runs just before a promise is resolved with its value (not before a rejection); an error
/// rejects instead.
pub type Hook = Box<dyn for<'s, 'i> FnOnce(&mut v8::PinScope<'s, 'i>) -> Result<(), NativeError>>;

/// Runs after a successful result was encoded and before the promise resolves; its return value
/// replaces the encoded one. Used where the resolution needs the guest's own objects (for
/// example the `ArrayBuffer` a copy-out read filled), which the future cannot hold: tasks never
/// own V8 handles.
pub type Wrap =
    Box<dyn for<'s, 'i> FnOnce(&mut v8::PinScope<'s, 'i>, v8::Local<'s, v8::Value>) -> Result<v8::Local<'s, v8::Value>, NativeError>>;

/// An async native's work: `future` runs on runtime `runtime`; its result settles the promise.
pub struct Op<'s, F> {
    pub runtime: u32,
    pub future: F,
    /// A buffer the result bytes are copied into before the promise resolves.
    read_into: Option<(ArrayBufferArg<'s>, Rc<RefCell<Vec<u8>>>)>,
    /// Extra step before resolving.
    hook: Option<Hook>,
    /// Replaces the encoded result just before resolving.
    wrap: Option<Wrap>,
}

impl<'s, F> Op<'s, F> {
    pub fn new(runtime: u32, future: F) -> Op<'s, F> {
        Op { runtime, future, read_into: None, hook: None, wrap: None }
    }

    /// Runs `hook` before the promise resolves (see [`Hook`]).
    #[must_use]
    pub fn with_hook(mut self, hook: Hook) -> Op<'s, F> {
        self.hook = Some(hook);
        self
    }

    /// Maps the encoded result before the promise resolves (see [`Wrap`]).
    #[must_use]
    pub fn with_wrap(mut self, wrap: Wrap) -> Op<'s, F> {
        self.wrap = Some(wrap);
        self
    }
}

impl<'s> Op<'s, ()> {
    /// A read: `future` yields the bytes; when it succeeds they are copied into `buffer` (if it
    /// is still attached, else the promise rejects with `StaleHandle`) and the promise resolves
    /// with the count.
    pub fn reading<R: Future<Output = Result<Vec<u8>, NativeError>> + 'static>(
        runtime: u32,
        future: R,
        buffer: ArrayBufferArg<'s>,
    ) -> Op<'s, impl Future<Output = Result<usize, NativeError>> + 'static + use<R>> {
        let cell = Rc::new(RefCell::new(Vec::new()));
        let shared = Rc::clone(&cell);
        let future = async move {
            let data = future.await?;
            let count = data.len();
            *shared.borrow_mut() = data;
            Ok(count)
        };
        Op { runtime, future, read_into: Some((buffer, cell)), hook: None, wrap: None }
    }
}

/// What a `promise` native may return.
pub trait IntoOp<'s> {
    type Fut: Future + 'static;
    fn into_op(self) -> Result<Op<'s, Self::Fut>, NativeError>;
}

impl<'s, F: Future + 'static> IntoOp<'s> for Op<'s, F> {
    type Fut = F;
    fn into_op(self) -> Result<Op<'s, F>, NativeError> {
        Ok(self)
    }
}

impl<'s, F: Future + 'static, E: Into<NativeError>> IntoOp<'s> for Result<Op<'s, F>, E> {
    type Fut = F;
    fn into_op(self) -> Result<Op<'s, F>, NativeError> {
        self.map_err(Into::into)
    }
}

/// How a task ended.
pub enum Outcome<T> {
    Done(T),
    Panicked,
}

/// Polls a future, containing its panics.
struct Guarded<F>(Pin<Box<F>>);

impl<F: Future> Future for Guarded<F> {
    type Output = Outcome<F::Output>;

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        match catch_unwind(AssertUnwindSafe(|| self.0.as_mut().poll(cx))) {
            Ok(Poll::Ready(value)) => Poll::Ready(Outcome::Done(value)),
            Ok(Poll::Pending) => Poll::Pending,
            Err(_) => Poll::Ready(Outcome::Panicked),
        }
    }
}

/// The promise form of a native: `make` decodes the arguments and calls the Rust fn, giving the
/// [`Op`]. The future is spawned on the op's runtime; when it completes, its result is queued
/// and settled on the isolate thread by [`crate::host::poll`]. An argument error (or any `make`
/// failure, or an unknown/closed runtime) returns an already-rejected promise; no errno cell is
/// involved.
pub fn promise<'s, 'i, F, T, E>(
    scope: &mut v8::PinScope<'s, 'i>,
    make: impl FnOnce(&mut v8::PinScope<'s, 'i>) -> Result<Op<'s, F>, NativeError>,
) -> Result<v8::Local<'s, v8::Value>, NativeError>
where
    F: Future<Output = Result<T, E>> + 'static,
    T: for<'a> IntoJs<'a> + 'static,
    E: Into<NativeError> + 'static,
{
    let resolver = v8::PromiseResolver::new(scope).ok_or_else(|| NativeError::error("cannot create a promise"))?;
    let promise = resolver.get_promise(scope);
    let started = make(scope).and_then(|op| {
        let resolver = v8::Global::new(scope, resolver);
        let current = scope.get_current_context();
        let context = v8::Global::new(scope, current);
        let mut hook = op.hook;
        if let Some((buffer, cell)) = op.read_into {
            let target = v8::Global::new(scope, buffer.buffer());
            let (offset, len) = (buffer.offset(), buffer.len());
            hook = Some(Box::new(move |scope| {
                let buffer = v8::Local::new(scope, &target);
                copy_into(buffer, offset, len, &cell.borrow())
            }));
        }
        let pending = Pending::new(resolver, context, op.runtime, hook).with_wrap(op.wrap);
        let host = host_mut(scope)?;
        let completions = host.completions();
        host.start(pending, move |id| {
            Box::pin(async move {
                let outcome = Guarded(Box::pin(op.future)).await;
                let completion: crate::host::Completion = Box::new(move |scope| settle(scope, id, outcome));
                completions.borrow_mut().push(completion);
            })
        })
    });
    if let Err(error) = started {
        let value = error_value(scope, error);
        resolver.reject(scope, value);
    }
    Ok(promise.into())
}

/// Borrows data through return and copies it into the live guest window, using atomic
/// stores for shared memory. Retains no Rust storage; rejects detached or undersized buffers.
pub(crate) fn copy_into(buffer: v8::Local<'_, v8::ArrayBufferBase>, offset: usize, len: usize, data: &[u8]) -> Result<(), NativeError> {
    let stale = || NativeError::Errno(errno::STALE_HANDLE);
    if v8::Local::<v8::ArrayBuffer>::try_from(buffer).is_ok_and(|buffer| buffer.was_detached())
        || offset.checked_add(len).is_none_or(|end| end > buffer.byte_length())
    {
        return Err(stale());
    }
    if data.len() > len {
        return Err(stale());
    }
    ArrayBufferArg::from_parts(buffer, offset, len).copy_from_slice(data);
    Ok(())
}

/// Settles the promise of op `id` (if it is still pending) with a finished task's result.
fn settle<T, E>(scope: &mut v8::PinScope<'_, '_, ()>, id: u64, outcome: Outcome<Result<T, E>>)
where
    T: for<'a> IntoJs<'a>,
    E: Into<NativeError>,
{
    let Some(pending) = scope.get_slot_mut::<HostState>().and_then(|host| host.take_pending(id)) else {
        return; // the runtime was closed meanwhile; its promises were rejected then
    };
    let result = match outcome {
        Outcome::Done(result) => result.map_err(Into::into),
        Outcome::Panicked => Err(NativeError::Errno(errno::UNEXPECTED)),
    };
    finish(scope, pending, result);
}

/// Resolves (or, for an error, rejects) `pending` inside its context.
pub fn finish<T: for<'a> IntoJs<'a>>(scope: &mut v8::PinScope<'_, '_, ()>, pending: Pending, result: Result<T, NativeError>) {
    let (resolver, context, hook, wrap) = pending.into_parts();
    let context = v8::Local::new(scope, &context);
    let scope = &mut v8::ContextScope::new(scope, context);
    let resolver = v8::Local::new(scope, &resolver);
    let value = result.and_then(|value| {
        if let Some(hook) = hook {
            hook(scope)?;
        }
        let value = value.into_js(scope)?;
        match wrap {
            Some(wrap) => wrap(scope, value),
            None => Ok(value),
        }
    });
    match value {
        Ok(value) => resolver.resolve(scope, value),
        Err(error) => {
            let value = error_value(scope, error);
            resolver.reject(scope, value)
        }
    };
}
