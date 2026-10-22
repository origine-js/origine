//! TCP ping-pong benchmark on `origine_io` (rt + Loop). Single OS thread, client and server in
//! the same process, loopback, TCP_NODELAY.
//!
//! usage: tcp_bench <msg_size> <conns> [warmup_s=1] [measure_s=3]
//! prints one JSON line.

use origine_io::rt::{Runtime, spawn};
use origine_io::{Backend, CAP_SOCKETS, Fd, Loop, Options};
use std::cell::Cell;
use std::net::{TcpListener, TcpStream};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd};
use std::rc::Rc;
use std::time::{Duration, Instant};

unsafe extern "C" {
    fn setsockopt(fd: i32, level: i32, name: i32, val: *const i32, len: u32) -> i32;
}
const SOL_SOCKET: i32 = 0xffff;
const SO_NOSIGPIPE: i32 = 0x1022;

/// macOS has no MSG_NOSIGNAL: use SO_NOSIGPIPE on the socket instead (send flags stay 0).
fn no_sigpipe(fd: i32) {
    let one: i32 = 1;
    // SAFETY: `fd` is an open socket and `&one` is a valid 4-byte int for the call's duration.
    let rc = unsafe { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4) };
    assert_eq!(rc, 0, "SO_NOSIGPIPE");
}

fn pat(i: usize) -> u8 {
    (i.wrapping_mul(7).wrapping_add(13)) as u8
}

/// Message layout: bytes 0..8 = sequence number (LE), the rest a fixed pattern.
fn make_msg(size: usize) -> Vec<u8> {
    let mut v: Vec<u8> = (0..size).map(pat).collect();
    v[..8].copy_from_slice(&0u64.to_le_bytes());
    v
}

