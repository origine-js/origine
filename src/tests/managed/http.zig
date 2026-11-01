const check = @import("support.zig").check;
const Parent = @import("channel.zig").Parent;
const tls_prelude = @import("tls.zig").prelude;
const m = @import("@managed");

// A tiny HTTP/2 server and client in JS over `api.http`, shared by the tests (TLS fixtures come from tls.zig).
const prelude = tls_prelude ++
    \\const limits = { streams: 100, headers: 16384, window: 65535, connection: 1 << 20, batch: 4096 };
    \\const headersOf = (api, pairs) => { const h = new api.http.HeaderList(); for (const [k, v] of pairs) h.put(k, v); return h; };
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
        \\  const list = new api.http.HeaderList().put('a', '1').put('b', 'é').put('a', '3');
        \\  out.list = list.length === 3 && list.get('A') === '1' && list.getAll('a').join() === '1,3' && list.get('b') === 'é' && list.has('b') && !list.has('c') && [...list].length === 3;
        \\  out.badName = throws(() => list.put('X-Upper', 'v'));
        \\  out.badValue = throws(() => list.put('x', 'a\nb'));
        \\  const { plain, accepted } = await pair(api, io);
        \\  out.limits = throws(() => api.http.session(plain, { role: 'client', mode: 'pull', limits: { streams: 1 } }));
        \\  out.role = throws(() => api.http.session(plain, { role: 'peer', mode: 'pull', limits }));
        \\  out.event = throws(() => api.http.session(plain, { role: 'client', mode: 'event', limits }));
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
    try check(p.scope, "report.list && report.badName === 'TypeError' && report.badValue === 'TypeError' && report.limits === 'TypeError' && report.role === 'TypeError' && report.event === 'Unsupported' && report.untouched && report.badHead === 'TypeError' && report.upper === 'TypeError' && report.reset === 8 && ['UnexpectedEof', 'ConnectionReset', 'BrokenPipe', 'NotConnected'].includes(report.aborted) && report.closedSession");
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
        \\  out.alpn = a.alpn === 'h2' && b.alpn === 'h2';
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
        \\  out.connectEvent = await outcome(api.http.connect(io, { port: server.port, mode: 'event', limits }));
        \\  out.serveEvent = throws(() => api.http.serve(io, { mode: 'event', limits }));
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
        \\  await timers.sleep(50);
        \\  out.dropped = secureServer.dropped >= 1;
        \\  await secure.close();
        \\  await secureServer.close();
        \\  await io.close();
        \\  await timers.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.port && report.h2c && report.noLimits === 'TypeError' && report.connectEvent === 'Unsupported' && report.serveEvent === 'Unsupported' && report.noPort === 'TypeError' && report.closed && report.refused === 'ConnectionRefused' && report.tls && report.noAlpn === 'NoApplicationProtocol' && report.wrongName === 'CertificateRejected' && report.dropped");
}
