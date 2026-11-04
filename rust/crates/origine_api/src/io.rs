//! `api.io`: the I/O runtime as a Rust-defined class.
//!
//! `native.io.create(opts)` makes a runtime (an `io::Loop` plus its task runtime, in the Host) and returns
//! an `Io` instance owning an [`IoCore`] in the cppgc heap. The instance carries its tables as frozen data
//! properties, each an instance of its own class over the same core: `io.timer` ([`IoTimer`]), `io.tcp`
//! ([`IoTcp`]) and `io.udp` ([`IoUdp`]). `io` itself has the loop-wide operations: `run()`, `close()`, `backend`
//! and `closed`. No id reaches the guest: the runtime's number stays inside the core (the glue reads it with
//! `native.io.runtime(io)` for `api.fs.requestAsync`).
//!
//! `close()` cancels the runtime's operations (their promises reject `Canceled`), closes every descriptor made on
//! it, runs the loop until quiet, releases its grants and destroys it. The objects stay allocated until they are
//! collected and answer `BadHandle` (or `closed === true`) from then on.

use std::cell::{Cell, RefCell};
use std::future::Future;
use std::rc::{Rc, Weak};
use std::time::Duration;

use origine_api_core::{BackendChoice, NativeError, errno};
use origine_io::Loop;

use crate::conn::{Conn, Kind};
use crate::host::Pending;
use crate::native::{Op, ScopeKey, host_mut, host_ref};
use crate::net::{SockAddr, Socket, Use, allowed, bind_datagram, connect_stream};
use crate::stream::{TcpListenerUnshaped, TcpStreamUnshaped};
use crate::sub::{Events, Idle};
use crate::udp::UdpSocketUnshaped;
use crate::{HostState, class, native};

/// The shared state of one runtime as its objects see it.
pub(crate) struct IoCore {
    pub(crate) owner: ScopeKey,
    pub(crate) runtime: u32,
    backend: &'static str,
    /// Weak: an object owned by the garbage collector must never keep an event loop alive.
    lp: Weak<Loop>,
    next_timer: Cell<u32>,
    /// The conns made on this runtime, closed with it.
    pub(crate) conns: Rc<RefCell<Vec<Weak<Conn>>>>,
    pub(crate) events: Events,
    pub(crate) refill: Rc<RefCell<Vec<u32>>>,
    pub(crate) idle: Rc<Idle>,
}

impl IoCore {
    /// Whether the runtime is open (not closing or closed).
    pub(crate) fn open(&self, host: &HostState) -> bool {
        host.loop_of(self.owner, self.runtime).is_ok()
    }

    /// The loop of the open runtime; `BadHandle` once it is closing.
    pub(crate) fn lp(&self, host: &HostState) -> Result<Rc<Loop>, NativeError> {
        host.loop_of(self.owner, self.runtime)
    }

    /// The loop, from a task of this runtime (which only runs while the runtime does).
    pub(crate) fn lp_weak(&self) -> Option<Rc<Loop>> {
        self.lp.upgrade()
    }

    /// Registers `conn` to be closed with the runtime.
    pub(crate) fn adopt(&self, conn: &Rc<Conn>) {
        let mut conns = self.conns.borrow_mut();
        if conns.len() >= 64 && conns.len().is_power_of_two() {
            conns.retain(|conn| conn.strong_count() > 0);
        }
        conns.push(Rc::downgrade(conn));
    }
}

/// The option bag of `api.io.create(opts)`.
#[derive(crate::FromJs)]
pub struct IoCreateOpts {
    /// `'auto'` (default), `'uring'`, `'kqueue'` or `'threaded'`.
    backend: Option<BackendChoice>,
    /// Queue depth / worker count hint.
    entries: Option<u32>,
}

/// Wraps a value of a class and defines it as the frozen data property `name` of `object`.
fn table<'s, T: class::Class>(
    scope: &mut v8::PinScope<'s, '_>,
    object: v8::Local<'s, v8::Object>,
    name: &str,
    value: T,
) -> Result<(), NativeError> {
    let value = class::wrap(scope, value)?;
    crate::encode::set(scope, object, name, value)
}

