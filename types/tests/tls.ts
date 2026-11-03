// Positive cases and `@ts-expect-error` negatives for api.tls. Type-checked only, never run.
import { SocketAddr } from 'origine:@std/net';
import type { Api, EventTcpStream, PullTcpStream, TcpStreamUnshaped, TlsClient, TlsServer } from '@origine/types';

export async function main(api: Api, pem: Uint8Array): Promise<void> {
  const { tls } = api;
  const io = api.io.create();
  const roots = tls.RootPki.fromPem(pem);
  const client: TlsClient = tls.client({ roots, alpn: ['h2'], sessions: tls.TlsSessions.create({ limit: 8 }) });
  const server: TlsServer = tls.server({ identities: [tls.Identity.fromPem(pem, pem)], clientAuth: tls.ClientAuth.none() });

  const listener = io.tcp.listen(SocketAddr.parse('127.0.0.1:0')).pulling();
  const plain = await io.tcp.connect(listener.localAddr);
  const unshaped: TcpStreamUnshaped = await client.connect(plain, { servername: 'localhost' });
  const secure: PullTcpStream = unshaped.pulling();
  const peer = (await server.accept(await listener.accept())).pulling();
  await secure.queued.send(new Uint8Array([1]));
  const chunk: Uint8Array = await peer.read(16);
  const alpn: string | undefined = tls.info(secure).alpn;
  const certs: Uint8Array[] = tls.info(secure).peer;
  await secure.end('write');
  const evented: EventTcpStream = (
    await client.connect((await io.tcp.connect(listener.localAddr)).pulling(), { servername: 'localhost' })
  ).evented();
  void [chunk, alpn, certs, evented];

  // @ts-expect-error roots are required: there is no default trust
  tls.client({});
  // @ts-expect-error clientAuth is required
  tls.server({ identities: [] });
  // @ts-expect-error the servername is required
  await client.connect(plain, {});
  // @ts-expect-error only a native stream: a listener is not one
  await client.connect(listener, { servername: 'localhost' });
  // @ts-expect-error values are made by their named constructors
  new tls.RootPki();
}
