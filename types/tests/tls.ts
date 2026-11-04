// Positive cases and `@ts-expect-error` negatives for api.tls. Type-checked only, never run.
import { SocketAddr } from 'origine:@std/net';
import type { Api, DuckStream, EventTlsStream, PullTlsStream, TlsClient, TlsServer, TlsStreamUnshaped } from '@origine/types';

export async function main(api: Api, pem: Uint8Array): Promise<void> {
  const { tls } = api;
  const io = api.io.create();
  const roots = tls.RootPki.fromPem(pem);
  const client: TlsClient = tls.client({ roots, alpn: ['h2'], sessions: tls.TlsSessions.create({ limit: 8 }) });
  const server: TlsServer = tls.server({ identities: [tls.Identity.fromPem(pem, pem)], clientAuth: tls.ClientAuth.none() });

  const listener = io.tcp.listen(SocketAddr.parse('127.0.0.1:0')).pulling();
  const plain = await io.tcp.connect(listener.localAddr);
  const unshaped: TlsStreamUnshaped = await client.connect(plain, { servername: 'localhost' });
  const secure: PullTlsStream = unshaped.pulling();
  const peer = (await server.accept(await listener.accept())).pulling();
  await secure.queued.send(new Uint8Array([1]));
  const chunk: Uint8Array = await peer.read(16);
  const alpn: string | undefined = secure.info().alpn;
  const certs: Uint8Array[] = unshaped.info().peer;
  await secure.end('write');
  const evented: EventTlsStream = (
    await client.connect((await io.tcp.connect(listener.localAddr)).pulling(), { servername: 'localhost' })
  ).evented();
  // TLS over TLS: a TLS stream is a native stream.
  const inner: TlsStreamUnshaped = await client.connect(evented, { servername: 'inner' });
  // A duck-typed stream runs on the io it is given.
  const duck: DuckStream = {
    read: async length => new Uint8Array(Math.min(length, 0)),
    queued: { put: bytes => bytes.length, drained: async () => {} },
    end: () => {},
    close: () => {},
  };
  const overJs = await server.accept(duck, { io });
  const isTls: boolean = overJs instanceof tls.TlsStreamUnshaped && inner.pulling() instanceof tls.PullTlsStream;
  void [chunk, alpn, certs, evented, isTls];

  // @ts-expect-error roots are required: there is no default trust
  tls.client({});
  // @ts-expect-error clientAuth is required
  tls.server({ identities: [] });
  // @ts-expect-error the servername is required
  await client.connect(plain, {});
  // @ts-expect-error a listener is not a stream
  await client.connect(listener, { servername: 'localhost' });
  // @ts-expect-error `info` is a method of the TLS streams, not of `api.tls`
  tls.info(secure);
  // @ts-expect-error a duck-typed stream needs `queued`
  await client.connect({ read: async () => new Uint8Array(0), end() {}, close() {} }, { servername: 'localhost', io });
  // @ts-expect-error values are made by their named constructors
  new tls.RootPki();
}
