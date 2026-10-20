//! `native.io.*`: the I/O runtimes.

use origine_api_core::{Backend, NativeError};

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
