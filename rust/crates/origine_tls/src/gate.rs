//! A first-come-first-served async lock for single-threaded tasks: one reader and one writer at a
//! time per [`TlsStream`](crate::TlsStream), without a thread or an executor.

use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll, Waker};

pub(crate) struct Gate {
    locked: Cell<bool>,
    waiters: RefCell<VecDeque<Waker>>,
}

pub(crate) struct Guard<'a>(&'a Gate);

pub(crate) struct Lock<'a>(&'a Gate);

impl Gate {
    pub(crate) fn new() -> Gate {
        Gate { locked: Cell::new(false), waiters: RefCell::new(VecDeque::new()) }
    }

    pub(crate) fn lock(&self) -> Lock<'_> {
        Lock(self)
    }

    pub(crate) fn try_lock(&self) -> Option<Guard<'_>> {
        if self.locked.get() {
            return None;
        }
        self.locked.set(true);
        Some(Guard(self))
    }
}

impl<'a> Future for Lock<'a> {
    type Output = Guard<'a>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Guard<'a>> {
        match self.0.try_lock() {
            Some(guard) => Poll::Ready(guard),
            None => {
                let mut waiters = self.0.waiters.borrow_mut();
                if !waiters.iter().any(|w| w.will_wake(cx.waker())) {
                    waiters.push_back(cx.waker().clone());
                }
                Poll::Pending
            }
        }
    }
}

impl Drop for Guard<'_> {
    fn drop(&mut self) {
        self.0.locked.set(false);
        let next = self.0.waiters.borrow_mut().pop_front();
        if let Some(waker) = next {
            waker.wake();
        }
    }
}
