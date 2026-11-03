# origine_h2

HTTP/2 as a sans-io state machine over [nghttp2](../../../../lib/nghttp2/README.md), and an async
driver that runs it over any [`Transport`](../../origine_transport/docs/README.md). A `Session` never
touches a socket: feed it received bytes with `recv`, take bytes to send with `send`, read what
happened with `next_event`. `connect(role, limits, transport)` returns a `Connection` handle and a
`Driver` future; `api.http` (in `origine_api`) sits on it. Design and decisions: [docs/http-design.md](../../../../docs/http-design.md).

```
src/lib.rs      exports
src/sys.rs      the hand-written slice of nghttp2's C ABI (a test pins the struct layouts to clang's)
src/session.rs  Session: recv, send, submit_request / submit_response, send_data, finish, consume, reset, goaway, ping
src/event.rs    Event, HeaderKind, Pseudo, Role, Limits
src/fields.rs   FieldList: ordered, packed header fields (not a map)
src/error.rs    H2Error
src/driver.rs   connect, Connection, Driver, Exchange, StreamEvent, ConnError
src/tests.rs    two sessions back to back
src/driver_tests.rs  two connections and their drivers over in-memory pipes, and h2 over TLS
```

Tests link `libnghttp2.a` only when `ORIGINE_NGHTTP2_LIB` (a directory) is set; `just test-net` builds it
with Zig and runs them. The product links nghttp2 from the Zig build (`-Dhttp`). Not run under Miri (FFI).

## Behaviour worth knowing

- **Headers are a stream of fields.** `FieldList` is one buffer of `name_len u16 | value_len u32 | name | value`
  records: duplicates and order kept, names lowercase, no pseudo headers, no connection-specific ones
  (`connection`, `keep-alive`, `transfer-encoding`, `upgrade`, `te` other than `trailers`). `put` checks;
  `from_packed` only checks the framing. A received header block is delivered as `Event::Headers`
  batches of about `Limits.batch` bytes; `last` ends the block and `end_stream` (with `last`) means the
  peer is done. Pseudo headers come with the first batch only.
- **Flow control is the caller's.** nghttp2 runs with automatic window updates off: received `Data` stays
  unacknowledged until `consume(stream, n)`, so a reader that is slow slows the peer. A stream that closes
  with unread bytes gives them back to the connection window at once. `queued(stream)` is the bytes
  accepted by `send_data` and not yet sent, the signal for the writer's own backpressure.
- **Limits are explicit.** `streams`, `headers` (a block over it resets the stream with
  `ENHANCE_YOUR_CALM`), `window`, `connection` (at least 65535) and `batch` have no defaults.
- **Wait for the peer's SETTINGS** (`Event::Settings`) before opening many streams or sending large
  bodies. Before they arrive the peer's limits are unknown: a client may overshoot the concurrency limit
  and get `REFUSED_STREAM` (code 7, safe to retry), and the first flight may use the default 65535-byte
  window. Requests over a known limit wait inside nghttp2.
- **Errors.** `recv` / `send` errors are fatal for the session (send what is queued, a GOAWAY, then drop
  the transport). A flood (rapid reset and the like) is `H2Error::Flooded`; HTTP/1 bytes to a server are
  `H2Error::BadPreface`.
- **Server push is off** (`ENABLE_PUSH` 0; a pushed stream is refused). **Not covered yet:** extended
  CONNECT (WebSockets over h2), priorities, the transport driver, zero-copy `Data` (it is copied once out
  of nghttp2's input buffer).

## The driver (`driver.rs`)

- **One I/O task per connection.** Spawn `Driver::run()` where tasks run (it is `!Send`; no executor is
  assumed). It keeps one read and one write in flight at once, so two peers that both fill their send
  buffers cannot deadlock each other. Everything else is a short synchronous call on the session plus a
  wake of that task; nothing holds a borrow across an await.
- **Handles.** `Connection`: `ready()` (peer SETTINGS arrived; open streams after this), `open(head,
  fields, body)` (client), `accept()` (server; `None` once the connection is over), `ping()` (round
  trip), `close()` (graceful GOAWAY), `error()`. `Exchange`: `next()` (the stream's events in order),
  `consume(n)`, `respond`, `send(data)`, `finish(trailers)`, `reset(code)`, `queued()`.
- **Backpressure both ways.** `send` waits while more than `Limits.window` bytes of the stream are queued
  and unsent (an empty queue always takes a chunk). `Data` stays unacknowledged until `consume`.
- **Ends.** A clean end is `Ok(())`. Transport failure, EOF with streams open, or a protocol error ends the
  driver with `ConnError`, queued output (a GOAWAY) is flushed first for protocol errors, and every open
  stream receives `StreamEvent::Aborted`. After the terminal event (`Closed` or `Aborted`) `next` is `None`.
- **Dropping an `Exchange`** whose own side is still being written cancels the stream (RST `CANCEL`).
  Dropping one whose side is complete lets the stream finish quietly, so a response just queued is not cut
  off; later data is discarded and its window returned. To abandon a request, call `reset`. A stream
  cancelled before its head left simply never exists on the wire.
- **Over TLS** by passing an `origine_tls::TlsStream` as the transport (tested).
