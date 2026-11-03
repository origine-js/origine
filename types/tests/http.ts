// Positive cases and `@ts-expect-error` negatives for api.http. Type-checked only, never run.
import { SocketAddr } from 'origine:@std/net';
import type {
  Api,
  ClientPool,
  ClientSession,
  FetchResponse,
  PullClientExchange,
  PullServerSession,
  ServerExchange,
  StreamEvent,
} from '@origine/types';

export async function main(api: Api): Promise<void> {
  const io = api.io.create();
  const limits = { streams: 100, headers: 16384, window: 65535, connection: 1 << 20, batch: 4096 };
  const listener = io.tcp.listen(SocketAddr.parse('127.0.0.1:0')).pulling();
  const plain = await io.tcp.connect(listener.localAddr);
  const accepted = await listener.accept();

  const client: ClientSession<'pull'> = api.http.session(plain, { role: 'client', mode: 'pull', limits });
  const server: PullServerSession = api.http.session(accepted, { role: 'server', mode: 'pull', limits });
  await client.ready();

  const headers = new api.http.HeaderList().put('accept', '*/*').put('x-dup', '1').put('x-dup', '2');
  const exchange = client.open({ method: 'GET', scheme: 'http', authority: 'example.test', path: '/' }, { headers });
  const first = await server.accept();
  first?.respond({ status: 200, headers, body: 'stream' });
  await first?.send(new Uint8Array([1]));
  first?.finish(headers);

  const event: StreamEvent | undefined = await exchange.next();
  if (event?.type === 'headers') {
    const status: number | undefined = event.status;
    const value: string | undefined = event.headers.get('content-type');
    void [status, value];
  } else if (event?.type === 'data') {
    const bytes: Uint8Array = event.data;
    exchange.consume(bytes.length);
  }
  const rtt: number = await client.ping();
  void rtt;

  // connect and serve: a server for every client, a session once the peer is ready.
  const front = api.http.serve(io, { listen: { port: 0 }, mode: 'pull', limits });
  const dialed: ClientSession = await api.http.connect(io, { port: front.port, mode: 'pull', limits });
  const request: ServerExchange | undefined = await front.accept();
  void [dialed, request, front.dropped];
  // @ts-expect-error a port is required to connect
  await api.http.connect(io, { mode: 'pull', limits });
  // @ts-expect-error limits are required
  api.http.session(plain, { role: 'client', mode: 'pull' });
  // @ts-expect-error a pull exchange has no register
  exchange.register('data', () => {});
  // Event mode: handlers instead of next() and accept().
  const evented = await api.http.serve(io, { listen: { port: 0 }, mode: 'event', limits });
  evented.register('request', request => {
    request.register('headers', event => {
      const path: string | undefined = event.path;
      void path;
    });
    request.register('data', event => request.consume(event.data.length));
    request.register('close', event => request.respond({ status: event.code === 0 ? 200 : 500 }));
  });
  const eventClient: ClientSession<'event'> = await api.http.connect(io, { port: evented.port, mode: 'event', limits });
  const eventExchange = eventClient.open({ method: 'GET', scheme: 'http', authority: 'x', path: '/' });
  const registration = eventExchange.register('end', () => {});
  const removed: boolean = registration.unregister();
  void removed;
  // @ts-expect-error an event server has no accept
  await evented.accept();
  // @ts-expect-error the handler of `data` gets the bytes
  eventExchange.register('data', (event: { type: 'end' }) => void event);
  // @ts-expect-error only a server exchange can respond
  exchange.respond({ status: 200 });
  // @ts-expect-error a session is made by http.session
  new api.http.ClientSession();

  // Pool and fetch: every size is required; fetch needs a pull pool and an explicit redirect policy.
  const pool: ClientPool<'pull'> = api.http.pool(io, {
    mode: 'pull',
    limits,
    sessions: { limit: 8, perKey: 2, idle: 30000, queue: 16 },
    lookup: async () => '127.0.0.1',
  });
  const pooled: PullClientExchange = await pool.open(
    { scheme: 'http', host: 'example.test', port: 80 },
    { method: 'GET', authority: 'example.test', path: '/' },
  );
  void pooled;
  const response: FetchResponse = await api.http.fetch(pool, {
    method: 'POST',
    url: 'http://example.test/',
    body: new Uint8Array(1),
    redirect: { limit: 5, strip: ['authorization'] },
  });
  for await (const chunk of response.body) {
    const size: number = chunk.length;
    void size;
  }
  const trailer: string | undefined = response.trailers?.get('x-done');
  void trailer;
  // @ts-expect-error a redirect policy is required
  await api.http.fetch(pool, { method: 'GET', url: 'http://example.test/' });
  // @ts-expect-error fetch reads in pull mode
  await api.http.fetch(api.http.pool(io, { mode: 'event', limits, sessions: { limit: 1, perKey: 1, idle: 0, queue: 0 } }), {
    method: 'GET',
    url: 'x',
    redirect: { limit: 0, strip: [] },
  });
  // @ts-expect-error the session policy has no defaults
  api.http.pool(io, { mode: 'pull', limits, sessions: { limit: 1 } });
  // @ts-expect-error a pool is made by http.pool
  new api.http.ClientPool();
}
