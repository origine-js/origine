// Run: zig build run -- examples/net/lifecycle/init.js   (or: zig-out/bin/origine examples/net/lifecycle/init.js)
// Closing is per direction. `end('write')` sends a FIN and keeps reading: the peer sees end of stream and can still
// answer. A stream closes itself once both directions are finished. The last part moves a pull stream to event mode
// with toEvented(): the pull object is consumed (BadHandle afterwards), and the bytes keep flowing.
//
// Prints (stderr):
//   server got: "ping", then end of stream: true
//   client got: "pong", then end of stream: true
//   both directions finished, client closed: true
//   toEvented: old object closed: true, new object is EventTcpStream
//   toEvented: new object received "event" then closed: true
import { encodeUtf8, decodeUtf8 } from 'origine:@std/text';
import { eprintln } from 'origine:@std/debug';
import { SocketAddr } from 'origine:@std/net';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const io = api.io.create({});
  try {
    const server = io.tcp.listen(SocketAddr.parse('127.0.0.1:0')).pulling();
    const accepting = server.accept();
    const client = (await io.tcp.connect(server.localAddr)).pulling();
    const conn = (await accepting).pulling();

    // The client writes, then half-closes its write side. The server reads the bytes, then the end of stream.
    await client.queued.send(encodeUtf8('ping'));
    await client.end('write');
    const ping = await conn.read(64);
    const eof = await conn.read(64);
    eprintln(`server got: "${decodeUtf8(ping)}", then end of stream: ${eof.length === 0}`);

    // The server can still answer on the half-open connection, then end its own write side.
    await conn.queued.send(encodeUtf8('pong'));
    await conn.end('write');
    const pong = await client.read(64);
    const end = await client.read(64);
    eprintln(`client got: "${decodeUtf8(pong)}", then end of stream: ${end.length === 0}`);
    eprintln('both directions finished, client closed:', client.closed);

    await conn.close();
    await server.close();

    // Transfer: connect again, accept, and move the accepted socket to event mode.
    const server2 = io.tcp.listen(SocketAddr.parse('127.0.0.1:0')).pulling();
    const accepting2 = server2.accept();
    const client2 = (await io.tcp.connect(server2.localAddr)).pulling();
    const pull = (await accepting2).pulling();
    await client2.queued.send(encodeUtf8('event'));
    await client2.end('write');
    const event = pull.toEvented();
    eprintln(`toEvented: old object closed: ${pull.closed}, new object is ${event.constructor.name}`);
    let received = '';
    event.register('data', e => {
      const lease = e.buffer(); // a lease: give it back with unref()
      received += decodeUtf8(lease);
      lease.unref();
    });
    const running = io.run(); // keeps the program waiting while the handle flows
    await event.end('write'); // both directions are now finished: the socket closes itself
    await running;
    eprintln(`toEvented: new object received "${received}" then closed: true`);
    await client2.close();
    await server2.close();
  } finally {
    await io.close();
  }
}
