const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const m = @import("@managed");
const support = @import("../support.zig");
const ensureV8 = support.ensureV8;
const check = @import("support.zig").check;

const Isolate = m.Api.ThreadIsolate;

/// An init module in a tmp dir run in this thread's isolate with the dir as fs root.
const Parent = struct {
    tmp: t.TmpDir,
    rt: *m.Runtime,
    host: *m.Api.Host,
    scope: *m.Scope,
    init_path: []u8,

    fn setup(self: *Parent, name: []const u8, source: []const u8) !void {
        ensureV8();
        self.tmp = t.tmpDir(.{ .iterate = true });
        errdefer self.tmp.cleanup();
        try self.tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = source });
        self.init_path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/{s}", .{ self.tmp.sub_path, name });
        errdefer t.allocator.free(self.init_path);
        self.rt = try m.Runtime.create(t.allocator, .{});
        errdefer self.rt.destroy();
        self.host = try m.Api.Host.create(t.allocator, .{ .fs = .{ .root = .{ .handle = self.tmp.dir.handle } }, .runtime = .{} });
        errdefer self.host.destroy();
        self.scope = try self.rt.createScope(self.host.initOptions());
    }

    fn run(self: *Parent) !void {
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

    fn deinit(self: *Parent) void {
        self.host.destroy();
        self.rt.destroy();
        t.allocator.free(self.init_path);
        self.tmp.cleanup();
    }
};

