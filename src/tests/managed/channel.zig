const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const m = @import("@managed");
const support = @import("../support.zig");
const ensureV8 = support.ensureV8;
const check = @import("support.zig").check;

const Isolate = m.Api.ThreadIsolate;

/// An init module in a tmp dir run in this thread's isolate with the dir as fs root.
pub const Parent = struct {
    tmp: t.TmpDir,
    rt: *m.Runtime,
    host: *m.Api.Host,
    scope: *m.Scope,
    init_path: []u8,
    /// The host's arguments borrow this until `deinit`.
    argv: [1][]const u8,

    pub fn setup(self: *Parent, name: []const u8, source: []const u8) !void {
        return self.setupWith(name, source, null);
    }

    /// `isolates` enables `api.isolate`; the host's argument is the init path (the way the process entry point passes it).
    pub fn setupWith(self: *Parent, name: []const u8, source: []const u8, isolates: ?m.Api.IsolateConfig) !void {
        ensureV8();
        self.tmp = t.tmpDir(.{ .iterate = true });
        errdefer self.tmp.cleanup();
        try self.tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = source });
        self.init_path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/{s}", .{ self.tmp.sub_path, name });
        errdefer t.allocator.free(self.init_path);
        self.argv = .{self.init_path};
        self.rt = try m.Runtime.create(t.allocator, .{});
        errdefer self.rt.destroy();
        self.host = try m.Api.Host.create(t.allocator, .{
            .args = &self.argv,
            .fs = .{ .root = .{ .handle = self.tmp.dir.handle } },
            .runtime = .{},
            .isolates = isolates,
        });
        errdefer self.host.destroy();
        self.scope = try self.rt.createScope(self.host.initOptions());
    }

    pub fn run(self: *Parent) !void {
        var error_info: m.ErrorInfo = .{};
        defer error_info.deinit();
        self.host.run(self.scope, support.engine.platform, self.init_path, &error_info) catch |err| {
            if (error_info.exception) |exception| self.describe(exception);
            return err;
        };
    }

    /// Prints the rejection value of a failed run to stderr for diagnosis.
    fn describe(self: *Parent, exception: v8.Global.Of(v8.Value)) void {
        var session: m.Scope.Session = undefined;
        session.init(self.scope);
        defer session.deinit();
        var shown = exception.deref();
        if (shown.toObject(session.ctx)) |object| {
            if (object.get(session.ctx, v8.String.initUtf8(session.isolate(), "stack").name.primitive.value)) |stack| {
                if (stack.isString()) shown = stack;
            }
        }
        const text = shown.toDetailString(session.ctx) orelse return;
        var buffer: [2048]u8 = undefined;
        const length = text.writeUtf8(session.isolate(), &buffer);
        std.debug.print("init failed: {s}\n", .{buffer[0..length]});
    }

    pub fn deinit(self: *Parent) void {
        self.host.destroy();
        self.rt.destroy();
        t.allocator.free(self.init_path);
        self.tmp.cleanup();
    }
};

