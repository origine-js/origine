//! `Grant` on the real library (set `ORIGINE_IO_LIB`) and, under Miri, on `origine_io`'s mock.

use origine_api_core::{NativeError, errno};
use origine_api_fs::{DirListing, Grant, Stat};
use origine_io::fs::Dir;
use origine_io::rt::{self, Runtime};
use origine_io::{Loop, Mode, Options};
use std::future::Future;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// The tests share descriptor numbers (a process-wide fd table), so run them one at a time.
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
        let root = std::env::temp_dir().join(format!("origine_apifs_{}_{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        Env { lp, rt, root, _guard: guard }
    }

    fn run<F: Future>(&self, f: F) -> F::Output {
        self.rt.block_on(f)
    }

    async fn grant(&self, write: bool) -> Rc<Grant> {
        let root = Dir::open_ambient(&self.lp, &self.root).await.unwrap();
        Grant::new(1, write, root)
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

const R: u32 = 0;
const W: u32 = 1;
const CREATE_TRUNC: u32 = 7;
const EXCL: u32 = 11;

fn code<T, F>(r: Result<F, NativeError>) -> u32
where
    F: Future<Output = Result<T, NativeError>>,
    T: std::fmt::Debug,
{
    match r {
        Ok(_) => panic!("expected an error at call time"),
        Err(NativeError::Errno(code)) => code,
        Err(other) => panic!("not an errno: {other}"),
    }
}

async fn code_of<T: std::fmt::Debug>(r: Result<impl Future<Output = Result<T, NativeError>>, NativeError>) -> u32 {
    let result = match r {
        Ok(future) => future.await,
        Err(err) => Err(err),
    };
    match result {
        Err(NativeError::Errno(code)) => code,
        Err(other) => panic!("not an errno: {other}"),
        Ok(value) => panic!("expected an error, got {value:?}"),
    }
}

#[test]
fn file_roundtrip_through_handles() {
    let env = Env::new("roundtrip");
    env.run(async {
        let g = env.grant(true).await;
        let id = g.open_file(0, "a.txt", CREATE_TRUNC).unwrap().await.unwrap();
        assert_eq!(id, 1);
        g.write_all(id, b"hello world".to_vec()).unwrap().await.unwrap();
        assert_eq!(g.file_stat(id).unwrap().await.unwrap(), Stat { kind: 1, size: 11.0 });
        g.file_pwrite_all(id, b"HELLO".to_vec(), 0).unwrap().await.unwrap();
        assert_eq!(g.file_read(id, 5, Some(6)).unwrap().await.unwrap(), b"world");
        assert_eq!(g.file_read(id, 0, None).unwrap().await.unwrap(), b"");
        g.file_set_length(id, 5).unwrap().await.unwrap();
        g.file_sync(id).unwrap().await.unwrap();
        g.close(id).unwrap().await.unwrap();
        assert_eq!(std::fs::read(env.root.join("a.txt")).unwrap(), b"HELLO");

        let id = g.open_file(0, "a.txt", R).unwrap().await.unwrap();
        assert_eq!(id, 1, "a closed slot is reused");
        assert_eq!(g.read_all(id, usize::MAX).unwrap().await.unwrap(), b"HELLO");
        g.close(id).unwrap().await.unwrap();

        // Streaming read and partial limit.
        let id = g.open_file(0, "a.txt", R).unwrap().await.unwrap();
        assert_eq!(g.file_read(id, 2, None).unwrap().await.unwrap(), b"HE");
        assert_eq!(g.read_all(id, 2).unwrap().await.unwrap(), b"LL");
        g.close(id).unwrap().await.unwrap();
    });
    env.drain();
}

#[test]
fn read_all_stops_at_the_limit_without_error() {
    let env = Env::new("limit");
    std::fs::write(env.root.join("big"), vec![7u8; 200_000]).unwrap();
    env.run(async {
        let g = env.grant(false).await;
        let id = g.open_file(0, "big", R).unwrap().await.unwrap();
        assert_eq!(g.read_all(id, 70_000).unwrap().await.unwrap().len(), 70_000);
        assert_eq!(g.read_all(id, usize::MAX).unwrap().await.unwrap().len(), 130_000);
        assert_eq!(g.read_all(id, usize::MAX).unwrap().await.unwrap().len(), 0);
        g.close(id).unwrap().await.unwrap();
    });
    env.drain();
}

#[test]
fn read_only_grants_deny_every_mutation() {
    let env = Env::new("readonly");
    std::fs::write(env.root.join("f"), "x").unwrap();
    std::fs::create_dir(env.root.join("d")).unwrap();
    env.run(async {
        let g = env.grant(false).await;
        assert!(!g.is_writable());
        for bits in [W, 2, 4, 8, CREATE_TRUNC] {
            assert_eq!(code(g.open_file(0, "f", bits)), errno::ACCESS_DENIED, "bits {bits}");
        }
        let f = g.open_file(0, "f", R).unwrap().await.unwrap();
        assert_eq!(code(g.create_dir(0, "n")), errno::ACCESS_DENIED);
        assert_eq!(code(g.delete_file(0, "f")), errno::ACCESS_DENIED);
        assert_eq!(code(g.create_dir_path(0, "a/b")), errno::ACCESS_DENIED);
        assert_eq!(code(g.delete_dir(0, "d")), errno::ACCESS_DENIED);
        assert_eq!(code(g.delete_tree(0, "d")), errno::ACCESS_DENIED);
        assert_eq!(code(g.rename(0, "f", 0, "g")), errno::ACCESS_DENIED);
        assert_eq!(code(g.write_all(f, vec![1])), errno::ACCESS_DENIED);
        assert_eq!(code(g.file_write(f, vec![1])), errno::ACCESS_DENIED);
        assert_eq!(code(g.file_pwrite_all(f, vec![1], 0)), errno::ACCESS_DENIED);
        assert_eq!(code(g.file_set_length(f, 0)), errno::ACCESS_DENIED);
        // Reading and syncing stay possible.
        assert_eq!(g.read_all(f, 10).unwrap().await.unwrap(), b"x");
        g.file_sync(f).unwrap().await.unwrap();
        g.close(f).unwrap().await.unwrap();
        assert!(std::fs::exists(env.root.join("f")).unwrap());
    });
    env.drain();
}

#[test]
fn paths_are_validated_before_anything_else() {
    let env = Env::new("paths");
    env.run(async {
        let g = env.grant(false).await; // read-only: the path error must still win over AccessDenied
        for bad in ["../x", "a/../b", "/etc/passwd", "a\0b"] {
            assert_eq!(code(g.open_file(0, bad, W)), errno::INVALID_PATH, "{bad:?}");
            assert_eq!(code(g.open_dir(0, bad)), errno::INVALID_PATH, "{bad:?}");
            assert_eq!(code(g.stat(0, bad)), errno::INVALID_PATH, "{bad:?}");
            assert_eq!(code(g.delete_tree(0, bad)), errno::INVALID_PATH, "{bad:?}");
        }
        assert_eq!(code(g.open_file(0, "", R)), errno::INVALID_PATH);
        assert_eq!(code(g.create_dir(0, "")), errno::INVALID_PATH);
        for root in ["", ".", "./.", "a/.."] {
            // The root cannot be destroyed (`a/..` is rejected lexically, the others name the root).
            assert_eq!(code(g.delete_dir(0, root)), errno::INVALID_PATH, "{root:?}");
        }
        // The root can be stat'ed and opened by an empty path or ".".
        assert_eq!(g.stat(0, "").unwrap().await.unwrap().kind, 2);
        assert_eq!(g.stat(0, ".").unwrap().await.unwrap().kind, 2);
        let d = g.open_dir(0, "").unwrap().await.unwrap();
        assert_eq!(d, 1);
        g.close_dir(d).unwrap().await.unwrap();
    });
    env.drain();
}

#[test]
fn handles_are_checked_per_table_and_state() {
    let env = Env::new("handles");
    std::fs::write(env.root.join("f"), "x").unwrap();
    env.run(async {
        let g = env.grant(true).await;
        assert_eq!(code(g.file_stat(0)), errno::BAD_HANDLE);
        assert_eq!(code(g.file_stat(9)), errno::BAD_HANDLE);
        assert_eq!(code(g.stat(5, "")), errno::BAD_HANDLE);
        assert_eq!(code(g.close_dir(0)), errno::BAD_HANDLE, "the root cannot be closed");

        let f = g.open_file(0, "f", R).unwrap().await.unwrap();
        // Dir and file ids are separate namespaces.
        assert_eq!(code(g.stat(f, "")), errno::BAD_HANDLE);
        let close = g.close(f).unwrap();
        assert_eq!(code(g.file_stat(f)), errno::STALE_HANDLE, "closing");
        assert_eq!(code(g.close(f)), errno::STALE_HANDLE, "closing twice");
        close.await.unwrap();
        assert_eq!(code(g.file_stat(f)), errno::BAD_HANDLE, "closed");
        assert_eq!(code(g.close(f)), errno::BAD_HANDLE);
    });
    env.drain();
}

#[test]
fn close_waits_for_operations_in_flight_and_ids_are_not_reused_meanwhile() {
    let env = Env::new("inflight");
    std::fs::write(env.root.join("f"), "0123456789").unwrap();
    env.run(async {
        let g = env.grant(true).await;
        let f = g.open_file(0, "f", R).unwrap().await.unwrap();
        // Started (guard taken) but not polled yet.
        let read = g.file_read(f, 4, Some(2)).unwrap();
        let close = g.close(f).unwrap();
        // The slot is closing, so a new file gets another id.
        let other = g.open_file(0, "f", R).unwrap().await.unwrap();
        assert_ne!(other, f);
        let order = Rc::new(std::cell::RefCell::new(Vec::new()));
        let (o1, o2) = (order.clone(), order.clone());
        let ((), data) = rt::join(
            async move {
                close.await.unwrap();
                o1.borrow_mut().push("closed");
            },
            async move {
                let data = read.await.unwrap();
                o2.borrow_mut().push("read");
                data
            },
        )
        .await;
        assert_eq!(data, b"2345");
        assert_eq!(*order.borrow(), ["read", "closed"]);
        // Now the slot is free again.
        assert_eq!(g.open_file(0, "f", R).unwrap().await.unwrap(), f);
        g.close(other).unwrap().await.unwrap();
    });
    env.drain();
}

#[test]
fn a_dropped_operation_releases_its_handle() {
    let env = Env::new("dropped");
    std::fs::write(env.root.join("f"), "abc").unwrap();
    env.run(async {
        let g = env.grant(true).await;
        let f = g.open_file(0, "f", R).unwrap().await.unwrap();
        drop(g.read_all(f, 10).unwrap());
        g.close(f).unwrap().await.unwrap();
        assert_eq!(g.open_handles(), 0);
    });
    env.drain();
}

#[test]
fn directories_listing_and_tree_operations() {
    let env = Env::new("tree");
    env.run(async {
        let g = env.grant(true).await;
        g.create_dir_path(0, "a/b/c").unwrap().await.unwrap();
        g.create_dir_path(0, "a/b/c").unwrap().await.unwrap();
        g.create_dir(0, "d").unwrap().await.unwrap();
        assert_eq!(code_of(g.create_dir(0, "d")).await, errno::PATH_ALREADY_EXISTS);
        let f = g.open_file(0, "a/b/f.txt", CREATE_TRUNC).unwrap().await.unwrap();
        g.write_all(f, b"data".to_vec()).unwrap().await.unwrap();
        g.close(f).unwrap().await.unwrap();
        assert_eq!(code_of(g.open_file(0, "a/b/f.txt", EXCL)).await, errno::PATH_ALREADY_EXISTS);

        let a = g.open_dir(0, "a").unwrap().await.unwrap();
        let DirListing(mut entries) = g.read_dir(a).unwrap().await.unwrap();
        entries.sort();
        assert_eq!(entries, [("b".to_owned(), 2)]);
        let b = g.open_dir(a, "b").unwrap().await.unwrap();
        let DirListing(mut entries) = g.read_dir(b).unwrap().await.unwrap();
        entries.sort();
        assert_eq!(entries, [("c".to_owned(), 2), ("f.txt".to_owned(), 1)]);
        let root = g.read_dir(0).unwrap().await.unwrap().0.len();
        assert_eq!(root, 2);

        assert_eq!(g.stat(a, "b/f.txt").unwrap().await.unwrap(), Stat { kind: 1, size: 4.0 });
        assert_eq!(code_of(g.stat(a, "nope")).await, errno::FILE_NOT_FOUND);
        assert_eq!(code_of(g.open_dir(a, "b/f.txt")).await, errno::NOT_DIR);
        assert_eq!(code_of(g.open_file(0, "a", R)).await, errno::IS_DIR);

        // rename between directories, then delete.
        g.rename(b, "f.txt", 0, "moved.txt").unwrap().await.unwrap();
        assert!(env.root.join("moved.txt").exists());
        assert_eq!(code_of(g.delete_dir(0, "a")).await, errno::DIR_NOT_EMPTY);
        g.delete_file(0, "moved.txt").unwrap().await.unwrap();
        assert_eq!(code_of(g.delete_file(0, "moved.txt")).await, errno::FILE_NOT_FOUND);

        g.close_dir(b).unwrap().await.unwrap();
        g.close_dir(a).unwrap().await.unwrap();
        g.delete_tree(0, "a").unwrap().await.unwrap();
        g.delete_tree(0, "a").unwrap().await.unwrap(); // missing is fine
        g.delete_dir(0, "d").unwrap().await.unwrap();
        assert!(std::fs::read_dir(&env.root).unwrap().next().is_none());
    });
    env.drain();
}

#[test]
fn delete_tree_removes_files_and_unlinks_symlinks() {
    let env = Env::new("deltree");
    let outside = env.root.with_extension("outside");
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("keep"), "k").unwrap();
    std::fs::create_dir(env.root.join("sub")).unwrap();
    std::fs::write(env.root.join("sub/f"), "x").unwrap();
    std::fs::write(env.root.join("plain"), "x").unwrap();
    std::os::unix::fs::symlink(&outside, env.root.join("link")).unwrap();
    env.run(async {
        let g = env.grant(true).await;
        g.delete_tree(0, "plain").unwrap().await.unwrap();
        g.delete_tree(0, "link").unwrap().await.unwrap();
        g.delete_tree(0, "sub").unwrap().await.unwrap();
        assert!(std::fs::read_dir(&env.root).unwrap().next().is_none());
        assert!(outside.join("keep").exists(), "a symlink is unlinked, never followed");
    });
    env.drain();
    let _ = std::fs::remove_dir_all(&outside);
}

#[test]
fn many_concurrent_operations_complete() {
    let env = Env::new("concurrent");
    for i in 0..20 {
        std::fs::write(env.root.join(format!("f{i}")), format!("content {i}")).unwrap();
    }
    env.run(async {
        let g = env.grant(false).await;
        let mut set = rt::JoinSet::new();
        for i in 0..20 {
            let g = g.clone();
            set.spawn(async move {
                let id = g.open_file(0, &format!("f{i}"), R).unwrap().await.unwrap();
                let data = g.read_all(id, usize::MAX).unwrap().await.unwrap();
                g.close(id).unwrap().await.unwrap();
                (i, data)
            });
        }
        let mut seen = 0;
        while let Some(done) = set.join_next().await {
            let (i, data) = done.unwrap();
            assert_eq!(data, format!("content {i}").into_bytes());
            seen += 1;
        }
        assert_eq!(seen, 20);
        assert_eq!(g.open_handles(), 0);
    });
    env.drain();
}

#[test]
fn futures_are_inert_until_polled_and_cancel_cleanly() {
    let env = Env::new("cancel");
    std::fs::write(env.root.join("f"), "abc").unwrap();
    env.run(async {
        let g = env.grant(true).await;
        let mut open = Box::pin(g.open_file(0, "f", R).unwrap());
        // Poll once so the op is submitted, then drop it: the op is cancelled, the table untouched.
        let waker = std::task::Waker::noop();
        let mut cx = std::task::Context::from_waker(waker);
        let _ = open.as_mut().poll(&mut cx);
        drop(open);
        assert_eq!(g.open_handles(), 0);
    });
    env.drain();
}

/// Stands in for a pinned V8 backing store: heap memory handed out as a raw pointer, freed (and
/// the flag set) only when the owner drops, like the last `SharedRef` of a store.
struct Store {
    raw: *mut [u8],
    freed: Rc<std::cell::Cell<bool>>,
}

impl Drop for Store {
    fn drop(&mut self) {
        // SAFETY: `raw` came from `Box::into_raw` in `pinned` and is reclaimed exactly once, here.
        drop(unsafe { Box::from_raw(self.raw) });
        self.freed.set(true);
    }
}

/// A region over `data` and the flag that says whether its memory was released. `init` selects
/// `new` (bytes initialized, a source) or `new_uninit` (a sink).
fn pinned(data: &[u8], init: bool) -> (origine_io::RawRegion, Rc<std::cell::Cell<bool>>) {
    let freed = Rc::new(std::cell::Cell::new(false));
    let raw = Box::into_raw(data.to_vec().into_boxed_slice());
    let ptr = std::ptr::NonNull::new(raw.cast::<u8>()).expect("non-null");
    let owner = Box::new(Store { raw, freed: Rc::clone(&freed) });
    let region = if init {
        // SAFETY: `ptr..ptr + len` is the live heap block `raw`, which only the owner frees (when
        // the region drops); nothing else touches it while the region exists; it does not move.
        unsafe { origine_io::RawRegion::new(ptr, data.len(), owner) }
    } else {
        // SAFETY: as above (the bytes are initialized here, which `new_uninit` does not need).
        unsafe { origine_io::RawRegion::new_uninit(ptr, data.len(), owner) }
    };
    (region, freed)
}

#[test]
fn pinned_regions_are_written_in_place_and_released_after_the_op() {
    let env = Env::new("pinned_write");
    env.run(async {
        let g = env.grant(true).await;
        let id = g.open_file(0, "w", CREATE_TRUNC).unwrap().await.unwrap();
        let (region, freed) = pinned(b"hello", true);
        assert_eq!(g.file_write(id, region).unwrap().await.unwrap(), 5);
        assert!(freed.get(), "the store is released once the write completed");
        let (region, freed) = pinned(b"WORLD", true);
        g.write_all(id, region).unwrap().await.unwrap();
        assert!(freed.get());
        let (region, _) = pinned(b"!!", true);
        g.file_pwrite_all(id, region, 10).unwrap().await.unwrap();
        g.close(id).unwrap().await.unwrap();
        assert_eq!(std::fs::read(env.root.join("w")).unwrap(), b"helloWORLD!!");
    });
    env.drain();
}

#[test]
fn pinned_reads_fill_the_region_and_return_the_owner() {
    let env = Env::new("pinned_read");
    std::fs::write(env.root.join("r"), "0123456789").unwrap();
    env.run(async {
        let g = env.grant(false).await;
        let id = g.open_file(0, "r", R).unwrap().await.unwrap();
        let (region, freed) = pinned(&[b'.'; 4], false);
        let (n, mut region) = g.file_read_into(id, region, Some(3)).unwrap().await.unwrap();
        assert_eq!(n, 4);
        assert!(!freed.get(), "the store lives while the caller holds the region");
        // The region is ours again (the op is done) and `n` bytes were initialized.
        let ptr = origine_io::IoBufMut::stable_mut_ptr(&mut region);
        // SAFETY: `ptr` is the region's live block and `n` bytes of it are initialized.
        let bytes = unsafe { std::slice::from_raw_parts(ptr, n) };
        assert_eq!(bytes, b"3456");
        drop(region.into_owner());
        assert!(freed.get());

        // Streaming read continues at the position; a short read at the end reports the count.
        let (region, _) = pinned(&[0; 100], false);
        let (n, region) = g.file_read_into(id, region, None).unwrap().await.unwrap();
        assert_eq!(n, 10);
        assert_eq!(origine_io::IoBuf::bytes_init(&region), 10);
        let (region, _) = pinned(&[0; 8], false);
        let (n, _) = g.file_read_into(id, region, None).unwrap().await.unwrap();
        assert_eq!(n, 0, "end of file");
        g.close(id).unwrap().await.unwrap();
    });
    env.drain();
}

#[test]
fn zero_length_pinned_buffers_complete_without_io() {
    let env = Env::new("pinned_empty");
    env.run(async {
        let g = env.grant(true).await;
        let id = g.open_file(0, "z", CREATE_TRUNC).unwrap().await.unwrap();
        let (region, freed) = pinned(b"", true);
        assert_eq!(g.file_write(id, region).unwrap().await.unwrap(), 0);
        assert!(freed.get());
        let (region, _) = pinned(b"", true);
        g.file_pwrite_all(id, region, 0).unwrap().await.unwrap();
        let (region, _) = pinned(b"", false);
        let (n, _) = g.file_read_into(id, region, Some(0)).unwrap().await.unwrap();
        assert_eq!(n, 0);
        assert_eq!(g.file_stat(id).unwrap().await.unwrap().size, 0.0);
        g.close(id).unwrap().await.unwrap();
    });
    env.drain();
}

#[test]
fn the_buffer_is_made_only_after_the_checks_pass() {
    let env = Env::new("pinned_order");
    std::fs::write(env.root.join("f"), "x").unwrap();
    env.run(async {
        let called = std::cell::Cell::new(0);
        let make = || {
            called.set(called.get() + 1);
            Ok(vec![0u8; 1])
        };
        let read_only = env.grant(false).await;
        let id = read_only.open_file(0, "f", R).unwrap().await.unwrap();
        assert_eq!(code(read_only.file_write_with(id, Box::new(make))), errno::ACCESS_DENIED);
        assert_eq!(code(read_only.write_all_with(id, Box::new(make))), errno::ACCESS_DENIED);
        assert_eq!(code(read_only.file_pwrite_all_with(id, 0, Box::new(make))), errno::ACCESS_DENIED);
        assert_eq!(code(read_only.file_read_into_with(99, None, Box::new(make))), errno::BAD_HANDLE);
        assert_eq!(called.get(), 0, "a rejected call must not touch the guest buffer");
        // A failing `make` fails the call and releases the handle again.
        let failed = read_only.file_read_into_with(id, None, Box::new(|| Err::<Vec<u8>, _>(NativeError::Errno(errno::STALE_HANDLE))));
        assert_eq!(code(failed), errno::STALE_HANDLE);
        assert_eq!(read_only.file_read_into_with(id, None, Box::new(make)).unwrap().await.unwrap().0, 1);
        assert_eq!(called.get(), 1);
        read_only.close(id).unwrap().await.unwrap();
    });
    env.drain();
}

#[test]
fn a_dropped_pinned_op_keeps_its_memory_until_the_loop_has_run_it() {
    let env = Env::new("pinned_cancel");
    std::fs::write(env.root.join("f"), "abcdef").unwrap();
    env.run(async {
        let g = env.grant(false).await;
        let id = g.open_file(0, "f", R).unwrap().await.unwrap();
        let (region, freed) = pinned(&[0; 6], false);
        let mut read = Box::pin(g.file_read_into(id, region, Some(0)).unwrap());
        let mut cx = std::task::Context::from_waker(std::task::Waker::noop());
        let _ = read.as_mut().poll(&mut cx); // submitted
        drop(read); // cancel-on-drop: the op owns the region until its completion callback
        assert!(!freed.get() || env.lp.active() == 0, "memory must not be freed while the op is active");
        env.drain();
        assert!(freed.get(), "released by the completion callback");
        assert_eq!(g.open_handles(), 1);
        g.close(id).unwrap().await.unwrap();
    });
    env.drain();
}
