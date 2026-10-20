//! The few OS calls std lacks: `poll(2)` and the wake channel that interrupts it.

use std::ffi::{c_int, c_short};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex, PoisonError};

#[repr(C)]
struct PollFd {
    fd: c_int,
    events: c_short,
    revents: c_short,
}

#[cfg(target_os = "linux")]
type NFds = std::ffi::c_ulong;
#[cfg(not(target_os = "linux"))]
type NFds = std::ffi::c_uint;

unsafe extern "C" {
    fn poll(fds: *mut PollFd, nfds: NFds, timeout: c_int) -> c_int;
}

const POLLIN: c_short = 1;

/// Waits until one of `fds` is readable or `timeout_ms` passes (-1 = forever). Returns which are
/// readable (an interrupted wait returns none).
pub fn wait_readable(fds: &[c_int], timeout_ms: c_int) -> io::Result<Vec<bool>> {
    let mut set: Vec<PollFd> = fds.iter().map(|&fd| PollFd { fd, events: POLLIN, revents: 0 }).collect();
    // SAFETY: `set` is a live, correctly laid out array of `set.len()` pollfd structs.
    let rc = unsafe { poll(set.as_mut_ptr(), set.len() as NFds, timeout_ms) };
    if rc < 0 {
        let err = io::Error::last_os_error();
        return if err.kind() == io::ErrorKind::Interrupted { Ok(vec![false; fds.len()]) } else { Err(err) };
    }
    // Errors and hang-ups also count: the caller then finds out by running the loop.
    Ok(set.iter().map(|entry| entry.revents != 0).collect())
}

/// The receiving end of the wake channel, owned by the Host state.
pub struct WakeRx(UnixStream);

impl WakeRx {
    /// A channel: the receiver and the thread-safe sender.
    pub fn pair() -> io::Result<(WakeRx, Arc<UnixStream>)> {
        let (rx, tx) = UnixStream::pair()?;
        rx.set_nonblocking(true)?;
        tx.set_nonblocking(true)?;
        Ok((WakeRx(rx), Arc::new(tx)))
    }

    pub fn fd(&self) -> c_int {
        self.0.as_raw_fd()
    }

    /// Discards pending wake bytes.
    pub fn drain(&self) {
        let mut buf = [0u8; 64];
        while matches!((&self.0).read(&mut buf), Ok(n) if n > 0) {}
    }
}

static WAKERS: Mutex<Vec<(usize, Arc<UnixStream>)>> = Mutex::new(Vec::new());

/// Makes `wake(isolate)` reach `tx`.
pub fn register_waker(isolate: usize, tx: Arc<UnixStream>) {
    let mut all = WAKERS.lock().unwrap_or_else(PoisonError::into_inner);
    all.retain(|(key, _)| *key != isolate);
    all.push((isolate, tx));
}

pub fn unregister_waker(isolate: usize) {
    WAKERS.lock().unwrap_or_else(PoisonError::into_inner).retain(|(key, _)| *key != isolate);
}

/// Thread-safe: interrupts a blocking poll of the Host attached to `isolate`.
pub fn wake(isolate: usize) {
    let tx = WAKERS.lock().unwrap_or_else(PoisonError::into_inner).iter().find(|(key, _)| *key == isolate).map(|(_, tx)| Arc::clone(tx));
    if let Some(tx) = tx {
        let _ = (&*tx).write(&[1]);
    }
}
