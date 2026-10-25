//! `native.io.*`: the I/O runtimes.

use origine_api_core::{Backend, NativeError};
use std::time::Duration;

use crate::HostState;
use crate::host::Pending;
use crate::native;
use crate::native::{ScopeKey, host_mut};

/// The option bag of `api.io.create(opts)`.
#[derive(crate::FromJs)]
pub struct IoCreateOpts {
    /// `'auto'` (default), `'uring'`, `'kqueue'` or `'threaded'`.
    backend: Option<Backend>,
    /// Queue depth / worker count hint.
    entries: Option<u32>,
}

/// The frozen handle `{ kind: 'io', id, backend }`.
#[derive(crate::IntoJs)]
pub struct IoHandle {
    kind: &'static str,
    id: u32,
    backend: &'static str,
}

/// `native.io.create(opts)`: creates a runtime (an `io::Loop` plus its task runtime) owned by the
/// calling scope. Throws `{errno,name}`: `AccessDenied` at the runtime ceiling, `Unsupported` for
/// a backend the embedder excluded or the platform lacks; `TypeError` for a bad option.
#[native(side_effect = "any", path = "io.create", needs = "runtime")]
fn io_create(host: &mut HostState, key: ScopeKey, opts: Option<IoCreateOpts>) -> Result<IoHandle, NativeError> {
    let (backend, entries) = opts.map_or((None, None), |opts| (opts.backend, opts.entries));
    let backend = backend.unwrap_or(Backend::Auto);
    let id = host.create_runtime(key, backend, entries)?;
    Ok(IoHandle { kind: "io", id, backend: backend.name() })
}

/// `native.io.close(id)`: Promise<void>. Cancels the runtime's operations (their promises reject
/// with `Canceled`), runs the loop until quiet, releases its grants and destroys it. Closing an
/// unknown, foreign or already closing runtime rejects with `BadHandle`.
#[native(side_effect = "any", path = "io.close", needs = "runtime")]
fn io_close<'s>(scope: &mut v8::PinScope<'s, '_>, key: ScopeKey, id: u32) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let resolver = v8::PromiseResolver::new(scope).ok_or_else(|| NativeError::error("cannot create a promise"))?;
    let promise = resolver.get_promise(scope);
    let resolver_global = v8::Global::new(scope, resolver);
    let current = scope.get_current_context();
    let context = v8::Global::new(scope, current);
    let closing = host_mut(scope).and_then(|host| host.begin_close(key, id, Pending::new(resolver_global, context, id, None)));
    match closing {
        Ok(canceled) => {
            for pending in canceled {
                native::finish::<()>(scope, pending, Err(NativeError::Errno(origine_api_core::errno::CANCELED)));
            }
        }
        Err(error) => {
            let value = native::error_value(scope, error);
            resolver.reject(scope, value);
        }
    }
    Ok(promise.into())
}

/// Creates a timer with a runtime-local token, returning its completion promise.
#[native(side_effect = "any", path = "io.sleep", needs = "runtime")]
fn io_sleep<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    key: ScopeKey,
    runtime: u32,
    token: u32,
    ms: f64,
) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    if !ms.is_finite() || !(0.0..=2_147_483_647.0).contains(&ms) {
        return Err(NativeError::type_error("milliseconds must be finite and between 0 and 2147483647"));
    }
    let resolver = v8::PromiseResolver::new(scope).ok_or_else(|| NativeError::error("cannot create a promise"))?;
    let promise = resolver.get_promise(scope);
    let resolver_global = v8::Global::new(scope, resolver);
    let current = scope.get_current_context();
    let context = v8::Global::new(scope, current);
    let pending = Pending::new(resolver_global, context, runtime, None);
    let started = host_mut(scope)?.start_timer(key, token, Duration::from_secs_f64(ms / 1000.0), pending);
    if let Err(error) = started {
        let value = native::error_value(scope, error);
        resolver.reject(scope, value);
    }
    Ok(promise.into())
}

/// Cancels a timer, rejecting its promise exactly once. False means it already settled.
#[native(side_effect = "any", path = "io.cancelTimer", needs = "runtime")]
fn io_cancel_timer(scope: &mut v8::PinScope<'_, '_>, key: ScopeKey, runtime: u32, token: u32) -> Result<bool, NativeError> {
    let pending = host_mut(scope)?.cancel_timer(key, runtime, token)?;
    let canceled = pending.is_some();
    if let Some(pending) = pending {
        native::finish::<()>(scope, pending, Err(NativeError::Errno(origine_api_core::errno::CANCELED)));
    }
    Ok(canceled)
}

/// Monotonic milliseconds since this host was created; never wall-clock time.
#[native(side_effect = "any", path = "io.now", needs = "runtime")]
fn io_now(host: &mut HostState, key: ScopeKey, runtime: u32) -> Result<f64, NativeError> {
    host.timer_now(key, runtime)
}
