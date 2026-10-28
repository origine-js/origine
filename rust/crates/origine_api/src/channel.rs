//! `native.channel.*`: bounded multi-producer channels of structured-clone messages that connect
//! isolates (on any thread).
//!
//! A channel lives in a process-wide registry; the guest holds integer handles for its ends. The
//! queue only holds [`Message`]s, so it is `Send`; the V8 side of an operation (its promise) stays
//! in the HostState of the isolate that started it. An operation that cannot finish yet is parked
//! there (a [`Wait`]) and the channel remembers which isolate to wake; the wake runs the isolate's
//! poll, which calls [`service`] to retry its parked operations. Registration and the check that
//! decides to park happen under the channel's lock, so a wake cannot be lost.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use origine_api_core::{NativeError, errno};

use crate::host::{HostState, Pending};
use crate::message::{self, Message};
use crate::native;
use crate::native::error_value;
use crate::sys;

struct State {
    queue: VecDeque<Message>,
    capacity: usize,
    senders: usize,
    receiver_open: bool,
    /// Isolates (by address) with a parked `recv` / `send` on this channel.
    recv_waiters: Vec<usize>,
    send_waiters: Vec<usize>,
}

type Chan = Arc<Mutex<State>>;

#[derive(Clone, Copy, PartialEq, Eq)]
enum End {
    Sender,
    Receiver,
}

/// One handle: its kind, its channel and the isolate (by address) that owns it. An isolate closes
/// the ends it owns when it goes away; `adopt` moves ownership.
struct Entry {
    end: End,
    chan: Chan,
    owner: usize,
}

struct Registry {
    next: u32,
    ends: HashMap<u32, Entry>,
}

static REGISTRY: Mutex<Option<Registry>> = Mutex::new(None);

fn registry() -> MutexGuard<'static, Option<Registry>> {
    REGISTRY.lock().unwrap_or_else(PoisonError::into_inner)
}

fn lock(chan: &Chan) -> MutexGuard<'_, State> {
    chan.lock().unwrap_or_else(PoisonError::into_inner)
}

fn bad_handle() -> NativeError {
    NativeError::Errno(errno::BAD_HANDLE)
}

/// The channel behind `id` if it is an end of kind `end`.
fn find(id: u32, end: End) -> Result<Chan, NativeError> {
    match registry().as_ref().and_then(|registry| registry.ends.get(&id)) {
        Some(entry) if entry.end == end => Ok(Arc::clone(&entry.chan)),
        _ => Err(bad_handle()),
    }
}

fn add_end(end: End, chan: Chan, owner: usize) -> Result<u32, NativeError> {
    let mut guard = registry();
    let registry = guard.get_or_insert_with(|| Registry { next: 1, ends: HashMap::new() });
    let id = registry.next;
    registry.next = id.checked_add(1).ok_or(NativeError::Errno(errno::QUOTA_EXCEEDED))?;
    registry.ends.insert(id, Entry { end, chan, owner });
    Ok(id)
}

fn wake_all(isolates: Vec<usize>) {
    for isolate in isolates {
        sys::wake(isolate);
    }
}

fn note(waiters: &mut Vec<usize>, isolate: usize) {
    if !waiters.contains(&isolate) {
        waiters.push(isolate);
    }
}

/// An operation parked on its isolate until the channel lets it finish.
pub(crate) enum Wait {
    Recv { rx: u32, pending: Pending },
    Send { tx: u32, message: Message, pending: Pending },
}

enum Sent {
    Done,
    Full(Message),
}

/// Pushes `message` if there is room. `Full` hands the message back and records `isolate` as a
/// waiter; a closed receiver is `BrokenPipe`.
fn try_send(tx: u32, message: Message, isolate: usize) -> Result<Sent, NativeError> {
    let chan = find(tx, End::Sender)?;
    let mut state = lock(&chan);
    if !state.receiver_open {
        return Err(NativeError::Errno(errno::BROKEN_PIPE));
    }
    if state.queue.len() >= state.capacity {
        note(&mut state.send_waiters, isolate);
        return Ok(Sent::Full(message));
    }
    state.queue.push_back(message);
    let waiters = std::mem::take(&mut state.recv_waiters);
    drop(state);
    wake_all(waiters);
    Ok(Sent::Done)
}

