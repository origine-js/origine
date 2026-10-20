use origine_io::rt::{self, Either, Elapsed, JoinError, JoinSet, Runtime};
use origine_io::{Loop, Mode, Options, flags};
use std::cell::{Cell, RefCell};
use std::future::Future;
use std::pin::Pin;
use std::rc::Rc;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};
use std::time::{Duration, Instant};

fn setup() -> (Rc<Loop>, Runtime) {
    let lp = Rc::new(Loop::new(Options::default()).expect("loop"));
    let rt = Runtime::new(lp.clone());
    (lp, rt)
}

/// Miri is slow: scale spacing between timers so ordering assertions stay meaningful.
fn ordered(n: u64) -> Duration {
    Duration::from_millis(if cfg!(miri) { n * 40 } else { n })
}

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

/// Run the loop until every op (including cancelled ones) has completed.
fn drain_loop(lp: &Loop) {
    let t0 = Instant::now();
    while lp.active() > 0 {
        lp.run(Mode::NoWait).unwrap();
        assert!(t0.elapsed() < Duration::from_secs(5), "ops never drained");
        std::thread::sleep(ms(1));
    }
}

fn poll_once<F: Future + Unpin>(f: &mut F) -> Poll<F::Output> {
    Pin::new(f).poll(&mut Context::from_waker(Waker::noop()))
}

#[test]
fn spawn_and_join_in_order() {
    let (_lp, rt) = setup();
    let log = Rc::new(RefCell::new(Vec::new()));
    let hs: Vec<_> = (0..4)
        .map(|i| {
            let log = log.clone();
            rt.spawn(async move {
                log.borrow_mut().push(i);
                i * 10
            })
        })
        .collect();
    let out = rt.block_on(async {
        let mut v = Vec::new();
        for h in hs {
            v.push(h.await.unwrap());
        }
        v
    });
    assert_eq!(out, [0, 10, 20, 30]);
    assert_eq!(*log.borrow(), [0, 1, 2, 3]);
    assert!(!rt.has_work());
}

#[test]
fn nested_spawn_from_task() {
    let (_lp, rt) = setup();
    let v = rt.block_on(async {
        let outer = rt::spawn(async {
            let inner = rt::spawn(async { 7 });
            inner.await.unwrap() + 1
        });
        outer.await.unwrap()
    });
    assert_eq!(v, 8);
}

#[test]
fn drop_handle_detaches() {
    let (_lp, rt) = setup();
    let hit = Rc::new(Cell::new(false));
    let h = hit.clone();
    drop(rt.spawn(async move { h.set(true) }));
    rt.run_until_idle();
    assert!(hit.get());
    assert_eq!(rt.task_count(), 0);
}

#[test]
fn sleep_ordering() {
    let (_lp, rt) = setup();
    let log = Rc::new(RefCell::new(Vec::new()));
    let t0 = Instant::now();
    for (i, d) in [(0, 60), (1, 10), (2, 35)] {
        let log = log.clone();
        rt.spawn(async move {
            rt::sleep(ordered(d)).await.unwrap();
            log.borrow_mut().push(i);
        });
    }
    while rt.has_work() {
        rt.tick(Mode::Once);
    }
    assert_eq!(*log.borrow(), [1, 2, 0]);
    assert!(t0.elapsed() >= ordered(55));
}

#[test]
fn timeout_elapses_and_passes() {
    let (lp, rt) = setup();
    let r = rt.block_on(rt.timeout(ms(10), rt.sleep(Duration::from_secs(3600))));
    assert_eq!(r.map(|_| ()), Err(Elapsed));
    let r = rt.block_on(rt.timeout(Duration::from_secs(3600), async { 5 }));
    assert_eq!(r, Ok(5));
    drain_loop(&lp);
}

