const check = @import("support.zig").check;
const Parent = @import("channel.zig").Parent;

// `settles` answers 'hang' instead of leaving the test waiting forever on the bug it looks for.
const prelude =
    \\const settles = (timers, promise) => Promise.race([promise.then(() => 'resolved', e => e.name), timers.timer.sleep(1000).then(() => 'hang')]);
    \\import { SocketAddr } from 'origine:@std/net';
    \\const at = port => SocketAddr.parse(`127.0.0.1:${port}`);
    \\const shape = (stream, mode, options) => (mode === 'event' ? stream.evented(options) : stream.pulling(options));
    \\const fill = async (api, io, mode) => {
    \\  const server = io.tcp.listen(at(0)).pulling();
    \\  const accepting = server.accept();
    \\  const client = shape(await io.tcp.connect(server.localAddr), mode);
    \\  const peer = (await accepting).pulling();
    \\  client.queued.limit = 1;
    \\  const first = client.queued.send(new Uint8Array(1 << 25));
    \\  const second = client.queued.send(new Uint8Array(10));
    \\  return { client, peer, first, second };
    \\};
    \\const consume = async peer => { while ((await peer.read(1 << 20)).length > 0); };
    \\
;

test "net: a paused socket still admits waiting sends" {
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const timers = api.io.create();
        \\  const io = api.io.create();
        \\  const { client, peer, first, second } = await fill(api, io, 'event');
        \\  let drains = 0;
        \\  client.register('drain', () => { drains++; });
        \\  client.pause();
        \\  consume(peer).catch(() => {});
        \\  out.first = await settles(timers, first);
        \\  out.second = await settles(timers, second);
        \\  out.drains = drains > 0;
        \\  await io.close();
        \\  await timers.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.first === 'resolved' && report.second === 'resolved' && report.drains");
}

test "net: a write failure rejects waiting sends of a paused socket with its error" {
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const timers = api.io.create();
        \\  const io = api.io.create();
        \\  const { client, peer, second } = await fill(api, io, 'event');
        \\  let errors = 0;
        \\  client.register('error', () => { errors++; });
        \\  client.pause();
        \\  await peer.close();
        \\  out.second = await settles(timers, second);
        \\  out.heldBack = errors === 0;
        \\  client.resume();
        \\  await timers.timer.sleep(50);
        \\  out.delivered = errors === 1 && client.closed;
        \\  await io.close();
        \\  await timers.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "['BrokenPipe', 'ConnectionReset'].includes(report.second) && report.heldBack && report.delivered");
}

test "net: with no data handler end, error and close still fire; held chunks keep end behind them" {
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const server = io.tcp.listen(at(0)).pulling();
        \\  const open = async () => {
        \\    const accepting = server.accept();
        \\    const client = (await io.tcp.connect(server.localAddr)).evented();
        \\    return [client, (await accepting).pulling()];
        \\  };
        \\  const [a, peerA] = await open();
        \\  let ends = 0;
        \\  a.register('end', () => { ends++; });
        \\  a.register('data', () => {}).unregister();
        \\  await peerA.end('write');
        \\  await io.timer.sleep(50);
        \\  out.endFired = ends === 1;
        \\  const [b, peerB] = await open();
        \\  let endsB = 0;
        \\  const bytes = [];
        \\  b.register('end', () => { endsB++; });
        \\  b.register('data', () => {}).unregister();
        \\  await peerB.queued.send(Uint8Array.of(7));
        \\  await peerB.end('write');
        \\  await io.timer.sleep(50);
        \\  out.endWaits = endsB === 0;
        \\  b.register('data', ev => { using chunk = ev.buffer(); bytes.push(...chunk); });
        \\  await io.timer.sleep(50);
        \\  out.inOrder = bytes.join() === '7' && endsB === 1;
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.endFired && report.endWaits && report.inOrder");
}

test "net: closing the runtime rejects sends and drained() that wait in the queue" {
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const timers = api.io.create();
        \\  const io = api.io.create();
        \\  const { client, first, second } = await fill(api, io, 'pull');
        \\  const emptied = client.queued.drained();
        \\  out.waited = client.queued.waiting === 1;
        \\  await io.close();
        \\  out.results = (await Promise.all([first, second, emptied].map(x => settles(timers, x)))).join();
        \\  await timers.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.waited && report.results === 'Canceled,Canceled,Canceled'");
}

