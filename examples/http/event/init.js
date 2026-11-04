// Run: zig build run -- examples/http/event/init.js   (or: zig-out/bin/origine examples/http/event/init.js)
// Event mode: the runtime pushes. A server registers 'request' and each request's stream registers its own events.
// The client exchange is event mode too. Handlers run from the host loop, in order, one event at a time. Flow control
// is unchanged: consume(bytes) once the data was used. A session keeps the program alive until it is closed, so
// the program ends by closing the sessions and the server.
//
// Prints (stderr):
//   server: GET /event answered
//   client: status 200, body "event mode"
import { encodeUtf8, decodeUtf8 } from 'origine:@std/text';
import { eprintln } from 'origine:@std/debug';

const limits = { streams: 100, headers: 16384, window: 65535, connection: 1 << 20, batch: 4096 };

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const { http } = api;
  const io = api.io.create({});
  try {
    const server = http.serve(io, { listen: { port: 0 }, mode: 'event', limits });

    // 'request' delivers each request. Register the stream's handlers at once, before the next turn.
    server.register('request', exchange => {
      exchange.register('headers', event => {
        if (event.method === undefined) return;
        eprintln(`server: ${event.method} ${event.path} answered`);
        exchange.respond({ status: 200, headers: http.fields.of([['content-type', 'text/plain']]), body: 'stream' });
        exchange.send(encodeUtf8('event mode')).then(() => exchange.finish());
      });
      exchange.register('data', event => exchange.consume(event.data.length));
    });

    const client = await http.connect(io, { port: server.port, mode: 'event', limits });
    const exchange = client.open({ method: 'GET', scheme: 'http', authority: 'example.test', path: '/event' });
    let status;
    let body = '';
    const done = new Promise(resolve => exchange.register('end', resolve));
    exchange.register('headers', event => {
      if (event.status !== undefined) status = event.status;
    });
    exchange.register('data', event => {
      body += decodeUtf8(event.data);
      exchange.consume(event.data.length);
    });
    await done;
    eprintln(`client: status ${status}, body "${body}"`);

    await client.close();
    await server.close();
  } finally {
    await io.close();
  }
}
