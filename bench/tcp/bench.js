// TCP ping-pong benchmark for Bun and Deno (native socket API and node:net).
// Single thread, client and server in the same process, loopback, TCP_NODELAY.
//
//   bun bench.js <native|node> <msg_size> <conns> [warmup_s=1] [measure_s=3]
//   deno run -A bench.js <native|node> <msg_size> <conns> [warmup_s=1] [measure_s=3]
//
// Prints one JSON line.
const IS_BUN = typeof Bun !== "undefined";
const IS_DENO = typeof Deno !== "undefined";
const args = IS_DENO ? Deno.args : process.argv.slice(2);
const variant = args[0];
const SIZE = Number(args[1]);
const CONNS = Number(args[2]);
const WARM = Number(args[3] ?? 1) * 1000;
const MEAS = Number(args[4] ?? 3) * 1000;
const RT = IS_BUN ? "bun" : IS_DENO ? "deno" : "?";
if (!(SIZE >= 16) || !(CONNS >= 1) || !["native", "node"].includes(variant)) throw new Error("bad args");
const now = () => performance.now();
const exit = (c) => (IS_DENO ? Deno.exit(c) : process.exit(c));

// Message layout (same as the Rust bench): bytes 0..8 = sequence number (LE), the rest a pattern.
const pat = (i) => (i * 7 + 13) & 255;
const seqByte = (seq, i) => Number((BigInt(seq) >> BigInt(8 * i)) & 0xffn);
function makeMsg() {
  const m = new Uint8Array(SIZE);
  for (let i = 8; i < SIZE; i++) m[i] = pat(i);
  return m;
}
const expect = (seq, i) => (i < 8 ? seqByte(seq, i) : pat(i));

let tStart, tWarmEnd, tEnd;
const lats = [];
let activeClients = CONNS;
let finish;
const finished = new Promise((r) => (finish = r));

// Client round-trip state machine shared by all variants. `write(u8)` must send the whole buffer
// (queueing internally if the socket is backed up); the returned `onData(chunk)` is fed echoed bytes.
function makeClient(write) {
  const msg = makeMsg();
  const dv = new DataView(msg.buffer);
  let seq = 0, got = 0, t0 = 0, done = false;
  function next() {
    seq++;
    t0 = now();
    if (t0 >= tEnd) {
      if (!done) { done = true; if (--activeClients === 0) finish(); }
      return;
    }
    dv.setUint32(0, seq, true); dv.setUint32(4, 0, true);
    got = 0;
    write(msg);
  }
  function onData(chunk) {
    if (done) return;
    const n = chunk.length;
    if (got + n > SIZE) throw new Error(`echo too long: ${got + n} > ${SIZE}`);
    if (chunk[0] !== expect(seq, got) || chunk[n - 1] !== expect(seq, got + n - 1)) throw new Error("echo content mismatch");
    got += n;
    if (got === SIZE) {
      const t1 = now();
      if (t0 >= tWarmEnd && t1 <= tEnd) lats.push((t1 - t0) * 1e6);
      next();
    }
  }
  return { start: next, onData };
}

// ---- native: Bun ----
async function bunNative() {
  // Writer with backpressure: Bun's socket.write may accept only part of the data.
  const makeWriter = (s) => {
    s.q = null;
    return (u8) => {
      const n = s.write(u8);
      if (n < u8.length) s.q = u8.slice(n);
    };
  };
  const drain = (s) => {
    if (!s.q) return;
    const n = s.write(s.q);
    s.q = n < s.q.length ? s.q.slice(n) : null;
  };
  const server = Bun.listen({
    hostname: "127.0.0.1", port: 0,
    socket: {
      open(s) { s.setNoDelay(true); s.q = null; s.w = makeWriter(s); },
      data(s, d) { if (s.q) { s.q = Buffer.concat([s.q, d]); drain(s); } else s.w(d); },
      drain,
      error() {}, close() {},
    },
  });
  const clients = [];
  await Promise.all(Array.from({ length: CONNS }, () => new Promise((res, rej) => {
    Bun.connect({
      hostname: "127.0.0.1", port: server.port,
      socket: {
        open(s) {
          s.setNoDelay(true);
          const w = makeWriter(s);
          s.cl = makeClient(w);
          clients.push(s);
          res();
        },
        data(s, d) { s.cl.onData(d); },
        drain,
        error(_, e) { rej(e); }, close() {},
      },
    }).catch(rej);
  })));
  return { go: () => clients.forEach((s) => s.cl.start()), stop: () => { clients.forEach((s) => s.end()); server.stop(true); } };
}