test "channel: pull ports carry values, order, backpressure, buffers and ports" {
    var p: Parent = undefined;
    try p.setup("init.js",
        \\export async function main(api) {
        \\  const { Channel } = api.host.threading;
        \\  const out = globalThis.report = {};
        \\  const [a, b] = new Channel({ mode: 'pull', capacity: 1 });
        \\  // Structured clone: richer than JSON, and a copy.
        \\  const original = { map: new Map([[1, 'a']]), bytes: new Uint8Array([1, 2, 3]), big: 5n };
        \\  await a.send(original);
        \\  const event = await b.recv();
        \\  const copy = event.data;
        \\  out.clone = copy !== original && copy.map.get(1) === 'a' && copy.bytes.join() === '1,2,3' && copy.big === 5n;
        \\  out.shape = event.identity === 0 && event.transfer.length === 0 && Object.isFrozen(event);
        \\  // Capacity 1: the second send waits until the first message is received.
        \\  await a.send('first');
        \\  let second = false;
        \\  const pending = a.send('second').then(() => { second = true; });
        \\  await Promise.resolve(); await Promise.resolve();
        \\  out.blocked = second === false;
        \\  out.first = (await b.recv()).data;
        \\  await pending;
        \\  out.second = (await b.recv()).data;
        \\  // A function cannot be cloned; nothing is queued.
        \\  try { a.send(() => 1); out.fn = 'sent'; } catch (e) { out.fn = e.name; }
        \\  // Transfer moves the buffer, and lists it among the received transfer.
        \\  const buffer = new ArrayBuffer(4);
        \\  await a.send(buffer, { transfer: [buffer] });
        \\  const moved = await b.recv();
        \\  out.moved = buffer.byteLength === 0 && moved.data.byteLength === 4 && moved.transfer[0] === moved.data;
        \\  // A shared buffer is shared, not copied.
        \\  const sab = new SharedArrayBuffer(4);
        \\  await a.send(sab);
        \\  Atomics.store(new Int32Array(sab), 0, 7);
        \\  out.shared = Atomics.load(new Int32Array((await b.recv()).data), 0);
        \\  // A port moves with a message when it is listed; the original stops working.
        \\  const [c, d] = new Channel({ mode: 'pull' });
        \\  try { a.send({ d }); out.unlisted = 'sent'; } catch (e) { out.unlisted = e.name; }
        \\  await a.send({ d }, { transfer: [d] });
        \\  const carried = await b.recv();
        \\  out.port = carried.transfer[0] === carried.data.d && carried.data.d.mode === 'pull';
        \\  try { await d.send(1); out.old = 'sent'; } catch (e) { out.old = e.name; }
        \\  await c.send('through');
        \\  out.through = (await carried.data.d.recv()).data;
        \\  // Closing a port ends the peer's iteration after what was sent.
        \\  await a.send('last');
        \\  a.close();
        \\  const rest = [];
        \\  for await (const e of b) rest.push(e.data);
        \\  out.rest = rest.join();
        \\  try { await b.recv(); } catch (e) { out.eof = e.name; }
        \\  try { await b.send(1); } catch (e) { out.broken = e.name; }
        \\  try { a.close(); } catch (e) { out.stale = e.name; }
        \\  try { new Channel({}); } catch (e) { out.mode = e.name; }
        \\  try { Channel({ mode: 'pull' }); } catch (e) { out.call = e.name; }
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.clone && report.shape && report.blocked && report.first === 'first' && report.second === 'second'");
    try check(p.scope, "report.fn === 'TypeError' && report.moved && report.shared === 7");
    try check(p.scope, "report.unlisted === 'TypeError' && report.port && report.old === 'BadHandle' && report.through === 'through'");
    try check(p.scope, "report.rest === 'last' && report.eof === 'NotConnected' && report.broken === 'BrokenPipe' && report.stale === 'BadHandle'");
    try check(p.scope, "report.mode === 'TypeError' && report.call === 'TypeError'");
}

test "channel: event ports deliver messages, pause and convert" {
    var p: Parent = undefined;
    try p.setup("init.js",
        \\export async function main(api) {
        \\  const { Channel } = api.host.threading;
        \\  const out = globalThis.report = {};
        \\  const [e, f] = new Channel({ mode: 'event' });
        \\  out.pullMethods = f.recv === undefined && typeof f.register === 'function';
        \\  const got = [];
        \\  const closed = new Promise(resolve => f.register('close', resolve));
        \\  const registration = f.register('message', event => got.push(event.data + '@' + event.identity));
        \\  await e.send(1);
        \\  await e.send(2);
        \\  f.pause();
        \\  out.paused = f.paused;
        \\  await e.send(3);
        \\  for (let n = 0; n < 5; n++) await Promise.resolve();
        \\  f.resume();
        \\  e.close();
        \\  await closed;
        \\  out.got = got.join();
        \\  out.unregistered = registration.unregister() === true && registration.unregister() === false;
        \\  // A throwing handler goes to the error handlers.
        \\  const [g, h] = new Channel({ mode: 'event' });
        \\  const errors = [];
        \\  h.register('error', error => errors.push(error.message));
        \\  h.register('message', () => { throw new Error('handler'); });
        \\  await g.send(0);
        \\  await new Promise(resolve => h.register('error', resolve));
        \\  out.errors = errors.join();
        \\  // Converting between modes consumes the old port.
        \\  const [i, j] = new Channel({ mode: 'pull' });
        \\  const event = j.toEvent();
        \\  try { await j.recv(); out.consumed = 'ok'; } catch (x) { out.consumed = x.name; }
        \\  out.mode = event.mode + '/' + event.toPull().mode;
        \\  const [k, l] = new Channel({ mode: 'event' });
        \\  l.register('message', () => {});
        \\  try { l.toPull(); out.started = 'ok'; } catch (x) { out.started = x.name; }
        \\  i.close(); k.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.pullMethods && report.got === '1@0,2@0,3@0' && report.unregistered");
    try check(p.scope, "report.errors === 'handler' && report.consumed === 'BadHandle' && report.mode === 'event/pull' && report.started === 'Unsupported' && report.paused === true");
}
