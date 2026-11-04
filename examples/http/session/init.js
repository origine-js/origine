// Run: zig build run -- examples/http/session/init.js   (or: zig-out/bin/origine examples/http/session/init.js)
// HTTP/2 sessions over a plain native stream (cleartext h2c, for loopback). Each side consumes its socket and gets a
// session. The client opens streams, the server accepts them as exchanges. Flow control is explicit: received data
// stays unacknowledged until consume(bytes). limits have no defaults; `ready()` is when the peer's limits are known.
//
// Prints (stderr):
//   server: GET /hello -> 200, sent 2 bytes
//   client: status 200, content-type text/plain, body "hi"
import { encodeUtf8, decodeUtf8 } from 'origine:@std/text';
import { eprintln } from 'origine:@std/debug';
import { SocketAddr } from 'origine:@std/net';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const { http } = api;
  const limits = { streams: 100, headers: 16384, window: 65535, connection: 1 << 20, batch: 4096 };
  const io = api.io.create({});
  try {
    const listener = io.tcp.listen(SocketAddr.parse('127.0.0.1:0')).pulling();
    const [clientSocket, serverSocket] = await Promise.all([io.tcp.connect(listener.localAddr), listener.accept()]);
    const server = http.session(serverSocket, { role: 'server', mode: 'pull', limits });
    const client = http.session(clientSocket, { role: 'client', mode: 'pull', limits });

    // Server: one exchange per request. Read the request's events (consuming the bytes), then respond.
    const serving = (async () => {
      for await (const exchange of server) {
        let request;
        for (let event; (event = await exchange.next());) {
          // The pseudo headers (method, path, ...) are on the first batch of the request's header block.
          if (event.type === 'headers' && event.method !== undefined) request = event;
          if (event.type === 'headers' && event.endStream) break;
          if (event.type === 'data') exchange.consume(event.data.length);
        }
        exchange.respond({ status: 200, headers: http.fields.of([['content-type', 'text/plain']]), body: 'stream' });
        await exchange.send(encodeUtf8('hi'));
        exchange.finish();
        eprintln(`server: ${request.method} ${request.path} -> 200, sent 2 bytes`);
        break;
      }
    })();

    await client.ready();
    const get = client.open({ method: 'GET', scheme: 'http', authority: 'example.test', path: '/hello' });
    let status,
      contentType,
      body = '';
    for (let event; (event = await get.next());) {
      // The response's :status is a pseudo header of its first batch; other fields come in HeaderList form.
      if (event.type === 'headers' && event.status !== undefined) status = event.status;
      if (event.type === 'headers') contentType ??= event.headers.get('content-type');
      if (event.type === 'data') {
        body += decodeUtf8(event.data);
        get.consume(event.data.length);
      }
    }
    eprintln(`client: status ${status}, content-type ${contentType}, body "${body}"`);

    await serving;
    await client.close();
    await server.close();
    await listener.close();
  } finally {
    await io.close();
  }
}