#[test]
fn select_cancels_loser() {
    let (lp, rt) = setup();
    let r = rt.block_on(rt::select(rt.sleep(ms(5)), rt.sleep(Duration::from_secs(3600))));
    assert!(matches!(r, Either::Left(Ok(()))));
    // The loser's timeout op is cancelled and completes through the loop.
    drain_loop(&lp);
    assert_eq!(lp.active(), 0);
}

#[test]
fn join_two() {
    let (_lp, rt) = setup();
    let (a, b) = rt.block_on(rt::join(
        async {
            rt.sleep(ms(10)).await.unwrap();
            1
        },
        async { 2 },
    ));
    assert_eq!((a, b), (1, 2));
}

#[test]
fn joinset_bounded_concurrency() {
    let (_lp, rt) = setup();
    let cur = Rc::new(Cell::new(0usize));
    let peak = Rc::new(Cell::new(0usize));
    let out = rt.block_on(async {
        let mut set = JoinSet::bounded(3);
        for i in 0..10u32 {
            let (cur, peak) = (cur.clone(), peak.clone());
            set.spawn(async move {
                cur.set(cur.get() + 1);
                peak.set(peak.get().max(cur.get()));
                rt::sleep(ms(2)).await.unwrap();
                cur.set(cur.get() - 1);
                i
            });
        }
        assert_eq!(set.len(), 10);
        let mut v = set.join_all().await.unwrap();
        v.sort();
        v
    });
    assert_eq!(out, (0..10).collect::<Vec<_>>());
    assert_eq!(peak.get(), 3);
    assert_eq!(cur.get(), 0);
}

#[test]
fn joinset_unbounded_and_join_next() {
    let (_lp, rt) = setup();
    let peak = Rc::new(Cell::new(0usize));
    let cur = Rc::new(Cell::new(0usize));
    rt.block_on(async {
        let mut set = JoinSet::new();
        for d in [30u64, 10, 20] {
            let (cur, peak) = (cur.clone(), peak.clone());
            set.spawn(async move {
                cur.set(cur.get() + 1);
                peak.set(peak.get().max(cur.get()));
                rt::sleep(ordered(d)).await.unwrap();
                cur.set(cur.get() - 1);
                d
            });
        }
        let mut order = Vec::new();
        while let Some(r) = set.join_next().await {
            order.push(r.unwrap());
        }
        assert_eq!(order, [10, 20, 30]);
        assert!(set.is_empty());
    });
    assert_eq!(peak.get(), 3);
}

#[test]
fn joinset_drop_aborts() {
    let (lp, rt) = setup();
    rt.block_on(async {
        let mut set = JoinSet::bounded(1);
        set.spawn(async { rt::sleep(Duration::from_secs(3600)).await.unwrap() });
        set.spawn(async { rt::sleep(Duration::from_secs(3600)).await.unwrap() });
        rt::yield_now().await;
        drop(set);
    });
    assert_eq!(rt.task_count(), 0);
    drain_loop(&lp);
}

