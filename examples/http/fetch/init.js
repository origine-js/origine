// Run: zig build run -- examples/http/fetch/init.js   (or: zig-out/bin/origine examples/http/fetch/init.js)
// A cleartext HTTP/2 server (http.serve, loopback) and the client side: a connection pool and fetch. fetch follows
// redirects only as far as redirect.limit says, and it strips the named headers when the origin changes. Reading the
// body to the end frees its stream; the pool keeps sessions per origin up to its limits.
//
// Prints (stderr):
//   fetch /moved: status 200, redirected true, body "hello, fetch"
//   POST /moved-post with 303: the method after the redirect is GET ("GET")
//   redirect.limit 0: status 301, location http://127.0.0.1:PORT/hello
//   redirect.limit 1 with two hops: QuotaExceeded
//   echo: got "ping" (4 bytes)
//   pool: sessions 1, waiting 0
import { encodeUtf8, decodeUtf8 } from 'origine:@std/text';
import { eprintln } from 'origine:@std/debug';

const limits = { streams: 100, headers: 16384, window: 65535, connection: 1 << 20, batch: 4096 };

/** Reads one request: its pseudo headers and its body. */
const readRequest = async exchange => {
  let head;
  let body = '';
  for (let event; (event = await exchange.next()); ) {
    if (event.type === 'headers' && event.method !== undefined) head = event;
    if (event.type === 'data') {
      body += decodeUtf8(event.data);
      exchange.consume(event.data.length);
    }
    if (event.type === 'end' || (event.type === 'headers' && event.endStream)) break;
  }
  return { method: head.method, path: head.path, body };
};

/** The routes of the example server. `base` is where the redirects point. */
const route = (request, base) => {
  switch (request.path) {
    case '/moved':
      return { status: 301, location: `${base}/hello` };
    case '/moved-post':
      return { status: 303, location: `${base}/method` };
    case '/loop':
      return { status: 302, location: `${base}/moved` };
    case '/hello':
      return { status: 200, body: 'hello, fetch' };
    case '/method':
      return { status: 200, body: request.method };
    case '/echo':
      return { status: 200, body: request.body };
    default:
      return { status: 404, body: 'not found' };
  }
};

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const { http } = api;
  const io = api.io.create({});
  try {
    const server = http.serve(io, { listen: { port: 0 }, mode: 'pull', limits });
    const base = `http://127.0.0.1:${server.port}`;

    // Each request is answered on its own; `for await` yields them in arrival order.
    const serving = (async () => {
      for await (const exchange of server) {
        const request = await readRequest(exchange);
        const answer = route(request, base);
        const headers = new http.HeaderList();
        if (answer.location) headers.put('location', answer.location);
        headers.put('content-type', 'text/plain');
        exchange.respond({ status: answer.status, headers, body: 'stream' });
        await exchange.send(encodeUtf8(answer.body ?? ''));
        exchange.finish();
      }
    })();

    const pool = http.pool(io, { mode: 'pull', limits, sessions: { limit: 8, perKey: 2, idle: 30_000, queue: 64 } });
    const text = async response => {
      let out = '';
      for await (const chunk of response.body) out += decodeUtf8(chunk);
      return out;
    };

    // Follows a 301 to /hello and reads the body to the end.
    const moved = await http.fetch(pool, { method: 'GET', url: `${base}/moved`, redirect: { limit: 5, strip: ['authorization', 'cookie'] } });
    eprintln(`fetch /moved: status ${moved.status}, redirected ${moved.redirected}, body "${await text(moved)}"`);

    // A 303 turns POST into GET: the redirected request has no body and the method is GET.
    const seeOther = await http.fetch(pool, { method: 'POST', url: `${base}/moved-post`, body: encodeUtf8('ignored'), redirect: { limit: 5, strip: [] } });
    eprintln(`POST /moved-post with 303: the method after the redirect is GET ("${await text(seeOther)}")`);

    // limit 0 follows nothing: the 3xx response is returned as it is.
    const raw = await http.fetch(pool, { method: 'GET', url: `${base}/moved`, redirect: { limit: 0, strip: [] } });
    eprintln(`redirect.limit 0: status ${raw.status}, location ${raw.headers.get('location')}`);
    await raw.close();

    // Past the limit the request fails with QuotaExceeded.
    const tooMany = await http.fetch(pool, { method: 'GET', url: `${base}/loop`, redirect: { limit: 1, strip: [] } }).then(
      () => 'ok',
      e => e.name,
    );
    eprintln(`redirect.limit 1 with two hops: ${tooMany}`);

    // A body of bytes is sent as it is; the echo route answers with what it received.
    const echo = await http.fetch(pool, { method: 'POST', url: `${base}/echo`, body: encodeUtf8('ping'), redirect: { limit: 0, strip: [] } });
    const echoed = await text(echo);
    eprintln(`echo: got "${echoed}" (${echoed.length} bytes)`);

    eprintln(`pool: sessions ${pool.size}, waiting ${pool.waiting}`);
    await pool.close();
    await server.close();
    await serving;
  } finally {
    await io.close();
  }
}
