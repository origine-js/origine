# `api.http`: HTTP/2

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
    exchange.respond({ status: 200, headers: http.fields.of([['content-type', 'text/plain']]), body: 'stream' });
    await exchange.send(new Uint8Array([104, 105]));
    exchange.finish();
  }
})();

await client.ready();                                    // the peer's SETTINGS: open streams after this
const get = client.open({ method: 'GET', scheme: 'http', authority: 'example.test', path: '/' });
for (let ev; (ev = await get.next()); ) if (ev.type === 'data') get.consume(ev.data.length);
await client.close();
```

## `protocols.h2`: HTTP/2 frame by frame

`api.http.protocols` is a table of protocol tables keyed by ALPN id: `h2` (nghttp2) and `h3` (same shape; every call throws `Unsupported` until QUIC exists). The caller negotiates: build TLS with [`api.tls`](tls.md) and your own `alpn` list, read `stream.info().alpn`, pick `api.http.protocols[alpn]`; over cleartext (h2c) pick `h2` yourself. Nothing is negotiated inside `api.http`.

```js
const { h2 } = api.http.protocols;
const settings = { headerTableSize: 4096, enablePush: false, maxConcurrentStreams: 100, initialWindowSize: 65535,
  maxFrameSize: 16384, maxHeaderListSize: 16384, enableConnectProtocol: false, noRfc7540Priorities: false };
const options = { settings, window: 1 << 20, batch: 4096, padding: 0, extensions: [], frames: 'parsed' };
const client = h2.client(stream, options).pulling();        // consumes `stream`
const id = client.submitHeaders(0, api.http.fields.of([[':method', 'GET'], [':scheme', 'https'],
  [':authority', 'example.test'], [':path', '/']]), { endStream: true });