// ---- native: Deno ----
async function denoNative() {
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const port = listener.addr.port;
  const writeAll = async (c, u8) => {
    let o = 0;
    while (o < u8.length) o += await c.write(u8.subarray(o));
  };
  (async () => {
    for await (const c of listener) {
      c.setNoDelay(true);
      (async () => {
        const buf = new Uint8Array(Math.max(SIZE, 1024));
        try {
          for (;;) {
            const n = await c.read(buf);
            if (n === null) break;
            await writeAll(c, buf.subarray(0, n));
          }
        } catch {}
        try { c.close(); } catch {}
      })();
    }
  })().catch(() => {});
  const clients = [];
  for (let i = 0; i < CONNS; i++) {
    const c = await Deno.connect({ hostname: "127.0.0.1", port });
    c.setNoDelay(true);
    // Writes are issued from the data path, in order; chain them so none interleave.
    let chain = Promise.resolve();
    const cl = makeClient((u8) => { chain = chain.then(() => writeAll(c, u8)); });
    clients.push({ c, cl });
  }
  const readLoops = clients.map(async ({ c, cl }) => {
    const buf = new Uint8Array(Math.max(SIZE, 1024));
    try {
      for (;;) {
        const n = await c.read(buf);
        if (n === null) break;
        cl.onData(buf.subarray(0, n));
      }
    } catch {}
  });
  return {
    go: () => clients.forEach(({ cl }) => cl.start()),
    stop: () => { clients.forEach(({ c }) => { try { c.close(); } catch {} }); try { listener.close(); } catch {} },
  };
}

// ---- node:net (Bun and Deno) ----
async function nodeNet() {
  const net = await import("node:net");
  const server = net.createServer((s) => {
    s.setNoDelay(true);
    s.on("data", (d) => s.write(d));
    s.on("error", () => {});
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const port = server.address().port;
  const clients = [];
  await Promise.all(Array.from({ length: CONNS }, () => new Promise((res, rej) => {
    const s = net.connect({ host: "127.0.0.1", port }, () => {
      s.setNoDelay(true);
      const cl = makeClient((u8) => s.write(u8));
      s.on("data", (d) => cl.onData(d));
      clients.push({ s, cl });
      res();
    });
    s.on("error", rej);
  })));
  return {
    go: () => clients.forEach(({ cl }) => cl.start()),
    stop: () => { clients.forEach(({ s }) => s.destroy()); server.close(); },
  };
}

const impl = variant === "node" ? nodeNet : IS_BUN ? bunNative : IS_DENO ? denoNative : null;
const h = await impl();
// Start the clock only when every connection is established.
const base = now();
tStart = base; tWarmEnd = base + WARM; tEnd = base + WARM + MEAS;
h.go();
await finished;
h.stop();

const v = Float64Array.from(lats).sort();
const pct = (p) => v[Math.min(v.length - 1, Math.max(0, Math.ceil(v.length * p) - 1))];
let sum = 0; for (const x of v) sum += x;
console.log(JSON.stringify({
  impl: `${RT}-${variant}`, size: SIZE, conns: CONNS, rounds: v.length,
  rps: Math.round(v.length / (MEAS / 1000)), p50_ns: Math.round(pct(0.5)), p99_ns: Math.round(pct(0.99)),
  mean_ns: Math.round(sum / v.length), secs: MEAS / 1000,
}));
exit(0);
