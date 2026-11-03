// Run: zig build run -- examples/http/tls/init.js   (or: zig-out/bin/origine examples/http/tls/init.js)
// HTTP/2 over TLS: the server is built with a TLS server config (ALPN 'h2'), the client connects with a TLS client
// config that trusts the example CA. The connection negotiates h2 or fails with NoApplicationProtocol. Certificates
// are the test pair in examples/tls/fixtures.
//
// Prints (stderr):
//   https GET /secure: 200 "secure hello"
import { fs } from 'origine:@std/fs';
import { encodeUtf8, decodeUtf8 } from 'origine:@std/text';
import { eprintln } from 'origine:@std/debug';

const limits = { streams: 100, headers: 16384, window: 65535, connection: 1 << 20, batch: 4096 };

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const { tls, http } = api;
  const fixtures = fs(api.fs.requestSync({ handle: 'plain', root: 'examples/tls/fixtures', access: 'r' }));
  const serverTls = tls.server({
    identities: [tls.Identity.fromPem(fixtures.read('server.pem'), fixtures.read('server.key'))],
    clientAuth: tls.ClientAuth.none(),
    alpn: ['h2'],
  });
  const clientTls = tls.client({ roots: tls.RootPki.fromPem(fixtures.read('ca.pem')), alpn: ['h2'] });

  const io = api.io.create({});
  try {
    const server = http.serve(io, { listen: { port: 0 }, tls: serverTls, mode: 'pull', limits });
    const serving = (async () => {
      for await (const exchange of server) {
        for (let event; (event = await exchange.next()); ) if (event.type === 'headers' && event.endStream) break;
        exchange.respond({ status: 200, headers: new http.HeaderList().put('content-type', 'text/plain'), body: 'stream' });
        await exchange.send(encodeUtf8('secure hello'));
        exchange.finish();
        break;
      }
    })();

    // The name must be one the certificate is valid for: `servername` defaults to `host`, and `host` is an IP literal.
    const client = await http.connect(io, { host: '127.0.0.1', port: server.port, tls: clientTls, servername: 'localhost', mode: 'pull', limits });
    const exchange = client.open({ method: 'GET', scheme: 'https', authority: 'localhost', path: '/secure' });
    let status;
    let body = '';
    for (let event; (event = await exchange.next()); ) {
      if (event.type === 'headers' && event.status !== undefined) status = event.status;
      if (event.type === 'data') {
        body += decodeUtf8(event.data);
        exchange.consume(event.data.length);
      }
    }
    eprintln(`https GET /secure: ${status} "${body}"`);

    await serving;
    await client.close();
    await server.close();
  } finally {
    await io.close();
  }
}
