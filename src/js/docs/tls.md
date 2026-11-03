# `api.tls`: TLS over `api.net` sockets

`api.tls` exists wherever `api.net` does and is built with `-Dtls` (on by default; without it the getter throws `PermissionDenied`). It runs TLS 1.2/1.3 (rustls on aws-lc) over a pull-mode [`api.net`](net.md) stream socket. Design and decisions: [docs/http-design.md](../../../docs/http-design.md). The Rust side: [`origine_tls`](../../../rust/crates/origine_tls/docs/README.md), natives in [natives.md](../../../rust/crates/origine_api/docs/natives.md#tls-needs--runtime).

```js
const { tls } = api;
const client = tls.client({ roots: tls.RootPki.fromPem(caPem), alpn: ['h2'] });
const server = tls.server({ identities: [tls.Identity.fromPem(certPem, keyPem)], clientAuth: tls.ClientAuth.none() });
const secure = await client.connect(plainSocket, { servername: 'localhost', mode: 'pull' });  // consumes plainSocket
await secure.send(new Uint8Array([1, 2, 3]));
const chunk = await secure.read(4096);                // empty only after the peer's close_notify
await secure.end('write');                            // close_notify; reading still works
await secure.close();
```

## Values

`RootPki`, `Identity`, `ClientAuth` and `TlsSessions` are classes with named constructors that parse and validate where they are called (`InvalidData` for a bad certificate, a key that does not belong to the certificate, or no certificate at all). `RootPki.bundled()` is the Mozilla set compiled into the binary; `fromPem` / `fromDer` take your own. `tls.client({ roots, identity?, alpn?, sessions? })` has **no default trust** (`roots` is required) and resumes sessions only if you pass a `TlsSessions`. `tls.server({ identities, clientAuth, alpn? })` needs `clientAuth` (`ClientAuth.none()` or `ClientAuth.require(roots)`); it presents the first identity whose certificate is valid for the client's SNI name, else the first, and the client then refuses it. These classes, and `TlsClient` / `TlsServer`, are defined in Rust: `new RootPki()` is a `TypeError` (use the named constructors), every class and prototype is frozen, `instanceof` works, and a method called on anything but an instance of its class (or a `RootPki` passed where an `Identity` is expected) is a `TypeError`. `release()` forgets the native value (configurations already built keep working).

## Sockets

`client.connect(stream, { servername })` and `server.accept(stream)` **consume** a native stream (a `TcpStreamUnshaped`, or a `PullTcpStream` / `EventTcpStream` nothing is using): it answers `BadHandle` afterwards. They throw before touching it for a stream that has a read pending or bytes queued (`WouldBlock`), a handler or an ended side (`Unsupported`), or for anything that is not a native stream (`TypeError`); a failed handshake closes the transport. The handshake runs in Rust on the stream's socket without entering JS. The result is a **new `TcpStreamUnshaped`** whose bytes are plaintext: `pulling()` / `evented()` shape it, and everything a stream offers works on it: `read` / `readCopy` / `readInto`, `register('data' ...)`, `pause`, `queued.send`, `end('write')` (sends `close_notify`, then the FIN), `close()`. There is no kernel lane under TLS: `direct.write` always takes 0 bytes, use `queued`. A connection cut without `close_notify` is `UnexpectedEof`, never an end of stream. `tls.info(stream)` (any shape) returns what the handshake settled: `alpn`, `version` (`'tls1.2'` / `'tls1.3'`), `servername`, `resumed`, `peer` (DER certificates, leaf first); `BadHandle` for a plain or closed stream.

- **Cost notes.** `send` copies `data` when called and resolves once it is all in the transport; sends go out in the order made. `read` allocates its result; `readCopy` copies into your buffer and detaches nothing.
- **Truncation is an error.** `read` resolves empty only after the peer's `close_notify`. A connection that ends without it rejects `UnexpectedEof`, also during the handshake.
- **`end('write')`** sends `close_notify`; later `send`s reject `BrokenPipe`. It does not close the transport; `close()` does and ends pending operations.
- **Errors.** `CertificateRejected` (`subject`: `UnknownIssuer`, `Expired`, `NotYetValid`, `NotValidForName`, `Revoked`, `BadSignature`, ...), `TlsAlert` (`subject`: the alert), `NoApplicationProtocol`, `ProtocolError`, `UnexpectedEof`, `InvalidData` (bad certificate or key), `InvalidInput` (bad server name), `BrokenPipe` (after `end` or a dropped write), plus the transport's own (`ConnectionReset`, ...).

**Lifetime.** `RootPki`, `Identity`, `TlsSessions`, `TlsClient` and `TlsServer` are owned by the garbage collector: the native value lives in V8's cppgc heap and is owned by the instance itself (there is no JS wrapper around it), so it is freed when the instance is collected, or at once on `release()` (later use throws `BadHandle`); anything built from them keeps its own copy, so collecting a `RootPki` never breaks a live `TlsClient`. Sockets and servers are handles that keep the program alive and are closed explicitly.
