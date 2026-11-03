// Run: zig build run -- examples/net/addresses/init.js   (or: zig-out/bin/origine examples/net/addresses/init.js)
// Which addresses io.tcp reaches. By default only loopback is allowed (127.0.0.1 and ::1). The embedder's network
// ceiling decides the rest, and a request above it is PermissionDenied with the address as the subject. Addresses are
// SocketAddr values: a name is not one (look it up with api.dns and pass the address; see examples/dns/resolver).
//
// Prints (stderr):
//   listening on 127.0.0.1:N
//   connect to ::1 reaches nothing here, 127.0.0.1 reaches the server: "hi"
//   connect to 10.0.0.1: PermissionDenied (subject 10.0.0.1:PORT)
//   example.com is not an address: TypeError
//   connect with a string: TypeError
//   closed server: closed true ; pending accept: Canceled
import { IpAddr, SocketAddr } from 'origine:@std/net';
import { encodeUtf8, decodeUtf8 } from 'origine:@std/text';
import { eprintln } from 'origine:@std/debug';

/** Runs `run` and reports what it threw. */
const failure = async run => {
  try {
    await run();
    return undefined;
  } catch (e) {
    return e;
  }
};

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const io = api.io.create({});
  try {
    // Port 0 asks the system for a free one; localAddr says which.
    const server = io.tcp.listen(SocketAddr.parse('127.0.0.1:0')).pulling();
    eprintln(`listening on ${server.localAddr}`);
    const port = server.localAddr.port;

    const accepting = server.accept();
    const client = (await io.tcp.connect(SocketAddr.new(IpAddr.v4(127, 0, 0, 1), port))).pulling();
    const accepted = (await accepting).pulling();
    await client.queued.send(encodeUtf8('hi'));
    eprintln(`127.0.0.1 reaches the server: "${decodeUtf8(await accepted.read(8))}"`);
    await client.close();
    await accepted.close();

    // Outside the ceiling: rejected with PermissionDenied, and the address is the error's subject.
    const err = /** @type {any} */ (await failure(() => io.tcp.connect(SocketAddr.parse(`10.0.0.1:${port}`))));
    eprintln(`connect to 10.0.0.1: ${err?.name} (subject ${err?.subject})`);

    // A name is not an address: parsing one is a TypeError, and nothing is ever looked up.
    const name = /** @type {any} */ (await failure(() => SocketAddr.parse(`example.com:${port}`)));
    eprintln(`example.com is not an address: ${name?.name}`);

    // Only a SocketAddr is taken: a string is a TypeError, not something to parse.
    const text = /** @type {any} */ (await failure(() => io.tcp.connect(/** @type {any} */ (`127.0.0.1:${port}`))));
    eprintln(`connect with a string: ${text?.name}`);

    // IpAddr is a value type: it parses and classifies without any authority.
    eprintln(`IpAddr.parse('10.0.0.1').isPrivate(): ${IpAddr.parse('10.0.0.1').isPrivate()}`);

    // Closing a server makes it closed; a pending accept is rejected with Canceled.
    const pending = failure(() => server.accept()); // attached before close, so the rejection is handled
    await server.close();
    eprintln('closed server:', server.closed, '; pending accept:', /** @type {any} */ (await pending)?.name);
  } finally {
    await io.close();
  }
}