for await (const frame of client) {
  if (frame.type === 'headers' && frame.streamId === id) console.log(frame.headers.get(':status'));
  if (frame.type === 'data') { client.consume(frame.streamId, frame.data.length); frame.data.unref(); }
  if (frame.type === 'closed' && frame.streamId === id) break;
}
client.submitGoaway(0, 0, new Uint8Array(0));
await client.close();
```

- **Sessions.** `h2.client(stream, options)` / `h2.server(stream, options)` take a native stream (TCP or TLS, consumed; one nothing is using) or a duck-typed stream (see [tls.md](tls.md); `options.io` is required for one), and return an `H2SessionUnshaped`: its SETTINGS are queued, nothing flows. `pulling()` gives a `PullH2Session` (`next()` and `for await`), `evented()` an `EventH2Session` (`register(type, handler)`, `pause()`, `resume()`, `paused`; handlers as in [net](net.md): one event at a time, in order, a returned promise is not awaited; events wait while no handler is registered). The classes are `h2.H2SessionUnshaped`, `h2.PullH2Session` and `h2.EventH2Session`, defined in Rust and owned by the garbage collector; `close()` (or the `io`'s) ends the session now and the object answers `BadHandle`.
- **Options, all required** but `io`: `settings` (every SETTINGS parameter), `window` (the connection's receive window, at least 65535), `batch` (header blocks arrive in batches of about this many bytes), `padding` (bytes of padding on every HEADERS and DATA frame, 0 for none), `extensions` (extension frame types received as `unknown` events), `frames` (`'parsed'`: header blocks must be valid HTTP messages; `'raw'`: nghttp2's HTTP messaging rules are off).
- **Frames in.** Every event is a frozen object whose `type` names it: `settings` (`ack`, `entries` as `[name, value]` pairs), `headers` (`streamId`, `category`: `request` / `response` / `push_response` / `headers` / `push_promise`, `headers`: a sealed `HeaderList` of this batch with pseudo header fields first, `last`, `endStream`, `padding`, `priority?`), `data` (`streamId`, `data`: a `Lease` of the frame's payload, `endStream`, `padding`), `priority`, `priority_update`, `rst_stream`, `push_promise` (`promisedStreamId`, after its `headers`), `ping` (`data`, `ack`), `goaway` (`lastStreamId`, `code`, `debug`), `window_update`, `altsvc`, `origin`, `unknown` (`frameType`, `flags`, `streamId`, `payload`), `invalid` (a frame nghttp2 refused, with its `reason`) and `closed` (a stream is over, `code`). An event session also has `error` and `close`; `next()` rejects once with the failure, then answers `undefined`.
- **Frames out.** Stateless submits on the session: `submitHeaders(streamId | 0, headers, { endStream, padding? })` (0 opens a stream, a client's; a block that does not end the stream opens its DATA; one on a stream with DATA still queued is sent after it as trailers and must end the stream), `submitData(streamId, bytes, { endStream, padding? })` (copies; resolves once packed into frames inside the peer's windows: that is the backpressure), `submitPriority(streamId, value)` (RFC 9218 PRIORITY_UPDATE, a client's; `InvalidInput` until the peer set `noRfc7540Priorities`: nghttp2 1.68 sends no RFC 7540 PRIORITY frames), `submitRst`, `submitSettings(partial)` (any time), `submitPing(8 bytes, { ack })`, `submitGoaway(lastStreamId, code, debug)`, `submitWindowUpdate(streamId | 0, increment)`, `submitPush(streamId, headers)` (returns the promised id), `submitAltsvc`, `submitOrigin`, `submitExtension(type, flags, streamId, payload)`.
- **Nothing implicit.** PINGs are not answered for you (answer with `submitPing(data, { ack: true })`), received DATA stays unacknowledged until `consume(streamId, bytes)` (or a `submitWindowUpdate`), and no GOAWAY is sent on `close()`.
- **Info.** `localSettings` (as the peer acknowledged them), `remoteSettings`, `streamState(id)`, `windows(id)` (`{ send, receive }`; 0 is the connection), `nextStreamId`, `closed`.
- **Cost notes.** A DATA payload is copied once into V8 memory for its `Lease`; a header batch is one `HeaderList`. A duck-typed stream adds a turn of the loop and a copy per read and write.

## `fields`: `HeaderList`

`api.http.fields` is `HeaderList`, a class defined in Rust: `HeaderList.of([[name, value], ...])` makes one (`new` throws), `put(name, value)` appends, `get` / `getAll` / `has` (case-insensitive), `length`, `entries()` and iteration read it. Fields are checked when put (`InvalidInput`): lowercase token names, no connection-specific field, values without CR, LF or NUL, pseudo header fields only before the others. A list a session received is sealed (`put` is a `TypeError`).

## `connect` and `serve`

`await http.connect(io, { host?, port, tls?, servername?, mode, limits })` dials (`host` is an IP address, default `127.0.0.1`, checked against the [network ceiling](../../../docs/net-grant.md): loopback only by default) and resolves a `ClientSession` once the peer's SETTINGS arrived, so it can be used at once. With `tls` (a `TlsClient` whose `alpn` includes `'h2'`) the connection is TLS, `servername` (default `host`) is checked, and the peer must negotiate `h2`, else `NoApplicationProtocol` and the connection is closed. A failed dial or handshake closes the socket it made.

`http.serve(io, { listen?: { host?, port? }, tls?, mode, limits })` binds and listens and returns an `HttpServer`: `server.port`, `server.accept()` / `for await` (the requests of every connection, in arrival order, as `ServerExchange`s), `server.dropped` (connections dropped before they became sessions: a failed TLS handshake, or no `h2`), `server.close()` (stops listening, closes every session). **With `tls` every connection is TLS; without it the server speaks cleartext HTTP/2 (h2c)**, which is for loopback and tests: there is no option to mix them, and a TLS client reaching a cleartext server (or the reverse) fails its handshake. The server keeps the program alive until `close()`. Inputs (`limits`, `mode`, `port`) are checked before anything is dialed or bound; 

## Headers are a stream of fields

`HeaderList` (`api.http.fields`, above) is an ordered sequence, not a map. The message-level API below takes one for `open`, `respond` and `finish`, without pseudo header fields (they travel separately here). A header block you receive arrives as `headers` events in batches of about `limits.batch` bytes (`last` ends the block, `endStream` with it means the peer is done); the pseudo headers (`method`, `scheme`, `authority`, `path`, `status`) are properties of the first batch.

## Sessions and streams

`http.session(socket, { role, mode, limits })` is synchronous and **consumes** the socket (same rules as `tls.connect`: `WouldBlock` for a read pending or bytes queued, `Unsupported` for a subscribed socket; a refused call leaves the socket usable). `mode` is required (`'pull'` or `'event'`, see Event mode). `limits` has no defaults. Until `ready()` resolves the peer's limits are unknown, so open streams after it.

- `ClientSession.open(head, { headers?, body? })` queues a request head: `head` is `{ method, scheme, authority, path }`; `body: 'stream'` follows with `send` and `finish`. `ServerSession.accept()` (or `for await`) yields the request streams; `respond({ status, headers?, body? })` queues the response head.
- `exchange.next()` yields `headers`, `data`, `end` and `closed` events in order, then `undefined`. A connection that died with the stream open rejects with the cause (`UnexpectedEof`, `ConnectionReset`, `ProtocolError`, ...).
- **Backpressure is flow control.** Received `data` stays unacknowledged until `consume(bytes)`, so a slow reader slows the peer; `send` waits while the stream already has `limits.window` bytes queued and unsent, and `queued` shows them.
- **Lifetime.** A session keeps the program alive until `close()` (immediate: the transport is shut down, every stream ends) or its connection ends; `end()` starts a graceful close (GOAWAY) and streams in flight finish. Dropping an `Exchange` with `release()` cancels it if its own side is still being written, and lets it finish quietly if its side is complete (so a response just queued is not cut off); to abandon a request call `reset(8)`.
- **Errors.** `BrokenPipe` (the stream or session is over), `InvalidInput` (bad head or field), `ProtocolError` (`subject` says what), plus the transport's own. A header block over `limits.headers` resets the stream with code 11 (`ENHANCE_YOUR_CALM`).
- **Event mode.** `mode: 'event'` gives `EventServerSession`, `EventHttpServer` and `EventClientExchange` / `EventServerExchange` in place of the `Pull*` classes (the mode is visible in the class; `ClientSession` serves both). `server.register('request', exchange => ...)` (on a server or a server session) delivers each request, one nobody listens for is refused with `REFUSED_STREAM`; `exchange.register('headers' | 'data' | 'end' | 'close' | 'error', handler)` delivers a stream's events one at a time, in order, from the turn after the first `register`, so register everything at once. `register` returns `{ unregister() }`; a throwing handler goes to the `error` handlers, or is an unhandled rejection. Flow control is unchanged: call `consume(bytes)` when the data was used. Event servers, sessions and exchanges keep the program alive until closed or released, as in pull mode.
- **Not yet:** DNS lookups inside `connect` (pass the address, or give the pool a `lookup`), WebSocket (extended CONNECT), server push (off), HTTP/1.x, cookies, caching, response decompression.

## Pool, redirects and `fetch`

Built on `connect` and the sessions above; source `src/js/glue/http/client.js`. Host resolution stays yours: the pool dials what `lookup` returns (or an IP literal), and everything is subject to the [network ceiling](../../../docs/net-grant.md).

```js
const pool = http.pool(io, {
  mode: 'pull', limits,                                   // as http.connect
  sessions: { limit: 8, perKey: 2, idle: 30_000, queue: 64 },
  lookup: async name => (await resolver.lookup(name, { family: 'ipv4' }))[0].toString(),   // optional
});
const res = await http.fetch(pool, { method: 'GET', url: 'https://example.test/a', tls, redirect: { limit: 5, strip: ['authorization', 'cookie'] } });
for await (const chunk of res.body) use(chunk);          // reading to the end frees the stream
```

**`http.pool(io, { mode, limits, sessions, lookup? })`** returns a `ClientPool`. `sessions` has no defaults: `limit` (sessions over all origins, open or being dialed), `perKey` (per origin), `idle` (ms a session without streams is kept; `0` closes it with its last stream) and `queue` (requests allowed to wait; one more rejects `WouldBlock`). They are readable as `pool.sessions`; `pool.size`, `pool.waiting` and `pool.closed` are live.

- **Key.** `(scheme, host lowercased, port, TLS configuration object, servername)`. Two `TlsClient` objects are two keys even with equal contents.
- **`pool.open(target, head, options?)`** with `target = { scheme, host, port, tls?, servername? }` (`https` needs `tls`, `http` forbids it) and `head = { method, authority, path }` resolves the exchange of the pool's mode. It picks a session of the key whose open streams are below the peer's `SETTINGS_MAX_CONCURRENT_STREAMS` (`native.http.peer`); with none it dials another session, **one dial per key at a time**, if `perKey` and `limit` allow (at `limit` the idle session used longest ago, of any key, is closed first); else it waits. A host that is not an IP literal is passed to `lookup`; without one `open` rejects `InvalidInput`.
- **Dead sessions.** A session the peer sent GOAWAY on, that ended, or that was closed is not used for new streams; one with streams in flight drains and then closes. A reused session that turns out dead when the stream is opened is dropped and another is taken (a session dialed for this very request that fails throws).
- **What holds a slot.** An exchange from the pool holds a stream slot until its `closed` event is read (pull) or delivered (event), its connection dies, or you call `release()`. Read it to the end or release it. Sessions keep the program alive until `idle` expires or `pool.close()` (closes every session now, rejects the waiting requests with `BadHandle`).
- Costs, as the guidelines ask: `open` may dial (a socket, a TLS handshake, a timer per idle session); nothing is copied or buffered.

**`http.fetch(pool, request)`** needs a pool in `'pull'` mode and resolves a `FetchResponse` when the final head arrived (1xx blocks are skipped). `request` is `{ method, url, headers?, body?, tls?, redirect }`:

- `url` is an absolute `http:` or `https:` URL without userinfo (`TypeError` otherwise); `tls` is used for every `https` hop.
- `body` is bytes (copied as it is sent, and sent again after a 307/308) or an async iterable of bytes (consumed once, flow-controlled by `send`). It is sent while the response is read; an error in the iterable resets the stream (`CANCEL`) and fails the response body with that error.
- **`redirect: { limit, strip }` is required.** `limit: 0` follows nothing and returns the 3xx response. Followed statuses are 301, 302, 303, 307, 308 with a `Location` (resolved per RFC 3986, fragment dropped). Method rules (RFC 9110 15.4): 301 and 302 turn `POST` into `GET`; 303 turns everything but `GET` and `HEAD` into `GET`; 307 and 308 keep method and body. A rewrite to `GET` drops the body and `content-length`, `content-type`, `content-encoding`, `content-language`, `content-location`. When the origin changes, the lowercase names in `strip` are dropped (put `authorization`, `cookie` and `proxy-authorization` there). Errors: past `limit` `QuotaExceeded`; a `Location` that is not an http(s) URL `ProtocolError`; https to http `PermissionDenied`; http to https without `tls` `Unsupported`; a 307/308 with a stream body `Unsupported`. Redirect responses are cancelled (`reset(8)`), not drained.
- **`FetchResponse`** has `status`, `headers` (a frozen `HeaderList`), `url` (last hop), `redirected`, `body`, `trailers` (set once the body was read) and `close()` / `dispose`. `body` is an async iterable of `Uint8Array`, readable once. **Flow control:** a chunk counts as used, and its bytes are given back to the peer's window with `consume`, when the next chunk is asked for; stopping the loop early cancels the stream. The response holds a stream slot until the body ends, the iteration stops or `close()`; a response whose head ended the stream (HEAD, 204) frees it at once.