/// Pops the oldest message. `None` records `isolate` as a waiter; no message and no sender left is
/// `NotConnected`.
fn try_recv(rx: u32, isolate: usize) -> Result<Option<Message>, NativeError> {
    let chan = find(rx, End::Receiver)?;
    let mut state = lock(&chan);
    if let Some(message) = state.queue.pop_front() {
        let waiters = std::mem::take(&mut state.send_waiters);
        drop(state);
        wake_all(waiters);
        return Ok(Some(message));
    }
    if state.senders == 0 {
        return Err(NativeError::Errno(errno::NOT_CONNECTED));
    }
    note(&mut state.recv_waiters, isolate);
    Ok(None)
}

/// Settles `pending` with the value `body` builds inside the promise's own context.
fn settle(
    scope: &mut v8::PinScope<'_, '_, ()>,
    pending: Pending,
    body: impl for<'s, 'i> FnOnce(&mut v8::PinScope<'s, 'i>) -> Result<v8::Local<'s, v8::Value>, NativeError>,
) {
    let (resolver, context, _, _) = pending.into_parts();
    let context = v8::Local::new(scope, &context);
    let scope = &mut v8::ContextScope::new(scope, context);
    let resolver = v8::Local::new(scope, &resolver);
    match body(scope) {
        Ok(value) => resolver.resolve(scope, value),
        Err(error) => {
            let value = error_value(scope, error);
            resolver.reject(scope, value)
        }
    };
}

fn settle_unit(scope: &mut v8::PinScope<'_, '_, ()>, pending: Pending, result: Result<(), NativeError>) {
    native::finish(scope, pending, result);
}

/// Retries the parked operations of this isolate; returns how many settled. Called by every poll.
pub(crate) fn service(scope: &mut v8::PinScope<'_, '_, ()>) -> usize {
    let (isolate, waits) = match scope.get_slot_mut::<HostState>() {
        Some(host) if !host.chan_waits.is_empty() => (host.isolate, std::mem::take(&mut host.chan_waits)),
        _ => return 0,
    };
    let mut parked = Vec::new();
    let mut settled = 0;
    for wait in waits {
        match wait {
            Wait::Recv { rx, pending } => match try_recv(rx, isolate) {
                Ok(Some(message)) => {
                    settle(scope, pending, |scope| message::decode(scope, message));
                    settled += 1;
                }
                Ok(None) => parked.push(Wait::Recv { rx, pending }),
                Err(error) => {
                    settle_unit(scope, pending, Err(error));
                    settled += 1;
                }
            },
            Wait::Send { tx, message, pending } => match try_send(tx, message, isolate) {
                Ok(Sent::Done) => {
                    settle_unit(scope, pending, Ok(()));
                    settled += 1;
                }
                Ok(Sent::Full(message)) => parked.push(Wait::Send { tx, message, pending }),
                Err(error) => {
                    settle_unit(scope, pending, Err(error));
                    settled += 1;
                }
            },
        }
    }
    if let Some(host) = scope.get_slot_mut::<HostState>() {
        parked.append(&mut host.chan_waits);
        host.chan_waits = parked;
    }
    settled
}

/// The two ends of a new channel.
#[derive(crate::IntoJs)]
pub struct Ends {
    tx: u32,
    rx: u32,
}

