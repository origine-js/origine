// Run: zig build run -- examples/net/write-lanes/init.js   (or: zig-out/bin/origine examples/net/write-lanes/init.js)
// A socket has two write lanes that share one order. `direct.write` is one unbuffered write(2): it takes what the kernel
// takes and never queues. `queued` holds what does not fit, up to `queued.limit`, and `drained()` resolves when the queue
// is empty. `end('read')` stops reading on this side; the server's handle can also be turned into an event server and back.
//
// Prints (stderr):
//   direct.write took 6 bytes (unbuffered)
//   queued.put took 10 bytes with limit 1024 ; drained: queued.bytes is 0
//   server read 16 bytes: "direct" + "0123456789"
//   end('read') on the client: resolves ; reads after it are empty: true
//   server toEvent: connection event delivered: true
//   toPull after a connection handler started: Unsupported
//   toPull without a handler: accept works: true
import { encodeUtf8, decodeUtf8 } from 'origine:@std/text';
import { eprintln } from 'origine:@std/debug';

/** Reads exactly `n` bytes from a pull socket and returns them as text. */
const readText = async (socket, n) => {
  let text = '';
  while (text.length < n) text += decodeUtf8(await socket.read(n - text.length));
  return text;
};

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const io = api.io.create({});
  try {
    const server = api.net.listen(io, { port: 0, mode: 'pull', socketMode: 'pull' });
    const client = await api.net.connect(io, { port: server.port, mode: 'pull' });
    const conn = await server.accept();

    // direct: one write(2). The kernel takes the bytes or part of them; the count is returned, nothing is kept.
    const direct = client.direct.write(encodeUtf8('direct'));
    eprintln(`direct.write took ${direct} bytes (unbuffered)`);

    // queued.put copies what fits under the limit into the queue and returns the count accepted.
    client.queued.limit = 1024;
    const taken = client.queued.put(encodeUtf8('0123456789'));
    await client.queued.drained();
    eprintln(`queued.put took ${taken} bytes with limit ${client.queued.limit} ; drained: queued.bytes is ${client.queued.bytes}`);

    eprintln(`server read ${direct + taken} bytes: "${await readText(conn, direct + taken)}"`);

    // end('read') stops this side reading: reads started afterwards resolve empty.
    await client.end('read');
    const afterwards = await client.read(8);
    eprintln(`end('read') on the client: resolves ; reads after it are empty: ${afterwards.length === 0}`);

    // A server can be moved to event mode: each connection then arrives as an event. Once a connection handler has
    // started the flow, toPull() is refused (Unsupported); a server with no handler yet can go back to pull mode.
    const events = server.toEvent();
    const connected = new Promise(resolve => events.register('connection', resolve));
    const peer = await api.net.connect(io, { port: server.port, mode: 'pull' });
    const accepted = await connected;
    eprintln('server toEvent: connection event delivered:', accepted !== undefined);
    try {
      events.toPull();
    } catch (e) {
      eprintln(`toPull after a connection handler started: ${e.name}`);
    }
    await events.close();

    const idle = api.net.listen(io, { port: 0, mode: 'event', socketMode: 'pull' });
    const pull = idle.toPull();
    const second = api.net.connect(io, { port: pull.port, mode: 'pull' });
    const next = await pull.accept();
    await second.then(s => s.close());
    eprintln('toPull without a handler: accept works:', next !== undefined);

    await next.close();
    await accepted.close();
    await peer.close();
    await client.close();
    await conn.close();
    await pull.close();
  } finally {
    await io.close();
  }
}
