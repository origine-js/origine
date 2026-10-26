// TCP ping-pong benchmark on origine's `api.net`, same workload as bench.js / the Rust bench.
//
//   zig-out/bin/origine bench/tcp/bench.origine.js <msg_size> <conns> [warmup_s=1] [measure_s=3] [backend=auto]
//
// The guest has no high-resolution clock (only `Date.now()`), so this prints throughput and mean
// round-trip latency (conns / rps) but not p50/p99.
/** @param {import('@origine/types').Api} api */
export async function main(api) {
  const [, sizeArg, connsArg, warmArg, measArg, backend = 'auto', mode = 'copy'] = api.env.args();
  // mode: 'copy' = readCopy (copy into a reused buffer), 'into' = readInto (detach and get the buffer back),
  // 'events' = socket.register('data') with exact-size leases and synchronous send (no promise per message)
  const pinnedReads = mode === 'into';
  const SIZE = Number(sizeArg);
  const CONNS = Number(connsArg);
  const WARM = Number(warmArg ?? 1) * 1000;
  const MEAS = Number(measArg ?? 3) * 1000;
  if (!(SIZE >= 16) || !(CONNS >= 1)) throw new Error('bad args');

  const eventsMode = mode === 'events';
  const pat = i => (i * 7 + 13) & 255;
  const expect = (seq, i) => (i < 4 ? (seq >>> (8 * i)) & 255 : i < 8 ? 0 : pat(i));
  const io = api.io.create({ backend: /** @type {NonNullable<import('@origine/types').IoOptions['backend']>} */ (backend) });

  if (eventsMode) {
    const server = api.net.listen(io, { port: 0, mode: 'event', socketMode: 'event' });
    // Echo over events: lease the chunk, send it back, give the lease back.
    server.register('connection', conn => {
      conn.register('data', ev => {
        const buf = ev.buffer();
        if (conn.queued.put(buf) !== buf.length) throw new Error('send queue full'); // copied: the lease can go back
        buf.unref();
      });
    });
    const running = io.run(); // handlers alone do not keep the program alive
    const clients = [];
    for (let i = 0; i < CONNS; i++) clients.push(await api.net.connect(io, { port: server.port, mode: 'event' }));
    const start = Date.now();
    const warmEnd = start + WARM;
    const end = warmEnd + MEAS;
    let rounds = 0;
    const drive = sock =>
      new Promise((resolve, reject) => {
        const msg = new Uint8Array(SIZE);
        for (let i = 8; i < SIZE; i++) msg[i] = pat(i);
        const view = new DataView(msg.buffer);
        let seq = 1;
        let got = 0;
        sock.register('error', reject);
        sock.register('data', ev => {
          const buf = ev.buffer();
          const n = buf.length;
          const bad = buf[0] !== expect(seq, got) || buf[n - 1] !== expect(seq, got + n - 1);
          buf.unref();
          if (bad) return reject(new Error('echo content mismatch'));
          got += n;
          if (got < SIZE) return;
          got = 0;
          const now = Date.now();
          if (now >= warmEnd) rounds++;
          if (now >= end) return resolve(undefined);
          view.setUint32(0, ++seq, true);
          sock.queued.put(msg);
        });
        view.setUint32(0, seq, true);
        sock.queued.put(msg);
      });
    await Promise.all(clients.map(drive));
    const rps = Math.round(rounds / (MEAS / 1000));
    print(
      JSON.stringify({
        impl: 'origine-js',
        backend,
        mode,
        size: SIZE,
        conns: CONNS,
        rounds,
        rps,
        mean_ns: Math.round((CONNS / rps) * 1e9),
        secs: MEAS / 1000,
      }),
    );
    for (const sock of clients) sock.close();
    await server.close();
    await running;
    await io.close();
    return;
  }

  const server = api.net.listen(io, { port: 0, mode: 'pull', socketMode: 'pull' });

  // A reusable read buffer per connection. 'copy' keeps one Uint8Array (readCopy copies into it);
  // 'into' gets the detached buffer back from readInto each time and wraps it in a new view.
  const makeReader = size => {
    let u8 = new Uint8Array(size);
    return {
      get u8() {
        return u8;
      },
      async read(sock, at) {
        if (!pinnedReads) return sock.readCopy(at === 0 ? u8 : u8.subarray(at));
        const r = await sock.readInto(at === 0 ? u8 : new Uint8Array(u8.buffer, at));
        u8 = new Uint8Array(r.buffer);
        return r.bytes;
      },
    };
  };

  const echo = async () => {
    const conn = await server.accept();
    const reader = makeReader(Math.max(SIZE, 1024));
    try {
      for (;;) {
        const n = await reader.read(conn, 0);
        if (n === 0) break;
        const buf = reader.u8;
        await conn.queued.send(n === buf.length ? buf : buf.subarray(0, n));
      }
    } catch {
      // the client closed first
    }
    await conn.close();
  };
  for (let i = 0; i < CONNS; i++) echo();

  const clients = [];
  for (let i = 0; i < CONNS; i++) clients.push(await api.net.connect(io, { port: server.port, mode: 'pull' }));

  const start = Date.now();
  const warmEnd = start + WARM;
  const end = warmEnd + MEAS;
  let rounds = 0;
  const client = async sock => {
    const msg = new Uint8Array(SIZE);
    for (let i = 8; i < SIZE; i++) msg[i] = pat(i);
    const view = new DataView(msg.buffer);
    const reader = makeReader(SIZE);
    for (let seq = 1; ; seq++) {
      const t0 = Date.now();
      if (t0 >= end) return;
      view.setUint32(0, seq, true);
      await sock.queued.send(msg);
      let got = 0;
      while (got < SIZE) {
        const n = await reader.read(sock, got);
        if (n === 0) throw new Error('unexpected end of stream');
        const rbuf = reader.u8;
        if (rbuf[got] !== expect(seq, got) || rbuf[got + n - 1] !== expect(seq, got + n - 1)) throw new Error('echo content mismatch');
        got += n;
      }
      if (t0 >= warmEnd) rounds++;
    }
  };
  await Promise.all(clients.map(client));
  const rps = Math.round(rounds / (MEAS / 1000));
  print(
    JSON.stringify({
      impl: 'origine-js',
      backend,
      mode,
      size: SIZE,
      conns: CONNS,
      rounds,
      rps,
      mean_ns: Math.round((CONNS / rps) * 1e9),
      secs: MEAS / 1000,
    }),
  );
  for (const sock of clients) await sock.close();
  await server.close();
  await io.close();
}