test "net: every pending io.run() resolves" {
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const timers = api.io.create();
        \\  const io = api.io.create();
        \\  const server = io.tcp.listen(at(0)).evented();
        \\  server.register('connection', socket => socket.close());
        \\  const runs = [io.run(), io.run(), io.run()];
        \\  await timers.timer.sleep(20);
        \\  await server.close();
        \\  out.runs = (await Promise.all(runs.map(x => settles(timers, x)))).join();
        \\  await io.close();
        \\  await timers.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.runs === 'resolved,resolved,resolved'");
}

test "net: closing a pull server ends its accepts, its loop and the port" {
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const timers = api.io.create();
        \\  const io = api.io.create();
        \\  const server = io.tcp.listen(at(0)).pulling();
        \\  const { port } = server.localAddr;
        \\  const pending = server.accept();
        \\  const second = server.accept();
        \\  const loop = (async () => { for await (const socket of server) await socket.close(); })();
        \\  await timers.timer.sleep(20);
        \\  await server.close();
        \\  // The promise of close() says the port is free: nothing may be needed in between.
        \\  const again = io.tcp.listen(at(port)).pulling();
        \\  out.results = (await Promise.all([pending, second, loop].map(x => settles(timers, x)))).join();
        \\  const accepting = again.accept();
        \\  const client = await io.tcp.connect(at(port));
        \\  const conn = await accepting;
        \\  out.rebound = conn.peerAddr.port > 0;
        \\  await client.close(); await conn.close();
        \\  // Twice is fine.
        \\  await again.close();
        \\  await again.close();
        \\  await io.close();
        \\  await timers.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.results === 'Canceled,Canceled,resolved' && report.rebound");
}

test "net: connections queued when an event server closes are closed, not leaked" {
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const timers = api.io.create();
        \\  const io = api.io.create();
        \\  const server = io.tcp.listen(at(0)).evented();
        \\  const kept = [];
        \\  server.pause();
        \\  server.register('connection', socket => { kept.push(socket); server.close(); });
        \\  const clients = [];
        \\  for (let i = 0; i < 3; i++) clients.push((await io.tcp.connect(server.localAddr)).pulling());
        \\  await timers.timer.sleep(50);
        \\  server.resume();
        \\  await timers.timer.sleep(50);
        \\  out.handled = kept.length === 1;
        \\  const ends = await Promise.all(clients.map(c => settles(timers, c.read(16).then(r => { if (r.length !== 0) throw new Error('data'); }))));
        \\  out.closed = ends.filter(x => x === 'resolved').length === 2;
        \\  await io.close();
        \\  await timers.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.handled && report.closed");
}

