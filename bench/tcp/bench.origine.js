// TCP ping-pong benchmark on origine's `api.net`, same workload as bench.js / the Rust bench.
//
//   zig-out/bin/origine bench/tcp/bench.origine.js <msg_size> <conns> [warmup_s=1] [measure_s=3] [backend=auto]
//
// The guest has no high-resolution clock (only `Date.now()`), so this prints throughput and mean
// round-trip latency (conns / rps) but not p50/p99.
export async function main(api) {
  const [, sizeArg, connsArg, warmArg, measArg, backend = 'auto'] = api.env.args();
  const SIZE = Number(sizeArg);
  const CONNS = Number(connsArg);
  const WARM = Number(warmArg ?? 1) * 1000;
  const MEAS = Number(measArg ?? 3) * 1000;
  if (!(SIZE >= 16) || !(CONNS >= 1)) throw new Error('bad args');

  const pat = i => (i * 7 + 13) & 255;
  const expect = (seq, i) => (i < 4 ? (seq >>> (8 * i)) & 255 : i < 8 ? 0 : pat(i));
  const io = api.io.create({ backend });
  const server = api.net.listen(io, { port: 0 });

  const echo = async () => {
    const conn = await server.accept();
    try {
      for (;;) {
        const chunk = await conn.read(Math.max(SIZE, 1024));
        if (chunk.length === 0) break;
        await conn.write(chunk);
      }
    } catch {
      // the client closed first
    }
    await conn.close();
  };
  for (let i = 0; i < CONNS; i++) echo();

  const clients = [];
  for (let i = 0; i < CONNS; i++) clients.push(await api.net.connect(io, { port: server.port }));

  const start = Date.now();
  const warmEnd = start + WARM;
  const end = warmEnd + MEAS;
  let rounds = 0;
  const client = async sock => {
    const msg = new Uint8Array(SIZE);
    for (let i = 8; i < SIZE; i++) msg[i] = pat(i);
    const view = new DataView(msg.buffer);
    for (let seq = 1; ; seq++) {
      const t0 = Date.now();
      if (t0 >= end) return;
      view.setUint32(0, seq, true);
      await sock.write(msg);
      let got = 0;
      while (got < SIZE) {
        const chunk = await sock.read(SIZE - got);
        if (chunk.length === 0) throw new Error('unexpected end of stream');
        if (chunk[0] !== expect(seq, got) || chunk[chunk.length - 1] !== expect(seq, got + chunk.length - 1))
          throw new Error('echo content mismatch');
        got += chunk.length;
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
