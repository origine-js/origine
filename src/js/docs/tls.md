# `api.tls`: TLS over streams

`api.tls` exists wherever `api.net` does and is built with `-Dtls` (on by default; without it the getter throws `PermissionDenied`). It runs TLS 1.2/1.3 (rustls on aws-lc) over a stream: a native [`api.net`](net.md) stream (or a TLS stream, for TLS over TLS), or any object with the stream methods. Design and decisions: [docs/http-design.md](../../../docs/http-design.md). The Rust side: [`origine_tls`](../../../rust/crates/origine_tls/docs/README.md), natives in [natives.md](../../../rust/crates/origine_api/docs/natives.md#tls-needs--runtime).

```js
const { tls } = api;
const client = tls.client({ roots: tls.RootPki.fromPem(caPem), alpn: ['h2'] });
const server = tls.server({ identities: [tls.Identity.fromPem(certPem, keyPem)], clientAuth: tls.ClientAuth.none() });
const plain = await io.tcp.connect(addr);
const secure = (await client.connect(plain, { servername: 'localhost' })).pulling();  // consumes plain
await secure.queued.send(new Uint8Array([1, 2, 3]));
const chunk = await secure.read(4096);                // empty only after the peer's close_notify
secure.info().alpn;                                   // what the handshake settled
await secure.end('write');                            // close_notify; reading still works
await secure.close();
```

## Values

`RootPki`, `Identity`, `ClientAuth` and `TlsSessions` are classes with named constructors that parse and validate where they are called (`InvalidData` for a bad certificate, a key that does not belong to the certificate, or no certificate at all). `RootPki.bundled()` is the Mozilla set compiled into the binary; `fromPem` / `fromDer` take your own. `tls.client({ roots, identity?, alpn?, sessions? })` has **no default trust** (`roots` is required) and resumes sessions only if you pass a `TlsSessions`. `tls.server({ identities, clientAuth, alpn? })` needs `clientAuth` (`ClientAuth.none()` or `ClientAuth.require(roots)`); it presents the first identity whose certificate is valid for the client's SNI name, else the first, and the client then refuses it. These classes, and `TlsClient` / `TlsServer`, are defined in Rust: `new RootPki()` is a `TypeError` (use the named constructors), every class and prototype is frozen, `instanceof` works, and a method called on anything but an instance of its class (or a `RootPki` passed where an `Identity` is expected) is a `TypeError`. `release()` forgets the native value (configurations already built keep working).

## Streams

`client.connect(stream, { servername, io? })` and `server.accept(stream, { io? })` resolve a **`TlsStreamUnshaped`** whose bytes are plaintext. `pulling()` / `evented()` turn it into a `PullTlsStream` / `EventTlsStream`, which have the members of `PullTcpStream` / `EventTcpStream` (`read` / `readCopy` / `readInto`, `register('data' ...)` with leases, `pause`, `queued`, `end('write')`, `close()`, `toEvented()` / `toPulling()`; handlers as in [net](net.md)) plus **`info()`**: what the handshake settled, `alpn`, `version` (`'tls1.2'` / `'tls1.3'`), `servername`, `resumed`, `peer` (DER certificates, leaf first), a new frozen object per call, `BadHandle` once the stream is closed or consumed. `api.tls` has `TlsStreamUnshaped`, `PullTlsStream` and `EventTlsStream` for `instanceof`.

- **A native stream** (a `TcpStreamUnshaped`, a `TlsStreamUnshaped`, or a shaped TCP or TLS stream nothing is using) is **consumed**: it answers `BadHandle` afterwards. `connect` / `accept` throw before touching it for a stream that has a read pending or bytes queued (`WouldBlock`), a handler or an ended side (`Unsupported`). The handshake and every later read and write run in Rust on the stream underneath, without entering JS, on the stream's own runtime: `io` may be omitted, and naming another `Io` is a `TypeError`. **TLS over TLS** is a `connect` over a TLS stream.
- **Any other object is a duck-typed stream**, read and written through its methods: `read(length)` (or, without it, `readInto(new Uint8Array(length))`), `queued.put(bytes)` (returns the bytes it took and must copy them) and `queued.drained()` (awaited before putting the rest), `end('write')` (called after `close_notify`) and `close()` (called when the TLS stream closes; neither result is awaited). It has no runtime of its own, so **`io` is required** (`TypeError` without it, or for an object missing a method). The object is not consumed (it cannot be): stop using it yourself. **Cost:** every call is a turn of the loop and a copy, so it is slower than a native stream. A rejection carrying an `errno` (an `IoError` / `HostError`) fails the TLS stream with that code, any other with `Unexpected`; a value of the wrong kind is `InvalidData`; the method's name is the `subject`. `localAddr` / `peerAddr` are `NotConnected` over it.
- A failed handshake closes what is underneath. There is no kernel lane under TLS: `direct.write` always takes 0 bytes, use `queued`. A connection cut without `close_notify` is `UnexpectedEof`, never an end of stream.

- **Cost notes.** `send` copies `data` when called and resolves once it is all in the transport; sends go out in the order made. `read` allocates its result; `readCopy` copies into your buffer and detaches nothing.
- **Truncation is an error.** `read` resolves empty only after the peer's `close_notify`. A connection that ends without it rejects `UnexpectedEof`, also during the handshake.
- **`end('write')`** sends `close_notify`, then the FIN (or the duck-typed stream's `end('write')`); later `send`s reject `BrokenPipe`. It does not close the transport; `close()` does and ends pending operations.
- **Errors.** `CertificateRejected` (`subject`: `UnknownIssuer`, `Expired`, `NotYetValid`, `NotValidForName`, `Revoked`, `BadSignature`, ...), `TlsAlert` (`subject`: the alert), `NoApplicationProtocol`, `ProtocolError`, `UnexpectedEof`, `InvalidData` (bad certificate or key), `InvalidInput` (bad server name), `BrokenPipe` (after `end` or a dropped write), plus the transport's own (`ConnectionReset`, ..., or a duck-typed stream's code).

**Lifetime.** `RootPki`, `Identity`, `TlsSessions`, `TlsClient` and `TlsServer` are owned by the garbage collector: the native value lives in V8's cppgc heap and is owned by the instance itself (there is no JS wrapper around it), so it is freed when the instance is collected, or at once on `release()` (later use throws `BadHandle`); anything built from them keeps its own copy, so collecting a `RootPki` never breaks a live `TlsClient`. TLS streams are handles like the sockets: closed explicitly (`close()`, or with their `io`).
