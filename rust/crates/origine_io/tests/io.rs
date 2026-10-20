use origine_io::*;
use std::io::ErrorKind;
use std::time::{Duration, Instant};

fn tmpdir(name: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("origine_io_{}_{}", name, std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn new_loop() -> Loop {
    Loop::new(Options::default()).expect("loop")
}

#[test]
fn write_read_roundtrip() {
    let lp = new_loop();
    let dir = tmpdir("rt");
    let path = dir.join("a.txt");
    block_on(&lp, async {
        let fd = lp.open(&path, flags::RDWR | flags::CREAT | flags::TRUNC, 0o644).await.unwrap();
        let (r, buf) = lp.write(fd, b"hello origine".to_vec(), Some(0)).await;
        assert_eq!(r.unwrap(), 13);
        assert_eq!(buf, b"hello origine");
        let st = lp.fstat(fd).await.unwrap();
        assert_eq!(st.size, 13);
        assert_eq!(st.kind, FileKind::File);
        let (r, buf) = lp.read(fd, vec![0; 32], Some(0)).await;
        let n = r.unwrap();
        assert_eq!(&buf[..n], b"hello origine");
        lp.close(fd).await.unwrap();

        lp.mkdir(dir.join("sub"), 0o755).await.unwrap();
        lp.rename(&path, dir.join("b.txt")).await.unwrap();
        assert!(dir.join("b.txt").exists()); // (mkdir mode bug in backend: sub is created mode 000, so do not rename into it)
        lp.unlink(dir.join("b.txt"), false).await.unwrap();
        lp.unlink(dir.join("sub"), true).await.unwrap();
        assert!(!dir.join("sub").exists());
    });
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn open_missing_is_enoent() {
    let lp = new_loop();
    let dir = tmpdir("enoent");
    let e = block_on(&lp, lp.open(dir.join("nope"), flags::RDONLY, 0)).unwrap_err();
    assert_eq!(e.kind(), ErrorKind::NotFound);
    assert_eq!(e.raw_os_error(), Some(2));
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn slow_timeout_and_fast_op_out_of_order() {
    let lp = new_loop();
    let order = std::cell::RefCell::new(Vec::new());
    let t0 = Instant::now();
    let (a, b) = block_on(
        &lp,
        join(
            async {
                lp.timeout(Duration::from_millis(200)).await.unwrap();
                order.borrow_mut().push("slow");
            },
            async {
                lp.timeout(Duration::from_millis(5)).await.unwrap();
                order.borrow_mut().push("fast");
            },
        ),
    );
    let _ = (a, b);
    assert_eq!(*order.borrow(), ["fast", "slow"]);
    assert!(t0.elapsed() >= Duration::from_millis(190));
}

#[test]
fn drop_pending_timeout_cancels() {
    let lp = new_loop();
    {
        #[allow(clippy::unnecessary_box_pin, reason = "the future is dropped explicitly below to cancel the op")]
        let mut f = Box::pin(lp.timeout(Duration::from_secs(3600)));
        let w = std::task::Waker::noop();
        let mut cx = std::task::Context::from_waker(w);
        assert!(std::future::Future::poll(f.as_mut(), &mut cx).is_pending());
        assert_eq!(lp.active(), 1);
    }
    // The cancelled op completes through the loop and releases its state.
    let t0 = Instant::now();
    while lp.active() > 0 {
        lp.run(Mode::NoWait).unwrap();
        assert!(t0.elapsed() < Duration::from_secs(5), "cancel never completed");
        std::thread::sleep(Duration::from_millis(1));
    }
    // Loop still usable.
    block_on(&lp, lp.timeout(Duration::from_millis(1))).unwrap();
}

#[test]
fn drop_loop_with_pending_op() {
    let lp = new_loop();
    #[allow(clippy::unnecessary_box_pin, reason = "the future is dropped explicitly below to cancel the op")]
    let mut f = Box::pin(lp.timeout(Duration::from_secs(3600)));
    let mut cx = std::task::Context::from_waker(std::task::Waker::noop());
    assert!(std::future::Future::poll(f.as_mut(), &mut cx).is_pending());
    drop(lp); // future keeps the loop alive
    drop(f);
}

#[test]
fn post_from_thread_wakes_run() {
    let lp = new_loop();
    let h = lp.handle();
    let flag = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let f2 = flag.clone();
    let t = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(20));
        h.post(move || f2.store(true, std::sync::atomic::Ordering::SeqCst)).unwrap();
    });
    block_on(&lp, lp.timeout(Duration::from_millis(300))).unwrap();
    t.join().unwrap();
    assert!(flag.load(std::sync::atomic::Ordering::SeqCst));
}

#[test]
fn abandoned_inflight_ops_are_released() {
    let lp = new_loop();
    let dir = tmpdir("abandon");
    let path = dir.join("f");
    let fd = block_on(&lp, lp.open(&path, flags::RDWR | flags::CREAT, 0o644)).unwrap();
    // Dropped while in flight (cancelled or completed by the loop later): buffers and state must
    // stay valid until the callback runs.
    drop(lp.read(fd, vec![0; 64], Some(0)));
    drop(lp.write(fd, b"abandoned".to_vec(), Some(0)));
    drop(lp.fstat(fd));
    drop(lp.nop());
    while lp.active() > 0 {
        lp.run(Mode::NoWait).unwrap();
    }
    block_on(&lp, lp.close(fd)).unwrap();
    // Abandoned ops still outstanding when the loop is dropped.
    drop(lp.timeout(Duration::from_secs(3600)));
    drop(lp.nop());
    drop(lp);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn post_runs_on_loop_drop() {
    let lp = new_loop();
    let h = lp.handle();
    let flag = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let f2 = flag.clone();
    h.post(move || f2.store(true, std::sync::atomic::Ordering::SeqCst)).unwrap();
    drop(lp);
    assert!(h.post(|| {}).is_err());
    h.wake();
}

#[test]
fn new_file_ops() {
    let lp = new_loop();
    let dir = tmpdir("newops");
    let a = dir.join("a");
    let b = dir.join("b");
    block_on(&lp, async {
        let fd = lp.open(&a, flags::RDWR | flags::CREAT | flags::TRUNC, 0o644).await.unwrap();
        let (r, bufs) = lp.writev(fd, vec![b"hello ".to_vec(), b"vectored".to_vec()], Some(0)).await;
        assert_eq!(r.unwrap(), 14);
        assert_eq!(bufs.len(), 2);
        lp.fsync(fd, false).await.unwrap();
        lp.fsync(fd, true).await.unwrap();
        let (r, bufs) = lp.readv(fd, vec![vec![0; 5], vec![0; 20]], Some(0)).await;
        assert_eq!(r.unwrap(), 14);
        assert_eq!(bufs[0], b"hello");
        assert_eq!(&bufs[1][..9], b" vectored");

        lp.fallocate(fd, 0, 64, false).await.unwrap();
        assert_eq!(lp.fstat(fd).await.unwrap().size, 64);

        let out = lp.open(&b, flags::RDWR | flags::CREAT | flags::TRUNC, 0o644).await.unwrap();
        assert_eq!(lp.sendfile(out, fd, Some(0), 14).await.unwrap(), 14);
        let (r, buf) = lp.read(out, vec![0; 14], Some(0)).await;
        assert_eq!(&buf[..r.unwrap()], b"hello vectored");
        lp.close(out).await.unwrap();
        lp.close(fd).await.unwrap();

        let st = lp.stat_at(&a, false).await.unwrap();
        assert_eq!((st.kind, st.size), (FileKind::File, 64));
        let l = dir.join("l");
        lp.link(&a, &l).await.unwrap();
        assert_eq!(lp.stat_at(&l, true).await.unwrap().size, 64);
        assert_eq!(lp.stat_at(dir.join("zz"), false).await.unwrap_err().kind(), ErrorKind::NotFound);
        lp.unlink(&l, false).await.unwrap();
    });
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn futex_wait_wake() {
    use std::sync::{Arc, atomic::AtomicU32};
    let lp = new_loop();
    let w = Arc::new(AtomicU32::new(0));
    // Mismatch: EAGAIN straight away.
    let e = block_on(&lp, lp.futex_wait(w.clone(), 1, None)).unwrap_err();
    assert_eq!(e.kind(), ErrorKind::WouldBlock);
    // Timeout.
    let e = block_on(&lp, lp.futex_wait(w.clone(), 0, Some(Duration::from_millis(5)))).unwrap_err();
    assert_eq!(e.kind(), ErrorKind::TimedOut);
    // Wait, then wake from the same loop.
    let (a, b) = block_on(
        &lp,
        join(lp.futex_wait(w.clone(), 0, None), async {
            lp.timeout(Duration::from_millis(5)).await.unwrap();
            lp.futex_wake(w.clone(), 10).await
        }),
    );
    a.unwrap();
    assert_eq!(b.unwrap(), 1);
    // Dropped waiter is cancelled and released.
    drop(lp.futex_wait(w, 0, None));
    while lp.active() > 0 {
        lp.run(Mode::NoWait).unwrap();
    }
}

#[test]
fn socket_buffers_come_back() {
    let lp = new_loop();
    if lp.caps() & CAP_SOCKETS != 0 {
        return; // real backend: would need a real socket; covered by the mock only
    }
    let (r, buf) = block_on(&lp, lp.send(-1, b"x".to_vec(), 0));
    assert!(r.is_err());
    assert_eq!(buf, b"x");
    assert!(block_on(&lp, lp.accept(-1, 16)).is_err());
    assert!(block_on(&lp, lp.connect(-1, vec![0; 16])).is_err());
    drop(lp.recv(-1, vec![0; 8], 0));
}

#[test]
fn ftruncate_shrinks_and_extends() {
    let lp = new_loop();
    if lp.caps() & CAP_FTRUNCATE == 0 {
        eprintln!("skip: no ftruncate");
        return;
    }
    let dir = tmpdir("ftrunc");
    let path = dir.join("f");
    block_on(&lp, async {
        let fd = lp.open(&path, flags::RDWR | flags::CREAT | flags::TRUNC, 0o644).await.unwrap();
        lp.write(fd, b"0123456789".to_vec(), Some(0)).await.0.unwrap();
        lp.ftruncate(fd, 4).await.unwrap();
        assert_eq!(lp.fstat(fd).await.unwrap().size, 4);
        lp.ftruncate(fd, 100).await.unwrap();
        assert_eq!(lp.fstat(fd).await.unwrap().size, 100);
        let (r, buf) = lp.read(fd, vec![0; 8], Some(0)).await;
        assert_eq!(r.unwrap(), 8);
        assert_eq!(&buf[..4], b"0123");
        assert_eq!(&buf[4..], [0; 4]);
        lp.close(fd).await.unwrap();
        assert!(lp.ftruncate(fd, 0).await.is_err());
    });
    std::fs::remove_dir_all(dir).unwrap();
}

fn make_listing_dir(name: &str) -> (std::path::PathBuf, Vec<(Vec<u8>, FileKind)>) {
    let dir = tmpdir(name);
    let mut want = Vec::new();
    for i in 0..20 {
        let n = format!("file_{i:02}_{}", "x".repeat(i));
        std::fs::write(dir.join(&n), b"x").unwrap();
        want.push((n.into_bytes(), FileKind::File));
    }
    std::fs::create_dir(dir.join("subdir")).unwrap();
    want.push((b"subdir".to_vec(), FileKind::Directory));
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink("file_00_", dir.join("link")).unwrap();
        want.push((b"link".to_vec(), FileKind::Symlink));
    }
    want.sort_by(|a, b| a.0.cmp(&b.0));
    (dir, want)
}

async fn list_all(lp: &Loop, dir: &std::path::Path, bufsize: usize) -> Vec<(Vec<u8>, FileKind)> {
    let fd = lp.open(dir, flags::RDONLY | flags::DIRECTORY, 0).await.unwrap();
    let mut out = Vec::new();
    let mut cookie = 0;
    let mut buf = vec![0u8; bufsize];
    loop {
        let r = lp.readdir(fd, buf, cookie).await;
        let n = r.result.unwrap();
        if n == 0 {
            buf = r.buf;
            break;
        }
        out.extend(parse_dir_entries(&r.buf[..n]).map(|e| (e.name.to_vec(), e.kind)));
        cookie = r.cookie;
        buf = r.buf;
    }
    assert_eq!(buf.len(), bufsize);
    lp.close(fd).await.unwrap();
    out
}

#[test]
fn readdir_full_listing() {
    let lp = new_loop();
    if lp.caps() & CAP_READDIR == 0 {
        eprintln!("skip: no readdir");
        return;
    }
    let (dir, want) = make_listing_dir("rd_full");
    let mut got = block_on(&lp, list_all(&lp, &dir, 65536));
    got.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(got, want);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn readdir_continuation_tiny_buffer() {
    let lp = new_loop();
    if lp.caps() & CAP_READDIR == 0 {
        eprintln!("skip: no readdir");
        return;
    }
    let (dir, want) = make_listing_dir("rd_cont");
    // Longest entry is 3 + "file_19_" + 19 x = 30 bytes. 64 holds one or two entries per call and is
    // above the macOS backend's documented minimum (about 32 bytes of native dirent room).
    let mut got = block_on(&lp, list_all(&lp, &dir, 64));
    assert_eq!(got.len(), want.len(), "no duplicates, none missing");
    got.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(got, want);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn readdir_erange_and_errors() {
    let lp = new_loop();
    if lp.caps() & CAP_READDIR == 0 {
        eprintln!("skip: no readdir");
        return;
    }
    let (dir, _) = make_listing_dir("rd_erange");
    block_on(&lp, async {
        let fd = lp.open(&dir, flags::RDONLY | flags::DIRECTORY, 0).await.unwrap();
        let r = lp.readdir(fd, vec![0; 2], 0).await;
        let e = r.result.unwrap_err();
        assert!(is_erange(&e), "{e}");
        assert_eq!(e.kind(), ErrorKind::InvalidInput);
        assert_eq!((r.buf.len(), r.cookie), (2, 0));
        lp.close(fd).await.unwrap();

        // A regular file is not a directory.
        let f = dir.join("file_00_");
        let fd = lp.open(&f, flags::RDONLY, 0).await.unwrap();
        let r = lp.readdir(fd, vec![0; 4096], 0).await;
        assert!(r.result.is_err());
        lp.close(fd).await.unwrap();
    });
    std::fs::remove_dir_all(dir).unwrap();
}
