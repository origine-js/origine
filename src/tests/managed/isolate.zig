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
;

test "isolate: create, talk through the default channels, share memory and join" {
    var c: Case = undefined;
    try c.setup(prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  out.first = api.isolate.parent;
        \\  const sab = new SharedArrayBuffer(8);
        \\  const iso = api.isolate.create({ init: childPath(api), capacity: 2, args: ['x', 'y'], env: { A: 'b' }, data: { sab, tag: 'hello' } });
        \\  await iso.tx.send({ n: 21 });
        \\  const reply = await iso.rx.recv();
        \\  out.reply = reply.n;
        \\  out.args = reply.args; out.env = reply.env; out.tag = reply.tag;
        \\  out.shared = Atomics.load(new Int32Array(sab), 0);
        \\  iso.tx.close();
        \\  const rest = [];
        \\  for await (const m of iso.rx) rest.push(m);
        \\  out.rest = rest.length;
        \\  out.joined = await iso.join();
        \\  out.again = (await iso.join()) === out.joined;
        \\}
    ,
        \\export async function main(api) {
        \\  const parent = api.isolate.parent;
        \\  Atomics.store(new Int32Array(parent.data.sab), 0, 9);
        \\  for await (const message of parent.rx) {
        \\    await parent.tx.send({ n: message.n * 2, args: api.host.env.args().slice(1), env: api.host.env.get('A'), tag: parent.data.tag });
        \\  }
        \\}
    );
    defer c.deinit();
    try c.parent.run();
    try check(c.parent.scope, "report.first === null && report.reply === 42 && report.args.join() === 'x,y' && report.env === 'b' && report.tag === 'hello'");
    try check(c.parent.scope, "report.shared === 9 && report.rest === 0 && report.joined.status === 'completed' && report.joined.error === undefined && report.again");
}

test "isolate: a child that fails is reported and releases its channels" {
    var c: Case = undefined;
    try c.setup(prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const iso = api.isolate.create({ init: childPath(api), capacity: 1 });
        \\  try { await iso.rx.recv(); out.ended = false; } catch (e) { out.ended = e.name; }
        \\  try { for (;;) await iso.tx.send(1); } catch (e) { out.broken = e.name; }
        \\  out.joined = await iso.join();
        \\}
    ,
        \\export function main(api) {
        \\  api.isolate.parent;
        \\  throw new Error('child dies');
        \\}
    );
    defer c.deinit();
    try c.parent.run();
    try check(c.parent.scope, "report.ended === 'NotConnected' && report.broken === 'BrokenPipe'");
    try check(c.parent.scope, "report.joined.status === 'failed' && report.joined.error === 'MainFailed'");
}

test "isolate: terminate stops a busy child; bad options are TypeErrors" {
    var c: Case = undefined;
    try c.setup(prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const iso = api.isolate.create({ init: childPath(api), capacity: 1 });
        \\  iso.terminate();
        \\  out.joined = (await iso.join()).status;
        \\  for (const bad of [{}, { init: 'x' }, { init: 'x', capacity: 0 }, { init: 'x', capacity: 1, args: [1] }, { init: 'x', capacity: 1, env: { A: 1 } }]) {
        \\    try { api.isolate.create(bad); out.bad = 'created'; } catch (e) { out.bad = e.name; if (e.name !== 'TypeError') break; }
        \\  }
        \\  const config = api.isolate.CreateConfig({ init: childPath(api), capacity: 1 });
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
        \\  try { api.isolate.create({ init: 'x', capacity: 1 }); globalThis.report = { code: 'created' }; } catch (e) { globalThis.report = { code: e.name }; }
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.code === 'PermissionDenied'");
}
