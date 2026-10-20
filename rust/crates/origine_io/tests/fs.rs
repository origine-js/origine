//! `origine_io::fs` on the real library (set `ORIGINE_IO_LIB`) and, under Miri, on the mock.

use origine_io::fs::{Dir, OpenOptions, sanitize};
use origine_io::rt::{self, JoinSet, Runtime};
use origine_io::{Loop, Mode, Options};
use std::future::Future;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::rc::Rc;
use std::sync::Mutex;
use std::task::{Context, Poll, Waker};
use std::time::{Duration, Instant};

/// The tests share descriptor numbers (a process-wide fd table), and the leak checks reason about
/// "fd N is closed now", so run them one at a time.
static SERIAL: Mutex<()> = Mutex::new(());

struct Env {
    lp: Rc<Loop>,
    rt: Runtime,
    root: PathBuf,
    _guard: std::sync::MutexGuard<'static, ()>,
}

impl Env {
    fn new(name: &str) -> Env {
        let guard = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let lp = Rc::new(Loop::new(Options::default()).expect("loop"));
        let rt = Runtime::new(lp.clone());
        let root = std::env::temp_dir().join(format!("origine_fs_{}_{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        Env { lp, rt, root, _guard: guard }
    }

    fn run<F: Future>(&self, f: F) -> F::Output {
        self.rt.block_on(f)
    }

    async fn dir(&self) -> Dir {
        Dir::open_ambient(&self.lp, &self.root).await.unwrap()
    }

    fn drain(&self) {
        let t0 = Instant::now();
        while self.lp.active() > 0 {
            self.lp.run(Mode::NoWait).unwrap();
            assert!(t0.elapsed() < Duration::from_secs(10), "ops never drained");
            std::thread::sleep(Duration::from_millis(1));
        }
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn poll_once<F: Future + Unpin>(f: &mut F) -> Poll<F::Output> {
    Pin::new(f).poll(&mut Context::from_waker(Waker::noop()))
}

fn kind<T>(r: std::io::Result<T>) -> ErrorKind {
    match r {
        Ok(_) => panic!("expected an error"),
        Err(e) => e.kind(),
    }
}

// ---------------------------------------------------------------------------------------------

#[test]
fn file_roundtrip() {
    let env = Env::new("roundtrip");
    env.run(async {
        let d = env.dir().await;
        d.write("a.txt", "hello origine").await.unwrap();
        assert_eq!(d.read("a.txt").await.unwrap(), b"hello origine");
        assert_eq!(d.metadata("a.txt").await.unwrap().len(), 13);

        let f = d.open_file("a.txt", OpenOptions::new().read(true).write(true)).await.unwrap();
        let (r, buf) = f.read_at(vec![0; 5], 6).await;
        assert_eq!(&buf[..r.unwrap()], b"origi");
        let (r, _) = f.write_at(b"ORIGINE".to_vec(), 6).await;
        assert_eq!(r.unwrap(), 7);
        // Position-based read starts at 0 and advances.
        let (r, buf) = f.read(vec![0; 5]).await;
        assert_eq!(&buf[..r.unwrap()], b"hello");
        let (r, buf) = f.read(vec![0; 64]).await;
        assert_eq!(&buf[..r.unwrap()], b" ORIGINE");
        let (r, buf) = f.read(vec![0; 8]).await;
        assert_eq!(r.unwrap(), 0, "EOF");
        assert_eq!(buf.len(), 8);

        let (r, back) = f.write_all_at(b"!!".to_vec(), 13).await;
        r.unwrap();
        assert_eq!(back, b"!!", "write_all returns the buffer unchanged");
        assert_eq!(f.metadata().await.unwrap().len(), 15);
        f.set_len(5).await.unwrap();
        f.sync_all().await.unwrap();
        f.sync_data().await.unwrap();
        assert_eq!(f.metadata().await.unwrap().len(), 5);
        f.close().await.unwrap();
        assert_eq!(d.read("a.txt").await.unwrap(), b"hello");
        d.close().await.unwrap();
    });
}

#[test]
fn write_all_large_and_read_to_end_limit() {
    let env = Env::new("big");
    env.run(async {
        let d = env.dir().await;
        let n = if cfg!(miri) { 100_000 } else { 3_000_000 };
        let data: Vec<u8> = (0..n).map(|i| (i % 251) as u8).collect();
        d.write("big", data.clone()).await.unwrap();
        assert_eq!(d.read("big").await.unwrap(), data);

        let f = d.open_file("big", OpenOptions::new().read(true)).await.unwrap();
        assert_eq!(kind(f.read_to_end(n - 1).await), ErrorKind::FileTooLarge);
        f.close().await.unwrap();
        let f = d.open_file("big", OpenOptions::new().read(true)).await.unwrap();
        assert_eq!(f.read_to_end(n).await.unwrap().len(), n, "exactly at the limit is fine");
        // At EOF now: nothing more, any limit.
        assert!(f.read_to_end(0).await.unwrap().is_empty());
        f.close().await.unwrap();

        d.write("empty", Vec::new()).await.unwrap();
        let f = d.open_file("empty", OpenOptions::new().read(true)).await.unwrap();
        assert!(f.read_to_end(0).await.unwrap().is_empty());
    });
}

#[test]
fn open_options() {
    let env = Env::new("opts");
    env.run(async {
        let d = env.dir().await;
        let mut create_new = OpenOptions::new();
        create_new.write(true).create_new(true);
        d.open_file("x", &create_new).await.unwrap().close().await.unwrap();
        assert_eq!(kind(d.open_file("x", &create_new).await), ErrorKind::AlreadyExists);
        assert_eq!(kind(d.open_file("missing", OpenOptions::new().read(true)).await), ErrorKind::NotFound);

        // append
        d.write("log", "a").await.unwrap();
        let f = d.open_file("log", OpenOptions::new().append(true)).await.unwrap();
        f.write_all(b"b".to_vec()).await.0.unwrap();
        f.write_all(b"c".to_vec()).await.0.unwrap();
        f.close().await.unwrap();
        assert_eq!(d.read("log").await.unwrap(), b"abc");

        // truncate
        let f = d.open_file("log", OpenOptions::new().write(true).truncate(true)).await.unwrap();
        f.close().await.unwrap();
        assert_eq!(d.metadata("log").await.unwrap().len(), 0);

        // reading a write-only file / writing a read-only file fails
        let f = d.open_file("log", OpenOptions::new().write(true)).await.unwrap();
        assert!(f.read(vec![0; 1]).await.0.is_err());
        let f = d.open_file("log", OpenOptions::new().read(true)).await.unwrap();
        assert!(f.write(vec![1]).await.0.is_err());

        // std's invalid combinations
        assert_eq!(kind(d.open_file("x", &OpenOptions::new()).await), ErrorKind::InvalidInput);
        assert_eq!(kind(d.open_file("x", OpenOptions::new().read(true).create(true)).await), ErrorKind::InvalidInput);
        assert_eq!(kind(d.open_file("x", OpenOptions::new().append(true).truncate(true)).await), ErrorKind::InvalidInput);

        // mode applies to new files
        d.open_file("m", OpenOptions::new().write(true).create(true).mode(0o600)).await.unwrap().close().await.unwrap();
        let m = d.metadata("m").await.unwrap();
        assert!(m.is_file());
        assert_eq!(m.permissions_mode() & 0o077, 0);
    });
}

#[test]
fn create_dir_all_is_idempotent() {
    let env = Env::new("mkdirall");
    env.run(async {
        let d = env.dir().await;
        d.create_dir_all("a/b/c").await.unwrap();
        d.create_dir_all("a/b/c").await.unwrap();
        d.create_dir_all("./a//b/./c/").await.unwrap();
        d.create_dir_all("a/b/c/d/e").await.unwrap();
        d.create_dir_all("").await.unwrap();
        d.create_dir_all(".").await.unwrap();
        assert!(d.metadata("a/b/c/d/e").await.unwrap().is_dir());
        assert_eq!(kind(d.create_dir("a").await), ErrorKind::AlreadyExists);

        d.write("file", "x").await.unwrap();
        assert_eq!(kind(d.create_dir_all("file").await), ErrorKind::AlreadyExists);
        assert_eq!(kind(d.create_dir_all("file/sub").await), ErrorKind::NotADirectory);

        // Concurrent create_dir_all on overlapping paths.
        let mut set = JoinSet::new();
        for i in 0..8 {
            let d = d.clone();
            set.spawn(async move { d.create_dir_all(format!("p/q/r{}", i % 3)).await });
        }
        for r in set.join_all().await.unwrap() {
            r.unwrap();
        }
    });
}

#[test]
fn remove_dir_all_nested_tree() {
    let env = Env::new("rmall");
    // A tree wider than the concurrency bound (16) and several levels deep.
    let (width, files) = if cfg!(miri) { (3, 20) } else { (5, 40) };
    fn build(p: &Path, depth: u32, width: u32, files: u32) {
        std::fs::create_dir_all(p).unwrap();
        for i in 0..files {
            std::fs::write(p.join(format!("f{i}")), b"x").unwrap();
        }
        if depth > 0 {
            for i in 0..width {
                build(&p.join(format!("d{i}")), depth - 1, width, files);
            }
        }
    }
    build(&env.root.join("tree"), 3, width, files);
    std::fs::create_dir_all(env.root.join("outside")).unwrap();
    std::fs::write(env.root.join("outside/keep"), b"keep").unwrap();
    std::os::unix::fs::symlink(env.root.join("outside"), env.root.join("tree/d0/link")).unwrap();

    env.run(async {
        let d = env.dir().await;
        d.remove_dir_all("tree").await.unwrap();
        assert!(!d.try_exists("tree").await.unwrap());
        assert!(d.try_exists("outside/keep").await.unwrap(), "symlink target must not be followed");
        assert_eq!(kind(d.remove_dir_all("tree").await), ErrorKind::NotFound);
        d.write("plain", "x").await.unwrap();
        assert_eq!(kind(d.remove_dir_all("plain").await), ErrorKind::NotADirectory);
    });
    assert!(!env.root.join("tree").exists());
    env.drain();
}

#[test]
fn remove_file_and_dir_errors() {
    let env = Env::new("rmerr");
    env.run(async {
        let d = env.dir().await;
        d.create_dir_all("full/inner").await.unwrap();
        assert_eq!(kind(d.remove_dir("full").await), ErrorKind::DirectoryNotEmpty);
        assert_eq!(kind(d.remove_file("nope").await), ErrorKind::NotFound);
        assert_eq!(kind(d.remove_dir("nope").await), ErrorKind::NotFound);
        d.remove_dir("full/inner").await.unwrap();
        d.remove_dir("full").await.unwrap();
        d.write("f", "x").await.unwrap();
        d.remove_file("f").await.unwrap();
        assert!(!d.try_exists("f").await.unwrap());
        assert_eq!(kind(d.open_dir("nope").await), ErrorKind::NotFound);
        d.write("f", "x").await.unwrap();
        assert_eq!(kind(d.open_dir("f").await), ErrorKind::NotADirectory);
    });
}

#[test]
fn read_dir_many_entries() {
    let env = Env::new("readdir");
    let n = if cfg!(miri) { 150 } else { 500 };
    // Long names so one 8 KiB listing buffer cannot hold them all (several refills).
    let name = |i: usize| format!("entry-with-a-rather-long-name-to-fill-the-buffer-{i:05}");
    for i in 0..n {
        std::fs::write(env.root.join(name(i)), b"").unwrap();
    }
    std::fs::create_dir(env.root.join("subdir")).unwrap();
    std::os::unix::fs::symlink("entry", env.root.join("link")).unwrap();
    env.run(async {
        let d = env.dir().await;
        let mut rd = d.read_dir(".").await.unwrap();
        let mut names = Vec::new();
        let (mut files, mut dirs, mut links) = (0, 0, 0);
        while let Some(e) = rd.next_entry().await.unwrap() {
            let ft = e.file_type();
            files += usize::from(ft.is_file());
            dirs += usize::from(ft.is_dir());
            links += usize::from(ft.is_symlink());
            names.push(e.file_name().to_string_lossy().into_owned());
        }
        assert!(rd.next_entry().await.unwrap().is_none(), "stays at the end");
        assert_eq!((files, dirs, links), (n, 1, 1));
        names.sort();
        names.dedup();
        assert_eq!(names.len(), n + 2);
        assert!(!names.iter().any(|n| n == "." || n == ".."));
        assert_eq!(kind(d.read_dir("missing").await), ErrorKind::NotFound);
        // Sub-directory listing.
        let mut rd = d.read_dir("subdir").await.unwrap();
        assert!(rd.next_entry().await.unwrap().is_none());
    });
}

#[test]
fn metadata_and_symlink_metadata() {
    let env = Env::new("meta");
    std::fs::write(env.root.join("f"), b"12345").unwrap();
    std::os::unix::fs::symlink("f", env.root.join("l")).unwrap();
    std::fs::create_dir(env.root.join("d")).unwrap();
    env.run(async {
        let d = env.dir().await;
        let m = d.metadata("f").await.unwrap();
        assert!(m.is_file() && !m.is_dir() && !m.is_symlink());
        assert_eq!(m.len(), 5);
        assert!(d.metadata("d").await.unwrap().is_dir());
        assert!(d.metadata(".").await.unwrap().is_dir());
        // follows the link / does not
        let through = d.metadata("l").await.unwrap();
        assert!(through.is_file());
        assert_eq!(through.len(), 5);
        let own = d.symlink_metadata("l").await.unwrap();
        assert!(own.is_symlink() && !own.is_file());
        assert_eq!(kind(d.metadata("none").await), ErrorKind::NotFound);
        assert!(d.try_exists("l").await.unwrap());
        assert!(!d.try_exists("none").await.unwrap());
        assert_eq!(kind(d.try_exists("../x").await), ErrorKind::InvalidInput);
    });
}

#[test]
fn rename_across_dirs_and_copy() {
    let env = Env::new("rename");
    env.run(async {
        let root = env.dir().await;
        root.create_dir_all("one").await.unwrap();
        root.create_dir_all("two/sub").await.unwrap();
        let one = root.open_dir("one").await.unwrap();
        let two = root.open_dir("two").await.unwrap();
        one.write("f", "payload").await.unwrap();

        one.rename("f", &two, "sub/g").await.unwrap();
        assert!(!one.try_exists("f").await.unwrap());
        assert_eq!(two.read("sub/g").await.unwrap(), b"payload");
        assert_eq!(root.read("two/sub/g").await.unwrap(), b"payload");
        assert_eq!(kind(one.rename("f", &two, "x").await), ErrorKind::NotFound);
        assert_eq!(kind(one.rename("../one/f", &two, "x").await), ErrorKind::InvalidInput);
        assert_eq!(kind(one.rename("f", &two, "/abs").await), ErrorKind::InvalidInput);

        // copy within a Dir and across Dirs
        assert_eq!(two.copy("sub/g", "h").await.unwrap(), 7);
        assert_eq!(two.read("h").await.unwrap(), b"payload");
        assert_eq!(two.copy_to("h", &one, "copied").await.unwrap(), 7);
        assert_eq!(one.read("copied").await.unwrap(), b"payload");
        // copy over an existing, longer file truncates it
        one.write("copied", "a much longer previous content").await.unwrap();
        two.copy_to("h", &one, "copied").await.unwrap();
        assert_eq!(one.read("copied").await.unwrap(), b"payload");
        assert_eq!(kind(two.copy("missing", "z").await), ErrorKind::NotFound);
        assert!(!two.try_exists("z").await.unwrap(), "failed copy creates nothing");

        // multi-chunk copy
        let n = if cfg!(miri) { 70_000 } else { 400_000 };
        let data: Vec<u8> = (0..n).map(|i| (i % 253) as u8).collect();
        two.write("src", data.clone()).await.unwrap();
        assert_eq!(two.copy("src", "dst").await.unwrap(), n as u64);
        assert_eq!(two.read("dst").await.unwrap(), data);
    });
}

#[test]
fn path_rejection_never_touches_the_fs() {
    let env = Env::new("paths");
    std::fs::create_dir(env.root.join("inner")).unwrap();
    std::fs::write(env.root.join("secret"), b"s").unwrap();
    env.run(async {
        let root = env.dir().await;
        let d = root.open_dir("inner").await.unwrap();
        let bad: [&str; 5] = ["../secret", "..", "a/../../secret", "/etc/passwd", "x\0y"];
        for p in bad {
            assert_eq!(kind(d.metadata(p).await), ErrorKind::InvalidInput, "{p:?}");
            assert_eq!(kind(d.symlink_metadata(p).await), ErrorKind::InvalidInput);
            assert_eq!(kind(d.open_dir(p).await), ErrorKind::InvalidInput);
            assert_eq!(kind(d.open_file(p, OpenOptions::new().read(true)).await), ErrorKind::InvalidInput);
            assert_eq!(kind(d.create_dir(p).await), ErrorKind::InvalidInput);
            assert_eq!(kind(d.create_dir_all(p).await), ErrorKind::InvalidInput);
            assert_eq!(kind(d.remove_file(p).await), ErrorKind::InvalidInput);
            assert_eq!(kind(d.remove_dir(p).await), ErrorKind::InvalidInput);
            assert_eq!(kind(d.remove_dir_all(p).await), ErrorKind::InvalidInput);
            assert_eq!(kind(d.read_dir(p).await), ErrorKind::InvalidInput);
            assert_eq!(kind(d.read(p).await), ErrorKind::InvalidInput);
            assert_eq!(kind(d.write(p, "x").await), ErrorKind::InvalidInput);
            assert_eq!(kind(d.copy(p, "ok").await), ErrorKind::InvalidInput);
            assert_eq!(kind(d.copy("ok", p).await), ErrorKind::InvalidInput);
            assert_eq!(kind(d.try_exists(p).await), ErrorKind::InvalidInput);
        }
        assert_eq!(std::fs::read(env.root.join("secret")).unwrap(), b"s");
        assert!(!env.root.join("ok").exists() && !env.root.join("inner/ok").exists());
        // `..` can never be smuggled in through a file name containing dots only.
        assert!(sanitize(Path::new("a/..b/c.")).is_ok());
    });
}

#[test]
fn dropped_pending_futures_cancel_cleanly() {
    let env = Env::new("cancel");
    env.run(async {
        let d = env.dir().await;
        d.write("f", "0123456789").await.unwrap();
        let f = d.open_file("f", OpenOptions::new().read(true).write(true)).await.unwrap();
        {
            let mut a = Box::pin(f.read(vec![0; 4]));
            let mut b = Box::pin(f.write_at(b"zz".to_vec(), 0));
            let mut c = Box::pin(d.metadata("f"));
            let mut e = Box::pin(d.read("f"));
            let mut g = Box::pin(d.remove_dir_all("nothing"));
            let mut h = Box::pin(f.write_all(vec![b'q'; 100_000]));
            assert!(poll_once(&mut a).is_pending());
            assert!(poll_once(&mut b).is_pending());
            assert!(poll_once(&mut c).is_pending());
            assert!(poll_once(&mut e).is_pending());
            assert!(poll_once(&mut g).is_pending());
            assert!(poll_once(&mut h).is_pending());
        }
        let mut rd = d.read_dir(".").await.unwrap();
        {
            let mut n = Box::pin(rd.next_entry());
            assert!(poll_once(&mut n).is_pending());
        }
    });
    env.drain();
    // Everything still works afterwards.
    env.run(async {
        let d = env.dir().await;
        assert!(d.try_exists("f").await.unwrap());
        d.write("g", "ok").await.unwrap();
    });
}

#[test]
fn drop_without_close_submits_detached_close() {
    let env = Env::new("drop");
    env.run(async {
        let d = env.dir().await;
        d.write("f", "x").await.unwrap();
        let sub_fd;
        let file_fd;
        {
            let clone = d.clone();
            let sub = d.open_dir(".").await.unwrap();
            sub_fd = sub.raw_fd().unwrap();
            let file = d.open_file("f", OpenOptions::new().read(true)).await.unwrap();
            file_fd = file.raw_fd().unwrap();
            let _rd = d.read_dir(".").await.unwrap(); // its private fd is covered by the active-op count
            drop(clone); // not the last handle: nothing may be closed yet
            assert_eq!(env.lp.active(), 0);
            assert!(d.metadata("f").await.is_ok());
            assert!(env.lp.fstat(sub_fd).await.is_ok());
        }
        // `sub`, `file` and `rd` were dropped: three detached closes are in flight.
        assert_eq!(env.lp.active(), 3);
        env.drain();
        assert_eq!(env.lp.fstat(sub_fd).await.unwrap_err().raw_os_error(), Some(9), "dir fd closed");
        assert_eq!(env.lp.fstat(file_fd).await.unwrap_err().raw_os_error(), Some(9), "file fd closed");
        assert!(d.metadata("f").await.is_ok(), "the root dir is still open");

        // Last clone dropped -> close.
        let root_fd = d.raw_fd().unwrap();
        drop(d);
        assert_eq!(env.lp.active(), 1);
        env.drain();
        assert_eq!(env.lp.fstat(root_fd).await.unwrap_err().raw_os_error(), Some(9));
    });
}

#[test]
fn explicit_close_and_use_after_close() {
    let env = Env::new("close");
    env.run(async {
        let d = env.dir().await;
        let d2 = d.clone();
        let f = d.open_file("f", OpenOptions::new().write(true).create(true)).await.unwrap();
        f.close().await.unwrap();
        assert_eq!(f.close().await.unwrap_err().raw_os_error(), Some(9));
        assert_eq!(f.write(vec![1]).await.0.unwrap_err().raw_os_error(), Some(9));
        assert!(f.raw_fd().is_none());
        d.close().await.unwrap();
        assert_eq!(d2.metadata("f").await.unwrap_err().raw_os_error(), Some(9), "all clones see the close");
        assert_eq!(d2.close().await.unwrap_err().raw_os_error(), Some(9));
    });
    // No detached close was submitted for the already closed handles.
    assert_eq!(env.lp.active(), 0);
}

#[test]
fn drop_dir_then_loop_without_draining() {
    // The detached close is released by the loop's destroy (Miri checks the memory).
    let lp = Rc::new(Loop::new(Options::default()).unwrap());
    let root = std::env::temp_dir().join(format!("origine_fs_destroy_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    {
        let _guard = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let rt = Runtime::new(lp.clone());
        let d = rt.block_on(Dir::open_ambient(&lp, &root)).unwrap();
        drop(d);
        assert_eq!(lp.active(), 1);
        drop(rt);
        drop(lp);
    }
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn concurrent_tasks_share_a_dir() {
    let env = Env::new("conc");
    let n: usize = if cfg!(miri) { 12 } else { 100 };
    env.run(async {
        let d = env.dir().await;
        d.create_dir("out").await.unwrap();
        let mut set = JoinSet::bounded(8);
        for i in 0..n {
            let d = d.clone();
            set.spawn(async move {
                let p = format!("out/{i}");
                d.write(&p, format!("value-{i}")).await?;
                let back = d.read(&p).await?;
                assert_eq!(back, format!("value-{i}").as_bytes());
                Ok::<_, std::io::Error>(i)
            });
        }
        let mut got = set.join_all().await.unwrap().into_iter().collect::<Result<Vec<_>, _>>().unwrap();
        got.sort_unstable();
        assert_eq!(got, (0..n).collect::<Vec<_>>());
        let mut rd = d.read_dir("out").await.unwrap();
        let mut count = 0;
        while rd.next_entry().await.unwrap().is_some() {
            count += 1;
        }
        assert_eq!(count, n);
        let h = rt::spawn({
            let d = d.clone();
            async move { d.remove_dir_all("out").await }
        });
        h.await.unwrap().unwrap();
    });
    env.drain();
}
