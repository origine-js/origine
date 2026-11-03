// Positive cases and `@ts-expect-error` negatives for io.tcp / io.udp and api.net. Type-checked only, never run.
import { SocketAddr } from 'origine:@std/net';
import type {
  Api,
  DataEvent,
  DatagramEvent,
  EventTcpListener,
  EventTcpStream,
  EventUdpSocket,
  Lease,
  PullTcpListener,
  PullTcpStream,
  PullUdpSocket,
  TcpListenerUnshaped,
  TcpStreamUnshaped,
} from '@origine/types';

type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends <T>() => T extends B ? 1 : 2 ? true : false;
const assertType = <_T extends true>() => {};

export async function main(api: Api): Promise<void> {
  const io = api.io.create();
  const any = SocketAddr.parse('127.0.0.1:0');

  // --- pull ------------------------------------------------------------------------------
  const unshaped = io.tcp.listen(any);
  assertType<Equal<typeof unshaped, TcpListenerUnshaped>>();
  const server = unshaped.pulling();
  assertType<Equal<typeof server, PullTcpListener>>();
  const port: number = server.localAddr.port;
  const raw = await io.tcp.connect(server.localAddr);
  assertType<Equal<typeof raw, TcpStreamUnshaped>>();
  const client = raw.pulling({ queued: { limit: 4096 } });
  assertType<Equal<typeof client, PullTcpStream>>();
  const conn = (await server.accept()).pulling();
  const sent: Promise<void> = client.queued.send(new Uint8Array([1, 2, 3]));
  await sent;
  const chunk: Uint8Array = await conn.read(4096);
  const { bytes, buffer }: { bytes: number; buffer: ArrayBuffer } = await conn.readInto(new Uint8Array(16));
  const copied: number = await conn.readCopy(new Uint8Array(16));
  const taken: number = client.queued.put(chunk);
  const wrote: number = client.direct.write(new ArrayBuffer(4));
  client.queued.limit = 1024;
  const peer: SocketAddr = client.peerAddr;
  await client.end('write');
  await client.end('both');
  await client.close();
  for await (const part of conn) void part.length;
  for await (const accepted of server) assertType<Equal<typeof accepted, TcpStreamUnshaped>>();
  await using _owned = (await io.tcp.connect(server.localAddr)).pulling();
  void [port, bytes, buffer, copied, taken, wrote, peer];

  // --- event -----------------------------------------------------------------------------
  const evServer = io.tcp.listen(any).evented();
  assertType<Equal<typeof evServer, EventTcpListener>>();
  evServer.register('connection', stream => {
    assertType<Equal<typeof stream, TcpStreamUnshaped>>();
    const socket = stream.evented();
    socket.register('data', async (event: DataEvent) => {
      using lease = event.buffer();
      assertType<Equal<typeof lease, Lease>>();
      const n: number = event.length;
      await socket.queued.send(lease);
      void n;
    });
    socket.register('end', () => void socket.end('write'));
    socket.register('error', (error: unknown) => void error);
    socket.register('drain', () => {});
    const registration = socket.register('close', () => {});
    const removed: boolean = registration.unregister();
    void removed;
  });
  const evClient = (await io.tcp.connect(evServer.localAddr)).evented();
  assertType<Equal<typeof evClient, EventTcpStream>>();
  await io.run();

  // Transfers consume the old object and give the other shape.
  const asPull: PullTcpStream = evClient.toPulling();
  const asEvent: EventTcpStream = asPull.toEvented();
  void asEvent;

  // --- udp -------------------------------------------------------------------------------
  const udp = io.udp.bind(any).pulling();
  assertType<Equal<typeof udp, PullUdpSocket>>();
  const sentBytes: number = await udp.sendTo(new Uint8Array(1), any);
  const { data, addr }: { readonly data: Uint8Array; readonly addr: SocketAddr } = await udp.recvFrom(1500);
  udp.connect(addr);
  await udp.sendTo(data);
  const evUdp = io.udp.bind(any).evented();
  assertType<Equal<typeof evUdp, EventUdpSocket>>();
  evUdp.register('datagram', (event: DatagramEvent) => {
    using lease = event.buffer();
    const from: SocketAddr = event.from;
    void [lease.length, from];
  });
  void sentBytes;

  // --- timers ----------------------------------------------------------------------------
  await io.timer.sleep(1);
  const timer = io.timer.timerAt(io.timer.now() + 5);
  const canceled: boolean = timer.cancel();
  void canceled;

  // --- negatives -------------------------------------------------------------------------

  // @ts-expect-error an address is a SocketAddr, not a string
  io.tcp.listen('127.0.0.1:0');
  // @ts-expect-error nothing is resolved: no host/port options
  await io.tcp.connect({ host: 'localhost', port: 80 });
  // @ts-expect-error `end` needs a side
  await client.end();
  // @ts-expect-error not a side
  await client.end('send');
  // @ts-expect-error `read` is a pull method: an event stream has no read
  void evClient.read(10);
  // @ts-expect-error `register` is an event method: a pull stream has no register
  client.register('data', () => {});
  // @ts-expect-error an unshaped stream flows nothing
  void raw.read(1);
  // @ts-expect-error `accept` does not exist on an event listener
  await evServer.accept();
  // @ts-expect-error `toPulling` does not exist on a pull stream
  client.toPulling();
  // @ts-expect-error `send` takes bytes, not a string
  await client.queued.send('hello');
  // @ts-expect-error `put` returns the number of bytes taken, not a boolean
  const fit: boolean = client.queued.put(chunk);
  // @ts-expect-error unknown event name
  evClient.register('message', () => {});
  // @ts-expect-error the `data` handler gets a DataEvent, not bytes
  evClient.register('data', (bytes: Uint8Array) => bytes.length);
  // @ts-expect-error `queued.bytes` is read-only
  client.queued.bytes = 0;
  // @ts-expect-error `closed` is read-only
  client.closed = true;
  // @ts-expect-error the network objects have no public constructor
  new api.net.PullTcpStream();
  // @ts-expect-error misspelled option key
  raw.pulling({ queued: { limt: 1 } });
  void fit;
}
