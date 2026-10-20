//! Generic buffers (`IoBuf` / `IoBufMut`): `Vec<u8>`, `Box<[u8]>` and `RawRegion` over pinned
//! heap memory. Runs on the real library (set `ORIGINE_IO_LIB`) and, under Miri, on the mock.

use origine_io::fs::File;
use origine_io::{IoBuf, Loop, Mode, Options, RawRegion, block_on, flags};
use std::cell::Cell;
use std::future::Future;
use std::io::ErrorKind;
use std::ptr::NonNull;
use std::rc::Rc;
use std::task::{Context, Waker};
use std::time::{Duration, Instant};

fn tmpdir(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("origine_buf_{}_{}", name, std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn new_loop() -> Loop {
    Loop::new(Options::default()).expect("loop")
}

/// Owner of a leaked heap block; `Drop` frees it and sets a flag (the "V8 backing store").
struct Block {
    ptr: *mut [u8],
    freed: Rc<Cell<bool>>,
}

impl Drop for Block {
    fn drop(&mut self) {
        // SAFETY: `ptr` came from `Box::into_raw` in `region` and is reclaimed exactly once, here.
        drop(unsafe { Box::from_raw(self.ptr) });
        self.freed.set(true);
    }
}

/// A `RawRegion` over a fresh heap block holding `data` (all initialized), and the drop flag.
fn region(data: &[u8]) -> (RawRegion, Rc<Cell<bool>>) {
    let freed = Rc::new(Cell::new(false));
    let raw = Box::into_raw(data.to_vec().into_boxed_slice());
    let ptr = NonNull::new(raw.cast::<u8>()).unwrap();
    let owner = Block { ptr: raw, freed: freed.clone() };
    // SAFETY: the block is valid for `len` bytes until `owner` drops it, nothing else touches it,
    // and its address is stable (leaked box).
    (unsafe { RawRegion::new(ptr, data.len(), Box::new(owner)) }, freed)
}

fn region_uninit(len: usize) -> (RawRegion, Rc<Cell<bool>>) {
    let (r, freed) = region(&vec![0; len]);
    let (ptr, len) = (NonNull::new(r.as_ptr()).unwrap(), r.len());
    // Re-wrap the same block as "uninitialized" (bytes_init == 0), keeping its owner.
    let owner = r.into_owner();
    // SAFETY: same block and owner as above; only the init bookkeeping differs.
    (unsafe { RawRegion::new_uninit(ptr, len, owner) }, freed)
}

fn bytes(r: &RawRegion, n: usize) -> Vec<u8> {
    assert!(n <= r.len());
    // SAFETY: the region is valid for `len` initialized-or-zeroed bytes and no op is in flight
    // (the buffer was handed back).
    unsafe { std::slice::from_raw_parts(r.as_ptr(), n) }.to_vec()
}

fn open_rw(lp: &Loop, path: &std::path::Path) -> isize {
    block_on(lp, lp.open(path, flags::RDWR | flags::CREAT | flags::TRUNC, 0o644)).unwrap()
}

#[test]
fn vec_semantics_unchanged() {
    let lp = new_loop();
    let dir = tmpdir("vec");
    let path = dir.join("f");
    let fd = open_rw(&lp, &path);
    let (r, buf) = block_on(&lp, lp.write(fd, b"0123456789".to_vec(), Some(0)));
    assert_eq!(r.unwrap(), 10);
    assert_eq!(buf, b"0123456789");
    // Reads fill `len()` bytes, never the spare capacity; the length is unchanged.
    let mut v = Vec::with_capacity(64);
    v.resize(4, 0);
    let (r, v) = block_on(&lp, lp.read(fd, v, Some(2)));
    assert_eq!(r.unwrap(), 4);
    assert_eq!(v, b"2345");
    assert_eq!(v.bytes_init(), 4);
    assert_eq!(v.bytes_total(), 4);
    // Past EOF: short read, length still unchanged.
    let (r, v) = block_on(&lp, lp.read(fd, vec![0; 32], Some(6)));
    assert_eq!(r.unwrap(), 4);
    assert_eq!(v.len(), 32);
    assert_eq!(&v[..4], b"6789");
    block_on(&lp, lp.close(fd)).unwrap();
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn box_slice_roundtrip() {
    let lp = new_loop();
    let dir = tmpdir("box");
    let path = dir.join("f");
    let fd = open_rw(&lp, &path);
    let file = File::from_fd(&lp, fd);
    block_on(&lp, async {
        let data: Box<[u8]> = b"boxed bytes".to_vec().into_boxed_slice();
        let (r, data) = file.write_at(data, 0).await;
        assert_eq!(r.unwrap(), 11);
        assert_eq!(&*data, b"boxed bytes");
        let (r, out) = file.read_at(vec![0u8; 11].into_boxed_slice(), 0).await;
        assert_eq!(r.unwrap(), 11);
        assert_eq!(&*out, b"boxed bytes");
        let (r, _) = file.write_all_at(out, 11).await;
        r.unwrap();
        let (r, out) = file.read_at(vec![0u8; 22].into_boxed_slice(), 0).await;
        assert_eq!(r.unwrap(), 22);
        assert_eq!(&*out, b"boxed bytesboxed bytes");
        // Static slices and Strings can be written too.
        let (r, _) = file.write_all_at(&b"!!"[..], 0).await;
        r.unwrap();
        let (r, s) = file.write_all_at(String::from("??"), 2).await;
        r.unwrap();
        assert_eq!(s, "??");
        file.close().await.unwrap();
    });
    assert_eq!(&std::fs::read(&path).unwrap()[..6], b"!!??d ");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn raw_region_read_write() {
    let lp = new_loop();
    let dir = tmpdir("raw");
    let path = dir.join("f");
    let fd = open_rw(&lp, &path);
    let file = File::from_fd(&lp, fd);
    block_on(&lp, async {
        let (reg, freed) = region(b"pinned region data");
        // write, position-less then positioned
        let (r, reg) = file.write(reg).await;
        assert_eq!(r.unwrap(), 18);
        assert!(!freed.get(), "the region is handed back, not dropped");
        let (r, reg) = file.write_all_at(reg, 18).await;
        r.unwrap();
        assert_eq!(bytes(&reg, 18), b"pinned region data");
        // read back into a fresh region
        let (dst, dst_freed) = region(&[0; 36]);
        let (r, dst) = file.read_at(dst, 0).await;
        assert_eq!(r.unwrap(), 36);
        assert_eq!(bytes(&dst, 36), b"pinned region datapinned region data");
        assert_eq!(dst.bytes_init(), 36);
        drop(reg);
        assert!(freed.get());
        assert!(!dst_freed.get());
        drop(dst);
        assert!(dst_freed.get());
        file.close().await.unwrap();
    });
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn raw_region_uninit_set_init_and_ranges() {
    let lp = new_loop();
    let dir = tmpdir("uninit");
    let path = dir.join("f");
    std::fs::write(&path, b"abcdefgh").unwrap();
    let fd = block_on(&lp, lp.open(&path, flags::RDWR, 0)).unwrap();
    block_on(&lp, async {
        let (reg, _freed) = region_uninit(16);
        assert_eq!((reg.bytes_init(), reg.bytes_total()), (0, 16));
        // Read 8 bytes into the middle of the region; init covers everything up to the end.
        let (r, reg) = lp.read_range(fd, reg, 4, Some(0)).await;
        assert_eq!(r.unwrap(), 8);
        assert_eq!(reg.bytes_init(), 12);
        assert_eq!(bytes(&reg, 12)[4..], *b"abcdefgh");
        // Reading again at EOF changes nothing.
        let (r, reg) = lp.read_range(fd, reg, 0, Some(8)).await;
        assert_eq!(r.unwrap(), 0);
        assert_eq!(reg.bytes_init(), 12);

        // write_range writes only the tail of the initialized bytes.
        let (r, reg) = lp.write_range(fd, reg, 8, Some(0)).await;
        assert_eq!(r.unwrap(), 4);
        // Bad ranges fail without touching the loop and hand the buffer back.
        let (r, reg) = lp.write_range(fd, reg, 13, Some(0)).await;
        assert_eq!(r.unwrap_err().kind(), ErrorKind::InvalidInput);
        let (r, reg) = lp.read_range(fd, reg, 17, Some(0)).await;
        assert_eq!(r.unwrap_err().kind(), ErrorKind::InvalidInput);
        assert_eq!(reg.bytes_init(), 12);
        lp.close(fd).await.unwrap();
    });
    assert_eq!(std::fs::read(&path).unwrap(), b"efghefgh");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn write_all_large_region_with_offsets() {
    let lp = new_loop();
    let dir = tmpdir("large");
    let path = dir.join("f");
    let fd = open_rw(&lp, &path);
    let file = File::from_fd(&lp, fd);
    let n = if cfg!(miri) { 4096 } else { 1 << 20 };
    let data: Vec<u8> = (0..n).map(|i| (i % 251) as u8).collect();
    block_on(&lp, async {
        let (reg, freed) = region(&data);
        let (r, reg) = file.write_all_at(reg, 3).await;
        r.unwrap();
        assert_eq!(bytes(&reg, n), data);
        drop(reg);
        assert!(freed.get());
        // An empty region writes nothing and still returns the buffer.
        let (empty, _) = region(&[]);
        let (r, _empty) = file.write_all(empty).await;
        r.unwrap();
        // Use after close hands the buffer back.
        file.close().await.unwrap();
        let (reg, _) = region(b"x");
        let (r, reg) = file.write_all(reg).await;
        assert!(r.is_err());
        assert_eq!(bytes(&reg, 1), b"x");
    });
    let got = std::fs::read(&path).unwrap();
    assert_eq!(&got[..3], &[0, 0, 0]);
    assert_eq!(&got[3..], &data[..]);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn vectored_with_generic_buffers() {
    let lp = new_loop();
    let dir = tmpdir("vec_io");
    let path = dir.join("f");
    let fd = open_rw(&lp, &path);
    block_on(&lp, async {
        let bufs: Vec<Box<[u8]>> = vec![b"ab".to_vec().into(), b"cde".to_vec().into()];
        let (r, bufs) = lp.writev(fd, bufs, Some(0)).await;
        assert_eq!(r.unwrap(), 5);
        assert_eq!(&*bufs[1], b"cde");
        let (a, fa) = region_uninit(2);
        let (b, _fb) = region_uninit(6);
        let (r, mut bufs) = lp.readv(fd, vec![a, b], Some(0)).await;
        assert_eq!(r.unwrap(), 5);
        let b = bufs.pop().unwrap();
        let a = bufs.pop().unwrap();
        assert_eq!((a.bytes_init(), b.bytes_init()), (2, 3));
        assert_eq!(bytes(&a, 2), b"ab");
        assert_eq!(bytes(&b, 3), b"cde");
        drop(a);
        assert!(fa.get());
        lp.close(fd).await.unwrap();
    });
    std::fs::remove_dir_all(dir).unwrap();
}

/// Dropping a pending read keeps the pinned memory alive until the completion callback ran.
fn pending_read_keeps_region_alive(lp: &Loop, fd: isize, wake: impl FnOnce()) {
    let (reg, freed) = region_uninit(8);
    let mut fut = Box::pin(lp.read(fd, reg, None));
    let mut cx = Context::from_waker(Waker::noop());
    let pending = fut.as_mut().poll(&mut cx).is_pending();
    drop(fut);
    if pending {
        assert!(!freed.get(), "region freed while the op was still in flight");
        assert_eq!(lp.active(), 1);
    }
    wake();
    let t0 = Instant::now();
    while lp.active() > 0 {
        assert!(!freed.get(), "region freed before the callback ran");
        lp.run(Mode::NoWait).unwrap();
        assert!(t0.elapsed() < Duration::from_secs(10), "op never completed");
        std::thread::sleep(Duration::from_millis(1));
    }
    assert!(freed.get(), "owner not dropped after the callback");
}

#[test]
fn dropped_pending_read_keeps_region_alive_file() {
    // On the mock the op only runs when the loop is driven, so it is pending. The real backend
    // may finish a file read before the drop; the end state is the same either way.
    let lp = new_loop();
    let dir = tmpdir("drop_file");
    let path = dir.join("f");
    std::fs::write(&path, b"data").unwrap();
    let fd = block_on(&lp, lp.open(&path, flags::RDONLY, 0)).unwrap();
    pending_read_keeps_region_alive(&lp, fd, || {});
    block_on(&lp, lp.close(fd)).unwrap();
    std::fs::remove_dir_all(dir).unwrap();
}

#[cfg(all(unix, not(miri)))]
mod pipes {
    use super::*;
    use std::io::{Read, Write};
    use std::os::fd::{FromRawFd, IntoRawFd, OwnedFd};

    #[test]
    fn dropped_pending_read_on_pipe_keeps_region_alive() {
        let lp = new_loop();
        let (r, mut w) = std::io::pipe().unwrap();
        let rfd = r.into_raw_fd();
        pending_read_keeps_region_alive(&lp, rfd as isize, || {
            // Let the (cancelled or not) read finish.
            w.write_all(b"x").unwrap();
        });
        // SAFETY: `rfd` was released by `into_raw_fd` above and is closed only here.
        drop(unsafe { OwnedFd::from_raw_fd(rfd) });
    }

    #[test]
    fn write_all_region_into_pipe_loops_over_partial_writes() {
        let lp = new_loop();
        let (mut r, w) = std::io::pipe().unwrap();
        let wfd = w.into_raw_fd();
        let n = 4 << 20;
        let data: Vec<u8> = (0..n).map(|i| (i % 253) as u8).collect();
        let reader = std::thread::spawn(move || {
            let mut out = Vec::new();
            r.read_to_end(&mut out).unwrap();
            out
        });
        let file = File::from_fd(&lp, wfd as isize);
        let (reg, freed) = region(&data);
        let (res, reg) = block_on(&lp, file.write_all(reg));
        res.unwrap();
        assert_eq!(bytes(&reg, 16), data[..16]);
        drop(reg);
        assert!(freed.get());
        block_on(&lp, file.close()).unwrap();
        let got = reader.join().unwrap();
        assert!(got == data, "pipe contents differ ({} vs {} bytes)", got.len(), data.len());
    }
}

#[test]
fn raw_region_is_not_send() {
    // `RawRegion` must stay `!Send` (compile-time check through autoref specialization).
    trait NotSend {
        const IS_SEND: bool = false;
    }
    impl<T> NotSend for T {}
    struct Probe<T>(std::marker::PhantomData<T>);
    #[allow(dead_code)]
    impl<T: Send> Probe<T> {
        const IS_SEND: bool = true;
    }
    const { assert!(!<Probe<RawRegion>>::IS_SEND) };
}
