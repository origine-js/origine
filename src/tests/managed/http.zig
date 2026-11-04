const check = @import("support.zig").check;
const Parent = @import("channel.zig").Parent;
const tls_prelude = @import("tls.zig").prelude;
const m = @import("@managed");

// A tiny HTTP/2 server and client in JS over `api.http`, shared by the tests (TLS fixtures come from tls.zig).
const prelude = tls_prelude ++
    \\const limits = { streams: 100, headers: 16384, window: 65535, connection: 1 << 20, batch: 4096 };
    \\const headersOf = (api, pairs) => api.http.fields.of(pairs);
    \\// Reads a stream to its end: { status, headers, trailers, body, closed }.
    \\const collect = async (ex) => {
    \\  const out = { body: [], size: 0 };
    \\  for (let ev; (ev = await ex.next()); ) {
    \\    if (ev.type === 'headers') { if (ev.kind === 'trailers') out.trailers = ev.headers; else { out.status ??= ev.status; out.path ??= ev.path; out.method ??= ev.method; out.headers ??= ev.headers; } }
    \\    else if (ev.type === 'data') { out.body.push(ev.data); out.size += ev.data.length; ex.consume(ev.data.length); }
    \\    else if (ev.type === 'closed') out.closed = ev.code;
    \\    if (ev.type === 'headers' && ev.endStream && ev.kind !== 'response') { /* a request without a body */ }
    \\  }
    \\  out.text = text(out.body.flatMap(c => Array.from(c)));
    \\  return out;
    \\};
    \\// Answers every request with 200, the request's path, method and size in headers, and `you asked for <path>` as body.
    \\const serve = (api, session) => (async () => {
    \\  for await (const ex of session) {
    \\    (async () => {
    \\      let path, method, seen, size = 0, trailer;
    \\      for (let ev; (ev = await ex.next()); ) {
    \\        if (ev.type === 'headers' && ev.kind === 'request') { path = ev.path; method = ev.method; seen = ev.headers.get('x-test') ?? ''; }
    \\        if (ev.type === 'headers' && ev.kind === 'trailers') trailer = ev.headers.get('x-checksum');
    \\        if (ev.type === 'data') { size += ev.data.length; ex.consume(ev.data.length); }
    \\        if ((ev.type === 'headers' && ev.endStream) || ev.type === 'end' || ev.type === 'closed') break;
    \\      }
    \\      ex.respond({ status: 200, headers: headersOf(api, [['x-path', path], ['x-method', method], ['x-seen', seen], ['x-size', String(size)], ['x-trailer-seen', trailer ?? '']]), body: 'stream' });
    \\      await ex.send(bytes(`you asked for ${path}`));
    \\      ex.finish(headersOf(api, [['x-done', 'yes']]));
    \\    })();
    \\  }
    \\})();
    \\
;

