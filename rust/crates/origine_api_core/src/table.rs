//! Per-grant handle tables with in-flight accounting, with no V8 dependency.
//!
//! A handle is a 1-based id into a [`Table`]. An entry is [`State::Open`] until `close` is called,
//! then [`State::Closing`] while operations that started earlier are still running (new ones fail
//! with [`HandleError::Stale`]), and [`State::Closed`] once the close completed. Only closed slots
//! are reused for new handles, so an id never changes meaning while an operation on it is in
//! flight. Everything is single-threaded (`Rc`, `Cell`): async operations of one runtime and the
//! natives that start them all run on the isolate thread.

use std::cell::{Cell, RefCell};
use std::future::Future;
use std::ops::Deref;
use std::pin::Pin;
use std::rc::Rc;
use std::task::{Context, Poll, Waker};

use crate::NativeError;
use crate::errno;

/// Lifecycle of one entry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Open,
    /// `close` was called; waiting for in-flight operations, then the real close.
    Closing,
    Closed,
}

/// Why a handle cannot be used.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HandleError {
    /// Unknown, never issued, or already closed: `BadHandle`.
    Bad,
    /// Closing: `StaleHandle`.
    Stale,
}

impl HandleError {
    /// The `Errno` code of the error.
    pub fn code(self) -> u32 {
        match self {
            HandleError::Bad => errno::BAD_HANDLE,
            HandleError::Stale => errno::STALE_HANDLE,
        }
    }
}

impl From<HandleError> for NativeError {
    fn from(err: HandleError) -> NativeError {
        NativeError::Errno(err.code())
    }
}

/// One handle's value plus its lifecycle. Shared (`Rc`) between the table and running operations.
pub struct Entry<T> {
    value: T,
    state: Cell<State>,
    in_flight: Cell<u32>,
    waiters: RefCell<Vec<Waker>>,
}

impl<T> Entry<T> {
    fn new(value: T) -> Rc<Entry<T>> {
        Rc::new(Entry { value, state: Cell::new(State::Open), in_flight: Cell::new(0), waiters: RefCell::new(Vec::new()) })
    }

    /// The handle's value.
    pub fn value(&self) -> &T {
        &self.value
    }

    /// The current state.
    pub fn state(&self) -> State {
        self.state.get()
    }

    /// Operations that hold a [`Guard`].
    pub fn in_flight(&self) -> u32 {
        self.in_flight.get()
    }

    /// Starts an operation: the returned guard keeps the entry from being reused or closed until
    /// it is dropped.
    pub fn begin(self: &Rc<Self>) -> Result<Guard<T>, HandleError> {
        match self.state.get() {
            State::Open => {
                self.in_flight.set(self.in_flight.get() + 1);
                Ok(Guard { entry: Rc::clone(self) })
            }
            State::Closing => Err(HandleError::Stale),
            State::Closed => Err(HandleError::Bad),
        }
    }

    /// Marks the entry as closing; later `begin`s fail with `Stale`. Fails if it already is.
    pub fn begin_close(&self) -> Result<(), HandleError> {
        match self.state.get() {
            State::Open => {
                self.state.set(State::Closing);
                Ok(())
            }
            State::Closing => Err(HandleError::Stale),
            State::Closed => Err(HandleError::Bad),
        }
    }

    /// Completes when no operation is in flight any more.
    pub fn drained(self: &Rc<Self>) -> Drained<T> {
        Drained { entry: Rc::clone(self) }
    }

    /// Marks the entry closed; its slot may be reused.
    pub fn finish_close(&self) {
        self.state.set(State::Closed);
    }
}

/// Keeps an entry in use for the duration of an operation; derefs to the value.
pub struct Guard<T> {
    entry: Rc<Entry<T>>,
}

impl<T> Guard<T> {
    /// The entry this guard belongs to.
    pub fn entry(&self) -> &Rc<Entry<T>> {
        &self.entry
    }
}

impl<T> Deref for Guard<T> {
    type Target = T;
    fn deref(&self) -> &T {
        &self.entry.value
    }
}

impl<T> Drop for Guard<T> {
    fn drop(&mut self) {
        let left = self.entry.in_flight.get() - 1;
        self.entry.in_flight.set(left);
        if left == 0 {
            let waiters = std::mem::take(&mut *self.entry.waiters.borrow_mut());
            for waker in waiters {
                waker.wake();
            }
        }
    }
}

/// See [`Entry::drained`].
pub struct Drained<T> {
    entry: Rc<Entry<T>>,
}

