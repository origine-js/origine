// Run: zig build run -- examples/net/write-lanes/init.js   (or: zig-out/bin/origine examples/net/write-lanes/init.js)
// A socket has two write lanes that share one order. `direct.write` is one unbuffered write(2): it takes what the kernel
// takes and never queues. `queued` holds what does not fit, up to `queued.limit`, and `drained()` resolves when the queue
// is empty. `end('read')` stops reading on this side. An unshaped listener takes one shape, and so does every connection.
//
// Prints (stderr):
//   direct.write took 6 bytes (unbuffered)
//   queued.put took 10 bytes with limit 1024 ; drained: queued.bytes is 0
//   server read 16 bytes: "direct" + "0123456789"
//   end('read') on the client: resolves ; reads after it are empty: true
//   event listener: connection event delivered unshaped: true
//   a consumed unshaped listener: BadHandle
import { encodeUtf8, decodeUtf8 } from 'origine:@std/text';
import { eprintln } from 'origine:@std/debug';
import { SocketAddr } from 'origine:@std/net';

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
    const server = io.tcp.listen(SocketAddr.parse('127.0.0.1:0')).pulling();
    const accepting = server.accept();
    const client = (await io.tcp.connect(server.localAddr)).pulling();
    const conn = (await accepting).pulling();

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

    // A listener is shaped once: evented() gives connection events, each connection unshaped (it takes its own shape).
    const unshaped = io.tcp.listen(SocketAddr.parse('127.0.0.1:0'));
    const events = unshaped.evented();
    const connected = new Promise(resolve => events.register('connection', resolve));
    const peer = await io.tcp.connect(events.localAddr);
    const accepted = await connected;
    eprintln('event listener: connection event delivered unshaped:', accepted instanceof api.net.TcpStreamUnshaped);
    try {
      unshaped.pulling();
    } catch (e) {
      eprintln(`a consumed unshaped listener: ${/** @type {any} */ (e).name}`);
    }

    await accepted.close();
    await peer.close();
    await events.close();
    await client.close();
    await conn.close();
    await server.close();
  } finally {
    await io.close();
  }
}
