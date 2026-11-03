# TCP examples

Run from the repository root:

```sh
zig build run -- examples/net/promises/init.js
zig build run -- examples/net/events/init.js
zig build run -- examples/net/lifecycle/init.js
zig build run -- examples/net/write-lanes/init.js
zig build run -- examples/net/addresses/init.js
```

Each demo starts its own server on an automatically assigned loopback port, connects a client, checks what it
received and closes its runtime before exiting. No separate server or network permissions are needed.

- `promises/`: echo UTF-8 text in `'pull'` mode with `listen`, `connect`, `accept`, `queued.send`, and all three
  read modes (`read`, reusable `readCopy`, detaching `readInto`). Handles partial reads and end of stream.
- `events/`: stream and verify 1 MiB in `'event'` mode with `register`, `queued.put`, `drain` backpressure,
  `pause`/`resume`, exact-size `event.buffer()` leases, `unref()`, and `io.run()` for event lifetime.
- `lifecycle/`: half-close with `end('write')`, the rule that a socket closes once both directions are finished, and
  moving a pull socket to event mode with `toEvent()`.
- `write-lanes/`: `direct.write` (unbuffered), `queued.put` with `queued.limit` and `drained()`, `end('read')`, and a
  server moved to event mode and back with `toEvent()` and `toPull()`.
- `addresses/`: what the default network ceiling allows (loopback, `localhost`), and the `PermissionDenied` for the rest.

See the [net API reference](../../src/js/docs/net.md) for the loopback restriction, handle lifetime, and buffer
ownership rules, and [examples/README.md](../README.md) for every example.
