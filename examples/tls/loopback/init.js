// Run: zig build run -- examples/tls/loopback/init.js   (or: zig-out/bin/origine examples/tls/loopback/init.js)
// TLS over a native stream. The client and server consume their plain (unshaped) streams and return TLS streams,
// unshaped again: shape them with pulling() or evented() and use read, queued.send, end('write'), close. The handshake
// runs natively, without entering JS. The certificates are test material from
// examples/tls/fixtures (a CA and a server certificate for localhost; never trust them anywhere else).
//
// Prints (stderr):
//   client got "hello over tls" from the server
//   server got "hello, server" from the client
//   tls.info: version=tls1.3 servername=localhost peer certificates=1 resumed=false
//   wrong servername: client CertificateRejected (NotValidForName)
//   client that trusts no CA: client CertificateRejected (UnknownIssuer)
import { fs } from 'origine:@std/fs';
import { encodeUtf8, decodeUtf8 } from 'origine:@std/text';
import { eprintln } from 'origine:@std/debug';
import { SocketAddr } from 'origine:@std/net';

/** Connects a plain stream to the listener and accepts it on the other side (both unshaped). */
const plainPair = async (api, io, listener) => {
  const [client, server] = await Promise.all([io.tcp.connect(listener.localAddr), listener.accept()]);
  return { client, server };
};

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  // Certificates are read through a read-only grant of the fixtures directory.
  const fixtures = fs(api.fs.requestSync({ handle: 'plain', root: 'examples/tls/fixtures', access: 'r' }));
  const ca = fixtures.read('ca.pem');
  const { tls } = api;
  // The server presents its identity to any client; the client trusts exactly the CA it is given (no default trust).
  const server = tls.server({
    identities: [tls.Identity.fromPem(fixtures.read('server.pem'), fixtures.read('server.key'))],
    clientAuth: tls.ClientAuth.none(),
    alpn: ['h2'],
  });
  const client = tls.client({ roots: tls.RootPki.fromPem(ca), alpn: ['h2'] });

  const io = api.io.create({});
  try {
    const listener = io.tcp.listen(SocketAddr.parse('127.0.0.1:0')).pulling();

    // The handshake runs on both ends at once. Each side consumes its plain stream and gets a TLS stream back.
    const plain = await plainPair(api, io, listener);
    const [tlsClient, tlsServer] = await Promise.all([
      client.connect(plain.client, { servername: 'localhost' }),
      server.accept(plain.server),
    ]);
    const secureClient = tlsClient.pulling();
    const secureServer = tlsServer.pulling();

    await secureServer.queued.send(encodeUtf8('hello over tls'));
    eprintln(`client got "${decodeUtf8(await secureClient.read(64))}" from the server`);
    await secureClient.queued.send(encodeUtf8('hello, server'));
    eprintln(`server got "${decodeUtf8(await secureServer.read(64))}" from the client`);

    // tls.info describes what the handshake settled. It works on the TLS stream (any shape), not on the plain one.
    const info = tls.info(secureClient);
    eprintln(
      `tls.info: version=${info.version} servername=${info.servername} peer certificates=${info.peer.length} resumed=${info.resumed}`,
    );

    // The name the client asks for must be in the certificate. A wrong one fails the handshake on the client.
    const wrongName = await handshakeOutcome(api, io, listener, client, { servername: 'example.com' }, server);
    eprintln(`wrong servername: client ${wrongName}`);

    // A client whose roots are the bundled public CAs does not trust this test CA.
    const untrusted = tls.client({ roots: tls.RootPki.bundled(), alpn: ['h2'] });
    const unknown = await handshakeOutcome(api, io, listener, untrusted, { servername: 'localhost' }, server);
    eprintln(`client that trusts no CA: client ${unknown}`);

    await secureClient.close();
    await secureServer.close();
    await listener.close();
  } finally {
    await io.close();
  }
}

/** One fresh connection: runs both handshakes and names the client's error (or 'connected'). */
const handshakeOutcome = async (api, io, listener, tlsClient, options, tlsServer) => {
  const plain = await plainPair(api, io, listener);
  const [clientSide, serverSide] = await Promise.allSettled([tlsClient.connect(plain.client, options), tlsServer.accept(plain.server)]);
  if (serverSide.status === 'fulfilled') await serverSide.value.close();
  return clientSide.status === 'fulfilled' ? 'connected' : `${clientSide.reason.name} (${clientSide.reason.subject})`;
};
