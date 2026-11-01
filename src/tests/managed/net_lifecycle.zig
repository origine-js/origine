const check = @import("support.zig").check;
const Parent = @import("channel.zig").Parent;

// `settles` answers 'hang' instead of leaving the test waiting forever on the bug it looks for.
const prelude =
    \\const settles = (timers, promise) => Promise.race([promise.then(() => 'resolved', e => e.name), timers.sleep(1000).then(() => 'hang')]);
    \\const fill = async (api, io, mode) => {
    \\  const server = api.net.listen(io, { mode: 'pull', socketMode: 'pull', port: 0 });
    \\  const client = await api.net.connect(io, { mode, port: server.port });
    \\  const peer = await server.accept();
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
        \\  await timers.sleep(50);
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
        \\  const server = api.net.listen(io, { mode: 'pull', socketMode: 'pull', port: 0 });
        \\  const open = async () => {
        \\    const client = await api.net.connect(io, { mode: 'event', port: server.port });
        \\    return [client, await server.accept()];
        \\  };
        \\  const [a, peerA] = await open();
        \\  let ends = 0;
        \\  a.register('end', () => { ends++; });
        \\  a.register('data', () => {}).unregister();
        \\  await peerA.end('write');
        \\  await io.sleep(50);
        \\  out.endFired = ends === 1;
        \\  const [b, peerB] = await open();
        \\  let endsB = 0;
        \\  const bytes = [];
        \\  b.register('end', () => { endsB++; });
        \\  b.register('data', () => {}).unregister();
        \\  await peerB.queued.send(Uint8Array.of(7));
        \\  await peerB.end('write');
        \\  await io.sleep(50);
        \\  out.endWaits = endsB === 0;
        \\  b.register('data', ev => { using chunk = ev.buffer(); bytes.push(...chunk); });
        \\  await io.sleep(50);
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
        \\  const server = api.net.listen(io, { mode: 'event', socketMode: 'event', port: 0 });
        \\  server.register('connection', socket => socket.close());
        \\  const runs = [io.run(), io.run(), io.run()];
        \\  await timers.sleep(20);
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
        \\  const server = api.net.listen(io, { mode: 'pull', socketMode: 'pull', port: 0 });
        \\  const { port } = server;
        \\  const pending = server.accept();
        \\  const second = server.accept();
        \\  const loop = (async () => { for await (const socket of server) await socket.close(); })();
        \\  await timers.sleep(20);
        \\  await server.close();
        \\  // The promise of close() says the port is free: nothing may be needed in between.
        \\  const again = api.net.listen(io, { mode: 'pull', socketMode: 'pull', port });
        \\  out.results = (await Promise.all([pending, second, loop].map(x => settles(timers, x)))).join();
        \\  const client = await api.net.connect(io, { mode: 'pull', port });
        \\  const conn = await again.accept();
        \\  out.rebound = conn.remotePort > 0;
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
        \\  const server = api.net.listen(io, { mode: 'event', socketMode: 'pull', port: 0 });
        \\  const kept = [];
        \\  server.pause();
        \\  server.register('connection', socket => { kept.push(socket); server.close(); });
        \\  const clients = [];
        \\  for (let i = 0; i < 3; i++) clients.push(await api.net.connect(io, { mode: 'pull', port: server.port }));
        \\  await timers.sleep(50);
        \\  server.resume();
        \\  await timers.sleep(50);
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