test "fs: an async grant refuses the handles of another grant" {
    var p: Parent = undefined;
    try p.setup("init.js",
        \\import { Dir, File } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const name = promise => promise.then(() => 'resolved', e => e.name);
        \\  const wide = await api.fs.requestAsync({ io, access: 'rw', handle: 'plain' });
        \\  await wide.dirCreateDir(Dir.cwd(), 'sub');
        \\  const secret = await wide.dirOpenFile(Dir.cwd(), 'secret.txt', 'w');
        \\  const narrow = await api.fs.requestAsync({ io, access: 'r', root: 'sub', handle: 'plain' });
        \\  const other = Dir.at(wide.id, 0);
        \\  const file = File.at(wide.id, secret.id);
        \\  const names = await Promise.all([
        \\    narrow.dirCreateDir(other, 'x'),
        \\    narrow.dirOpenFile(other, 'secret.txt'),
        \\    narrow.dirStat(other, 'secret.txt'),
        \\    narrow.dirDeleteFile(other, 'secret.txt'),
        \\    narrow.dirRename(Dir.cwd(), 'a', other, 'b'),
        \\    narrow.dirRename(other, 'a', Dir.cwd(), 'b'),
        \\    narrow.fileReadAll(file),
        \\    narrow.fileRead(file, new Uint8Array(1)),
        \\    narrow.fileReadInto(file, new Uint8Array(1)),
        \\    narrow.filePreadInto(file, new Uint8Array(1), 0),
        \\    narrow.fileClose(file),
        \\  ].map(name));
        \\  out.foreign = names.every(n => n === 'BadHandle') || names.join();
        \\  out.untouched = await wide.dirStat(Dir.cwd(), 'x').then(() => false, e => e.name === 'NotFound')
        \\    && await name(wide.dirStat(Dir.cwd(), 'secret.txt')) === 'resolved';
        \\  // Its own handles and the root sentinel still work.
        \\  out.own = await name(narrow.dirRead(Dir.cwd())) === 'resolved' && await name(wide.fileStat(file)) === 'resolved';
        \\
        \\  // A hardened grant reads a handle's fields once: a getter cannot pass as the sentinel and then name a grant.
        \\  const hard = await api.fs.requestAsync({ io, access: 'r', root: 'sub', handle: 'hardened' });
        \\  let reads = 0;
        \\  const forged = Object.create(Object.getPrototypeOf(Dir.cwd()), { fs: { get: () => (reads++ < 1 ? 0 : wide.id) }, id: { get: () => 0 } });
        \\  await name(hard.dirCreateDir(forged, 'y'));
        \\  out.forged = await wide.dirStat(Dir.cwd(), 'y').then(() => false, e => e.name === 'NotFound');
        \\  out.hardenedForeign = await name(hard.dirStat(other, 'secret.txt')) === 'InvalidInput';
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.foreign === true && report.untouched && report.own && report.forged && report.hardenedForeign");
}

test "graph: a graph made before the first async grant reads through one" {
    var p: Parent = undefined;
    try p.setup("init.js",
        \\import { Dir } from 'origine:@std/io';
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative } from 'origine:@std/graph/resolve/layers';
        \\import { fsProvider } from 'origine:@std/graph/providers';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const root = api.graph.root;
        \\  const created = api.graph.create();
        \\  const closed = api.graph.create();
        \\  closed.close();
        \\  const io = api.io.create();
        \\  const grant = await api.fs.requestAsync({ io, access: 'rw', handle: 'plain' });
        \\  const file = await grant.dirOpenFile(Dir.cwd(), 'm.js', 'w');
        \\  await grant.fileWriteAll(file, Uint8Array.from('export const m = 1;', c => c.charCodeAt(0)));
        \\  await grant.fileClose(file);
        \\  const handler = () => ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [fsProvider({ fs: grant, read: 'copy' })] });
        \\  const load = async graph => {
        \\    const context = await api.context.create({ import: handler(), graph });
        \\    const reference = await context.import('./m.js');
        \\    return graph.exports(reference).m;
        \\  };
        \\  out.root = await load(root);
        \\  out.created = await load(created);
        \\  out.after = await load(api.graph.create());
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.root === 1 && report.created === 1 && report.after === 1");
}

