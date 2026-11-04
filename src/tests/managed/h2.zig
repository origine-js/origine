const check = @import("support.zig").check;
const Parent = @import("channel.zig").Parent;
const tls_prelude = @import("tls.zig").prelude;
const m = @import("@managed");

// `api.http.protocols.h2` at the frame level. `request` and `respond` are the small helper that stands in for the
// message-level session API: a request is a header block (pseudo header fields first) and DATA, read back frame by
// frame.
const prelude = tls_prelude ++
    \\const settings = { headerTableSize: 4096, enablePush: false, maxConcurrentStreams: 100, initialWindowSize: 65535, maxFrameSize: 16384, maxHeaderListSize: 16384, enableConnectProtocol: false, noRfc7540Priorities: false };
    \\const options = (more = {}) => ({ settings, window: 1 << 20, batch: 4096, padding: 0, extensions: [0xb0], frames: 'parsed', ...more });
    \\const fieldsOf = (api, pairs) => api.http.fields.of(pairs);
    \\// Two sessions over a loopback TCP pair, pull mode.
    \\const sessions = async (api, io, client = options(), server = options()) => {
    \\  const { plain, accepted } = await pair(api, io);
    \\  const { h2 } = api.http.protocols;
    \\  return { c: h2.client(plain, client).pulling(), s: h2.server(accepted, server).pulling(), plain, accepted };
    \\};
    \\// Reads frame events until `until(event)`; returns them all.
    \\const until = async (session, done) => { const seen = []; for (;;) { const e = await session.next(); if (e === undefined) return seen; seen.push(e); if (done(e, seen)) return seen; } };
    \\const all = (...types) => (e, seen) => types.every(t => seen.some(x => x.type === t));
    \\// The body and the last header block of a stream, consuming what it reads.
    \\const read = async (session, id) => {
    \\  const out = { body: [], blocks: [] };
    \\  for (;;) {
    \\    const e = await session.next();
    \\    if (e === undefined) return out;
    \\    if (e.streamId !== id) continue;
    \\    if (e.type === 'headers' && e.last) out.blocks.push(e);
    \\    if (e.type === 'data') { out.body.push(...e.data); session.consume(id, e.data.length); e.data.unref(); }
    \\    if (e.type === 'closed' || e.endStream) return out;
    \\  }
    \\};
    \\
;

