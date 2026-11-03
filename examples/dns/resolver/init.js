// Run: zig build run -- examples/dns/resolver/init.js   (or: zig-out/bin/origine examples/dns/resolver/init.js)
// A resolver asks the servers you name, in order, over the transport each DnsServer names. This example answers
// queries itself, over DNS-over-TCP on loopback (a few lines of wire format below), so it needs no network. It shows
// the answers, the cache (a second lookup does not reach the server), and what is never asked: literals and localhost.
//
// Prints (stderr):
//   example.test (ipv4): 192.0.2.7 ; server queries: 1
//   again: 192.0.2.7 ; server queries: 1 (answered from the cache)
//   example.test (any): 192.0.2.7 (IPv6 answers: none)   (asks for A and AAAA)
//   localhost: 127.0.0.1 ; server queries unchanged: true
//   1.2.3.4 is itself: 1.2.3.4
//   missing.test: NotFound
import { SocketAddr } from 'origine:@std/net';
import { eprintln } from 'origine:@std/debug';

/** Reads exactly `n` bytes from a pull socket; null at the end of the stream. */
const readExact = async (socket, n) => {
  const out = new Uint8Array(n);
  let got = 0;
  while (got < n) {
    const chunk = await socket.read(n - got);
    if (chunk.length === 0) return null;
    out.set(chunk, got);
    got += chunk.length;
  }
  return out;
};

/** The labels of the question name, starting at offset 12 of a query, and the offset after the question. */
const question = message => {
  const labels = [];
  let at = 12;
  while (message[at] !== 0) {
    labels.push(String.fromCharCode(...message.subarray(at + 1, at + 1 + message[at])));
    at += message[at] + 1;
  }
  const type = (message[at + 1] << 8) | message[at + 2];
  return { name: labels.join('.'), type, end: at + 5 };
};

/**
 * The answer to one query: example.test has one A record, AAAA has none, everything else is NXDOMAIN.
 * The reply repeats the question and answers with a pointer (0xC00C) to its name.
 */
const answer = (query, queries) => {
  const q = question(query);
  queries.count += 1;
  const reply = [];
  const head = (rcode, answers) => reply.push(query[0], query[1], 0x81, rcode, 0, 1, 0, answers, 0, 0, 0, 0);
  if (q.name === 'example.test' && q.type === 1) {
    head(0, 1);
    reply.push(...query.subarray(12, q.end));
    reply.push(0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 7);
  } else {
    head(q.name === 'example.test' ? 0 : 3, 0);
    reply.push(...query.subarray(12, q.end));
  }
  return Uint8Array.from(reply);
};

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const io = api.io.create({});
  const queries = { count: 0 };
  try {
    // The fake server: each connection carries length-prefixed messages (2 bytes, big endian) until it ends.
    const server = io.tcp.listen(SocketAddr.parse('127.0.0.1:0')).pulling();
    (async () => {
      for await (const stream of server) {
        const socket = stream.pulling();
        for (let prefix; (prefix = await readExact(socket, 2));) {
          const query = await readExact(socket, (prefix[0] << 8) | prefix[1]);
          const reply = answer(query, queries);
          await socket.queued.send(Uint8Array.from([reply.length >> 8, reply.length & 0xff, ...reply]));
        }
        await socket.close();
      }
    })();

    const resolver = api.dns.resolver(io, {
      servers: [api.dns.DnsServer.tcp([server.localAddr])],
      dnssec: 'off',
      timeout: 2000,
      tries: 2,
      cache: { limit: 16, ttl: { min: 0, max: 60_000 }, negative: { min: 0, max: 0 } },
    });

    const show = addresses => addresses.map(String).join(', ') || '(none)';
    eprintln(`example.test (ipv4): ${show(await resolver.lookup('example.test', { family: 'ipv4' }))} ; server queries: ${queries.count}`);
    eprintln(
      `again: ${show(await resolver.lookup('example.test', { family: 'ipv4' }))} ; server queries: ${queries.count} (answered from the cache)`,
    );
    eprintln(`example.test (any): ${show(await resolver.lookup('example.test', { family: 'any' }))} (IPv6 answers: none)`);
    const before = queries.count;
    eprintln(
      `localhost: ${show(await resolver.lookup('localhost', { family: 'ipv4' }))} ; server queries unchanged: ${queries.count === before}`,
    );
    eprintln(`1.2.3.4 is itself: ${show(await resolver.lookup('1.2.3.4', { family: 'ipv4' }))}`);
    await resolver.lookup('missing.test', { family: 'ipv4' }).catch(e => eprintln(`missing.test: ${e.name}`));
    await resolver.close();
    await server.close();
  } finally {
    await io.close();
  }
}