test "net: readCopy refuses an empty buffer, which could not tell end of stream" {
    var p: Parent = undefined;
    try p.setup("init.js",
        \\import { SocketAddr } from 'origine:@std/net';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const server = io.tcp.listen(SocketAddr.parse('127.0.0.1:0')).pulling();
        \\  const accepting = server.accept();
        \\  const client = (await io.tcp.connect(server.localAddr)).pulling();
        \\  const peer = (await accepting).pulling();
        \\  out.refused = await client.readCopy(new Uint8Array(0)).then(() => false, e => e instanceof TypeError);
        \\  await client.end('write');
        \\  await io.timer.sleep(50);
        \\  out.open = !client.closed;
        \\  await peer.queued.send(Uint8Array.of(9));
        \\  const buffer = new Uint8Array(4);
        \\  out.read = await client.readCopy(buffer) === 1 && buffer[0] === 9;
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.refused && report.open && report.read");
}

test "net: the send queue limit is an option, paused tells the truth, end rejects" {
    var p: Parent = undefined;
    try p.setup("init.js",
        \\import { SocketAddr } from 'origine:@std/net';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const server = io.tcp.listen(SocketAddr.parse('127.0.0.1:0')).evented();
        \\  out.serverPaused = server.paused;
        \\  const accepted = new Promise(resolve => server.register('connection', socket => resolve(socket.evented({ queued: { limit: 5 } }))));
        \\  io.run().catch(() => {});
        \\  out.serverFlowing = !server.paused;
        \\  const client = (await io.tcp.connect(server.localAddr)).evented({ queued: { limit: 7 } });
        \\  out.limits = client.queued.limit + ',' + (await accepted).queued.limit;
        \\  out.freshPaused = client.paused;
        \\  const registration = client.register('data', () => {});
        \\  out.flowing = !client.paused;
        \\  registration.unregister();
        \\  out.unregistered = client.paused;
        \\  client.pause();
        \\  client.register('data', () => {});
        \\  out.stillPaused = client.paused;
        \\  client.resume();
        \\  out.resumed = !client.paused;
        \\  const rejects = async f => { const pending = f(); return pending.then(() => false, e => e instanceof TypeError); };
        \\  out.end = await rejects(() => client.end()) && await rejects(() => client.end('send'));
        \\  const spare = () => io.tcp.listen(SocketAddr.parse('127.0.0.1:0'));
        \\  const unshaped = await io.tcp.connect(server.localAddr);
        \\  out.bad = [() => unshaped.pulling({ queued: 5 }), () => unshaped.pulling({ queued: { limit: 0 } }), () => unshaped.evented({ queued: { limit: -1 } }), () => { client.queued.limit = 1.5; }, () => spare().pulling.call(client)]
        \\    .every(f => { try { f(); return false; } catch (e) { return e instanceof TypeError; } });
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.limits === '7,5' && report.serverPaused && report.serverFlowing && report.freshPaused && report.flowing && report.unregistered && report.stillPaused && report.resumed && report.end && report.bad");
}

test "net: a data lease works with using and stays valid across awaits until disposed" {
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const server = io.tcp.listen(at(0)).evented();
        \\  // An async echo handler: the lease is used after an await, then disposed by `using` at block exit.
        \\  const kept = [];
        \\  let thrownRouted = 0;
        \\  server.register('connection', raw => {
        \\    const conn = raw.evented();
        \\    conn.register('error', e => { if (e.message === 'sync') thrownRouted++; });
        \\    conn.register('data', async ev => {
        \\      using chunk = ev.buffer();
        \\      kept.push(chunk);
        \\      out.same = ev.buffer() === chunk && chunk.length === ev.length && chunk instanceof api.net.Lease;
        \\      await io.timer.sleep(5);
        \\      out.validAfterAwait = !chunk.released && chunk.length > 0 && chunk.buffer.byteLength === chunk.length;
        \\      out.eventOver = ev.length === 0 && (() => { try { ev.buffer(); return false; } catch (e) { return e instanceof TypeError; } })();
        \\      await conn.queued.send(chunk);
        \\    });
        \\    conn.register('data', ev => { if (ev.length === 5) throw new Error('sync'); });
        \\  });
        \\  const client = (await io.tcp.connect(server.localAddr)).pulling();
        \\  await client.queued.send(Uint8Array.of(1, 2, 3));
        \\  const echoed = await client.read(16);
        \\  await io.timer.sleep(10);
        \\  out.echo = echoed.join() === '1,2,3';
        \\  out.disposed = kept.length === 1 && kept[0].released && kept[0].length === 0;
        \\  // A synchronous throw goes to the error handlers; the other handlers still ran.
        \\  await client.queued.send(Uint8Array.of(1, 2, 3, 4, 5));
        \\  out.echo5 = (await client.read(16)).length === 5;
        \\  await io.timer.sleep(10);
        \\  out.thrown = thrownRouted === 1;
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.same && report.validAfterAwait && report.eventOver && report.echo && report.disposed && report.echo5 && report.thrown");
}

test "udp: bind, sendTo, recvFrom, connect and datagram events with leases" {
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const { UdpSocketUnshaped, PullUdpSocket, EventUdpSocket, DatagramEvent, Lease } = api.net;
        \\  const raw = io.udp.bind(at(0));
        \\  const pull = raw.pulling();
        \\  out.shapes = raw instanceof UdpSocketUnshaped && pull instanceof PullUdpSocket && raw.closed && pull.localAddr.port > 0;
        \\  const events = io.udp.bind(at(0)).evented();
        \\  out.evented = events instanceof EventUdpSocket && events.paused;
        \\  const got = [];
        \\  let lease;
        \\  events.register('datagram', async ev => {
        \\    using chunk = ev.buffer();
        \\    lease = chunk;
        \\    out.event = ev instanceof DatagramEvent && chunk instanceof Lease && ev.buffer() === chunk && ev.length === chunk.length && String(ev.from) === String(pull.localAddr);
        \\    await io.timer.sleep(5);
        \\    got.push([...chunk].join());
        \\  });
        \\  // Whole datagrams, one lease each.
        \\  out.sent = await pull.sendTo(Uint8Array.of(1, 2, 3), events.localAddr);
        \\  await pull.sendTo(Uint8Array.of(4), events.localAddr);
        \\  await io.timer.sleep(30);
        \\  out.datagrams = got.join('|') === '1,2,3|4' && lease.released;
        \\  // recvFrom: the source as a SocketAddr; a short buffer keeps the head.
        \\  await events.sendTo(Uint8Array.of(9, 8, 7), pull.localAddr);
        \\  const first = await pull.recvFrom(2);
        \\  out.recv = first.data.join() === '9,8' && first.addr.port === events.localAddr.port && Object.isFrozen(first);
        \\  // connect: sendTo without an address goes to the peer; without one it is NotConnected.
        \\  out.notConnected = await pull.sendTo(Uint8Array.of(1)).then(() => false, e => e.name === 'NotConnected');
        \\  pull.connect(events.localAddr);
        \\  out.peer = pull.peerAddr.port === events.localAddr.port;
        \\  await pull.sendTo(Uint8Array.of(6));
        \\  await io.timer.sleep(20);
        \\  out.connected = got.at(-1) === '6';
        \\  // Closing the runtime cancels a pending receive; the objects stay and answer BadHandle.
        \\  const target = events.localAddr;
        \\  const pending = pull.recvFrom(16).then(() => 'resolved', e => e.name);
        \\  await io.close();
        \\  out.canceled = await pending;
        \\  out.closed = pull.closed && events.closed && await pull.sendTo(Uint8Array.of(1), target).then(() => false, e => e.name === 'BadHandle') &&
        \\    (() => { try { void events.localAddr; return false; } catch (e) { return e.name === 'BadHandle'; } })();
        \\  out.badArgs = (() => { try { io.udp.bind('127.0.0.1:0'); return false; } catch (e) { return e instanceof TypeError || e.name === 'BadHandle'; } })();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.shapes && report.evented && report.event && report.sent === 3 && report.datagrams && report.recv && report.notConnected && report.peer && report.connected && report.canceled === 'Canceled' && report.closed && report.badArgs");
}

test "io: close cancels pending connects, accepts and sends; stale objects answer BadHandle" {
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const listener = io.tcp.listen(at(0)).pulling();
        \\  const accepting = listener.accept().then(() => 'resolved', e => e.name);
        \\  const timer = io.timer.sleep(60000).then(() => 'resolved', e => e.name);
        \\  const running = io.run();
        \\  const closing = io.close();
        \\  out.same = io.close() === closing && io.closed;
        \\  await closing;
        \\  out.results = [await accepting, await timer].join();
        \\  out.run = await running.then(() => 'resolved', e => e.name);
        \\  out.stale = listener.closed && await listener.accept().then(() => false, e => e.name === 'BadHandle') &&
        \\    (() => { try { io.tcp.listen(at(0)); return false; } catch (e) { return e.name === 'BadHandle'; } })() &&
        \\    (() => { try { io.timer.sleep(1); return false; } catch (e) { return e.name === 'BadHandle'; } })() &&
        \\    await io.run().then(() => false, e => e.name === 'BadHandle');
        \\  // Brand checks: a member on the wrong receiver is a TypeError, never a crash.
        \\  out.brand = [() => api.net.PullTcpStream.prototype.close.call(listener), () => Object.getOwnPropertyDescriptor(api.net.SendQueue.prototype, 'bytes').get.call({}), () => io.tcp.listen.call(io.udp, at(0))]
        \\    .every(f => { try { f(); return false; } catch (e) { return e instanceof TypeError; } });
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.same && report.results === 'Canceled,Canceled' && report.run === 'Canceled' && report.stale && report.brand");
}
