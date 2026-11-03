// Positive cases and `@ts-expect-error` negatives for api.tls. Type-checked only, never run.
import type { Api, EventSocket, PullSocket, TlsClient, TlsServer } from '@origine/types';

export async function main(api: Api, pem: Uint8Array): Promise<void> {
  const { tls } = api;
  const io = api.io.create();
  const roots = tls.RootPki.fromPem(pem);
  const client: TlsClient = tls.client({ roots, alpn: ['h2'], sessions: tls.TlsSessions.create({ limit: 8 }) });
  const server: TlsServer = tls.server({ identities: [tls.Identity.fromPem(pem, pem)], clientAuth: tls.ClientAuth.none() });

  const listener = api.net.listen(io, { port: 0, mode: 'pull', socketMode: 'pull' });
  const plain = await api.net.connect(io, { port: listener.port, mode: 'pull' });
  const secure: PullSocket = await client.connect(plain, { servername: 'localhost', mode: 'pull' });
  const peer = await server.accept(await listener.accept(), { mode: 'pull' });
  await secure.queued.send(new Uint8Array([1]));
  const chunk: Uint8Array = await peer.read(16);
  const alpn: string | undefined = tls.info(secure).alpn;
  const certs: Uint8Array[] = tls.info(secure).peer;
  await secure.end('write');
  const evented: EventSocket = await client.connect(await api.net.connect(io, { port: listener.port, mode: 'pull' }), {
    servername: 'localhost',
    mode: 'event',
  });
  void [chunk, alpn, certs, evented];

  // @ts-expect-error roots are required: there is no default trust
  tls.client({});
  // @ts-expect-error clientAuth is required
  tls.server({ identities: [] });
  // @ts-expect-error the mode is required
  await client.connect(plain, { servername: 'localhost' });
  // @ts-expect-error values are made by their named constructors
  new tls.RootPki();
}