/// `native.io.create(opts)`: creates a runtime owned by the calling scope and returns its `Io`. Throws an
/// OrigineError subclass: `PermissionDenied` at the runtime ceiling, `Unsupported` for a backend the embedder excluded
/// or the platform lacks; `TypeError` for a bad option.
#[native(side_effect = "any", path = "io.create", needs = "runtime")]
fn io_create<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    key: ScopeKey,
    opts: Option<IoCreateOpts>,
) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    let (backend, entries) = opts.map_or((None, None), |opts| (opts.backend, opts.entries));
    let backend = backend.unwrap_or_default();
    let host = host_mut(scope)?;
    let (runtime, running) = host.create_runtime(key, backend, entries)?;
    let lp = host.loop_of(key, runtime)?;
    let core = Rc::new(IoCore {
        owner: key,
        runtime,
        backend: running.name(),
        lp: Rc::downgrade(&lp),
        next_timer: Cell::new(0),
        conns: host.conns_of(runtime),
        events: Rc::clone(&host.events),
        refill: Rc::clone(&host.refill),
        idle: host.idle_of(runtime),
    });
    let io = class::wrap(scope, Io(Rc::clone(&core)))?;
    let object = v8::Local::<v8::Object>::try_from(io).map_err(|_| NativeError::Errno(errno::UNEXPECTED))?;
    table(scope, object, "timer", IoTimer(Rc::clone(&core)))?;
    table(scope, object, "tcp", IoTcp(Rc::clone(&core)))?;
    table(scope, object, "udp", IoUdp(core))?;
    crate::encode::freeze(scope, object)
}

/// `native.io.runtime(io)`: the number of the runtime of `io`, for the glue of `api.fs.requestAsync` (whose natives
/// take it). `BadHandle` once the runtime is closing.
#[native(side_effect = "none", path = "io.runtime", needs = "runtime")]
fn io_runtime(host: &HostState, io: &Io) -> Result<u32, NativeError> {
    io.0.lp(host)?;
    Ok(io.0.runtime)
}

/// The key of the realm's closing hook (`native.io.link`), a private of the global.
const CLOSING: &str = "origine:io.closing";

/// `native.io.link(closing)`: `closing(runtime)` is called when a runtime of this realm starts closing (the glue
/// tells the async fs, whose grants on it stop being an authority). Called once per realm.
#[native(side_effect = "any", path = "io.link", needs = "runtime")]
fn io_link<'s>(scope: &mut v8::PinScope<'s, '_>, closing: v8::Local<'s, v8::Function>) -> Result<(), NativeError> {
    let name = v8::String::new(scope, CLOSING).ok_or(NativeError::Errno(errno::UNEXPECTED))?;
    let key = v8::Private::for_api(scope, Some(name));
    let global = scope.get_current_context().global(scope);
    global.set_private(scope, key, closing.into());
    Ok(())
}

/// Calls the realm's closing hook, if the glue linked one; what it throws is dropped.
fn closing_hook(scope: &mut v8::PinScope<'_, '_>, runtime: u32) {
    let Some(name) = v8::String::new(scope, CLOSING) else { return };
    let key = v8::Private::for_api(scope, Some(name));
    let global = scope.get_current_context().global(scope);
    let Some(function) = global.get_private(scope, key).and_then(|f| v8::Local::<v8::Function>::try_from(f).ok()) else { return };
    let id = v8::Integer::new_from_unsigned(scope, runtime).into();
    let undefined = v8::undefined(scope).into();
    v8::tc_scope!(let tc, scope);
    let _ = function.call(tc, undefined, &[id]);
}

/// An I/O runtime (`api.io.create`).
pub(crate) struct Io(pub(crate) Rc<IoCore>);

