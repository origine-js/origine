//! Guest API natives written in Rust against the `v8` crate, running on the isolate Zig created.
//!
//! Zig owns the isolate, the Host and the module/scope plumbing; this crate adds natives to the
//! same `native` table the glue consumes (`src/api/binding.zig` `raw` entries). The `v8` crate
//! keeps per-isolate state in an "annex" in embedder data slot 0 that only `Isolate::new`
//! creates, so Zig attaches one to its isolate with [`origine_api_attach_isolate`] before any
//! native runs and detaches it with [`origine_api_detach_isolate`] before the isolate dies. The
//! Rust-side Host state lives in an annex slot and is dropped by the detach.
//!
//! Natives are written as ordinary Rust fns under `#[native]` (see `origine_api_macros`): the macro
//! generates the `extern "C" fn(*const FunctionCallbackInfo)` that decodes the arguments
//! ([`FromJs`]), runs the fn under `catch_unwind` (a panic becomes a JS `Error`, never an unwind
//! into C++) and encodes the result ([`IntoJs`]). Async natives (`promise`) return a `Promise`
//! settled by [`host::tick`]; V8 `Global`s they hold must be released by [`HostState::drop_all`]
//! (done by the detach function) before `Runtime.destroy`.

extern crate self as origine_api;

pub mod decode;
pub mod encode;
mod fs;
pub mod host;
mod io;
pub mod native;
mod net;
pub mod pinned;
mod registry;
mod sys;

// CONTRACT (docs/contracts.md, surfaces B and C): `include/origine_api.h` is the source of truth;
// `abi_gen.rs` is generated from it (`just gen-contracts`). The structs are used as they are, and
// the `extern "C"` functions below and in `registry.rs` must have exactly the declared signatures
// (`abi_signatures`).
#[rustfmt::skip]
#[allow(non_camel_case_types, dead_code, clashing_extern_declarations, unsafe_op_in_unsafe_fn, clippy::all, clippy::undocumented_unsafe_blocks, clippy::multiple_unsafe_ops_per_block)]
mod abi_gen;

pub use decode::{ArrayBufferArg, FromJs};
pub use encode::IntoJs;
pub use host::HostState;
pub use origine_api_core::{ArgError, NativeError};
pub use origine_api_macros::{FromJs, IntoJs, native};
/// The `v8` crate, re-exported for `#[native]`'s generated code.
pub use v8;

use std::ffi::c_void;
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Attaches the `v8` crate's per-isolate state and the Rust Host state to `isolate`, a live
/// `v8::Isolate*` created outside Rust. Idempotent: returns `false` when already attached.
///
/// # Safety
///
/// `isolate` must be a live isolate on the calling thread whose embedder data slot 0 is unused
/// by the embedder. Call [`origine_api_detach_isolate`] before the isolate is disposed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_api_attach_isolate(isolate: *mut c_void) -> bool {
    let attached = catch_unwind(|| {
        let ptr = isolate.cast::<v8::RealIsolate>();
        // SAFETY: the caller guarantees `isolate` is live with slot 0 unused (or already ours).
        if !unsafe { v8::Isolate::attach_foreign_annex(ptr) } {
            return false;
        }
        // SAFETY: as above; the annex now exists so the reference is valid for this call only.
        let mut isolate = unsafe { v8::Isolate::from_raw_ptr(ptr) };
        let Ok((rx, tx)) = sys::WakeRx::pair() else {
            // SAFETY: undo the annex attached above; nothing else was set up.
            unsafe { v8::Isolate::detach_foreign_annex(ptr) };
            return false;
        };
        sys::register_waker(ptr as usize, tx);
        isolate.set_slot(HostState::new(rx));
        true
    });
    attached.unwrap_or(false)
}

/// Drops the Rust Host state and the annex attached by [`origine_api_attach_isolate`].
/// No-op when nothing is attached.
///
/// # Safety
///
/// `isolate` must be a live isolate on the calling thread, with no Rust `Global` for it alive
/// and no Rust native running.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_api_detach_isolate(isolate: *mut c_void) {
    let _ = catch_unwind(|| {
        let ptr = isolate.cast::<v8::RealIsolate>();
        // SAFETY: the caller guarantees `isolate` is live with nothing of ours in use.
        let mut handle = unsafe { v8::Isolate::from_raw_ptr(ptr) };
        if let Some(mut state) = handle.remove_slot::<HostState>() {
            state.drop_all();
        }
        sys::unregister_waker(isolate as usize);
        // SAFETY: as above.
        unsafe { v8::Isolate::detach_foreign_annex(ptr) };
    });
}

/// What the embedder allows, passed to [`origine_api_configure`] (`origine_api_cfg` in the header).
pub use abi_gen::origine_api_cfg as OriginCfg;

