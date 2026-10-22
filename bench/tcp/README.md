# TCP ping-pong benchmark

Echo server + ping-pong client in one process, one OS thread, loopback 127.0.0.1, TCP_NODELAY.
A round trip = send a message, wait for the full echo (partial reads handled), repeat. Length is
checked every round; first/last byte of every received chunk are checked against the expected
stream (8-byte sequence number + pattern).

Implementations: origine `rt` + `Loop` (Rust, `Backend::Auto` = kqueue+GCD on macOS), Bun native
(`Bun.listen/connect`), Bun `node:net`, Deno native (`Deno.listen/connect`), Deno `node:net`.

## Run

```sh
# 1. static lib (not produced by build.zig); ReleaseFast
zig build-lib -static -lc -OReleaseFast --name origine_io src/io/c_api.zig   # run in an empty dir
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
