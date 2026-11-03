// Run: zig build run -- examples/net/promises/init.js
import { encodeUtf8, decodeUtf8 } from 'origine:@std/text';
import { eprintln } from 'origine:@std/debug';
import { SocketAddr } from 'origine:@std/net';

/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const io = api.io.create();
  try {
    // Port 0 chooses a free port. The network ceiling allows loopback addresses by default. The factories return
    // unshaped objects; pulling() gives the promise-read shape.
    const server = io.tcp.listen(SocketAddr.parse('127.0.0.1:0')).pulling();
    eprintln('listening on ' + server.localAddr);
    const accepting = server.accept();
    const client = (await io.tcp.connect(server.localAddr)).pulling();
    const peer = (await accepting).pulling();
    await server.close(); // This demo accepts just one client.

    const echo = async () => {
      try {
        for (;;) {
          const chunk = await peer.read(4096);
          if (chunk.length === 0) break; // Empty reads mean end of stream.
          await peer.queued.send(chunk); // send() resolves once every byte is in the kernel.
        }
        eprintln('server: end of stream');
        // The client's FIN alone leaves the socket open; ending our side too closes it.
        await peer.end('write');
      } finally {
        await peer.close(); // Idempotent: also covers a failure before the clean end.
      }
    };

    const exchange = async () => {
      try {
        for (const mode of ['read', 'readCopy', 'readInto']) {
          const message = encodeUtf8(`hello via ${mode}: 你好 🌍`);
          await client.queued.send(message);
          const reply = new Uint8Array(message.length);
          let received = 0;
          let buffer = new Uint8Array(8); // Deliberately small to require multiple reads.
          while (received < reply.length) {
            // TCP is a byte stream: a write need not correspond to a single read.
            let chunk;
            if (mode === 'read') {
              chunk = await client.read(buffer.length);
            } else if (mode === 'readCopy') {
              const bytes = await client.readCopy(buffer);
              chunk = buffer.subarray(0, bytes); // The original buffer stays usable.
            } else {
              const result = await client.readInto(buffer);
              // readInto detaches the old buffer; use the returned ArrayBuffer next time.
              buffer = new Uint8Array(result.buffer);
              chunk = buffer.subarray(0, result.bytes);
            }
            if (chunk.length === 0) throw new Error('echo ended early');
            reply.set(chunk, received);
            received += chunk.length;
          }
          if (reply.some((byte, i) => byte !== message[i])) throw new Error('echo mismatch');
          // Decode only after collecting the message: UTF-8 characters can span chunks.
          eprintln(mode + ':', decodeUtf8(reply));
        }
      } finally {
        await client.end('write'); // The server's pending read now sees end of stream...
        await client.read(1); // ...and its own end('write') shows up here as an empty read: both sides are closed.
      }
    };

    await Promise.all([echo(), exchange()]);
  } finally {
    await io.close(); // Also releases any handles left open if an operation failed.
  }
}
