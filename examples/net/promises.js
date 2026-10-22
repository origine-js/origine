// Run: zig build run -- examples/net/promises.js
import { encodeUtf8, decodeUtf8 } from 'origine:@std/text';

export async function main(api) {
  const io = api.io.create();
  try {
    // Port 0 chooses a free port. api.net currently allows loopback hosts only.
    const server = api.net.listen(io, { host: '127.0.0.1', port: 0 });
    print('listening on 127.0.0.1:' + server.port);
    const client = await api.net.connect(io, { port: server.port });
    const peer = await server.accept();
    await server.close(); // This demo accepts just one client.

    const echo = async () => {
      try {
        for (;;) {
          const chunk = await peer.read(4096);
          if (chunk.length === 0) break; // Empty reads mean end of stream.
          await peer.write(chunk); // write() sends all bytes, even after a partial OS write.
        }
        print('server: end of stream');
      } finally {
        await peer.close();
      }
    };

    const exchange = async () => {
      try {
        for (const mode of ['read', 'readCopy', 'readInto']) {
          const message = encodeUtf8(`hello via ${mode}: 你好 🌍`);
          await client.write(message);
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
          print(mode + ':', decodeUtf8(reply));
        }
      } finally {
        await client.close(); // The server's pending read now sees end of stream.
      }
    };

    await Promise.all([echo(), exchange()]);
  } finally {
    await io.close(); // Also releases any handles left open if an operation failed.
  }
}
