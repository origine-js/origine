# Natives (`native.io.*`, `native.fsAsync.*`, `native.net.*`, ...)

Reference for the Rust natives registered into the Zig `native` table (see
[README.md](README.md) for how registration works). Code: `src/io.rs`, `src/fs.rs`, `src/net.rs`, `src/conn.rs`, `src/stream.rs`, `src/udp.rs`, `src/sub.rs`; fs semantics in
`rust/crates/origine_api_fs/src/lib.rs`. Planned/changing behaviour is specified in
[`docs/async-host-contract.md`](../../../../docs/async-host-contract.md); this page describes the
code as it is.

## Conventions

* JS name = the `path = "namespace.name"` of `#[native]` (by convention camelCase of the Rust fn
  without its prefix); there is no per-native C symbol, natives are reached through the registry.

  | JS | Rust fn / C symbol suffix |
  |---|---|
  | `native.io.create` | `io_create` |
  | `native.io.runtime` | `io_runtime` |
  | `native.fsAsync.request` | `fs_async_request` |
  | `native.fsAsync.<op>` | `fs_async_<snake_op>` (e.g. `openFile` -> `fs_async_open_file`) |

* All use `side_effect = "any"`.
* Argument errors are `TypeError("argument N: expected X")` thrown (sync) or an already-rejected
  promise (promise natives). Failures of the operation reject with an `Error` carrying `errno`, `name`, `subject` and `os`
  (`origine_api_core::errno`, `native::error_value`), which `glue/util.js` `settled` turns into an `OrigineError` subclass
  instance; none touches the shared errno cell. The path natives name their path as `subject` (`fs.rs` `named`).
* Handles: `{fs, id}` handles are flattened into **two** JS arguments (`DirRef`/`FileRef` have
  `ARITY = 2`). Directory id 0 is the grant root. The sync twins in `src/api/fs.zig` take the same
  argument lists.
* Promise natives return the promise synchronously; the work is spawned on the runtime of the
  grant. Everything is settled by `origine_api_poll`.
* Ownership: a runtime or grant can only be used by the scope that created it (`BadHandle`
  otherwise); a grant belongs to the runtime it was created for and becomes unusable (`BadHandle`)
  when that runtime starts closing.

## `native.io`

