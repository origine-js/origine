# TCP ping-pong benchmark

Echo server + ping-pong client in one process, one OS thread, loopback 127.0.0.1, TCP_NODELAY.
A round trip = send a message, wait for the full echo (partial reads handled), repeat. Length is
checked every round; first/last byte of every received chunk are checked against the expected
stream (8-byte sequence number + pattern).

Implementations: origine `rt` + `Loop` (Rust, `Backend::Auto` = kqueue+GCD on macOS), Bun native
(`Bun.listen/connect`), Bun `node:net`, Deno native (`Deno.listen/connect`), Deno `node:net`.

## Run

```sh
# 1. static lib (build.zig links its own copy but has no install step); ReleaseFast
zig build-lib -static -lc -OReleaseFast --name origine_io \
  --dep @io -Mroot=<repo>/src/io/lib.zig --dep @safe -M@io=<repo>/src/io/io.zig -M@safe=<repo>/src/safe.zig   # run in an empty dir
# 2. Rust bench (standalone crate, not in the rust/ workspace)
cd bench/tcp/rust && ORIGINE_IO_LIB=<dir with liborigine_io.a> cargo +nightly-2026-10-19 build --release
# 3. one cell
bench/tcp/rust/target/release/tcp_bench <size> <conns> [warmup_s=1] [measure_s=3]
bun bench.js <native|node> <size> <conns> [warmup_s] [measure_s]
deno run -A bench.js <native|node> <size> <conns> [warmup_s] [measure_s]
# 4. full matrix (3 reps per cell, median by rt/s, implementations interleaved)
bun bench/tcp/run.js <out_dir> 1 3 3
```

Each run is a fresh process: 1 s warmup, 3 s measured; only rounds that start and finish inside the
window are counted. Raw runs: `results.jsonl`.

## Results

Apple M4 Max, macOS 27.2, Bun 1.3.12, Deno 2.9.7, nightly-2026-10-19. Median of 3 runs per cell.

| size | conns | origine rt | Bun native | Bun node:net | Deno native | Deno node:net |
|---|---|---|---|---|---|---|
| 16 B | 1 | 35,959 rt/s<br>p50 27.0 us / p99 43.2 us | 37,566 rt/s<br>p50 25.7 us / p99 42.0 us | 36,095 rt/s<br>p50 26.2 us / p99 50.4 us | 32,194 rt/s<br>p50 29.6 us / p99 49.0 us | 32,556 rt/s<br>p50 29.3 us / p99 50.4 us |
| 16 B | 64 | 89,083 rt/s<br>p50 703.4 us / p99 881.3 us | 119,712 rt/s<br>p50 523.8 us / p99 689.8 us | 106,313 rt/s<br>p50 591.3 us / p99 823.9 us | 89,846 rt/s<br>p50 691.7 us / p99 1.13 ms | 75,438 rt/s<br>p50 836.3 us / p99 993.2 us |
| 1 KiB | 1 | 35,523 rt/s<br>p50 27.4 us / p99 41.5 us | 36,995 rt/s<br>p50 26.2 us / p99 40.0 us | 36,998 rt/s<br>p50 25.5 us / p99 44.1 us | 32,738 rt/s<br>p50 29.8 us / p99 56.4 us | 32,939 rt/s<br>p50 29.5 us / p99 49.6 us |
| 1 KiB | 64 | 85,809 rt/s<br>p50 717.9 us / p99 1.23 ms | 106,816 rt/s<br>p50 572.5 us / p99 1.04 ms | 98,758 rt/s<br>p50 626.8 us / p99 1.03 ms | 80,099 rt/s<br>p50 773.0 us / p99 1.15 ms | 72,296 rt/s<br>p50 862.5 us / p99 1.17 ms |
| 64 KiB | 1 | 19,403 rt/s<br>p50 49.0 us / p99 73.2 us | 18,862 rt/s<br>p50 48.8 us / p99 121.0 us | 18,468 rt/s<br>p50 50.2 us / p99 93.1 us | 16,431 rt/s<br>p50 58.2 us / p99 79.2 us | 15,607 rt/s<br>p50 60.4 us / p99 81.4 us |
| 64 KiB | 64 | 32,136 rt/s<br>p50 1.96 ms / p99 2.89 ms | 33,421 rt/s<br>p50 1.90 ms / p99 2.45 ms | 32,469 rt/s<br>p50 1.95 ms / p99 2.33 ms | 31,186 rt/s<br>p50 2.04 ms / p99 2.31 ms | 30,249 rt/s<br>p50 2.02 ms / p99 3.43 ms |

## Caveats

- Client and server share one thread, so with 64 connections latency is dominated by queueing
  (each round trip waits behind the others); p50/p99 there are not per-request service times.
