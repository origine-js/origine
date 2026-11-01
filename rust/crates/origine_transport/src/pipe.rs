//! An in-memory duplex transport for tests: what one end writes, the other reads. Writes never block;
//! dropping an end is that end closing (the other reads `0` once it has drained what was sent).

use crate::Transport;
use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::future::{Future, poll_fn};
use std::io;
use std::rc::Rc;
use std::task::{Poll, Waker};

#[derive(Default)]
struct Half {
    queue: RefCell<VecDeque<u8>>,
    closed: Cell<bool>,
    waker: RefCell<Option<Waker>>,
}

impl Half {
    fn wake(&self) {
        if let Some(w) = self.waker.borrow_mut().take() {
            w.wake();
        }
    }
}

pub struct Pipe {
    incoming: Rc<Half>,
    outgoing: Rc<Half>,
    /// While set, `write_all` never completes: a peer that stopped reading.
    pub hang: Rc<Cell<bool>>,
}

/// Two connected ends.
pub fn pipe() -> (Pipe, Pipe) {
    let (a, b) = (Rc::new(Half::default()), Rc::new(Half::default()));
    let one = Pipe { incoming: a.clone(), outgoing: b.clone(), hang: Rc::default() };
    let two = Pipe { incoming: b, outgoing: a, hang: Rc::default() };
    (one, two)
}

impl Drop for Pipe {
    fn drop(&mut self) {
        self.outgoing.closed.set(true);
        self.outgoing.wake();
    }
}

impl Transport for Pipe {
    fn read(&self, mut buf: Vec<u8>) -> impl Future<Output = (io::Result<usize>, Vec<u8>)> {
        let half = self.incoming.clone();
        poll_fn(move |cx| {
            let mut queue = half.queue.borrow_mut();
            if queue.is_empty() {
                if half.closed.get() {
                    return Poll::Ready((Ok(0), std::mem::take(&mut buf)));
                }
                *half.waker.borrow_mut() = Some(cx.waker().clone());
                return Poll::Pending;
            }
            let n = queue.len().min(buf.len());
            for slot in &mut buf[..n] {
                *slot = queue.pop_front().unwrap();
            }
            Poll::Ready((Ok(n), std::mem::take(&mut buf)))
        })
    }

    fn write_all(&self, buf: Vec<u8>) -> impl Future<Output = (io::Result<()>, Vec<u8>)> {
        let half = self.outgoing.clone();
        let hang = self.hang.clone();
        let mut buf = Some(buf);
        poll_fn(move |_cx| {
            if hang.get() {
                return Poll::Pending;
            }
            let data = buf.take().unwrap();
            half.queue.borrow_mut().extend(&data);
            half.wake();
            Poll::Ready((Ok(()), data))
        })
    }
}
