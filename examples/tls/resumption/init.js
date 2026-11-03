// Run: zig build run -- examples/tls/resumption/init.js   (or: zig-out/bin/origine examples/tls/resumption/init.js)
// Session resumption on the client: a client resumes only when it is given a TlsSessions store (`limit` server names;
// a limit of 0 is a TypeError). Resumption also needs the server to issue session tickets, and tls.server has no option
// for that, so here the second handshake is a full one. tls.info(socket).resumed says which kind a handshake was.
//
// Prints (stderr):
//   first handshake: resumed=false (server got "round 1")
//   second handshake: resumed=false (server got "round 2"): the server issues no tickets, so nothing is resumed
import { fs } from 'origine:@std/fs';
import { eprintln } from 'origine:@std/debug';
import { encodeUtf8, decodeUtf8 } from 'origine:@std/text';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const { tls } = api;
  const fixtures = fs(api.fs.requestSync({ handle: 'plain', root: 'examples/tls/fixtures', access: 'r' }));
  const server = tls.server({
    identities: [tls.Identity.fromPem(fixtures.read('server.pem'), fixtures.read('server.key'))],
    clientAuth: tls.ClientAuth.none(),
  });
  const sessions = tls.TlsSessions.create({ limit: 8 });
  const client = tls.client({ roots: tls.RootPki.fromPem(fixtures.read('ca.pem')), sessions });

  const io = api.io.create({});
  try {
    const listener = api.net.listen(io, { port: 0, mode: 'pull', socketMode: 'pull' });
    for (let round = 1; round <= 2; round++) {
      const [plainClient, plainServer] = await Promise.all([api.net.connect(io, { port: listener.port, mode: 'pull' }), listener.accept()]);
      const [secureClient, secureServer] = await Promise.all([
        client.connect(plainClient, { servername: 'localhost', mode: 'pull' }),
        server.accept(plainServer, { mode: 'pull' }),
      ]);
      await secureClient.queued.send(encodeUtf8(`round ${round}`));
      const got = decodeUtf8(await secureServer.read(64));
      eprintln(`${round === 1 ? 'first' : 'second'} handshake: resumed=${tls.info(secureClient).resumed} (server got "${got}")`);
      await secureClient.close();
      await secureServer.close();
    }
    await listener.close();
  } finally {
    await io.close();
  }
}
