// Positive cases and `@ts-expect-error` negatives for api.net. Type-checked only, never run.
import type { Api, EventServer, EventSocket, PullServer, PullSocket, Socket } from "@origine/types";

type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends <T>() => T extends B ? 1 : 2 ? true : false;
const assertType = <_T extends true>() => {};

export async function main(api: Api): Promise<void> {
  const io = api.io.create();

  // --- pull mode -------------------------------------------------------------------------
  const server = api.net.listen(io, { port: 0, mode: "pull", socketMode: "pull" });
  assertType<Equal<typeof server, PullServer<"pull">>>();
  const client = await api.net.connect(io, { port: server.port, mode: "pull" });
  assertType<Equal<typeof client, PullSocket>>();
  assertType<Equal<typeof client, Socket<"pull">>>();
  const conn = await server.accept();
  assertType<Equal<typeof conn, PullSocket>>();
  const sent: Promise<void> = client.queued.send(new Uint8Array([1, 2, 3]));
  await sent;
  const chunk: Uint8Array = await conn.read(4096);
  const { bytes, buffer }: { bytes: number; buffer: ArrayBuffer } = await conn.readInto(new Uint8Array(16));
  const copied: number = await conn.readCopy(new Uint8Array(16));
  const taken: number = client.queued.put(chunk);
  const wrote: number = client.direct.write(new ArrayBuffer(4));
  client.queued.limit = 1024;
  await client.end("write");
  await client.end("both");
  await client.close();
  await using _owned = await api.net.connect(io, { port: server.port, mode: "pull", host: "localhost", sendQueueLimit: 4096 });
  void [bytes, buffer, copied, taken, wrote];

  // --- event mode ------------------------------------------------------------------------
  const evServer = api.net.listen(io, { mode: "event", socketMode: "event" });
  assertType<Equal<typeof evServer, EventServer<"event">>>();
  evServer.register("connection", socket => {
    assertType<Equal<typeof socket, EventSocket>>();
    socket.register("data", event => {
      using lease = event.buffer();
      const n: number = event.length;
      const first: number | undefined = lease[0];
      socket.pause();
      void socket.queued.send(lease).then(() => socket.resume());
      void [n, first];
    });
    socket.register("end", () => void socket.end("write"));
    socket.register("error", (error: unknown) => void error);
    socket.register("drain", () => {});
    const registration = socket.register("close", () => {});
    const removed: boolean = registration.unregister();
    void removed;
  });
  const evClient = await api.net.connect(io, { port: evServer.port, mode: "event" });
  assertType<Equal<typeof evClient, EventSocket>>();
  await io.run();

  // A server's socketMode types what it hands out.
  const mixed = api.net.listen(io, { mode: "pull", socketMode: "event" });
  const accepted = await mixed.accept();
  assertType<Equal<typeof accepted, EventSocket>>();
  assertType<Equal<ReturnType<typeof mixed.toEvent>, EventServer<"event">>>();

  // Transfers consume the old handle and give the other type.
  const asEvent: EventSocket = client.toEvent();
  const asPull: PullSocket = asEvent.toPull();
  const evFromPullServer: EventServer<"pull"> = api.net.listen(io, { mode: "pull", socketMode: "pull" }).toEvent();
  void [asPull, evFromPullServer];

  // A dynamic mode gives the union, which has only the shared write side.
  const dynamic = await api.net.connect(io, { port: 1, mode: Math.random() > 0.5 ? "pull" : "event" });
  void dynamic.queued.bytes;
  if ("read" in dynamic) void dynamic.read(1);
  else void dynamic.pause();

  // --- negatives -------------------------------------------------------------------------

  // @ts-expect-error `mode` is required when connecting
  await api.net.connect(io, { port: 1 });
  // @ts-expect-error `mode` is required when listening
  api.net.listen(io, { socketMode: "pull" });
  // @ts-expect-error `socketMode` is required when listening
  api.net.listen(io, { mode: "pull" });
  // @ts-expect-error `port` is required when connecting
  await api.net.connect(io, { mode: "pull" });
  // @ts-expect-error unknown mode
  await api.net.connect(io, { port: 1, mode: "push" });
  // @ts-expect-error misspelled option key
  await api.net.connect(io, { port: 1, mode: "pull", sendQueueLimt: 10 });
  // @ts-expect-error misspelled option key (listen)
  api.net.listen(io, { mode: "pull", socketMode: "pull", prot: 0 });
  // @ts-expect-error no allowHalfOpen option: the call says it, end('write')
  api.net.listen(io, { mode: "pull", socketMode: "pull", allowHalfOpen: true });
  // @ts-expect-error `end` needs a side
  await client.end();
  // @ts-expect-error not a side
  await client.end("send");
  // @ts-expect-error `read` is a pull method: an event socket has no read
  void evClient.read(10);
  // @ts-expect-error `register` is an event method: a pull socket has no register
  client.register("data", () => {});
  // @ts-expect-error `pause` does not exist on a pull socket
  client.pause();
  // @ts-expect-error `accept` does not exist on an event server
  await evServer.accept();
  // @ts-expect-error `toPull` does not exist on a pull socket
  client.toPull();
  // @ts-expect-error `toEvent` does not exist on an event socket
  evClient.toEvent();
  // @ts-expect-error `send` takes bytes, not a string
  await client.queued.send("hello");
  // @ts-expect-error `send` takes bytes, not a number
  await client.queued.send(42);
  // @ts-expect-error `put` returns the number of bytes taken, not a boolean
  const fit: boolean = client.queued.put(chunk);
  // @ts-expect-error `direct.write` takes bytes
  client.direct.write("x");
  // @ts-expect-error `read` takes a length
  await conn.read();
  // @ts-expect-error unknown event name
  evClient.register("message", () => {});
  // @ts-expect-error the `data` handler gets a DataEvent, not bytes
  evClient.register("data", (bytes: Uint8Array) => bytes.length);
  // @ts-expect-error `queued.bytes` is read-only
  client.queued.bytes = 0;
  // @ts-expect-error `closed` is read-only
  client.closed = true;
  void fit;
}