test "channel: values, order, backpressure and close within one isolate" {
    var p: Parent = undefined;
    try p.setup("init.js",
        \\export async function main(api) {
        \\  const { channel, sender, receiver } = api.host.threading;
        \\  const out = globalThis.report = {};
        \\  const { tx, rx } = channel({ capacity: 1 });
        \\  // Structured clone: richer than JSON, and a copy.
        \\  const original = { map: new Map([[1, 'a']]), bytes: new Uint8Array([1, 2, 3]), big: 5n };
        \\  await tx.send(original);
        \\  const copy = await rx.recv();
        \\  out.clone = copy !== original && copy.map.get(1) === 'a' && copy.bytes.join() === '1,2,3' && copy.big === 5n;
        \\  // Capacity 1: the second send waits until the first message is received.
        \\  await tx.send('first');
        \\  let second = false;
        \\  const pending = tx.send('second').then(() => { second = true; });
        \\  await Promise.resolve(); await Promise.resolve();
        \\  out.blocked = second === false;
        \\  out.first = await rx.recv();
        \\  await pending;
        \\  out.second = await rx.recv();
        \\  // A function cannot be cloned; nothing is queued.
        \\  try { tx.send(() => 1); out.fn = 'sent'; } catch (e) { out.fn = e.name; }
        \\  // Transfer moves the buffer.
        \\  const buffer = new ArrayBuffer(4);
        \\  await tx.send(buffer, { transfer: [buffer] });
        \\  const moved = await rx.recv();
        \\  out.moved = buffer.byteLength === 0 && moved.byteLength === 4;
        \\  // A shared buffer is shared, not copied.
        \\  const sab = new SharedArrayBuffer(4);
        \\  await tx.send(sab);
        \\  Atomics.store(new Int32Array(sab), 0, 7);
        \\  out.shared = Atomics.load(new Int32Array(await rx.recv()), 0);
        \\  // Closing the last sender drains, then ends the iteration; a second sender keeps it open.
        \\  const other = tx.clone();
        \\  await tx.send('x');
        \\  tx.close();
        \\  out.open = await rx.recv();
        \\  await other.send('y');
        \\  other.close();
        \\  const rest = [];
        \\  for await (const value of rx) rest.push(value);
        \\  out.rest = rest.join();
        \\  try { await rx.recv(); } catch (e) { out.eof = e.name; }
        \\  // Closing the receiver breaks sends.
        \\  const again = channel({ capacity: 2 });
        \\  again.rx.close();
        \\  try { await again.tx.send(1); } catch (e) { out.broken = e.name; }
        \\  try { channel({ capacity: 0 }); } catch (e) { out.cap = e.name; }
        \\  try { tx.close(); } catch (e) { out.stale = e.name; }
        \\  out.reattached = typeof sender(again.tx.handle).send === 'function' && typeof receiver(again.rx.handle).recv === 'function';
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.clone && report.blocked && report.first === 'first' && report.second === 'second'");
    try check(p.scope, "report.fn === 'TypeError' && report.moved && report.shared === 7");
    try check(p.scope, "report.open === 'x' && report.rest === 'y' && report.eof === 'NotConnected'");
    try check(p.scope, "report.broken === 'BrokenPipe' && report.cap === 'TypeError' && report.stale === 'BadHandle' && report.reattached");
}

/// Waits for the parent to publish the channel handles in `handles.txt`, then starts the child.
const Launch = struct {
    parent: *Parent,
    buffers: v8.ArrayBuffer.Allocator,
    child_path: []const u8,
    child: ?*Isolate = null,
    failed: bool = false,

    fn run(self: *Launch) void {
        var tries: usize = 0;
        while (tries < 2000) : (tries += 1) {
            var delay: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&delay, null);
            const text = self.parent.tmp.dir.readFileAlloc(t.io, "handles.txt", t.allocator, .limited(64)) catch continue;
            defer t.allocator.free(text);
            var parts = std.mem.splitScalar(u8, text, ' ');
            const first = parts.next() orelse continue;
            const second = parts.next() orelse continue;
            if (second.len == 0) continue;
            self.child = Isolate.spawn(t.allocator, .{
                .init = self.child_path,
                .args = &.{ self.child_path, first, second },
                .fs = .{ .root = .{ .handle = self.parent.tmp.dir.handle } },
                .array_buffer_allocator = self.buffers,
                .platform = support.engine.platform,
            }) catch {
                self.failed = true;
                return;
            };
            return;
        }
        self.failed = true;
    }
};

test "channel: two isolates on two threads exchange messages and share memory" {
    var p: Parent = undefined;
    try p.setup("parent.js",
        \\import { Dir, IoError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const { channel } = api.host.threading;
        \\  const out = globalThis.report = {};
        \\  const toChild = channel({ capacity: 1 }), fromChild = channel({ capacity: 4 });
        \\  const sync = api.fs.requestSync({ access: 'rw' });
        \\  const f = IoError.check(sync, sync.dirOpenFile(Dir.cwd(), 'handles.txt', 'w'));
        \\  sync.fileWriteAll(f, Uint8Array.from(toChild.rx.handle + ' ' + fromChild.tx.handle, c => c.charCodeAt(0)));
        \\  sync.fileClose(f);
        \\  const sab = new SharedArrayBuffer(8);
        \\  for (let n = 1; n <= 3; n++) await toChild.tx.send({ n, sab });
        \\  toChild.tx.close();
        \\  const got = [];
        \\  for await (const reply of fromChild.rx) got.push(reply.doubled);
        \\  out.got = got.join(',');
        \\  out.shared = Atomics.load(new Int32Array(sab), 0);
        \\}
    );
    defer p.deinit();
    try p.tmp.dir.writeFile(t.io, .{ .sub_path = "child.js", .data =
        \\export async function main(api) {
        \\  const { receiver, sender } = api.host.threading;
        \\  const args = api.host.env.args();
        \\  const rx = receiver(Number(args[1])), tx = sender(Number(args[2]));
        \\  for await (const message of rx) {
        \\    Atomics.store(new Int32Array(message.sab), 0, 42);
        \\    await tx.send({ doubled: message.n * 2 });
        \\  }
        \\  tx.close();
        \\}
    });
    const child_path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/child.js", .{p.tmp.sub_path});
    defer t.allocator.free(child_path);
    const buffers = if (v8.V8.isSandboxEnabled())
        try v8.ArrayBuffer.Allocator.fromSandbox()
    else
        try v8.ArrayBuffer.Allocator.fromZig(t.allocator);
    defer buffers.deinit();
    var launch: Launch = .{ .parent = &p, .buffers = buffers, .child_path = child_path };
    const launcher = try std.Thread.spawn(.{}, Launch.run, .{&launch});
    // Join the helper and the child before anything they use is freed, even when the run fails.
    const ran = p.run();
    launcher.join();
    const outcome: ?m.Api.ThreadIsolateOutcome = if (launch.child) |child| child.join() else null;
    defer if (launch.child) |child| child.destroy();
    try ran;
    try t.expect(!launch.failed);
    try t.expectEqual(m.Api.ThreadIsolateOutcome.completed, outcome.?);
    try check(p.scope, "report.got === '2,4,6' && report.shared === 42");
}