test "h2: a request and a response at the frame level over h2c" {
    if (!m.Api.http_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const { h2 } = api.http.protocols;
        \\  const { c, s, plain, accepted } = await sessions(api, io);
        \\  out.kinds = c instanceof h2.PullH2Session && s instanceof h2.PullH2Session && plain.closed && accepted.closed;
        \\  const id = c.submitHeaders(0, fieldsOf(api, [[':method', 'POST'], [':scheme', 'http'], [':authority', 'x'], [':path', '/up'], ['x-a', '1'], ['x-a', '2']]), { endStream: false });
        \\  out.id = id === 1 && c.nextStreamId === 3 && c.streamState(1) !== 'idle';
        \\  const sent = c.submitData(id, bytes('hello '), { endStream: false, padding: 7 });
        \\  await c.submitData(id, bytes('world'), { endStream: true });
        \\  await sent;
        \\  const settings = await until(s, e => e.type === 'settings' && !e.ack);
        \\  out.settings = settings.at(-1).entries.length === 8 && settings.at(-1).entries[0][0] === 'headerTableSize';
        \\  const req = await read(s, 1);
        \\  const head = req.blocks[0];
        \\  out.head = head.category === 'request' && [...head.headers].map(([n]) => n).join() === ':method,:scheme,:authority,:path,x-a,x-a' && head.headers.getAll('x-a').join() === '1,2' && Object.isFrozen(head);
        \\  out.body = text(req.body);
        \\  // The answer: a head, DATA, then trailers while the DATA is still queued.
        \\  s.submitHeaders(1, fieldsOf(api, [[':status', '200'], ['content-type', 'text/plain']]), { endStream: false });
        \\  s.submitData(1, bytes('ok'), { endStream: false });
        \\  s.submitHeaders(1, fieldsOf(api, [['x-done', 'yes']]), { endStream: true });
        \\  const res = await read(c, 1);
        \\  out.response = res.blocks.length === 2 && res.blocks[0].category === 'response' && res.blocks[0].headers.get(':status') === '200' && res.blocks[1].headers.get('x-done') === 'yes' && text(res.body) === 'ok';
        \\  out.info = c.remoteSettings.maxConcurrentStreams === 100 && c.localSettings.initialWindowSize === 65535 && c.windows(0).send > 0 && typeof c.windows(1).receive === 'number';
        \\  await c.close();
        \\  await s.close();
        \\  out.closed = c.closed && (() => { try { c.submitPing(new Uint8Array(8), { ack: false }); return 'no'; } catch (e) { return e.name; } })() === 'BadHandle';
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.kinds && report.id && report.settings && report.head && report.body === 'hello world' && report.response && report.info && report.closed");
}

test "h2: control frames, extensions and a DATA lease" {
    if (!m.Api.http_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const { c, s } = await sessions(api, io);
        \\  c.submitPing(bytes('12345678'), { ack: false });
        \\  c.submitWindowUpdate(0, 1000);
        \\  c.submitSettings({ maxConcurrentStreams: 7 });
        \\  c.submitExtension(0xb0, 3, 0, bytes('ext'));
        \\  const seen = await until(s, (e, seen) => all('ping', 'window_update', 'unknown')(e, seen) && seen.some(x => x.type === 'settings' && x.entries.length === 1));
        \\  const ping = seen.find(e => e.type === 'ping');
        \\  out.ping = ping && !ping.ack && text(ping.data) === '12345678';
        \\  out.window = seen.some(e => e.type === 'window_update' && e.streamId === 0 && e.increment === 1000);
        \\  out.update = seen.some(e => e.type === 'settings' && e.entries.some(([k, v]) => k === 'maxConcurrentStreams' && v === 7));
        \\  const ext = seen.find(e => e.type === 'unknown');
        \\  out.ext = ext.frameType === 0xb0 && ext.flags === 3 && text(ext.payload) === 'ext';
        \\  // RFC 9218 priorities need the peer's noRfc7540Priorities.
        \\  out.priority = (() => { try { c.submitPriority(1, 'u=1'); return 'no'; } catch (e) { return e.name; } })();
        \\  // PINGs are answered by the caller.
        \\  s.submitPing(ping.data, { ack: true });
        \\  s.submitAltsvc(0, 'http://x', 'h3=":443"');
        \\  s.submitOrigin(['http://x', 'http://y']);
        \\  s.submitGoaway(0, 0, bytes('bye'));
        \\  const back = await until(c, all('ping', 'altsvc', 'origin', 'goaway'));
        \\  out.ack = back.some(e => e.type === 'ping' && e.ack);
        \\  out.altsvc = back.some(e => e.type === 'altsvc' && e.origin === 'http://x' && e.value === 'h3=":443"');
        \\  out.origin = back.some(e => e.type === 'origin' && e.origins.join() === 'http://x,http://y');
        \\  out.goaway = text(back.find(e => e.type === 'goaway').debug) === 'bye';
        \\  await c.close(); await s.close();
        \\  // DATA arrives as a Lease, one per frame.
        \\  const t = await sessions(api, io);
        \\  const id = t.c.submitHeaders(0, fieldsOf(api, [[':method', 'POST'], [':scheme', 'http'], [':authority', 'x'], [':path', '/']]), { endStream: false });
        \\  await t.c.submitData(id, bytes('leased'), { endStream: true });
        \\  const data = (await until(t.s, e => e.type === 'data')).at(-1);
        \\  out.lease = data.data instanceof api.net.Lease && text(data.data) === 'leased' && data.endStream && data.data.buffer.byteLength === 6;
        \\  data.data.unref();
        \\  out.released = data.data.released && data.data.length === 0;
        \\  await io.close();
        \\  out.canceled = t.c.closed;
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.ping && report.window && report.update && report.ext && report.ack && report.altsvc && report.origin && report.goaway && report.priority === 'InvalidInput' && report.lease && report.released && report.canceled");
}

test "h2: event-mode sessions, TLS with the caller's ALPN, a duck-typed stream and bad inputs" {
    if (!m.Api.http_enabled or !m.Api.tls_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\const pipePair = () => {
        \\  const lane = () => ({ chunks: [], ended: false, reader: null });
        \\  const wake = l => { const r = l.reader; l.reader = null; r?.(); };
        \\  const end = (inn, out) => ({
        \\    read(length) { return new Promise(resolve => { const go = () => { if (inn.chunks.length) { let c = inn.chunks[0]; if (c.length > length) { inn.chunks[0] = c.subarray(length); c = c.subarray(0, length); } else inn.chunks.shift(); resolve(c); } else if (inn.ended) resolve(new Uint8Array(0)); else inn.reader = go; }; go(); }); },
        \\    queued: { put(b) { out.chunks.push(b.slice()); wake(out); return b.length; }, drained() { return Promise.resolve(); } },
        \\    end() { out.ended = true; wake(out); },
        \\    close() { out.ended = inn.ended = true; wake(out); wake(inn); },
        \\  });
        \\  const ab = lane(), ba = lane();
        \\  return [end(ba, ab), end(ab, ba)];
        \\};
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const { tls } = api;
        \\  const { h2 } = api.http.protocols;
        \\  const throws = f => { try { f(); return 'no'; } catch (e) { return e.name; } };
        \\  // The caller negotiates: TLS with its own ALPN list, then the table its protocol names.
        \\  const client = tls.client({ roots: tls.RootPki.fromPem(bytes(CA)), alpn: ['h2'] });
        \\  const server = tls.server({ identities: [tls.Identity.fromPem(bytes(SERVER), bytes(KEY))], clientAuth: tls.ClientAuth.none(), alpn: ['h2'] });
        \\  const { plain, accepted } = await pair(api, io);
        \\  const [a, b] = await Promise.all([client.connect(plain, { servername: 'localhost' }), server.accept(accepted)]);
        \\  const protocol = api.http.protocols[a.info().alpn];
        \\  out.alpn = protocol === h2;
        \\  const c = protocol.client(a, options()).pulling();
        \\  const s = protocol.server(b, options()).evented();
        \\  out.event = s instanceof h2.EventH2Session && s.paused;
        \\  // The server answers each request from its handlers.
        \\  const order = [];
        \\  s.register('headers', e => { order.push('headers'); if (e.last && e.category === 'request') s.submitHeaders(e.streamId, fieldsOf(api, [[':status', '204']]), { endStream: true }); });
        \\  s.register('settings', () => order.push('settings'));
        \\  const reg = s.register('ping', () => order.push('ping'));
        \\  out.unregister = reg.unregister() && !reg.unregister();
        \\  const id = c.submitHeaders(0, fieldsOf(api, [[':method', 'GET'], [':scheme', 'https'], [':authority', 'localhost'], [':path', '/']]), { endStream: true });
        \\  const res = await read(c, id);
        \\  out.status = res.blocks[0].headers.get(':status');
        \\  out.order = order[0] === 'settings' && order.includes('headers') && !order.includes('ping');
        \\  const closing = new Promise(resolve => s.register('close', resolve));
        \\  await c.close();
        \\  await closing;
        \\  // Over a duck-typed JS stream: io is required.
        \\  const [left, right] = pipePair();
        \\  out.needsIo = throws(() => h2.client(left, options()));
        \\  const jc = h2.client(left, options({ io })).pulling();
        \\  const js = h2.server(right, options({ io })).pulling();
        \\  const jid = jc.submitHeaders(0, fieldsOf(api, [[':method', 'GET'], [':scheme', 'http'], [':authority', 'x'], [':path', '/js']]), { endStream: true });
        \\  const req = await read(js, jid);
        \\  out.js = req.blocks[0].headers.get(':path') === '/js';
        \\  await jc.close(); await js.close();
        \\  // Inputs are checked before the stream is touched.
        \\  const spare = await pair(api, io);
        \\  out.missing = throws(() => h2.client(spare.plain, { ...options(), settings: { headerTableSize: 1 } }));
        \\  out.frames = throws(() => h2.client(spare.plain, options({ frames: 'bytes' })));
        \\  out.untouched = !spare.plain.closed;
        \\  out.fields = throws(() => fieldsOf(api, [['X', '1']])) + ',' + throws(() => fieldsOf(api, [['a', '1'], [':path', '/']])) + ',' + throws(() => new api.http.fields());
        \\  const received = res.blocks[0].headers;
        \\  out.sealed = throws(() => received.put('a', 'b'));
        \\  out.h3 = throws(() => api.http.protocols.h3.client(spare.plain, options()));
        \\  out.brand = await outcome(h2.PullH2Session.prototype.next.call({}));
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.alpn && report.event && report.unregister && report.status === '204' && report.order && report.needsIo === 'TypeError' && report.js");
    try check(p.scope, "report.missing === 'TypeError' && report.frames === 'TypeError' && report.untouched && report.fields === 'InvalidInput,InvalidInput,TypeError' && report.sealed === 'TypeError' && report.h3 === 'Unsupported' && report.brand === 'TypeError'");
}