/// `native.channel.create(capacity)`: a channel holding at most `capacity` (>= 1) messages.
/// Returns `{ tx, rx }`, the handles of its ends.
#[native(side_effect = "any", path = "channel.create")]
fn channel_create(host: &mut HostState, capacity: u32) -> Result<Ends, NativeError> {
    if capacity == 0 {
        return Err(NativeError::Errno(errno::INVALID_INPUT));
    }
    let chan: Chan = Arc::new(Mutex::new(State {
        queue: VecDeque::new(),
        capacity: capacity as usize,
        senders: 1,
        receiver_open: true,
        recv_waiters: Vec::new(),
        send_waiters: Vec::new(),
    }));
    let owner = host.isolate;
    let tx = add_end(End::Sender, Arc::clone(&chan), owner)?;
    let rx = match add_end(End::Receiver, chan, owner) {
        Ok(rx) => rx,
        Err(error) => {
            if let Some(registry) = registry().as_mut() {
                registry.ends.remove(&tx);
            }
            return Err(error);
        }
    };
    Ok(Ends { tx, rx })
}

/// `native.channel.clone(tx)`: another sender handle of the same channel. `BadHandle` for a
/// handle that is not an open sender.
#[native(side_effect = "any", path = "channel.clone")]
fn channel_clone(host: &mut HostState, tx: u32) -> Result<u32, NativeError> {
    let chan = find(tx, End::Sender)?;
    lock(&chan).senders += 1;
    match add_end(End::Sender, Arc::clone(&chan), host.isolate) {
        Ok(id) => Ok(id),
        Err(error) => {
            lock(&chan).senders -= 1;
            Err(error)
        }
    }
}

/// `native.channel.close(handle)`: closes a sender (the last one lets `recv` drain and then fail
/// `NotConnected`) or the receiver (queued messages are dropped and `send` fails `BrokenPipe`).
/// `BadHandle` for an unknown or already closed handle.
#[native(side_effect = "any", path = "channel.close")]
fn channel_close(handle: u32) -> Result<(), NativeError> {
    let entry = registry().as_mut().and_then(|registry| registry.ends.remove(&handle)).ok_or_else(bad_handle)?;
    finish_end(entry);
    Ok(())
}

/// Detaches a removed end from its channel and wakes whoever waited on it.
fn finish_end(entry: Entry) {
    let mut state = lock(&entry.chan);
    let waiters = match entry.end {
        End::Sender => {
            state.senders -= 1;
            if state.senders == 0 { std::mem::take(&mut state.recv_waiters) } else { Vec::new() }
        }
        End::Receiver => {
            state.receiver_open = false;
            state.queue.clear();
            std::mem::take(&mut state.send_waiters)
        }
    };
    drop(state);
    wake_all(waiters);
}

/// Closes every end owned by `isolate`: the isolate is going away, so a peer waiting on one of them
/// finds the channel closed instead of waiting forever. Called when the Host state is dropped.
pub(crate) fn release_owned(isolate: usize) {
    let owned: Vec<Entry> = {
        let mut guard = registry();
        let Some(registry) = guard.as_mut() else { return };
        let handles: Vec<u32> = registry.ends.iter().filter(|(_, entry)| entry.owner == isolate).map(|(handle, _)| *handle).collect();
        handles.into_iter().filter_map(|handle| registry.ends.remove(&handle)).collect()
    };
    for entry in owned {
        finish_end(entry);
    }
}

/// `origine_api_channel_close(handle)`: closes an end from outside any isolate (the thread of an
/// isolate that is going away uses it for the ends it was given). An unknown handle is ignored.
#[unsafe(no_mangle)]
pub extern "C" fn origine_api_channel_close(handle: u32) {
    let entry = registry().as_mut().and_then(|registry| registry.ends.remove(&handle));
    if let Some(entry) = entry {
        finish_end(entry);
    }
}

/// `native.channel.adopt(handle)`: makes the calling isolate the owner of an end, so that it is closed
/// when this isolate goes away. `BadHandle` for an unknown or closed handle.
#[native(side_effect = "any", path = "channel.adopt")]
fn channel_adopt(host: &mut HostState, handle: u32) -> Result<(), NativeError> {
    let mut guard = registry();
    let entry = guard.as_mut().and_then(|registry| registry.ends.get_mut(&handle)).ok_or_else(bad_handle)?;
    entry.owner = host.isolate;
    Ok(())
}