#[class(path = "io.Io", side_effect = "any", needs = "runtime")]
impl Io {
    /// The backend that runs: what `'auto'` resolved to, never `'auto'`.
    #[getter]
    fn backend(&self) -> &'static str {
        self.0.backend
    }

    /// `close()` was called.
    #[getter]
    fn closed(&self, host: &HostState) -> bool {
        !self.0.open(host)
    }

    /// Resolves once every flowing object of this runtime has closed (immediately when there is none); keeps the
    /// program alive while pending. `BadHandle` once the runtime is closing.
    #[method(promise)]
    fn run(&self, host: &mut HostState) -> Result<Op<'static, impl Future<Output = Result<(), NativeError>> + use<>>, NativeError> {
        self.0.lp(host)?;
        Ok(Op::new(self.0.runtime, Rc::clone(&self.0.idle).run()))
    }

    /// Closes the runtime (see the module docs). Every call returns the same promise.
    fn close<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        let runtime = self.0.runtime;
        if let Some(promise) = host_ref(scope)?.closings.get(&runtime).cloned() {
            return Ok(v8::Local::new(scope, promise).into());
        }
        let resolver = v8::PromiseResolver::new(scope).ok_or(NativeError::Errno(errno::UNEXPECTED))?;
        let promise = resolver.get_promise(scope);
        let resolver_global = v8::Global::new(scope, resolver);
        let current = scope.get_current_context();
        let context = v8::Global::new(scope, current);
        let promise_global = v8::Global::new(scope, promise);
        let host = host_mut(scope)?;
        let closing = host.begin_close(self.0.owner, runtime, Pending::new(resolver_global, context, runtime, None));
        match closing {
            Ok(canceled) => {
                host.closings.insert(runtime, promise_global);
                for pending in canceled {
                    native::finish::<()>(scope, pending, Err(NativeError::Errno(errno::CANCELED)));
                }
                closing_hook(scope, runtime);
            }
            Err(error) => {
                let value = class::guest_error(scope, error);
                resolver.reject(scope, value);
            }
        }
        Ok(promise.into())
    }
}

fn duration(ms: f64) -> Result<Duration, NativeError> {
    if !ms.is_finite() || !(0.0..=2_147_483_647.0).contains(&ms) {
        return Err(NativeError::type_error("milliseconds must be finite and between 0 and 2147483647"));
    }
    Ok(Duration::from_secs_f64(ms / 1000.0))
}

/// `io.timer`: sleeps and cancellable timers on the runtime's monotonic clock.
pub(crate) struct IoTimer(Rc<IoCore>);

impl IoTimer {
    /// Starts a timer of `ms` milliseconds: its token and its promise.
    fn start<'s>(&self, scope: &mut v8::PinScope<'s, '_>, ms: f64) -> Result<(u32, v8::Local<'s, v8::Promise>), NativeError> {
        let duration = duration(ms)?;
        let core = &self.0;
        core.lp(host_ref(scope)?)?;
        let token = core.next_timer.get();
        core.next_timer.set(token.checked_add(1).ok_or(NativeError::Errno(errno::UNSUPPORTED))?);
        let resolver = v8::PromiseResolver::new(scope).ok_or(NativeError::Errno(errno::UNEXPECTED))?;
        let promise = resolver.get_promise(scope);
        let resolver_global = v8::Global::new(scope, resolver);
        let current = scope.get_current_context();
        let context = v8::Global::new(scope, current);
        let pending = Pending::new(resolver_global, context, core.runtime, None);
        host_mut(scope)?.start_timer(core.owner, token, duration, pending)?;
        Ok((token, promise))
    }

    /// Milliseconds until `deadline` (a value of `now()`), 0 when it passed.
    fn until(&self, host: &HostState, deadline: f64) -> Result<f64, NativeError> {
        if !deadline.is_finite() || deadline < 0.0 {
            return Err(NativeError::type_error("deadline must be a finite non-negative monotonic time"));
        }
        Ok((deadline - host.timer_now(self.0.owner, self.0.runtime)?).clamp(0.0, 2_147_483_647.0))
    }

    fn timer_object<'s>(&self, scope: &mut v8::PinScope<'s, '_>, ms: f64) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        let (token, promise) = self.start(scope, ms)?;
        let timer = class::wrap(scope, Timer { io: Rc::clone(&self.0), token })?;
        let object = v8::Local::<v8::Object>::try_from(timer).map_err(|_| NativeError::Errno(errno::UNEXPECTED))?;
        crate::encode::set(scope, object, "promise", promise)?;
        crate::encode::freeze(scope, object)
    }
}

#[class(path = "io.IoTimer", side_effect = "any", needs = "runtime")]
impl IoTimer {
    /// Monotonic milliseconds since the host was created; not a wall clock.
    fn now(&self, host: &HostState) -> Result<f64, NativeError> {
        host.timer_now(self.0.owner, self.0.runtime)
    }