- origine: every send/recv allocates an op (completion-style API); the Zig library was built
  ReleaseFast (docs suggest ReleaseSafe). Sockets are plain `std::net` fds, switched to
  non-blocking with SO_NOSIGPIPE set via `setsockopt` (macOS has no MSG_NOSIGNAL; flags are 0).
- The JS client/server use a different structure per API (callbacks for Bun/node:net, async read
  loops for Deno), and the Rust one uses tasks; per-runtime code is not equally optimised.
- Single machine, other processes running; differences of a few percent are within noise.

## After the kqueue wait rework (origine rt only, median of 3, same machine)

Persistent per-fd `EV_DISPATCH` filters with batched registration replaced `dup` + one-shot `kevent` + `close` per wait (see `src/io/docs/backends.md`). Bun/Deno numbers above are unchanged.

| size | conns | origine rt before | origine rt after |
|---|---|---|---|
| 16 B | 1 | 35,959 | 41,157 |
| 16 B | 64 | 89,083 | 110,464 |
| 1 KiB | 1 | 35,523 | 39,282 |
| 1 KiB | 64 | 85,809 | 106,824 |
| 64 KiB | 1 | 19,403 | 20,750 |
| 64 KiB | 64 | 32,136 | 34,231 |

Note: the Rust bench bundles `liborigine_io.a` into the `origine_io` rlib, so after rebuilding the Zig library delete the bench crate's `target/` before rebuilding, or cargo keeps linking the old code.

## Full matrix with origine's JS API (`api.net`), after the kqueue rework

`origine JS` is `bench.origine.js` on `zig-out/bin/origine` (same workload through `api.net`). The guest has no high-resolution clock (`Date.now()` only), so it reports mean latency instead of p50/p99. Median of 3, 1 s warmup, 3 s measured. Run with `bun run.js <out_dir> 1 3 3` after `zig build`.

| size | conns | origine rt | origine JS | Bun native | Bun node:net | Deno native | Deno node:net |
|---|---|---|---|---|---|---|---|
| 16 B | 1 | 41,073 rt/s<br>p50 23.8 us / p99 36.3 us | 24,439 rt/s<br>mean 40.9 us | 37,700 rt/s<br>p50 25.8 us / p99 37.9 us | 37,974 rt/s<br>p50 25.1 us / p99 37.5 us | 33,211 rt/s<br>p50 29.2 us / p99 44.5 us | 32,957 rt/s<br>p50 29.3 us / p99 41.8 us |
| 16 B | 64 | 107,349 rt/s<br>p50 571.5 us / p99 1.10 ms | 40,753 rt/s<br>mean 1.57 ms | 115,021 rt/s<br>p50 524.7 us / p99 992.1 us | 104,611 rt/s<br>p50 592.5 us / p99 1.03 ms | 88,365 rt/s<br>p50 693.5 us / p99 1.22 ms | 73,708 rt/s<br>p50 837.9 us / p99 1.33 ms |
| 1 KiB | 1 | 38,223 rt/s<br>p50 25.0 us / p99 40.3 us | 23,149 rt/s<br>mean 43.2 us | 36,711 rt/s<br>p50 26.2 us / p99 41.4 us | 37,423 rt/s<br>p50 25.3 us / p99 38.5 us | 33,134 rt/s<br>p50 29.0 us / p99 47.8 us | 32,708 rt/s<br>p50 29.8 us / p99 45.3 us |
| 1 KiB | 64 | 108,299 rt/s<br>p50 585.5 us / p99 671.6 us | 38,740 rt/s<br>mean 1.65 ms | 109,055 rt/s<br>p50 569.0 us / p99 986.7 us | 100,898 rt/s<br>p50 622.3 us / p99 901.5 us | 82,280 rt/s<br>p50 768.5 us / p99 892.2 us | 74,097 rt/s<br>p50 852.6 us / p99 972.7 us |
| 64 KiB | 1 | 21,139 rt/s<br>p50 44.4 us / p99 65.2 us | 11,311 rt/s<br>mean 88.4 us | 18,574 rt/s<br>p50 50.6 us / p99 107.2 us | 18,211 rt/s<br>p50 51.2 us / p99 88.4 us | 15,800 rt/s<br>p50 61.3 us / p99 102.5 us | 15,381 rt/s<br>p50 60.7 us / p99 90.8 us |
| 64 KiB | 64 | 34,551 rt/s<br>p50 1.82 ms / p99 2.42 ms | 10,813 rt/s<br>mean 5.92 ms | 33,907 rt/s<br>p50 1.86 ms / p99 2.33 ms | 32,448 rt/s<br>p50 1.92 ms / p99 2.41 ms | 31,354 rt/s<br>p50 2.02 ms / p99 2.41 ms | 30,556 rt/s<br>p50 2.02 ms / p99 3.31 ms |

The JS path is 30-65% below Bun at small messages: per-operation promise, completion and `Uint8Array` machinery costs about 8 us per round trip on top of the same four syscalls (see the profile notes in the commit history); origine's Rust runtime matches Bun.

