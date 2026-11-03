// Run: zig build run -- examples/tls/client-auth/init.js   (or: zig-out/bin/origine examples/tls/client-auth/init.js)
// Client authentication. A server built with ClientAuth.require(roots) accepts only clients that present a certificate
// chaining to those roots; ClientAuth.none() asks for none. The client presents its identity through `identity`.
// The certificate used here is the test server pair, so it is valid as a client identity only for this example.
//
// Prints (stderr):
//   client with no identity: client connected, server ProtocolError (TLS 1.3 lets the client finish first)
//   client with an identity: connected
import { fs } from 'origine:@std/fs';
import { eprintln } from 'origine:@std/debug';
import { SocketAddr } from 'origine:@std/net';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const { tls } = api;
  const fixtures = fs(api.fs.requestSync({ handle: 'plain', root: 'examples/tls/fixtures', access: 'r' }));
  const ca = tls.RootPki.fromPem(fixtures.read('ca.pem'));
  const identity = () => tls.Identity.fromPem(fixtures.read('server.pem'), fixtures.read('server.key'));
  const server = tls.server({ identities: [identity()], clientAuth: tls.ClientAuth.require(ca) });

  const io = api.io.create({});
  try {
    const listener = io.tcp.listen(SocketAddr.parse('127.0.0.1:0')).pulling();
    const attempt = async client => {
      const [plainClient, plainServer] = await Promise.all([io.tcp.connect(listener.localAddr), listener.accept()]);
      const [clientSide, serverSide] = await Promise.allSettled([
        client.connect(plainClient, { servername: 'localhost' }),
        server.accept(plainServer),
      ]);
      if (clientSide.status === 'fulfilled') await clientSide.value.close();
      if (serverSide.status === 'fulfilled') await serverSide.value.close();
      return { clientSide, serverSide };
    };

    const anonymous = await attempt(tls.client({ roots: ca }));
    // TLS 1.3: the client's handshake completes before the server checks its certificate, so the refusal is seen by the server.
    const refused = anonymous.serverSide.status === 'rejected' ? anonymous.serverSide.reason.name : 'accepted';
    eprintln(`client with no identity: client ${anonymous.clientSide.status === 'fulfilled' ? 'connected' : 'failed'}, server ${refused}`);

    const withIdentity = await attempt(tls.client({ roots: ca, identity: identity() }));
    eprintln(
      `client with an identity: ${withIdentity.clientSide.status === 'fulfilled' ? 'connected' : withIdentity.clientSide.reason.name}`,
    );
    await listener.close();
  } finally {
    await io.close();
  }
}
