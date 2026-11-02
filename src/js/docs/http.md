# `api.http`: HTTP/2 sessions

`api.http` exists wherever `api.net` does and is built with `-Dhttp` (on by default; without it the getter throws `PermissionDenied`). HTTP/2 only (nghttp2), over a pull-mode [`api.net`](net.md) socket (cleartext h2c, for loopback) or a [`api.tls`](tls.md) socket negotiated with ALPN `h2`. Design and decisions: [docs/http-design.md](../../../docs/http-design.md). The Rust side: [`origine_h2`](../../../rust/crates/origine_h2/docs/README.md), natives in [natives.md](../../../rust/crates/origine_api/docs/natives.md#http-http2-needs--runtime).

```js
const { http } = api;
const limits = { streams: 100, headers: 16384, window: 65535, connection: 1 << 20, batch: 4096 };
const server = http.session(acceptedSocket, { role: 'server', mode: 'pull', limits });
const client = http.session(connectedSocket, { role: 'client', mode: 'pull', limits });   // both consume their socket

(async () => {
  for await (const exchange of server) {                 // one per request
    for (let ev; (ev = await exchange.next()); ) {
      if (ev.type === 'headers' && ev.endStream) break;
      if (ev.type === 'data') exchange.consume(ev.data.length);
    }
    exchange.respond({ status: 200, headers: new http.HeaderList().put('content-type', 'text/plain'), body: 'stream' });
    await exchange.send(new Uint8Array([104, 105]));
    exchange.finish();
  }
})();

await client.ready();                                    // the peer's SETTINGS: open streams after this
const get = client.open({ method: 'GET', scheme: 'http', authority: 'example.test', path: '/' });
for (let ev; (ev = await get.next()); ) if (ev.type === 'data') get.consume(ev.data.length);
await client.close();
```

## `connect` and `serve`

`await http.connect(io, { host?, port, tls?, servername?, mode, limits })` dials (`host` is an IP address, default `127.0.0.1`, checked against the [network ceiling](../../../docs/net-grant.md): loopback only by default) and resolves a `ClientSession` once the peer's SETTINGS arrived, so it can be used at once. With `tls` (a `TlsClient` whose `alpn` includes `'h2'`) the connection is TLS, `servername` (default `host`) is checked, and the peer must negotiate `h2`, else `NoApplicationProtocol` and the connection is closed. A failed dial or handshake closes the socket it made.

`http.serve(io, { listen?: { host?, port? }, tls?, mode, limits })` binds and listens and returns an `HttpServer`: `server.port`, `server.accept()` / `for await` (the requests of every connection, in arrival order, as `ServerExchange`s), `server.dropped` (connections dropped before they became sessions: a failed TLS handshake, or no `h2`), `server.close()` (stops listening, closes every session). **With `tls` every connection is TLS; without it the server speaks cleartext HTTP/2 (h2c)**, which is for loopback and tests: there is no option to mix them, and a TLS client reaching a cleartext server (or the reverse) fails its handshake. The server keeps the program alive until `close()`. Inputs (`limits`, `mode`, `port`) are checked before anything is dialed or bound; 

## Headers are a stream of fields

`HeaderList` is an ordered sequence, not a map: `put(name, value)` appends (duplicates and order are kept), `get`, `getAll`, `has` (case-insensitive) and iteration read it. Names must be lowercase tokens and values UTF-8 strings without CR, LF or NUL (`TypeError`); connection-specific fields (`connection`, `keep-alive`, `transfer-encoding`, `upgrade`, `te` other than `trailers`) are refused (`InvalidInput`). A list you build is packed into one buffer and crosses into the native once, at `open`, `respond` or `finish`. A header block you receive arrives as `headers` events in batches of about `limits.batch` bytes (`last` ends the block, `endStream` with it means the peer is done); the pseudo headers (`method`, `scheme`, `authority`, `path`, `status`) are properties of the first batch.

## Sessions and streams

`http.session(socket, { role, mode, limits })` is synchronous and **consumes** the socket (same rules as `tls.connect`: `WouldBlock` for a read pending or bytes queued, `Unsupported` for a subscribed socket; a refused call leaves the socket usable). `mode` is required and only `'pull'` exists. `limits` has no defaults. Until `ready()` resolves the peer's limits are unknown, so open streams after it.

- `ClientSession.open(head, { headers?, body? })` queues a request head: `head` is `{ method, scheme, authority, path }`; `body: 'stream'` follows with `send` and `finish`. `ServerSession.accept()` (or `for await`) yields the request streams; `respond({ status, headers?, body? })` queues the response head.
- `exchange.next()` yields `headers`, `data`, `end` and `closed` events in order, then `undefined`. A connection that died with the stream open rejects with the cause (`UnexpectedEof`, `ConnectionReset`, `ProtocolError`, ...).
- **Backpressure is flow control.** Received `data` stays unacknowledged until `consume(bytes)`, so a slow reader slows the peer; `send` waits while the stream already has `limits.window` bytes queued and unsent, and `queued` shows them.
- **Lifetime.** A session keeps the program alive until `close()` (immediate: the transport is shut down, every stream ends) or its connection ends; `end()` starts a graceful close (GOAWAY) and streams in flight finish. Dropping an `Exchange` with `release()` cancels it if its own side is still being written, and lets it finish quietly if its side is complete (so a response just queued is not cut off); to abandon a request call `reset(8)`.
- **Errors.** `BrokenPipe` (the stream or session is over), `InvalidInput` (bad head or field), `ProtocolError` (`subject` says what), plus the transport's own. A header block over `limits.headers` resets the stream with code 11 (`ENHANCE_YOUR_CALM`).
- **Event mode.** `mode: 'event'` gives `EventServerSession`, `EventHttpServer` and `EventClientExchange` / `EventServerExchange` in place of the `Pull*` classes (the mode is visible in the class; `ClientSession` serves both). `server.register('request', exchange => ...)` (on a server or a server session) delivers each request, one nobody listens for is refused with `REFUSED_STREAM`; `exchange.register('headers' | 'data' | 'end' | 'close' | 'error', handler)` delivers a stream's events one at a time, in order, from the turn after the first `register`, so register everything at once. `register` returns `{ unregister() }`; a throwing handler goes to the `error` handlers, or is an unhandled rejection. Flow control is unchanged: call `consume(bytes)` when the data was used. Event servers, sessions and exchanges keep the program alive until closed or released, as in pull mode.
- **Not yet:** a connection pool, redirects, DNS lookups inside `connect` (look the name up with `api.dns` and pass the address), WebSocket (extended CONNECT), server push (off).