impl<T> Future for Drained<T> {
    type Output = ();

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        if self.entry.in_flight.get() == 0 {
            Poll::Ready(())
        } else {
            let mut waiters = self.entry.waiters.borrow_mut();
            if !waiters.iter().any(|waker| waker.will_wake(cx.waker())) {
                waiters.push(cx.waker().clone());
            }
            Poll::Pending
        }
    }
}

/// Handles of one kind: ids `1..` index the slots.
pub struct Table<T> {
    slots: Vec<Option<Rc<Entry<T>>>>,
}

impl<T> Default for Table<T> {
    fn default() -> Self {
        Table { slots: Vec::new() }
    }
}

impl<T> Table<T> {
    /// An empty table.
    pub fn new() -> Table<T> {
        Table::default()
    }

    /// Stores `value` in the first reusable slot (never used, or closed) and returns its id.
    pub fn insert(&mut self, value: T) -> u32 {
        let entry = Entry::new(value);
        if let Some(index) = self.slots.iter().position(|slot| slot.as_ref().is_none_or(|entry| entry.state() == State::Closed)) {
            self.slots[index] = Some(entry);
            return index as u32 + 1;
        }
        self.slots.push(Some(entry));
        self.slots.len() as u32
    }

    /// The entry for `id`; `Bad` when the id was never issued or the entry is closed.
    pub fn get(&self, id: u32) -> Result<&Rc<Entry<T>>, HandleError> {
        let index = (id as usize).checked_sub(1).ok_or(HandleError::Bad)?;
        match self.slots.get(index) {
            Some(Some(entry)) if entry.state() != State::Closed => Ok(entry),
            _ => Err(HandleError::Bad),
        }
    }

    /// Entries that are not closed.
    pub fn live(&self) -> usize {
        self.slots.iter().flatten().filter(|entry| entry.state() != State::Closed).count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::task::Wake;

    struct Counter(AtomicUsize);

    impl Wake for Counter {
        fn wake(self: Arc<Self>) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    #[test]
    fn ids_start_at_one_and_unknown_ids_are_bad() {
        let mut table = Table::new();
        assert_eq!(table.get(0).err(), Some(HandleError::Bad));
        assert_eq!(table.get(1).err(), Some(HandleError::Bad));
        assert_eq!(table.insert("a"), 1);
        assert_eq!(table.insert("b"), 2);
        assert_eq!(*table.get(2).unwrap().value(), "b");
        assert_eq!(table.get(3).err(), Some(HandleError::Bad));
    }

    #[test]
    fn closing_entries_are_stale_and_their_ids_are_not_reused() {
        let mut table = Table::new();
        let id = table.insert(1);
        let entry = Rc::clone(table.get(id).unwrap());
        let guard = entry.begin().unwrap();
        entry.begin_close().unwrap();
        assert_eq!(entry.state(), State::Closing);
        assert_eq!(entry.begin().err(), Some(HandleError::Stale));
        assert_eq!(entry.begin_close().err(), Some(HandleError::Stale));
        assert_eq!(table.get(id).map(|_| ()), Ok(())); // still addressable while closing
        assert_eq!(table.insert(2), 2, "a closing slot is not reused");
        drop(guard);
        entry.finish_close();
        assert_eq!(table.get(id).err(), Some(HandleError::Bad));
        assert_eq!(table.insert(3), id, "a closed slot is reused");
        assert_eq!(table.live(), 2);
    }

    #[test]
    fn drained_wakes_when_the_last_guard_drops() {
        let mut table = Table::new();
        let id = table.insert(());
        let entry = Rc::clone(table.get(id).unwrap());
        let (a, b) = (entry.begin().unwrap(), entry.begin().unwrap());
        assert_eq!(entry.in_flight(), 2);
        let counter = Arc::new(Counter(AtomicUsize::new(0)));
        let waker = Waker::from(Arc::clone(&counter));
        let mut cx = Context::from_waker(&waker);
        let mut drained = std::pin::pin!(entry.drained());
        assert!(drained.as_mut().poll(&mut cx).is_pending());
        assert!(drained.as_mut().poll(&mut cx).is_pending());
        drop(a);
        assert_eq!(counter.0.load(Ordering::SeqCst), 0);
        drop(b);
        // `will_wake` may not recognize a waker (vtables are not unique), so a duplicate wake is fine.
        assert!((1..=2).contains(&counter.0.load(Ordering::SeqCst)));
        assert!(drained.as_mut().poll(&mut cx).is_ready());
    }

    #[test]
    fn errors_map_to_errno_codes() {
        assert!(matches!(NativeError::from(HandleError::Bad), NativeError::Errno(6)));
        assert!(matches!(NativeError::from(HandleError::Stale), NativeError::Errno(7)));
    }
}