/// Server: echo every received chunk back (fully sent) until EOF/error.
async fn echo(lp: Loop, fd: Fd, size: usize) {
    let mut buf = vec![0u8; size];
    loop {
        let (r, mut b) = lp.recv(fd, buf, 0).await;
        let n = match r {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        b.truncate(n);
        let mut b = b;
        loop {
            let (r, bb) = lp.send(fd, b, 0).await;
            b = bb;
            match r {
                Ok(k) if k == b.len() => break,
                Ok(k) => {
                    b.drain(..k);
                }
                Err(_) => return,
            }
        }
        // SAFETY: the buffer was allocated with `size` bytes, all initialized by `vec![0; size]`;
        // `truncate`/`drain` only shortened the length, so re-extending to `size` (<= capacity,
        // contents were once initialized) exposes only initialized bytes. `drain` shifted bytes
        // but never uninitialized any.
        unsafe { b.set_len(size) };
        buf = b;
    }
}

struct Phase {
    t_warm_end: Instant,
    t_end: Instant,
}

async fn client(lp: Loop, fd: Fd, size: usize, ph: Rc<Phase>, lat: Rc<Cell<u64>>, out: Rc<std::cell::RefCell<Vec<u64>>>) {
    let mut msg = make_msg(size);
    let mut rbuf = vec![0u8; size];
    let mut seq: u64 = 0;
    let mut mine: Vec<u64> = Vec::with_capacity(1 << 16);
    loop {
        seq += 1;
        msg[..8].copy_from_slice(&seq.to_le_bytes());
        let t0 = Instant::now();
        if t0 >= ph.t_end {
            break;
        }
        // send fully
        let mut sent = 0usize;
        loop {
            let (r, m) = lp.send(fd, msg, 0).await;
            msg = m;
            let k = r.expect("send");
            sent += k;
            if sent == size {
                break;
            }
            // partial: send the remainder; rebuild window
            let rest = msg[sent..].to_vec();
            let (r2, _) = write_all(&lp, fd, rest).await;
            r2.expect("send rest");
            break;
        }
        // receive exactly `size` bytes
        let mut got = 0usize;
        while got < size {
            rbuf.truncate(size - got);
            let (r, b) = lp.recv(fd, rbuf, 0).await;
            rbuf = b;
            let n = r.expect("recv");
            assert!(n > 0, "unexpected EOF");
            // spot-check: first/last byte of this chunk against the expected stream
            let lo = got;
            let hi = got + n - 1;
            let exp = |i: usize| if i < 8 { seq.to_le_bytes()[i] } else { pat(i) };
            assert_eq!(rbuf[0], exp(lo), "echo content mismatch (chunk start)");
            assert_eq!(rbuf[n - 1], exp(hi), "echo content mismatch (chunk end)");
            got += n;
            // SAFETY: `rbuf` has capacity >= size and all `size` bytes were initialized by
            // `vec![0; size]`; only its length was reduced by `truncate`.
            unsafe { rbuf.set_len(size) };
        }
        assert_eq!(got, size, "echo length mismatch");
        let t1 = Instant::now();
        if t0 >= ph.t_warm_end && t1 <= ph.t_end {
            mine.push(t1.duration_since(t0).as_nanos() as u64);
        }
    }
    lat.set(lat.get() + mine.len() as u64);
    out.borrow_mut().extend_from_slice(&mine);
}

async fn write_all(lp: &Loop, fd: Fd, mut b: Vec<u8>) -> (std::io::Result<()>, ()) {
    while !b.is_empty() {
        let (r, bb) = lp.send(fd, b, 0).await;
        b = bb;
        match r {
            Ok(k) => {
                b.drain(..k);
            }
            Err(e) => return (Err(e), ()),
        }
    }
    (Ok(()), ())
}

fn pct(v: &[u64], p: f64) -> u64 {
    let i = ((v.len() as f64) * p).ceil() as usize;
    v[i.saturating_sub(1).min(v.len() - 1)]
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let size: usize = a.get(1).and_then(|s| s.parse().ok()).expect("msg_size");
    let conns: usize = a.get(2).and_then(|s| s.parse().ok()).expect("conns");
    let warm: f64 = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(1.0);
    let meas: f64 = a.get(4).and_then(|s| s.parse().ok()).unwrap_or(3.0);
    assert!(size >= 16);

    let lp = Loop::new(Options { backend: Backend::Auto, entries: 0 }).expect("loop");
    assert!(lp.caps() & CAP_SOCKETS != 0, "backend lacks sockets (mock?)");
    let caps = lp.caps();
    let rt = Runtime::new(Rc::new(lp.clone()));

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let addr = listener.local_addr().unwrap();
    let lfd = listener.as_raw_fd() as Fd;
    // Connect clients with the blocking std connect (loopback completes via the backlog), then
    // switch them to non-blocking.
    let mut streams = Vec::new();
    for _ in 0..conns {
        let s = TcpStream::connect(addr).unwrap();
        s.set_nonblocking(true).unwrap();
        s.set_nodelay(true).unwrap();
        no_sigpipe(s.as_raw_fd());
        streams.push(s);
    }

    let now = Instant::now();
    let ph = Rc::new(Phase { t_warm_end: now + Duration::from_secs_f64(warm), t_end: now + Duration::from_secs_f64(warm + meas) });
    let count = Rc::new(Cell::new(0u64));
    let lats = Rc::new(std::cell::RefCell::new(Vec::<u64>::new()));

    let t_start = ph.t_warm_end;
    rt.block_on({
        let lp = lp.clone();
        let (ph, count, lats) = (ph.clone(), count.clone(), lats.clone());
        async move {
            // server: accept all, one echo task per connection
            let mut servers = Vec::new();
            for _ in 0..conns {
                let (fd, _addr) = lp.accept(lfd, 128).await.expect("accept");
                // SAFETY: `fd` is a fresh socket fd returned by accept that nobody else owns;
                // ownership moves into the TcpStream (and back out via into_raw_fd below).
                let s = unsafe { TcpStream::from_raw_fd(fd as i32) };
                s.set_nonblocking(true).unwrap();
                s.set_nodelay(true).unwrap();
                no_sigpipe(s.as_raw_fd());
                let fd = s.into_raw_fd() as Fd;
                servers.push(fd);
                spawn(echo(lp.clone(), fd, size));
            }
            let mut hs = Vec::new();
            for s in &streams {
                hs.push(spawn(client(lp.clone(), s.as_raw_fd() as Fd, size, ph.clone(), count.clone(), lats.clone())));
            }
            for h in hs {
                h.await.expect("client task");
            }
            // close server-side fds
            for fd in servers {
                // SAFETY: `fd` came from `into_raw_fd` above and is closed exactly once here;
                // the echo task may still hold a pending recv, which the process exit reaps.
                drop(unsafe { TcpStream::from_raw_fd(fd as i32) });
            }
        }
    });

    let mut v = std::mem::take(&mut *lats.borrow_mut());
    v.sort_unstable();
    let secs = meas;
    let n = v.len();
    let mean = v.iter().sum::<u64>() as f64 / n.max(1) as f64;
    println!(
        "{{\"impl\":\"origine-rt\",\"backend\":\"kqueue-gcd(auto)\",\"caps\":{caps},\"size\":{size},\"conns\":{conns},\"rounds\":{n},\"rps\":{:.0},\"p50_ns\":{},\"p99_ns\":{},\"mean_ns\":{:.0},\"secs\":{secs}}}",
        n as f64 / secs,
        pct(&v, 0.50),
        pct(&v, 0.99),
        mean
    );
    let _ = t_start;
    // Skip teardown of echo tasks parked in recv.
    std::process::exit(0);
}
