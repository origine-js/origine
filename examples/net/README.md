# Loopback TCP demos

Run from the repository root:

```sh
zig build run -- examples/net/promises.js
zig build run -- examples/net/events.js
```

Both demos start their own server on an automatically assigned loopback port,
connect a client, verify the received bytes, and close their runtime before exiting.
No separate server or network permissions are needed.

- `promises.js`: echo UTF-8 text with `listen`, `connect`, `accept`, `write`, and
  all three read modes (`read`, reusable `readCopy`, detaching `readInto`). Handles
  partial reads and end of stream.
- `events.js`: stream and verify 1 MiB with `register`, `send`, `ready` backpressure,
  pooled `event.buffer()` leases, `unref()`, and `io.run()` for event lifetime.

See the [net API reference](../../src/js/docs/net.md) for the loopback restriction,
handle lifetime, and buffer ownership rules.