#[test]
fn abort_cancels_inflight_read() {
    let (lp, rt) = setup();
    let dir = std::env::temp_dir().join(format!("origine_rt_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("f");
    std::fs::write(&path, b"data").unwrap();
    let fd = rt.block_on(lp.open(&path, flags::RDONLY, 0)).unwrap();

    let lp2 = lp.clone();
    let mut h = rt.spawn(async move {
        let (r, _buf) = lp2.read(fd, vec![0; 16], Some(0)).await;
        r.unwrap()
    });
    rt.run_until_idle(); // task submitted the read and is parked on it
    assert!(lp.active() >= 1);
    h.abort();
    assert!(matches!(poll_once(&mut h), Poll::Ready(Err(JoinError::Cancelled))));
    assert_eq!(rt.task_count(), 0);
    // The op memory is kept until the callback runs; the loop then drains.
    drain_loop(&lp);
    rt.block_on(lp.close(fd)).unwrap();
    std::fs::remove_dir_all(dir).unwrap();
}

struct Flag(Rc<Cell<bool>>);
impl Drop for Flag {
    fn drop(&mut self) {
        self.0.set(true);
    }
}

#[test]
fn drop_runtime_cancels_pending_tasks() {
    let (lp, rt) = setup();
    let dropped = Rc::new(Cell::new(false));
    let d = dropped.clone();
    let mut h = rt.spawn(async move {
        let _guard = Flag(d);
        rt::sleep(Duration::from_secs(3600)).await.unwrap();
    });
    rt.run_until_idle();
    assert_eq!(lp.active(), 1);
    drop(rt);
    assert!(dropped.get());
    assert!(matches!(poll_once(&mut h), Poll::Ready(Err(JoinError::Cancelled))));
    drain_loop(&lp);
    // Spawning through a stale handle is cancelled right away.
}

#[test]
fn panic_in_task_is_reported() {
    let (_lp, rt) = setup();
    let bad = rt.spawn(async {
        if true {
            panic!("boom");
        }
    });
    let good = rt.spawn(async { 1 });
    let (e, g) = rt.block_on(async { (bad.await, good.await) });
    let e = e.unwrap_err();
    assert!(e.is_panic());
    assert_eq!(*e.into_panic().downcast::<&str>().unwrap(), "boom");
    assert_eq!(g.unwrap(), 1);
    // Still usable.
    assert_eq!(rt.block_on(rt.spawn(async { 2 })).unwrap(), 2);
}

struct Gate {
    state: Arc<Mutex<(bool, Option<Waker>)>>,
}
impl Future for Gate {
    type Output = ();
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        let mut s = self.state.lock().unwrap();
        if s.0 {
            Poll::Ready(())
        } else {
            s.1 = Some(cx.waker().clone());
            Poll::Pending
        }
    }
}

#[test]
fn wake_from_another_thread() {
    let (lp, rt) = setup();
    let state = Arc::new(Mutex::new((false, None::<Waker>)));
    let s2 = state.clone();
    let t = std::thread::spawn(move || {
        std::thread::sleep(ms(30));
        let w = {
            let mut s = s2.lock().unwrap();
            s.0 = true;
            s.1.take()
        };
        if let Some(w) = w {
            w.wake();
        }
    });
    // No loop op is active: only the cross-thread wake can end `run(Once)`.
    assert_eq!(lp.active(), 0);
    let h = rt.spawn(async move {
        Gate { state }.await;
        42
    });
    let v = rt.block_on(h).unwrap();
    assert_eq!(v, 42);
    t.join().unwrap();
}

#[test]
fn budget_keeps_tasks_fair() {
    let (_lp, rt) = setup();
    let log = Rc::new(RefCell::new(Vec::new()));
    let l = log.clone();
    rt.spawn(async move {
        for _ in 0..2000 {
            rt::consume_budget().await;
        }
        l.borrow_mut().push("hog done");
    });
    let l = log.clone();
    rt.spawn(async move { l.borrow_mut().push("other") });
    rt.run_until_idle();
    assert_eq!(*log.borrow(), ["other", "hog done"]);
}

#[test]
fn yield_now_interleaves() {
    let (_lp, rt) = setup();
    let log = Rc::new(RefCell::new(Vec::new()));
    for name in ["a", "b"] {
        let log = log.clone();
        rt.spawn(async move {
            for i in 0..2 {
                log.borrow_mut().push(format!("{name}{i}"));
                rt::yield_now().await;
            }
        });
    }
    rt.run_until_idle();
    assert_eq!(*log.borrow(), ["a0", "b0", "a1", "b1"]);
}

#[test]
fn tick_reports_polls_and_has_work() {
    let (_lp, rt) = setup();
    assert!(!rt.has_work());
    rt.spawn(async {
        rt::sleep(ms(5)).await.unwrap();
    });
    assert!(rt.has_work());
    let mut polls = 0;
    while rt.has_work() {
        polls += rt.tick(Mode::Once);
    }
    assert!(polls >= 2);
}