fn promise<'s>(scope: &mut v8::PinScope<'s, '_>) -> Result<(v8::Local<'s, v8::PromiseResolver>, Pending), NativeError> {
    let resolver = v8::PromiseResolver::new(scope).ok_or_else(|| NativeError::error("cannot create a promise"))?;
    let global = v8::Global::new(scope, resolver);
    let current = scope.get_current_context();
    let context = v8::Global::new(scope, current);
    Ok((resolver, Pending::new(global, context, 0, None)))
}

fn park(scope: &mut v8::PinScope<'_, '_>, wait: Wait) -> Result<(), NativeError> {
    native::host_mut(scope)?.chan_waits.push(wait);
    Ok(())
}

/// `native.channel.send(tx, value, transfer?)`: Promise<void>, resolved once the message is queued
/// (it waits while the channel is full). `transfer` lists `ArrayBuffer`s to move. Rejects
/// `BrokenPipe` when the receiver is closed, `BadHandle` for a handle that is not an open sender;
/// a value that cannot be cloned throws synchronously and nothing is detached.
#[native(side_effect = "any", path = "channel.send")]
fn channel_send<'s>(
    scope: &mut v8::PinScope<'s, '_>,
    tx: u32,
    value: v8::Local<'s, v8::Value>,
    transfer: Option<v8::Local<'s, v8::Array>>,
) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    find(tx, End::Sender)?;
    let mut buffers = Vec::new();
    if let Some(list) = transfer {
        for index in 0..list.length() {
            let item = list.get_index(scope, index).ok_or_else(|| NativeError::type_error("cannot read the transfer list"))?;
            let buffer = v8::Local::<v8::ArrayBuffer>::try_from(item).map_err(|_| NativeError::type_error("the transfer list holds only ArrayBuffers"))?;
            buffers.push(buffer);
        }
    }
    let message = message::encode(scope, value, &buffers)?;
    let (resolver, pending) = promise(scope)?;
    let promise = resolver.get_promise(scope);
    let isolate = native::host_mut(scope)?.isolate;
    match try_send(tx, message, isolate) {
        Ok(Sent::Done) => {
            let _ = resolver.resolve(scope, v8::undefined(scope).into());
            drop(pending);
        }
        Ok(Sent::Full(message)) => park(scope, Wait::Send { tx, message, pending })?,
        Err(error) => {
            let value = error_value(scope, error);
            let _ = resolver.reject(scope, value);
            drop(pending);
        }
    }
    Ok(promise.into())
}

/// `native.channel.recv(rx)`: Promise of the oldest message, waiting while the channel is empty.
/// Rejects `NotConnected` once the queue is drained and every sender is closed, `BadHandle` for a
/// handle that is not an open receiver.
#[native(side_effect = "any", path = "channel.recv")]
fn channel_recv<'s>(scope: &mut v8::PinScope<'s, '_>, rx: u32) -> Result<v8::Local<'s, v8::Value>, NativeError> {
    find(rx, End::Receiver)?;
    let (resolver, pending) = promise(scope)?;
    let promise = resolver.get_promise(scope);
    let isolate = native::host_mut(scope)?.isolate;
    match try_recv(rx, isolate) {
        Ok(Some(message)) => {
            drop(pending);
            match message::decode(scope, message) {
                Ok(value) => {
                    let _ = resolver.resolve(scope, value);
                }
                Err(error) => {
                    let value = error_value(scope, error);
                    let _ = resolver.reject(scope, value);
                }
            }
        }
        Ok(None) => park(scope, Wait::Recv { rx, pending })?,
        Err(error) => {
            drop(pending);
            let value = error_value(scope, error);
            let _ = resolver.reject(scope, value);
        }
    }
    Ok(promise.into())
}