## 1 KiB only, 2 runs per cell, macOS efficiency mode off

After the wait-table and pending-slab changes (`bun run.js <out_dir> 1 3 2`; the driver now runs only 1 KiB messages and 2 repetitions). Numbers are higher than the tables above because the earlier runs were taken with efficiency mode on.

| size | conns | origine rt | origine JS | Bun native | Bun node:net | Deno native | Deno node:net |
|---|---|---|---|---|---|---|---|
| 1 KiB | 1 | 47,723 rt/s<br>p50 20.3 us / p99 39.3 us | 29,314 rt/s<br>mean 34.1 us | 45,430 rt/s<br>p50 21.2 us / p99 37.3 us | 45,071 rt/s<br>p50 22.0 us / p99 30.5 us | 41,768 rt/s<br>p50 23.3 us / p99 30.1 us | 41,440 rt/s<br>p50 23.8 us / p99 30.0 us |
| 1 KiB | 64 | 153,856 rt/s<br>p50 415.5 us / p99 449.0 us | 86,804 rt/s<br>mean 737.3 us | 164,032 rt/s<br>p50 386.4 us / p99 534.7 us | 149,163 rt/s<br>p50 425.0 us / p99 611.2 us | 119,889 rt/s<br>p50 533.2 us / p99 613.4 us | 104,728 rt/s<br>p50 604.8 us / p99 682.2 us |

Where the JS path's time goes at 1 connection (in-tree counters, one half round trip, about 19 us): kevent/recv/send syscalls about 11.6 us (the same as the Rust-only bench), Rust task/runtime overhead about 3.6 us, JS microtasks and native calls about 2.9 us, completion settling about 0.9 us. The host settle loop itself costs under 0.5 us per iteration. An *empty* zero-timeout `kevent` costs about 12 us on this macOS, so avoiding empty polls matters.

## Read modes of the origine JS bench

`bench.origine.js ... <backend> <mode>`: `copy` (default) uses `readCopy`, `into` uses the detaching `readInto`. 1 KiB: copy 38.9k / 87k rt/s vs into 35.1k / 84k (1 / 64 connections); 64 KiB x 1 connection: copy 16.5k vs into 17.9k. Zero-copy wins only when the copy is large.

## Latest: 1 KiB x 2 runs, after eager first poll and `Socket.readInto`

`origine JS` now polls native-started ops once at spawn (`Handle::spawn_eager`) and the bench reuses one buffer per connection with `readInto` (like the Deno variant). Tried and rejected because they measured no better or worse: a leaner spawn path without join handle, a native scratch buffer + copy for `read(len)` (about 8% slower), and a pooled/uninitialised backing store from the isolate's allocator (the raw allocation is a small part of the 405 ns `new_backing_store` cost).

| size | conns | origine rt | origine JS | Bun native | Bun node:net | Deno native | Deno node:net |
|---|---|---|---|---|---|---|---|
| 1 KiB | 1 | 48,781 rt/s<br>p50 20.2 us / p99 29.2 us | 40,182 rt/s<br>mean 24.9 us | 46,999 rt/s<br>p50 20.6 us / p99 30.7 us | 45,603 rt/s<br>p50 21.8 us / p99 31.0 us | 41,305 rt/s<br>p50 23.4 us / p99 34.9 us | 40,587 rt/s<br>p50 23.9 us / p99 34.8 us |
| 1 KiB | 64 | 150,580 rt/s<br>p50 420.5 us / p99 500.3 us | 85,813 rt/s<br>mean 745.8 us | 154,744 rt/s<br>p50 404.9 us / p99 568.0 us | 137,954 rt/s<br>p50 453.6 us / p99 667.0 us | 115,174 rt/s<br>p50 547.4 us / p99 674.9 us | 100,568 rt/s<br>p50 624.0 us / p99 762.0 us |

At 64 connections about 34% of the JS thread is in `sendto` (loopback sends do the receiver-side work synchronously; Bun pays this too), about 16% in the JS bodies and 11% in native glue.

## Event API (`socket.register('data')`), 1 KiB x 2 runs, macOS efficiency mode off

`bench.origine.js ... <backend> events`: the echo server and the clients use `register('data')` with pooled leases and synchronous `send`, no promise per message.

| conns | `readCopy` (promises) | events |
| --- | --- | --- |
| 1 | 31.8k, 33.8k rt/s | 38.4k, 38.3k rt/s |
| 64 | 82.2k, 81.6k rt/s | 96.0k, 96.5k rt/s |

After receiving straight into the pooled stores (`ev.buffer()` no longer copies; same session, copy path re-measured 33.6k/31.7k and 76.9k/75.3k): events 37.3k, 36.8k (1 conn) and 98.0k, 101.6k (64 conns). A 1 KiB memcpy is not the bottleneck, so the gain is small there; it matters for large chunks.
