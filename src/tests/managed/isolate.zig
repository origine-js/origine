const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const m = @import("@managed");
const support = @import("../support.zig");
const check = @import("support.zig").check;
const Parent = @import("channel.zig").Parent;

/// A parent whose host may create isolates; `child` is written next to it as `child.js`.
const Case = struct {
    parent: Parent,
    buffers: v8.ArrayBuffer.Allocator,

    fn setup(self: *Case, parent_source: []const u8, child_source: []const u8) !void {
        support.ensureV8();
        // As the process entry point: a sandboxed V8 only accepts ArrayBuffer memory from its own pages.
        self.buffers = if (v8.V8.isSandboxEnabled())
            try v8.ArrayBuffer.Allocator.fromSandbox()
        else
            try v8.ArrayBuffer.Allocator.fromZig(t.allocator);
        errdefer self.buffers.deinit();
        try self.parent.setupWith("parent.js", parent_source, .{ .platform = support.engine.platform, .array_buffer_allocator = self.buffers });
        errdefer self.parent.deinit();
        try self.parent.tmp.dir.writeFile(t.io, .{ .sub_path = "child.js", .data = child_source });
    }

    /// The host (and with it every child) goes before the buffers they use.
    fn deinit(self: *Case) void {
        self.parent.deinit();
        self.buffers.deinit();
    }
};

const prelude =
    \\const childPath = api => api.host.env.args()[0].replace('parent.js', 'child.js');
    \\
;

test "isolate: create, talk over a transferred port, share memory and join" {
    var c: Case = undefined;
    try c.setup(prelude ++
        \\export async function main(api, first) {
        \\  const out = globalThis.report = {};
        \\  out.first = first;
        \\  const { Channel } = api.host.threading;
        \\  const [mine, theirs] = new Channel({ mode: 'pull' });
        \\  const sab = new SharedArrayBuffer(8);
        \\  const iso = api.isolate.create({ init: childPath(api), args: ['x', 'y'], env: { A: 'b' }, data: { port: theirs, sab, tag: 'hello' }, transfer: [theirs] });
        \\  await mine.send({ n: 21 });
        \\  const reply = await mine.recv();
        \\  out.reply = reply.data.n;
        \\  out.from = reply.identity === iso.id && iso.id > 0;
        \\  out.args = reply.data.args; out.env = reply.data.env; out.tag = reply.data.tag;
        \\  out.shared = Atomics.load(new Int32Array(sab), 0);
        \\  mine.close();
        \\  out.joined = await iso.join();
        \\  out.again = (await iso.join()) === out.joined;
        \\}
    ,
        \\export async function main(api, { port, sab, tag }) {
        \\  Atomics.store(new Int32Array(sab), 0, 9);
        \\  for await (const event of port) {
        \\    await port.send({ n: event.data.n * 2, args: api.host.env.args().slice(1), env: api.host.env.get('A'), tag });
        \\  }
        \\}
    );
    defer c.deinit();
    try c.parent.run();
    try check(c.parent.scope, "report.first === undefined && report.reply === 42 && report.from && report.args.join() === 'x,y' && report.env === 'b' && report.tag === 'hello'");
    try check(c.parent.scope, "report.shared === 9 && report.joined.status === 'completed' && report.joined.error === undefined && report.again");
}

test "isolate: an event port in the child, and a child that dies releases its port" {
    var c: Case = undefined;
    try c.setup(prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const { Channel } = api.host.threading;
        \\  const [mine, theirs] = new Channel({ mode: 'event' });
        \\  const [other, otherTheirs] = new Channel({ mode: 'pull' });
        \\  const iso = api.isolate.create({ init: childPath(api), data: { theirs, otherTheirs }, transfer: [theirs, otherTheirs] });
        \\  const replies = [];
        \\  const closed = new Promise(resolve => mine.register('close', resolve));
        \\  mine.register('message', event => replies.push(event.data));
        \\  await mine.send('a');
        \\  await mine.send('b');
        \\  // The child dies after answering: both its ports close, so the peers are not left waiting.
        \\  await closed;
        \\  out.replies = replies.join();
        \\  try { await other.recv(); out.ended = false; } catch (e) { out.ended = e.name; }
        \\  try { for (;;) await other.send(1); } catch (e) { out.broken = e.name; }
        \\  out.joined = await iso.join();
        \\}
    ,
        \\export function main(api, { theirs, otherTheirs }) {
        \\  let seen = 0;
        \\  theirs.register('message', event => {
        \\    theirs.send(event.data + '!');
        \\    if (++seen === 2) throw new Error('child dies');
        \\  });
        \\  theirs.register('error', () => { throw new Error('child dies'); });
        \\}
    );
    defer c.deinit();
    try c.parent.run();
    try check(c.parent.scope, "report.replies === 'a!,b!' && report.ended === 'NotConnected' && report.broken === 'BrokenPipe'");
}

test "isolate: a child that never starts releases the ports it was sent" {
    var c: Case = undefined;
    try c.setup(prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const { Channel } = api.host.threading;
        \\  const [mine, theirs] = new Channel({ mode: 'pull' });
        \\  const iso = api.isolate.create({ init: childPath(api) + '.missing', data: { theirs }, transfer: [theirs] });
        \\  try { await mine.recv(); out.ended = false; } catch (e) { out.ended = e.name; }
        \\  out.joined = await iso.join();
        \\}
    , "export function main() {}");
    defer c.deinit();
    try c.parent.run();
    try check(c.parent.scope, "report.ended === 'NotConnected' && report.joined.status === 'failed'");
}

test "isolate: terminate stops a busy child; bad options are TypeErrors" {
    var c: Case = undefined;
    try c.setup(prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const iso = api.isolate.create({ init: childPath(api) });
        \\  iso.terminate();
        \\  out.joined = (await iso.join()).status;
        \\  for (const bad of [{}, { init: 1 }, { init: 'x', args: [1] }, { init: 'x', env: { A: 1 } }, { init: 'x', transfer: 1 }]) {
        \\    try { api.isolate.create(bad); out.bad = 'created'; } catch (e) { out.bad = e.name; if (e.name !== 'TypeError') break; }
        \\  }
        \\  const config = api.isolate.CreateConfig({ init: childPath(api) });
        \\  out.config = Object.isFrozen(config) && api.isolate.CreateConfig(config) === config;
        \\}
    , "export function main() { for (;;) {} }");
    defer c.deinit();
    try c.parent.run();
    try check(c.parent.scope, "report.joined === 'terminated' && report.bad === 'TypeError' && report.config");
}

test "isolate: a host without isolates has no api.isolate" {
    var p: Parent = undefined;
    try p.setup("parent.js",
        \\export function main(api) {
        \\  try { api.isolate.create({ init: 'x' }); globalThis.report = { code: 'created' }; } catch (e) { globalThis.report = { code: e.name }; }
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.code === 'PermissionDenied'");
}
