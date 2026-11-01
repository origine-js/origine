// Positive cases and `@ts-expect-error` negatives for api.http. Type-checked only, never run.
import type { Api, ClientSession, ServerExchange, ServerSession, StreamEvent } from "@origine/types";

export async function main(api: Api): Promise<void> {
  const io = api.io.create();
  const limits = { streams: 100, headers: 16384, window: 65535, connection: 1 << 20, batch: 4096 };
  const listener = api.net.listen(io, { port: 0, mode: "pull", socketMode: "pull" });
  const plain = await api.net.connect(io, { port: listener.port, mode: "pull" });
  const accepted = await listener.accept();

  const client: ClientSession = api.http.session(plain, { role: "client", mode: "pull", limits });
  const server: ServerSession = api.http.session(accepted, { role: "server", mode: "pull", limits });
  await client.ready();

  const headers = new api.http.HeaderList().put("accept", "*/*").put("x-dup", "1").put("x-dup", "2");
  const exchange = client.open({ method: "GET", scheme: "http", authority: "example.test", path: "/" }, { headers });
  const first = await server.accept();
  first?.respond({ status: 200, headers, body: "stream" });
  await first?.send(new Uint8Array([1]));
  first?.finish(headers);

  const event: StreamEvent | undefined = await exchange.next();
  if (event?.type === "headers") {
    const status: number | undefined = event.status;
    const value: string | undefined = event.headers.get("content-type");
    void [status, value];
  } else if (event?.type === "data") {
    const bytes: Uint8Array = event.data;
    exchange.consume(bytes.length);
  }
  const rtt: number = await client.ping();
  void rtt;

  // connect and serve: a server for every client, a session once the peer is ready.
  const front = api.http.serve(io, { listen: { port: 0 }, mode: "pull", limits });
  const dialed: ClientSession = await api.http.connect(io, { port: front.port, mode: "pull", limits });
  const request: ServerExchange | undefined = await front.accept();
  void [dialed, request, front.dropped];
  // @ts-expect-error a port is required to connect
  await api.http.connect(io, { mode: "pull", limits });
  // @ts-expect-error limits are required
  api.http.session(plain, { role: "client", mode: "pull" });
  // @ts-expect-error event mode is not available for sessions yet
  api.http.session(plain, { role: "client", mode: "event", limits });
  // @ts-expect-error only a server exchange can respond
  exchange.respond({ status: 200 });
  // @ts-expect-error a session is made by http.session
  new api.http.ClientSession();
}