test "http: requests and responses over h2c on loopback" {
    if (!m.Api.http_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const { plain, accepted } = await pair(api, io);
        \\  const client = api.http.session(plain, { role: 'client', mode: 'pull', limits });
        \\  const server = api.http.session(accepted, { role: 'server', mode: 'pull', limits });
        \\  out.consumed = plain.closed && accepted.closed;
        \\  serve(api, server);
        \\  await client.ready();
        \\  out.rtt = (await client.ping()) >= 0;
        \\  // A GET with headers; the response has a streamed body and a trailer.
        \\  const get = client.open({ method: 'GET', scheme: 'http', authority: 'example.test', path: '/hello?x=1' }, { headers: headersOf(api, [['x-test', 'abc'], ['x-dup', '1'], ['x-dup', '2']]) });
        \\  const got = await collect(get);
        \\  out.status = got.status;
        \\  out.echo = got.headers.get('x-path') === '/hello?x=1' && got.headers.get('x-method') === 'GET' && got.headers.get('x-seen') === 'abc';
        \\  out.body = got.text;
        \\  out.trailer = got.trailers?.get('x-done');
        \\  out.closed = got.closed;
        \\  // A streamed upload of 1 MiB with trailers: the writer is throttled by the peer's window.
        \\  const post = client.open({ method: 'POST', scheme: 'http', authority: 'example.test', path: '/upload' }, { body: 'stream' });
        \\  const chunk = new Uint8Array(16384).fill(7);
        \\  let worst = 0;
        \\  for (let i = 0; i < 64; i++) { await post.send(chunk); worst = Math.max(worst, post.queued); }
        \\  post.finish(headersOf(api, [['x-checksum', 'sum']]));
        \\  const posted = await collect(post);
        \\  out.size = posted.headers.get('x-size');
        \\  out.trailerSeen = posted.headers.get('x-trailer-seen');
        \\  out.throttled = worst <= 65535 + chunk.length;
        \\  // Many streams at once on one connection.
        \\  const many = await Promise.all(Array.from({ length: 40 }, async (_, i) => (await collect(client.open({ method: 'GET', scheme: 'http', authority: 'x', path: `/n/${i}` }))).text));
        \\  out.many = many.every((t, i) => t === `you asked for /n/${i}`);
        \\  await client.close();
        \\  await server.close();
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.consumed && report.rtt && report.status === 200 && report.echo && report.body === 'you asked for /hello?x=1' && report.trailer === 'yes' && report.closed === 0 && report.size === String(64 * 16384) && report.trailerSeen === 'sum' && report.throttled && report.many");
}

test "http: header lists, bad inputs and what ends a connection" {
    if (!m.Api.http_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const throws = f => { try { f(); return 'no'; } catch (e) { return e.name; } };
        \\  const list = api.http.fields.of([['a', '1'], ['b', 'é']]); list.put('a', '3');
        \\  out.list = list.length === 3 && list.get('A') === '1' && list.getAll('a').join() === '1,3' && list.get('b') === 'é' && list.has('b') && !list.has('c') && [...list].length === 3;
        \\  out.badName = throws(() => list.put('X-Upper', 'v'));
        \\  out.badValue = throws(() => list.put('x', 'a\nb'));
        \\  const { plain, accepted } = await pair(api, io);
        \\  out.limits = throws(() => api.http.session(plain, { role: 'client', mode: 'pull', limits: { streams: 1 } }));
        \\  out.role = throws(() => api.http.session(plain, { role: 'peer', mode: 'pull', limits }));
        \\  out.badMode = throws(() => api.http.session(plain, { role: 'client', mode: 'push', limits }));
        \\  out.untouched = !plain.closed;
        \\  const client = api.http.session(plain, { role: 'client', mode: 'pull', limits });
        \\  const server = api.http.session(accepted, { role: 'server', mode: 'pull', limits });
        \\  serve(api, server);
        \\  await client.ready();
        \\  out.badHead = throws(() => client.open({ method: 'GET', scheme: 'http', authority: 'x' }));
        \\  out.upper = throws(() => client.open({ method: 'GET', scheme: 'http', authority: 'x', path: '/' }, { headers: 3 }));
        \\  // Cancel an upload: the stream closes with CANCEL on this side.
        \\  const cut = client.open({ method: 'POST', scheme: 'http', authority: 'x', path: '/cut' }, { body: 'stream' });
        \\  await cut.send(bytes('half'));
        \\  cut.reset(8);
        \\  let ev; let code;
        \\  while ((ev = await cut.next())) if (ev.type === 'closed') code = ev.code;
        \\  out.reset = code;
        \\  // A connection that goes away ends the streams still open with the transport's error.
        \\  const hung = client.open({ method: 'POST', scheme: 'http', authority: 'x', path: '/hung' }, { body: 'stream' });
        \\  await hung.send(bytes('x'));
        \\  await server.close();
        \\  out.aborted = await hung.next().then(function again(e) { return e === undefined ? 'ended' : hung.next().then(again); }, e => e.name);
        \\  out.closedSession = (await client.close(), client.closed);
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.list && report.badName === 'InvalidInput' && report.badValue === 'InvalidInput' && report.limits === 'TypeError' && report.role === 'TypeError' && report.badMode === 'TypeError' && report.untouched && report.badHead === 'TypeError' && report.upper === 'TypeError' && report.reset === 8 && ['UnexpectedEof', 'ConnectionReset', 'BrokenPipe', 'NotConnected'].includes(report.aborted) && report.closedSession");
}

test "http: h2 over TLS with ALPN" {
    if (!m.Api.http_enabled or !m.Api.tls_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const { tls } = api;
        \\  const clientTls = tls.client({ roots: tls.RootPki.fromPem(bytes(CA)), alpn: ['h2'] });
        \\  const serverTls = tls.server({ identities: [tls.Identity.fromPem(bytes(SERVER), bytes(KEY))], clientAuth: tls.ClientAuth.none(), alpn: ['h2'] });
        \\  const { a, b } = await secure(api, io, clientTls, serverTls);
        \\  out.alpn = a.info().alpn === 'h2' && b.info().alpn === 'h2';
        \\  const client = api.http.session(a, { role: 'client', mode: 'pull', limits });
        \\  const server = api.http.session(b, { role: 'server', mode: 'pull', limits });
        \\  out.consumed = a.closed && b.closed;
        \\  serve(api, server);
        \\  await client.ready();
        \\  const got = await collect(client.open({ method: 'GET', scheme: 'https', authority: 'localhost', path: '/secure' }));
        \\  out.status = got.status;
        \\  out.body = got.text;
        \\  const big = client.open({ method: 'POST', scheme: 'https', authority: 'localhost', path: '/big' }, { body: 'stream' });
        \\  for (let i = 0; i < 20; i++) await big.send(new Uint8Array(32768).fill(i));
        \\  big.finish();
        \\  out.size = (await collect(big)).headers.get('x-size');
        \\  await client.close();
        \\  await server.close();
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.alpn && report.consumed && report.status === 200 && report.body === 'you asked for /secure' && report.size === String(20 * 32768)");
}

test "http: connect and serve" {
    if (!m.Api.http_enabled or !m.Api.tls_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const timers = api.io.create();
        \\  const { tls } = api;
        \\  const server = api.http.serve(io, { listen: { port: 0 }, mode: 'pull', limits });
        \\  out.port = server.port > 0;
        \\  serve(api, server);
        \\  // Two clients on one cleartext server.
        \\  const a = await api.http.connect(io, { port: server.port, mode: 'pull', limits });
        \\  const b = await api.http.connect(io, { port: server.port, mode: 'pull', limits });
        \\  const [x, y] = await Promise.all([collect(a.open({ method: 'GET', scheme: 'http', authority: 'x', path: '/a' })), collect(b.open({ method: 'GET', scheme: 'http', authority: 'x', path: '/b' }))]);
        \\  out.h2c = x.text === 'you asked for /a' && y.text === 'you asked for /b';
        \\  await a.close();
        \\  await b.close();
        \\  // Inputs are checked before anything is dialed or bound.
        \\  const throws = f => { try { f(); return 'no'; } catch (e) { return e.name; } };
        \\  out.noLimits = await outcome(api.http.connect(io, { port: server.port, mode: 'pull' }));
        \\  out.noPort = await outcome(api.http.connect(io, { mode: 'pull', limits }));
        \\  await server.close();
        \\  out.closed = server.closed && (await server.accept()) === undefined;
        \\  out.refused = await outcome(api.http.connect(io, { port: server.port, mode: 'pull', limits }));
        \\  // TLS: ALPN 'h2' is required on both sides.
        \\  const roots = tls.RootPki.fromPem(bytes(CA));
        \\  const secureServer = api.http.serve(io, { listen: { port: 0 }, tls: tls.server({ identities: [tls.Identity.fromPem(bytes(SERVER), bytes(KEY))], clientAuth: tls.ClientAuth.none(), alpn: ['h2'] }), mode: 'pull', limits });
        \\  serve(api, secureServer);
        \\  const secure = await api.http.connect(io, { port: secureServer.port, tls: tls.client({ roots, alpn: ['h2'] }), servername: 'localhost', mode: 'pull', limits });
        \\  out.tls = (await collect(secure.open({ method: 'GET', scheme: 'https', authority: 'localhost', path: '/secure' }))).text === 'you asked for /secure';
        \\  out.noAlpn = await outcome(api.http.connect(io, { port: secureServer.port, tls: tls.client({ roots }), servername: 'localhost', mode: 'pull', limits }));
        \\  out.wrongName = await outcome(api.http.connect(io, { port: secureServer.port, tls: tls.client({ roots, alpn: ['h2'] }), servername: 'example.com', mode: 'pull', limits }));
        \\  await timers.timer.sleep(50);
        \\  out.dropped = secureServer.dropped >= 1;
        \\  await secure.close();
        \\  await secureServer.close();
        \\  await io.close();
        \\  await timers.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.port && report.h2c && report.noLimits === 'TypeError' && report.noPort === 'TypeError' && report.closed && report.refused === 'ConnectionRefused' && report.tls && report.noAlpn === 'NoApplicationProtocol' && report.wrongName === 'CertificateRejected' && report.dropped");
}

test "http: event-mode servers, sessions and exchanges deliver in order" {
    if (!m.Api.http_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const server = api.http.serve(io, { listen: { port: 0 }, mode: 'event', limits });
        \\  out.classes = server instanceof api.http.EventHttpServer && !('accept' in server);
        \\  let seen = 0;
        \\  server.register('request', ex => {
        \\    out.serverExchange = ex instanceof api.http.EventServerExchange;
        \\    let path, size = 0;
        \\    ex.register('headers', ev => { if (ev.kind === 'request') path = ev.path; });
        \\    ex.register('data', ev => { size += ev.data.length; ex.consume(ev.data.length); });
        \\    ex.register('end', () => {});
        \\    ex.register('close', () => { seen++; ex.release(); });
        \\    // The request has no body: the head ends the stream, so answer once the head came.
        \\    ex.register('headers', ev => {
        \\      if (!ev.endStream) return;
        \\      ex.respond({ status: 200, headers: headersOf(api, [['x-path', path]]), body: 'stream' });
        \\      ex.send(bytes(`event ${path}`)).then(() => ex.finish());
        \\    });
        \\  });
        \\  const client = await api.http.connect(io, { port: server.port, mode: 'event', limits });
        \\  const ex = client.open({ method: 'GET', scheme: 'http', authority: 'x', path: '/one' });
        \\  out.clientExchange = ex instanceof api.http.EventClientExchange && !('next' in ex);
        \\  const done = new Promise(resolve => {
        \\    const parts = [];
        \\    let status, path;
        \\    ex.register('headers', ev => { if (ev.kind === 'response') { status = ev.status; path = ev.headers.get('x-path'); } });
        \\    ex.register('data', ev => { parts.push(...ev.data); ex.consume(ev.data.length); });
        \\    ex.register('close', ev => resolve({ status, path, body: text(parts), code: ev.code }));
        \\  });
        \\  const got = await done;
        \\  out.response = got.status === 200 && got.path === '/one' && got.body === 'event /one' && got.code === 0;
        \\  // A server with no `request` handler refuses the stream.
        \\  const quiet = api.http.serve(io, { listen: { port: 0 }, mode: 'event', limits });
        \\  const c2 = await api.http.connect(io, { port: quiet.port, mode: 'event', limits });
        \\  const refused = c2.open({ method: 'GET', scheme: 'http', authority: 'x', path: '/none' });
        \\  out.refused = await new Promise(resolve => { refused.register('close', ev => resolve(ev.code)); refused.register('error', () => resolve('error')); });
        \\  // An event session pair, without the server wrapper.
        \\  const { plain, accepted } = await pair(api, io);
        \\  const s = api.http.session(accepted, { role: 'server', mode: 'event', limits });
        \\  const c = api.http.session(plain, { role: 'client', mode: 'event', limits });
        \\  out.sessionClasses = s instanceof api.http.EventServerSession && c instanceof api.http.ClientSession;
        \\  const closed = new Promise(resolve => s.register('close', resolve));
        \\  s.register('request', rx => { rx.register('headers', ev => { if (ev.endStream) { rx.respond({ status: 204 }); } }); });
        \\  await c.ready();
        \\  const e3 = c.open({ method: 'GET', scheme: 'http', authority: 'x', path: '/204' });
        \\  out.status204 = await new Promise(resolve => e3.register('headers', ev => { if (ev.kind === 'response') resolve(ev.status); }));
        \\  out.badEvent = (() => { try { e3.register('nope', () => {}); return 'no'; } catch (e) { return e.name; } })();
        \\  await c.close();
        \\  await s.close();
        \\  await closed;
        \\  await client.close();
        \\  await c2.close();
        \\  await server.close();
        \\  await quiet.close();
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.classes && report.serverExchange && report.clientExchange && report.response && report.refused === 7 && report.sessionClasses && report.status204 === 204 && report.badEvent === 'TypeError'");
}

// A server for the pool and fetch tests: `/echo` answers `<method> <path> auth=<authorization> body=<request body>`, `/rNNN`
// redirects to /echo (`/xorigin` to `localhost`, `/loop` to itself), `/slow` answers after 100 ms, `/big` sends 300000 bytes.
const client_prelude = prelude ++
    \\const app = (api, io) => {
    \\  const handle = async (ex, port) => {
    \\    let path, method, auth = '', size = 0; const body = [];
    \\    for (let ev; (ev = await ex.next()); ) {
    \\      if (ev.type === 'headers' && ev.kind === 'request') { path = ev.path; method = ev.method; auth = ev.headers.get('authorization') ?? ''; }
    \\      if (ev.type === 'data') { body.push(...ev.data); ex.consume(ev.data.length); }
    \\      if ((ev.type === 'headers' && ev.endStream) || ev.type === 'end' || ev.type === 'closed') break;
    \\    }
    \\    const reply = async (status, fields, content) => {
    \\      ex.respond({ status, headers: headersOf(api, fields), body: 'stream' });
    \\      for (let at = 0; at < content.length; at += 16384) await ex.send(content.subarray(at, at + 16384));
    \\      ex.finish(headersOf(api, [['x-done', 'yes']]));
    \\    };
    \\    const redirect = (status, to) => reply(status, [['location', to]], new Uint8Array(0));
    \\    if (path === '/slow') await io.timer.sleep(100);
    \\    if (path === '/big') return reply(200, [], new Uint8Array(300000).fill(1));
    \\    if (path === '/xorigin') return redirect(302, `http://localhost:${port}/echo`);
    \\    if (path === '/loop') return redirect(302, '/loop');
    \\    if (path === '/same') return redirect(302, '../echo?x=1');
    \\    const m = /^\/r(\d\d\d)$/.exec(path);
    \\    if (m) return redirect(Number(m[1]), '/echo');
    \\    return reply(200, [], bytes(`${method} ${path} auth=${auth} body=${text(body)}`));
    \\  };
    \\  return { handle };
    \\};
    \\const listen = async (api, io, limitsOf = limits) => {
    \\  const listener = io.tcp.listen(stdNet.SocketAddr.parse('127.0.0.1:0')).pulling();
    \\  const port = listener.localAddr.port;
    \\  const sessions = [];
    \\  const { handle } = app(api, io);
    \\  (async () => { try { for (;;) {
    \\    const session = api.http.session(await listener.accept(), { role: 'server', mode: 'pull', limits: limitsOf });
    \\    sessions.push(session);
    \\    (async () => { try { for await (const ex of session) handle(ex, port).catch(() => {}); } catch {} })();
    \\  } } catch {} })();
    \\  return { port, sessions, close: () => listener.close() };
    \\};
    \\const readAll = async response => { let n = 0; const parts = []; for await (const chunk of response.body) { n += chunk.length; if (parts.length < 200) parts.push(...chunk.subarray(0, 64)); } return { n, text: text(parts) }; };
    \\
;

test "http: pool reuses sessions, opens another at the peer's stream limit, drops dead ones" {
    if (!m.Api.http_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", client_prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const clock = api.io.create();
        \\  const throws = f => { try { f(); return 'no'; } catch (e) { return e.name; } };
        \\  const policy = { limit: 4, perKey: 4, idle: 30000, queue: 8 };
        \\  out.checks = [throws(() => api.http.pool(io, { mode: 'pull', limits })), throws(() => api.http.pool(io, { mode: 'pull', limits, sessions: { limit: 1 } })), throws(() => api.http.pool(io, { mode: 'x', limits, sessions: policy })), throws(() => api.http.pool(io, { mode: 'pull', sessions: policy }))].join();
        \\  // Server streams limit 2: the peer's SETTINGS decide when the pool dials again.
        \\  const server = await listen(api, io, { ...limits, streams: 2 });
        \\  const target = { scheme: 'http', host: '127.0.0.1', port: server.port };
        \\  const head = path => ({ method: 'GET', authority: 'x', path });
        \\  const pool = api.http.pool(io, { mode: 'pull', limits, sessions: policy });
        \\  out.policy = pool.sessions.limit === 4 && pool.sessions.idle === 30000 && Object.isFrozen(pool.sessions) && pool instanceof api.http.ClientPool;
        \\  out.mode = pool.mode;
        \\  for (let i = 0; i < 3; i++) await collect(await pool.open(target, head('/echo')));
        \\  out.reused = pool.size === 1 && server.sessions.length === 1;
        \\  let most = 0;
        \\  const all = await Promise.all(Array.from({ length: 5 }, async () => { const ex = await pool.open(target, head('/slow')); most = Math.max(most, pool.size); return collect(ex); }));
        \\  out.concurrent = all.every(r => r.status === 200) && most === 3 && server.sessions.length === 3;
        \\  // A graceful close from the peer (GOAWAY) and a closed connection are noticed; the next request dials a new session.
        \\  const before = server.sessions.length;
        \\  for (const s of server.sessions) await s.end();
        \\  await clock.timer.sleep(100);
        \\  const after = await collect(await pool.open(target, head('/echo')));
        \\  out.goaway = after.status === 200 && server.sessions.length === before + 1;
        \\  await server.sessions.at(-1).close();
        \\  await clock.timer.sleep(100);
        \\  const again = await collect(await pool.open(target, head('/echo')));
        \\  out.dead = again.status === 200 && server.sessions.length === before + 2;
        \\  // Another origin (a different servername) is another key.
        \\  await collect(await pool.open({ ...target, servername: 'other' }, head('/echo')));
        \\  out.keyed = server.sessions.length === before + 3;
        \\  // A name needs a lookup.
        \\  out.name = await outcome(pool.open({ ...target, host: 'localhost' }, head('/echo')));
        \\  // Idle sessions are closed after `idle` ms; an idle one makes room for another origin.
        \\  const brief = api.http.pool(io, { mode: 'pull', limits, sessions: { limit: 1, perKey: 1, idle: 40, queue: 0 } });
        \\  await collect(await brief.open(target, head('/echo')));
        \\  out.held = brief.size === 1;
        \\  await clock.timer.sleep(250);
        \\  out.idle = brief.size === 0;
        \\  const tight = api.http.pool(io, { mode: 'pull', limits, sessions: { limit: 1, perKey: 1, idle: 30000, queue: 0 } });
        \\  await collect(await tight.open(target, head('/echo')));
        \\  await collect(await tight.open({ ...target, servername: 'evict' }, head('/echo')));
        \\  out.evicted = tight.size === 1;
        \\  // A full queue fails loudly.
        \\  const slow = tight.open({ ...target, servername: 'evict' }, head('/slow')).then(collect, e => e.name);
        \\  const full = await outcome(tight.open({ ...target, servername: 'evict2' }, head('/slow')));
        \\  out.queue = full === 'WouldBlock' && (await slow).status === 200;
        \\  await pool.close();
        \\  out.closed = pool.closed && (await outcome(pool.open(target, head('/echo')))) === 'BadHandle';
        \\  await brief.close();
        \\  await tight.close();
        \\  await server.close();
        \\  await io.close();
        \\  await clock.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.checks === 'TypeError,TypeError,TypeError,TypeError' && report.policy && report.mode === 'pull' && report.reused && report.concurrent && report.goaway && report.dead && report.keyed && report.name === 'InvalidInput' && report.held && report.idle && report.evicted && report.queue && report.closed");
}

test "http: fetch follows redirects with explicit rules and streams bodies" {
    if (!m.Api.http_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", client_prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const server = await listen(api, io);
        \\  const pool = api.http.pool(io, { mode: 'pull', limits, sessions: { limit: 4, perKey: 2, idle: 30000, queue: 8 }, lookup: host => host === 'localhost' ? '127.0.0.1' : Promise.reject(new Error('unknown host')) });
        \\  const base = `http://127.0.0.1:${server.port}`;
        \\  const follow = { limit: 3, strip: ['authorization', 'cookie'] };
        \\  const get = (path, extra = {}) => api.http.fetch(pool, { method: 'GET', url: base + path, redirect: follow, ...extra });
        \\  const auth = headersOf(api, [['authorization', 'secret'], ['x-keep', '1']]);
        \\  // Head and body of a plain response; trailers after the body.
        \\  const plain = await get('/echo?q=1');
        \\  const first = await readAll(plain);
        \\  out.plain = plain.status === 200 && plain.url === `${base}/echo?q=1` && !plain.redirected && first.text === 'GET /echo?q=1 auth= body=' && plain.trailers.get('x-done') === 'yes';
        \\  out.frozen = plain.headers instanceof api.http.fields && Object.isFrozen(plain) && plain instanceof api.http.FetchResponse;
        \\  out.once = (() => { try { plain.body[Symbol.asyncIterator](); return 'no'; } catch (e) { return e.name; } })();
        \\  // Flow control: 300000 bytes through a 65535 byte window arrive in full because each chunk is given back on the next pull.
        \\  const big = await get('/big');
        \\  out.big = (await readAll(big)).n === 300000;
        \\  // Stopping early cancels the stream and frees its slot.
        \\  for (let i = 0; i < 5; i++) { const r = await get('/big'); for await (const chunk of r.body) break; }
        \\  const closed = await get('/big'); closed.close();
        \\  out.early = (await readAll(await get('/echo'))).text.startsWith('GET /echo');
        \\  // Method rules of RFC 9110 section 15.4.
        \\  const send = (status, method, body) => api.http.fetch(pool, { method, url: `${base}/r${status}`, headers: auth, body, redirect: follow }).then(r => readAll(r).then(b => b.text), e => e.name);
        \\  out.r301 = await send(301, 'POST', bytes('hi'));
        \\  out.r302 = await send(302, 'PUT', bytes('hi'));
        \\  out.r303 = await send(303, 'PUT', bytes('hi'));
        \\  out.r307 = await send(307, 'POST', bytes('hi'));
        \\  out.r308 = await send(308, 'PUT', bytes('yo'));
        \\  out.stream = await send(307, 'POST', (async function* () { yield bytes('a'); })());
        \\  // A request body stream, sent while the response is read.
        \\  const posted = await api.http.fetch(pool, { method: 'POST', url: `${base}/echo`, redirect: follow, body: (async function* () { yield bytes('abc'); yield bytes('def'); })() });
        \\  out.upload = (await readAll(posted)).text;
        \\  // Sensitive headers survive a redirect inside the origin and are dropped across origins.
        \\  const same = await get('/same', { headers: auth });
        \\  out.same = (await readAll(same)).text === 'GET /echo?x=1 auth=secret body=' && same.redirected;
        \\  const cross = await get('/xorigin', { headers: auth });
        \\  out.cross = (await readAll(cross)).text === 'GET /echo auth= body=' && cross.url === `http://localhost:${server.port}/echo` && cross.redirected;
        \\  // Hop limit, no following.
        \\  out.loop = await get('/loop').then(() => 'no', e => e.name);
        \\  const manual = await get('/r302', { redirect: { limit: 0, strip: [] } });
        \\  out.manual = manual.status === 302 && manual.headers.get('location') === '/echo';
        \\  manual.close();
        \\  // Bad inputs.
        \\  const bad = f => f().then(() => 'no', e => e.name);
        \\  out.bad = [await bad(() => api.http.fetch(pool, { method: 'GET', url: base })), await bad(() => api.http.fetch(pool, { method: 'GET', url: 'ftp://x/', redirect: follow })), await bad(() => api.http.fetch(pool, { method: 'GET', url: 'https://x/', redirect: follow })), await bad(() => api.http.fetch(pool, { method: 'GET', url: 'http://u@x/', redirect: follow }))].join();
        \\  await pool.close();
        \\  await server.close();
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.plain && report.frozen && report.once === 'TypeError' && report.big && report.early && report.r301 === 'GET /echo auth=secret body=' && report.r302 === 'PUT /echo auth=secret body=hi' && report.r303 === 'GET /echo auth=secret body=' && report.r307 === 'POST /echo auth=secret body=hi' && report.r308 === 'PUT /echo auth=secret body=yo' && report.stream === 'Unsupported' && report.upload === 'POST /echo auth= body=abcdef' && report.same && report.cross && report.loop === 'QuotaExceeded' && report.manual && report.bad === 'TypeError,TypeError,TypeError,TypeError'");
}
