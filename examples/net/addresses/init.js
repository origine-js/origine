// Run: zig build run -- examples/net/addresses/init.js   (or: zig-out/bin/origine examples/net/addresses/init.js)
// Which addresses api.net reaches. By default only loopback is allowed (127.0.0.1, ::1, and localhost). The embedder's
// network ceiling decides the rest, and a request above it is PermissionDenied with the address as the subject.
// Names are never resolved by api.net: look them up with api.dns and pass the address (see examples/dns/resolver).
//
// Prints (stderr):
//   listen default host: 127.0.0.1 (port N)
//   connect to localhost reaches the server: "hi"
//   connect to 10.0.0.1: PermissionDenied (subject 10.0.0.1:PORT)
//   connect to example.com: PermissionDenied (subject example.com:PORT)
//   connect without a port: TypeError
//   closed server: closed true ; pending accept: Canceled
import { IpAddr } from 'origine:@std/net';
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
    // listen binds 127.0.0.1 unless a host is named; port 0 asks the system for a free one.
    const server = api.net.listen(io, { port: 0, mode: 'pull', socketMode: 'pull' });
    eprintln(`listen default host: 127.0.0.1 (port ${server.port})`);

    // localhost is a name, never looked up: connect tries 127.0.0.1, then ::1.
    const viaName = await api.net.connect(io, { host: 'localhost', port: server.port, mode: 'pull' });
    const accepted = await server.accept();
    await viaName.queued.send(encodeUtf8('hi'));
    eprintln(`connect to localhost reaches the server: "${decodeUtf8(await accepted.read(8))}"`);
    await viaName.close();
    await accepted.close();

    // Outside the ceiling: rejected with PermissionDenied, and the address is the error's subject.
    for (const host of ['10.0.0.1', 'example.com']) {
      const err = await failure(() => api.net.connect(io, { host, port: server.port, mode: 'pull' }));
      eprintln(`connect to ${host}: ${err?.name} (subject ${err?.subject})`);
    }

    // The port is required: a missing one is a TypeError, not a default.
    const noPort = await failure(() => api.net.connect(io, { host: '127.0.0.1', mode: 'pull' }));
    eprintln(`connect without a port: ${noPort?.name}`);

    // IpAddr is a value type: it parses and classifies without any authority.
    eprintln(`IpAddr.parse('10.0.0.1').isPrivate(): ${IpAddr.parse('10.0.0.1').isPrivate()}`);

    // Closing a server makes it closed; a pending accept is rejected with Canceled.
    const pending = failure(() => server.accept());     // attached before close, so the rejection is handled
    await server.close();
    eprintln('closed server:', server.closed, '; pending accept:', (await pending)?.name);
  } finally {
    await io.close();
  }
}