fn with_host<R>(isolate: *mut c_void, default: R, body: impl FnOnce(&mut HostState) -> R) -> R {
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller of the entry point guarantees `isolate` is live with our annex attached.
        let mut isolate = unsafe { v8::Isolate::from_raw_ptr(isolate.cast::<v8::RealIsolate>()) };
        isolate.get_slot_mut::<HostState>().map_or(default, body)
    }))
    .unwrap_or_else(|_| unreachable_default())
}

fn unreachable_default<R>() -> R {
    // A panic inside an entry point is a bug in this crate; there is no value to return for it.
    std::process::abort()
}

/// Sets the ceilings and the fs root of the Host attached to `isolate` (call once after attach).
///
/// # Safety
///
/// `isolate` must be a live isolate with our annex attached, on the calling thread; `cfg` must
/// point to a valid [`OriginCfg`]. The descriptor in `cfg` is duplicated, not taken over.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_api_configure(isolate: *mut c_void, cfg: *const OriginCfg) {
    // SAFETY: the caller guarantees `cfg` is valid for this call.
    let cfg = unsafe { &*cfg };
    let ceiling = origine_api_core::Ceiling {
        max_runtimes: cfg.max_runtimes,
        backends_mask: cfg.backends_mask,
        default_entries: cfg.default_entries,
    };
    let root = (cfg.fs_root_fd >= 0)
        .then(|| {
            // SAFETY: the caller guarantees the descriptor is open for the duration of this call.
            let borrowed = unsafe { std::os::fd::BorrowedFd::borrow_raw(cfg.fs_root_fd) };
            borrowed.try_clone_to_owned().ok()
        })
        .flatten();
    let fs = host::FsConfig { root, write: cfg.fs_write != 0, asynchronous: cfg.fs_async != 0 };
    with_host(isolate, (), |host| host.configure(ceiling, fs));
}

/// Waits for work and runs it: ticks every runtime, advances closing ones and settles finished
/// promises (each completion enters its saved context). With `block` it waits (`timeout_ns < 0` =
/// forever, still returning on [`origine_api_wake`]) when nothing was ready. Returns the number of
/// live items (tasks plus active ops), or -1 on error. The caller pumps microtasks afterwards.
///
/// # Safety
///
/// `isolate` must be a live isolate on the calling thread with our annex attached, entered (as
/// inside `Runtime.Session`), and the contexts of pending operations alive.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_api_poll(isolate: *mut c_void, block: u8, timeout_ns: i64) -> i64 {
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller guarantees `isolate` is live with our annex attached.
        let mut isolate = unsafe { v8::Isolate::from_raw_ptr(isolate.cast::<v8::RealIsolate>()) };
        v8::scope!(let scope, &mut isolate);
        let timeout = u64::try_from(timeout_ns).ok().map(std::time::Duration::from_nanos);
        host::poll(scope, block != 0, timeout)
    }))
    .unwrap_or(-1)
}

/// Whether any runtime has live tasks or ops, or a promise is waiting to settle.
///
/// # Safety
///
/// As [`origine_api_poll`], without the need for the isolate to be entered.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_api_has_work(isolate: *mut c_void) -> u8 {
    u8::from(with_host(isolate, false, |host| host.live_items() > 0))
}

/// A single fd that becomes readable when `origine_api_poll(block = 0)` would progress; -1 when
/// there is none. Not implemented yet (always -1): embedders without their own loop use poll.
///
/// # Safety
///
/// As [`origine_api_has_work`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn origine_api_pollable(_isolate: *mut c_void) -> i64 {
    -1
}

/// Interrupts a blocking [`origine_api_poll`] of the Host attached to `isolate`. Thread-safe.
#[unsafe(no_mangle)]
pub extern "C" fn origine_api_wake(isolate: *mut c_void) {
    sys::wake(isolate as usize);
}

/// Compile-time check that every entry point has the signature declared in `origine_api.h`: the
/// array only type-checks when both fn items coerce to one fn pointer type.
#[allow(dead_code)]
fn abi_signatures() {
    use abi_gen as h;
    let _ = [h::origine_api_attach_isolate, origine_api_attach_isolate];
    let _ = [h::origine_api_detach_isolate, origine_api_detach_isolate];
    let _ = [h::origine_api_configure, origine_api_configure];
    let _ = [h::origine_api_poll, origine_api_poll];
    let _ = [h::origine_api_has_work, origine_api_has_work];
    let _ = [h::origine_api_pollable, origine_api_pollable];
    let _ = [h::origine_api_wake, origine_api_wake];
    let _ = [h::origine_api_natives_count, registry::origine_api_natives_count];
    let _ = [h::origine_api_natives_get, registry::origine_api_natives_get];
}
