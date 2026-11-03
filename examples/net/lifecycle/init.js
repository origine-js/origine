// Run: zig build run -- examples/net/lifecycle/init.js   (or: zig-out/bin/origine examples/net/lifecycle/init.js)
// Closing is per direction. `end('write')` sends a FIN and keeps reading: the peer sees end of stream and can still
// answer. A socket closes itself once both directions are finished. The last part moves a pull socket to event mode
// with toEvent(): the pull handle is consumed (BadHandle afterwards), and the bytes keep flowing.
//
// Prints (stderr):
//   server got: "ping", then end of stream: true
//   client got: "pong", then end of stream: true
//   both directions finished, client closed: true
//   toEvent: old handle closed: true, new handle received "event" then end: true
import { encodeUtf8, decodeUtf8 } from 'origine:@std/text';
import { eprintln } from 'origine:@std/debug';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const io = api.io.create({});
  try {
    const server = api.net.listen(io, { port: 0, mode: 'pull', socketMode: 'pull' });
    const client = await api.net.connect(io, { port: server.port, mode: 'pull' });
    const conn = await server.accept();

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
    const server2 = api.net.listen(io, { port: 0, mode: 'pull', socketMode: 'pull' });
    const client2 = await api.net.connect(io, { port: server2.port, mode: 'pull' });
    const pull = await server2.accept();
    await client2.queued.send(encodeUtf8('event'));
    await client2.end('write');
    const event = pull.toEvent();
    eprintln(`toEvent: old handle closed: ${pull.closed}, new handle is ${event.constructor.name}`);
    let received = '';
    event.register('data', e => {
      const lease = e.buffer();           // a lease: give it back with unref()
      received += decodeUtf8(lease);
      lease.unref();
    });
    const running = io.run();             // keeps the program waiting while the handle flows
    await event.end('write');             // both directions are now finished: the socket closes itself
    await running;
    eprintln(`toEvent: new handle received "${received}" then closed: true`);
    await client2.close();
    await server2.close();
  } finally {
    await io.close();
  }
}