    /// Resolves after `ms` milliseconds; rejects `Canceled` when the runtime closes first.
    fn sleep<'s>(&self, scope: &mut v8::PinScope<'s, '_>, ms: f64) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        Ok(self.start(scope, ms)?.1.into())
    }

    /// Resolves at `deadline`, a value of `now()`.
    #[method(name = "sleepUntil")]
    fn sleep_until<'s>(&self, scope: &mut v8::PinScope<'s, '_>, deadline: f64) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        let ms = self.until(host_ref(scope)?, deadline)?;
        Ok(self.start(scope, ms)?.1.into())
    }

    /// A cancellable sleep: a `Timer` (`promise`, `cancel()`).
    fn timer<'s>(&self, scope: &mut v8::PinScope<'s, '_>, ms: f64) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        self.timer_object(scope, ms)
    }

    /// A cancellable sleep until `deadline`.
    #[method(name = "timerAt")]
    fn timer_at<'s>(&self, scope: &mut v8::PinScope<'s, '_>, deadline: f64) -> Result<v8::Local<'s, v8::Value>, NativeError> {
        let ms = self.until(host_ref(scope)?, deadline)?;
        self.timer_object(scope, ms)
    }
}

/// A cancellable timer (`io.timer.timer(ms)`); its `promise` is a frozen data property.
pub(crate) struct Timer {
    io: Rc<IoCore>,
    token: u32,
}

#[class(path = "io.Timer", side_effect = "any", needs = "runtime")]
impl Timer {
    /// Cancels the timer (its promise rejects `Canceled`): `true` when it cancelled a pending one, `false` when it
    /// already settled or the runtime is closed.
    fn cancel(&self, scope: &mut v8::PinScope<'_, '_>) -> Result<bool, NativeError> {
        let host = host_mut(scope)?;
        if !self.io.open(host) {
            return Ok(false);
        }
        let pending = host.cancel_timer(self.io.owner, self.io.runtime, self.token)?;
        let canceled = pending.is_some();
        if let Some(pending) = pending {
            native::finish::<()>(scope, pending, Err(NativeError::Errno(errno::CANCELED)));
        }
        Ok(canceled)
    }
}

/// `io.tcp`: TCP listeners and connections. Every address is checked against the network ceiling.
pub(crate) struct IoTcp(Rc<IoCore>);

#[class(path = "io.IoTcp", side_effect = "any", needs = "runtime")]
impl IoTcp {
    /// Binds and listens on `addr` (port 0 picks one, see `localAddr`), synchronously (`listen` rules).
    fn listen(&self, host: &HostState, addr: SockAddr) -> Result<TcpListenerUnshaped, NativeError> {
        self.0.lp(host)?;
        let listener = std::net::TcpListener::bind(allowed(host, addr.0, Use::Listen)?)?;
        listener.set_nonblocking(true)?;
        let conn = Conn::new(&self.0, Kind::Listener, Socket::listener(listener));
        Ok(TcpListenerUnshaped(crate::conn::Front::new(conn)))
    }

    /// Connects to `addr` (one address, no resolving; `connect` rules). Nothing blocks: the loop finishes the
    /// handshake.
    #[method(promise)]
    fn connect(
        &self,
        host: &mut HostState,
        addr: SockAddr,
    ) -> Result<Op<'static, impl Future<Output = Result<TcpStreamUnshaped, NativeError>> + use<>>, NativeError> {
        let lp = self.0.lp(host)?;
        let addr = allowed(host, addr.0, Use::Connect)?;
        let core = Rc::clone(&self.0);
        Ok(Op::new(self.0.runtime, async move {
            let stream = connect_stream(&lp, addr).await?;
            Ok(TcpStreamUnshaped::new(Conn::new(&core, Kind::Stream, Socket::stream(stream))))
        }))
    }
}

/// `io.udp`: datagram sockets.
pub(crate) struct IoUdp(Rc<IoCore>);

#[class(path = "io.IoUdp", side_effect = "any", needs = "runtime")]
impl IoUdp {
    /// Binds a datagram socket to `addr` (port 0 picks one), synchronously (`listen` rules).
    fn bind(&self, host: &HostState, addr: SockAddr) -> Result<UdpSocketUnshaped, NativeError> {
        self.0.lp(host)?;
        let socket = bind_datagram(allowed(host, addr.0, Use::Listen)?)?;
        let conn = Conn::new(&self.0, Kind::Datagram, Socket::datagram(socket));
        Ok(UdpSocketUnshaped(crate::conn::Front::new(conn)))
    }
}