The runtime is a Rust-defined class (`io.Io`, see [Rust-defined classes](#rust-defined-classes-class)) owning an
`IoCore` (the scope that made it, the runtime's number, a weak loop, the weak list of the conns made on it) in the
cppgc heap. Its tables are frozen data properties, each an instance of its own class over the same core. No runtime
number reaches the guest.

| Native / member | Signature | Result |
|---|---|---|
| `create` | `(opts?: { backend?, entries? }, onClose?: (promise, runtime) => void)` | an `Io` (sync, frozen). `onClose` is the glue's: called when `close()` starts, with its promise (narrowing slots, async fs). Throws `Unsupported` (backend excluded or unavailable), `PermissionDenied` (runtime ceiling), `TypeError`. |
| `runtime` | `(io: Io)` | the runtime's number, for the async fs natives the glue calls; `BadHandle` once closing |
| `Io` | installer | `backend`, `closed`, `run()` (Promise resolving once every flowing conn of the runtime delivered `close`), `close()` (cancels the runtime's ops, which reject `Canceled`, closes its conns, drains, releases its grants, destroys the loop; every call returns the same promise), `timer`, `tcp`, `udp` |
| `IoTimer` | installer | `now()` (monotonic ms since host creation), `sleep(ms)`, `sleepUntil(deadline)`, `timer(ms)` / `timerAt(deadline)` (a frozen `Timer` with `promise` and `cancel()`). `ms`: finite, 0 to 2147483647 (`TypeError`); `BadHandle` once closed. |
| `IoTcp` | installer | `listen(addr)` (sync, `TcpListenerUnshaped`), `connect(addr)` (Promise `TcpStreamUnshaped`; non-blocking, the loop's `connect`) |
| `IoUdp` | installer | `bind(addr)` (sync, `UdpSocketUnshaped`) |

Guest-facing timer and deadline helpers are documented in
[`src/js/docs/timers.md`](../../../../src/js/docs/timers.md).

## `native.fsAsync`

`request(runtime, root, access)` (the glue reads `runtime` with `native.io.runtime(io)`) creates a grant; every other op takes `(fs, id)` handles. Order of
checks, like Zig: path validation (`InvalidInput` for NUL, `PermissionDenied` for `..`, absolute and `__codecache__`), then the grant's access (`PermissionDenied`: a mutation on a read-only grant, an observation on a write-only one), then
the handles (`BadHandle` unknown/closed, `StaleHandle` closing), then the OS. These checks run
synchronously, so a bad call returns a rejected promise without starting a task.

| Native | JS arguments | Resolves with |
|---|---|---|
| `request` | `ioId: u32, root: string, access: u32` | `{ id }` (the `fs` of the grant). `access` bits: 1 read, 2 write (3 both; anything else `InvalidInput`). Opens `root` relative to the embedder's fs root (the dup'd `fs_root_fd`) with the same lexical check as every path. A write request above the embedder's ceiling is rejected `PermissionDenied`, never downgraded. Rejects `BadHandle` (runtime), `PermissionDenied` (no async fs configured, above the ceiling, or `root` escapes), `InvalidInput`, or the OS error. The grant is registered when the promise settles; `Canceled` if its runtime vanished meanwhile. |
| `openFile` | `fs, dirId, path, bits: u32` | file id. `bits`: 1 write, 2 create, 4 truncate, 8 exclusive; any of the four needs a writable grant; `create` implies read+write; a read-only open of a directory fails `IsADirectory`; a read-only open (bits 0) needs a readable grant. Empty path -> `InvalidInput`. |
| `openDir` | `fs, dirId, path` | directory id (`""` opens the dir itself). |
| `stat` | `fs, dirId, path` | `[kind, size]` like `std::fs::metadata`: a final symlink is followed (a dangling one is `NotFound`; following can leave the root, confinement is lexical). Empty path = the directory. kind: 1 file, 2 directory, 3 symlink, 4 other. `FileTooLarge` above 2^53-1. Needs a readable grant, like `symlinkStat`, `readDir`, `fileStat` and every read. |
| `symlinkStat` | `fs, dirId, path` | as `stat` for the entry itself (`std::fs::symlink_metadata`): a final symlink is not followed. |
| `createDir` | `fs, dirId, path` | `undefined`. |
| `deleteFile` | `fs, dirId, path` | `undefined` (file or symlink). |
| `readDir` | `fs, dirId` | flat `[name0, kind0, name1, kind1, ...]` (names lossy UTF-8, OS order, no `.`/`..`). |
| `readAll` | `fs, fileId, limit` | `Uint8Array` from the current position to EOF or `limit` (`Limit`: non-negative number or `Infinity`); `FileTooLarge` beyond 256 MiB (`MAX_READ_BYTES`). Hitting `limit` is not an error. |
| `writeAll` | `fs, fileId, data` | `undefined`; writes all of `data` at the current position. Always COPIES `data` at call time and never touches the guest's buffer (`StaleHandle` if it is already detached). See README. |
| `writeMoveAll` | `fs, fileId, data` | as `writeAll` but TRANSFERS: `data`'s whole ArrayBuffer is pinned and DETACHED and written in place. `Unsupported`, buffer untouched, when it cannot be detached (shared, resizable, wasm memory): never a silent copy. An empty window detaches nothing. |
| `close` | `fs, fileId` | `undefined`; waits for in-flight ops on the file, then closes. |
| `closeDir` | `fs, dirId` | `undefined`; the root (id 0) cannot be closed (`BadHandle`). |
| `createDirPath` | `fs, dirId, path` | `mkdir -p`; path must not name the root. |
| `deleteDir` | `fs, dirId, path` | removes an empty directory; not the root. |
| `deleteTree` | `fs, dirId, path` | removes a file/symlink or a directory tree; a missing path is not an error. Uses `Dir::remove_dir_all` (bounded concurrency 16 per level; runs on the grant's runtime). |
| `rename` | `fs, dirId, old, newFs, newDirId, new` | `undefined`; both handles must be of the same grant (`newFs == fs`) else `BadHandle`; neither path may name the root. |
| `fileStat` | `fs, fileId` | `[kind, size]`. |
| `fileRead` | `fs, fileId, buffer` | byte count (0 = EOF); reads `buffer.length` bytes at the current position, copied into `buffer` at completion (`StaleHandle` if it was detached/shrunk meanwhile). |
| `filePread` | `fs, fileId, buffer, offset: u64` | as `fileRead` at `offset`. |
| `fileWrite` | `fs, fileId, data` | bytes written by one `write` (may be partial; `0` for empty data). Copies like `writeAll`. |
| `fileWriteMove` | `fs, fileId, data` | as `fileWrite`, moving like `writeMoveAll`. |
| `filePwriteAll` | `fs, fileId, data, offset: u64` | `undefined`. Copies like `writeAll`. |
| `filePwriteMoveAll` | `fs, fileId, data, offset: u64` | as `filePwriteAll`, moving like `writeMoveAll`. |
| `fileReadInto` | `fs, fileId, buffer` | `{ bytes, buffer: ArrayBuffer }`: one read at the position into `buffer`'s window; a new ArrayBuffer over the same store (original dead). `Unsupported`, untouched, for a buffer that cannot be detached; an empty one comes back as it is. |
| `filePreadInto` | `fs, fileId, buffer, offset: u64` | as `fileReadInto` at `offset`. |
| `fileReadAlloc` | `fs, fileId, len: u64` | `Uint8Array` of the bytes read (<= `len`, empty at EOF) over a V8-allocated buffer of `len` bytes (or an exact-size copy when at most half of a >= 4 KiB buffer was used); `len` > 256 MiB rejects `FileTooLarge`. |
| `filePreadAlloc` | `fs, fileId, len: u64, offset: u64` | as `fileReadAlloc` at `offset`. |
| `fileSetLength` | `fs, fileId, length: u64` | `undefined`. |
| `fileSync` | `fs, fileId` | `undefined`. |

Handle lifecycle (`origine_api_core::table`): an id stays reserved while any operation using it is
in flight; `close` marks the entry `Closing` immediately (new ops fail `StaleHandle`), waits for
the in-flight ones, closes the descriptor, then marks it `Closed` so the slot may be reused. Ids
are `1..` per table (files and directories have separate tables); a dropped (cancelled)
operation releases its guard.

Buffer semantics (pin/detach, lifetime invariant): [README](README.md#buffers-pinning).
`fileRead`/`filePread` remain copying (they allocate `buffer.length` bytes per call).

## The network classes (`needs = "runtime"`)

Source: [`net.rs`](../src/net.rs) (the socket engine, the ceiling, `SocketAddr`), [`conn.rs`](../src/conn.rs) (the
state of one descriptor and its write lanes), [`stream.rs`](../src/stream.rs) (TCP), [`udp.rs`](../src/udp.rs),
[`sub.rs`](../src/sub.rs) (events). Guest surface: [`src/js/docs/net.md`](../../../../src/js/docs/net.md).

There is no socket table. Every network object is a Rust-defined class instance owning a `Front` over an
`Rc<Conn>`; a transfer (`pulling()`, `toEvented()`, a TLS handshake) takes the conn out of the old object, which
answers `BadHandle` from then on. A `Conn` holds the `Rc<Socket>` (taken out and shut down by `close()`), the
outbox, the read/write state and the event `Flow`; its runtime keeps a weak list of its conns so `io.close()` closes
their descriptors. An operation in flight holds its own `Rc<Socket>`, so closing never frees a descriptor under a
running `recv`. The engine is `Socket::recv/send/try_write/finish_write` (plain or TLS) and the pumps of `sub.rs`.

- **Addresses** cross as `SocketAddr` objects of the glue: `native.net.link(toParts, fromParts)` registers two
  converters per realm (private on the realm's global), `toParts(addr)` gives `[octets, port, scopeId]` of a genuine
  `SocketAddr` and `fromParts(octets, port, scopeId)` makes one; no text is parsed. `FromJs`/`IntoJs for SockAddr`.
- **Ceiling**: `listen` / `bind` against the `listen` rules, `connect` and every datagram destination against the
  `connect` rules (`net::allowed`), `PermissionDenied` with the address as `subject`.
- **Writes** (`conn.rs`): `direct.write` is one non-blocking write on the isolate thread (0 while the outbox is busy
  or sends wait); `queued.put` tries the kernel first, then copies at most the room under `limit` into the outbox
  that a writer task flushes; `queued.send` copies its bytes at the call, takes a ticket and is admitted in call
  order once it fits; `drained()` waits for no ticket and an empty outbox; `end('write')` takes a ticket, then sends
  the FIN (`close_notify` first under TLS) after the outbox. A failure rejects every waiter with its errno; `close()`
  with `Canceled`.
- **Events** (`sub.rs`): `register` makes the conn's `Hub` in the Host (`HostState::hubs`, by an internal id): the
  handlers as `Global<Function>`, the context, the reused `DataEvent`. The first handler of the flowing event spawns
  the pump (read into slabs, accept, receive datagrams), which queues events on the host-wide queue and stops
  re-arming while 8 are undelivered; `deliver` calls the handlers in the hub's context with a microtask checkpoint per
  event. A throw goes to the `error` handlers, else is an unhandled rejection; a returned promise is not awaited.
  `pause`/`resume` park and release the read-side events in order; the guest's `close()` lets `close` through a pause.
  Pumps and their receives are excluded from `live_items`; `io.run()` waits for every counted hub's `close`.

| Native | Args | Result |
|---|---|---|
| `net.link` | `toParts, fromParts` | sync; the realm's `SocketAddr` converters |
| `net.take` | `event: DataEvent` | the chunk's `ArrayBuffer`, carved out of its slab (no copy; the same one within one event; `TypeError` once over); the glue's `DataEvent.prototype.buffer` wraps it in a `Lease` |
| `net.takeDatagram` | `event: DatagramEvent` | the datagram's bytes as a new `ArrayBuffer` (one copy into V8 memory), once (`StaleHandle` afterwards; the glue keeps the lease) |
| `net.release` | `buffer` | sync; detaches a lease, dropping its hold on the slab |
| `net.<Class>` installers | `hostError, members?` | `TcpStreamUnshaped`, `PullTcpStream`, `EventTcpStream`, `TcpListenerUnshaped`, `PullTcpListener`, `EventTcpListener`, `UdpSocketUnshaped`, `PullUdpSocket`, `EventUdpSocket`, `SendQueue`, `Direct`, `DataEvent`, `DatagramEvent`, `Registration`; the glue adds `[Symbol.asyncDispose]`, the async iterators and `buffer()` |

Datagrams: the loop has no `recvfrom`, so a receive waits with a one-byte `MSG_PEEK` `recv` on the loop and takes the
datagram with a non-blocking `recvfrom(2)`; a send that would block retries after 1 ms.

## Adding a native

1. Write the fn in `src/` with `#[native(side_effect = "...", path = "ns.name"[, needs = "runtime" | "async_fs"][, promise])]`
   ([macro reference](../../origine_api_macros/docs/README.md)). Async natives return an
   [`Op`](../src/native.rs) (`Op::new(runtime, future)`, `Op::reading(...)`, `.with_hook(..)`) or
   `Result<Op, E>`; the future's output must be `Result<T, E>` with `T: IntoJs`, `E: Into<NativeError>`.
2. Add `<module>::NATIVE_<FN_NAME>,` to `NATIVES` in `src/registry.rs` (Zig installs the registry; the
   JS glue must use the same `native.<namespace>.<name>`; `just check-contracts` verifies both).
3. Keep V8-free logic in `origine_api_core` / `origine_api_fs` so Miri covers it.

## Errors are enums

A Rust failure is a value of an enum with one variant per cause, never a `String` built where it happens. Reuse the
enums of the crates underneath (`io::ErrorKind`, `rustls::Error` through `origine_tls::TlsError`, `hickory_proto`'s
errors through `origine_dns::DnsError`) and box large payloads so `Result` stays small. The text is written once, in
the enum's `fmt::Display` (plus `std::error::Error::source` when it wraps another error), and the enum converts into
`NativeError` with one `match` (`From<ClassError> for NativeError` in [`class.rs`](../src/class.rs), `tls_error` in
`tls.rs`, `dns_error` in `dns.rs`). A bad argument is an `ArgError` (`argument N: expected X`, `X` a constant).

## Rust-defined classes (`#[class]`)

Values a guest holds for a long time and that are not tied to a handle's lifetime (TLS roots, identities, client
authentication, session caches, configurations; DNS resolvers) are **instances of classes defined in Rust**. A
`#[class(path = "ns.Name", side_effect = "..", needs = "..")]` impl block ([macro reference](../../origine_api_macros/docs/README.md#class))
gives the type its own `FunctionTemplate` per isolate ([`class.rs`](../src/class.rs), made on first use, never in a
snapshot): the class name, a constructor that throws (`new Name()` is a `TypeError`), `#[static_method]`s on the
constructor, `&self` methods and `#[getter]`s on the prototype (non-enumerable). An instance is made from the
template's instance template, so `instanceof` works, and owns its Rust value in the isolate's cppgc heap
([`gc.rs`](../src/gc.rs), `Object::wrap`, one tag, a `TypeId` inside): the value is dropped when the instance is
collected. The brand check is the unwrap: a member called on anything else throws `ClassError::Receiver` (a
`TypeError`), and a `&Name` argument rejects anything but a `Name` (`argument N: expected a Name`).

* **Arguments and results.** A `#[class]` type is `IntoJs` (a new instance in the current realm) and `&T` is
  `FromJs` for any class `T` (also inside `Option`, `Vec` and `derive(FromJs)` structs with a lifetime, such as
  `struct ClientConfig<'s> { roots: &'s RootPki }`). The borrow lasts for the call: a `promise` native or member clones
  what it keeps (the values are `Arc`-backed), which is what holds a value alive across an `await`.
* **Installation.** `#[class]` registers an installer native at its path (`CLASS_<NAME>` in `NATIVES`). The glue
  calls `native.ns.Name(hostError, members?)` once per realm when the capability is bound (index.js `late`): it
  returns the constructor after freezing it like `freezeMethods` (every member, the prototype, the constructor).
  `hostError` is kept for the realm, so members, which the guest calls directly, throw and reject the realm's
  `IoError` / `HostError` instances like the glue-wrapped natives. `members` are the few JS members that need the
  glue's own objects (`Symbol.asyncDispose`, async iterators, `DataEvent.buffer` making a `Lease`); they are
  defined on the prototype before it is frozen.
* **Releasing.** `class::Releasable<T>` holds a value that `release()` can drop before the instance is collected
  (`BadHandle` afterwards); what was built from it keeps its own copy.
* **Rules for a class type:** `'static`, self-contained. Its `Drop` runs inside a collection, so it must not touch
  `HostState`, V8 or a scope table. Members take `&self` (shared with the collector; mutation goes through a
  `Cell`/`RefCell`) and cannot take a `ScopeKey` (a member is not bound to a scope; keep the owner in the value).
  The network objects own their descriptor this way too (`conn.rs`); what holds V8 handles for them (event
  handlers) lives in the Host (`HostState::hubs`), never in the cppgc value. HTTP/2 sessions still live in a Host
  table.

See [`docs/cppgc-research.md`](../../../../docs/cppgc-research.md) for the heap and why there is no JS wrapper class.

## `tls.*` (TLS, `needs = "runtime"`, feature `tls`)

Source: [`tls.rs`](../src/tls.rs); semantics and the guest surface: [`src/js/docs/tls.md`](../../../../src/js/docs/tls.md). Parsed values are the classes `RootPki`, `Identity`, `ClientAuth`, `TlsSessions`, `TlsClient` and `TlsServer` (see above; installed as `native.tls.<Class>`). `TlsClient.connect(stream, { servername })` / `TlsServer.accept(stream)` are native members: they take a native stream (`sockstream::StreamArg`: a `TcpStreamUnshaped`, or an idle `PullTcpStream` / `EventTcpStream`, recognised by its cppgc `TypeId`), take its socket out (the object is consumed) and run the handshake on its runtime over a `SocketTransport` (`Socket::recv` / `send`, so it works over a TLS socket too), without entering JS. The result is a new `TcpStreamUnshaped` over `Socket::over_tls`. TLS failures map to one errno each (`CertificateRejected` / `TlsAlert` / `NoApplicationProtocol` / `ProtocolError` / `UnexpectedEof` / `InvalidData` / `InvalidInput` / `BrokenPipe`), the detail in the error's `subject`.

| Native | Args | Returns |
|---|---|---|
| `tls.RootPki` | installer | class: `bundled()`, `fromPem(pem)`, `fromDer(certs[])` (`InvalidData` when none parse), `release()` |
| `tls.Identity` | installer | class: `fromPem(cert, key)`, `fromDer({ cert[], key })` (`InvalidData` for a bad pair), `release()` |
| `tls.ClientAuth` | installer | class: `none()`, `require(roots)` |
| `tls.TlsSessions` | installer | class: `create({ limit })` (a positive integer), `release()` |
| `tls.TlsClient` / `tls.TlsServer` | installer | classes: `connect(stream, { servername })` / `accept(stream)` (Promise `TcpStreamUnshaped`), `release()` |
| `tls.client` | `{ roots, identity?, alpn?: string[], sessions? }` | a `TlsClient` |
| `tls.server` | `{ identities (at least one), clientAuth, alpn?: string[] }` | a `TlsServer` |
| `tls.info` | `stream` (any shape) | frozen `{ alpn, version ('tls1.2' \| 'tls1.3'), servername, resumed, peer: Uint8Array[] }`; `BadHandle` for a plain or closed stream |

## `http.*` (HTTP/2, `needs = "runtime"`, feature `http`)

Source: [`http.rs`](../src/http.rs); guest surface: [`src/js/docs/http.md`](../../../../src/js/docs/http.md). A session is `origine_h2::Connection` plus the task that runs its `Driver` on the socket's runtime, over a plain stream socket or a TLS stream, either of which `http.session` takes out of a native stream object (`StreamArg` and `SocketTransport` in [`sockstream.rs`](../src/sockstream.rs), shared with `tls.*`). Streams are `Exchange`s in the session's table by stream id; a header list crosses as one packed buffer (`name_len u16 \| value_len u32 \| name \| value`, re-validated on entry). The driver's pending read counts as work, so a session keeps the program alive until `destroy`. Errors: stream/session over `BrokenPipe`, bad field `InvalidInput`, protocol breaks `ProtocolError` (detail in `subject`), a dead transport its own errno with the message as `subject`.

| Native | Args | Returns |
|---|---|---|
| `http.session` | `stream (a native stream, plain or TLS), role (0 client, 1 server), streams, headers, window, connection, batch` | session id; consumes the stream |
| `http.ready` / `http.ping` | `session` | Promise (void / round trip in ms) |
| `http.goaway` / `http.destroy` | `session` | sync; graceful close / end now |
| `http.peer` | `session` | the peer's concurrent-stream limit (`2**32 - 1` when unset; valid after `ready`), or -1 when no new stream can be opened (GOAWAY received or connection ended) |
| `http.open` | `session, method, scheme, authority, path, fields, body (0 none, 1 stream)` | stream id |
| `http.accept` | `session` | Promise of the next request stream id, `undefined` when over |
| `http.next` | `session, stream` | Promise `{ kind (0 headers, 1 data, 2 end, 3 closed), head (0 request, 1 response, 2 trailers), status, method, scheme, authority, path, fields, last, endStream, data, code }`, `undefined` after the last |
| `http.consume` | `session, stream, bytes` | sync; window credit |
| `http.respond` | `session, stream, status, fields, body` | sync |
| `http.send` | `session, stream, data` | Promise; `data` copied now, waits while a window's worth is queued |
| `http.queued` | `session, stream` | sync byte count |
| `http.finish` | `session, stream, trailers (empty for none)` | sync |
| `http.reset` | `session, stream, code` | sync |
| `http.release` | `session, stream` | sync; forgets the stream |

## `dns.*` (address lookups, `needs = "runtime"`, feature `dns`)

Source: [`dns.rs`](../src/dns.rs); semantics and the guest surface: [`src/js/docs/dns.md`](../../../../src/js/docs/dns.md). A resolver is an `origine_dns::Resolver` whose `Exchange` opens one socket per query on the resolver's runtime: a connected UDP socket (datagrams not carrying our id are skipped), or a stream (RFC 1035 length-prefixed, over TLS for DoT with the `origine_tls` client built from the roots at creation), or DoH: one `origine_h2` client connection over TLS (ALPN `h2`, features `tls` and `http`; `Unsupported` without them or when the server does not negotiate `h2`) and one POST per query, its driver polled by the query itself (never spawned, so an idle resolver keeps nothing alive), all inside the per-attempt timeout. Server addresses are checked against the network ceiling's `connect` rules, at creation and again per query.

| Native | Args | Returns |
|---|---|---|
| `dns.Resolver` | installer, glue members | class (`ResolverHandle`): `closed` getter, `close()`; `lookup`, `io` and `Symbol.asyncDispose` come from the glue |
| `dns.resolver` | `io (an Io), spec, roots (a RootPki, undefined none), timeout (ms), tries, entries (0 none), min, max, negative_min, negative_max (ms)` | a `Resolver`. `spec` is one server per line: `udp <addrs>`, `tcp <addrs>`, `tls <name> <addrs>`, `https <authority> <path> <addrs>` (`addrs` are comma-separated `ip:port`) or `system` |
| `dns.lookup` | `resolver, name, family (0 both, 4, 6)` | Promise of `[4 \| 6, octets]*`; `BadHandle` for a closed resolver or another scope's |

