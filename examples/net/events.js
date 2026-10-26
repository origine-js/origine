// Run: zig build run -- examples/net/events.js
// Stream a finite payload using events, exact-size receive leases, and send-queue backpressure.
/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const io = api.io.create();
  const sockets = [];
  const total = 1024 * 1024;
  let received = 0;
  let failure;
  try {
    const server = api.net.listen(io, { port: 0, mode: 'event', socketMode: 'event' });
    const stop = () => {
      // close() is idempotent and fires close events; closing io drops handlers instead.
      for (const socket of sockets) void socket.close();
      void server.close();
    };
    const fail = error => {
      failure ??= error;
      stop();
    };
    server.register('error', fail);
    server.register('connection', peer => {
      sockets.push(peer);
      void server.close(); // One connection is enough for this demo.
      peer.register('error', fail);
      const chunk = new Uint8Array(16 * 1024);
      for (let i = 0; i < chunk.length; i++) chunk[i] = i & 255;
      let sent = 0;
      const pump = () => {
        while (sent < total) {
          // put() takes what fits in the send queue and says how much; less than offered means
          // the queue is full. Continue from where it stopped (the pattern repeats every 256 bytes).
          const offset = sent % chunk.length;
          const part = chunk.subarray(offset, Math.min(chunk.length, offset + total - sent));
          const taken = peer.queued.put(part);
          sent += taken;
          if (taken < part.length) return; // Resume producing only when drain fires.
        }
      };
      peer.register('drain', pump);
      pump();
    });

    // Registrations alone do not keep main alive. Start run() after the listener flows,
    // and keep it pending while waiting for callbacks to finish the transfer.
    const running = io.run();
    const client = await api.net.connect(io, { port: server.port, mode: 'event' });
    sockets.push(client);
    client.register('error', fail);
    client.register('end', () => {
      if (received !== total) fail(new Error('stream ended early'));
    });
    client.register('data', event => {
      const chunk = event.buffer(); // A Uint8Array lease, valid until we release it.
      try {
        for (let i = 0; i < chunk.length; i++) {
          if (chunk[i] !== ((received + i) & 255)) throw new Error('stream mismatch');
        }
        received += chunk.length;
        if (received > total) throw new Error('too many bytes');
        if (received === total) stop();
      } finally {
        // Detaches chunk.buffer and frees its memory. Copy with slice()
        // first if you need to retain the data after releasing this lease.
        chunk.unref();
      }
    });
    await running; // Resolves once all flowing handles have closed.
    if (failure) throw failure;
    if (received !== total) throw new Error('incomplete transfer');
    print('events: received and verified', received, 'bytes');
  } finally {
    await io.close();
  }
}
