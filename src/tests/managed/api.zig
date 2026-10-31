const std = @import("std");
const t = std.testing;
const v8 = @import("@v8");
const m = @import("@managed");
const support = @import("../support.zig");
const ensureV8 = support.ensureV8;
const check = @import("support.zig").check;

/// Runs `source` as an init module in a fresh runtime with a tmp-dir fs grant (or
/// none) and returns control to `after` with the init scope and the child scopes.
const Fixture = struct {
    rt: *m.Runtime,
    host: *m.Api.Host,
    tmp: std.testing.TmpDir,
    scope: *m.Scope,
    init_path: []u8,

    fn setup(self: *Fixture, source: []const u8, grant_fs: bool, args: []const []const u8) !void {
        return self.setupWith(source, grant_fs, args, &m.Api.std_modules);
    }

    fn setupWith(self: *Fixture, source: []const u8, grant_fs: bool, args: []const []const u8, modules: []const m.Api.module.Module) !void {
        return self.setupFull("init.js", source, grant_fs, args, modules, m.Api.transformers.defaults, .{});
    }

    /// Like `setup` with an explicit runtime ceiling (`null`: no `api.io`).
    fn setupRuntime(self: *Fixture, source: []const u8, grant_fs: bool, runtime: ?m.Api.RuntimeConfig) !void {
        return self.setupFull("init.js", source, grant_fs, &.{}, &m.Api.std_modules, m.Api.transformers.defaults, runtime);
    }

    /// Writes `source` as `name` in the tmp dir (the init module) and runs with the given
    /// embedded modules and transformer map.
    fn setupFull(self: *Fixture, name: []const u8, source: []const u8, grant_fs: bool, args: []const []const u8, modules: []const m.Api.module.Module, transformers: []const m.Api.transformer.Entry, runtime: ?m.Api.RuntimeConfig) !void {
        return self.setupFullFs(name, source, grant_fs, true, args, modules, transformers, runtime);
    }

    /// `setup` with a read-only host ceiling (`FsConfig.write = false`): write requests are denied.
    fn setupReadOnlyCeiling(self: *Fixture, source: []const u8) !void {
        return self.setupFullFs("init.js", source, true, false, &.{}, &m.Api.std_modules, m.Api.transformers.defaults, .{});
    }

    fn setupFullFs(self: *Fixture, name: []const u8, source: []const u8, grant_fs: bool, fs_write: bool, args: []const []const u8, modules: []const m.Api.module.Module, transformers: []const m.Api.transformer.Entry, runtime: ?m.Api.RuntimeConfig) !void {
        ensureV8();
        self.tmp = t.tmpDir(.{ .iterate = true });
        errdefer self.tmp.cleanup();
        try self.tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = source });
        self.init_path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/{s}", .{ self.tmp.sub_path, name });
        errdefer t.allocator.free(self.init_path);
        self.rt = try m.Runtime.create(t.allocator, .{});
        errdefer self.rt.destroy();
        self.host = try m.Api.Host.create(t.allocator, .{
            .args = args,
            .env = &.{ .{ .name = "HOME", .value = "/home/test" }, .{ .name = "PATH", .value = "/bin" } },
            .fs = if (grant_fs) .{ .root = .{ .handle = self.tmp.dir.handle }, .write = fs_write } else null,
            .modules = modules,
            .transformers = transformers,
            .runtime = runtime,
        });
        errdefer self.host.destroy();
        self.scope = try self.rt.createScope(self.host.initOptions());
    }

    fn run(self: *Fixture) !void {
        var error_info: m.ErrorInfo = .{};
        defer error_info.deinit();
        self.host.run(self.scope, support.engine.platform, self.init_path, &error_info) catch |err| {
            if (error_info.exception) |exception| self.describe(exception);
            return err;
        };
    }

    /// Prints the rejection value of a failed run to stderr for diagnosis.
    fn describe(self: *Fixture, exception: v8.Global.Of(v8.Value)) void {
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

    fn deinit(self: *Fixture) void {
        self.host.destroy();
        self.rt.destroy();
        t.allocator.free(self.init_path);
        self.tmp.cleanup();
    }
};

/// Wraps the real disk cache to observe which scripts are requested and reused.
/// Owns recorded IDs until deinit; borrows inner's state while the scope is live.
const GlueCacheProbe = struct {
    inner: m.CodeCache,
    loads: std.StringHashMapUnmanaged(usize) = .empty,
    hits: usize = 0,
    stores: usize = 0,
    corrupt: bool = false,
    rejects: usize = 0,

    /// Borrows the request through the delegated load; returned bytes use its allocator.
    fn load(data: ?*anyopaque, request: m.CodeCacheRequest) ?[]const u8 {
        const self: *GlueCacheProbe = @ptrCast(@alignCast(data.?));
        const entry = self.loads.getOrPut(t.allocator, request.module_id) catch unreachable;
        if (!entry.found_existing) {
            entry.key_ptr.* = t.allocator.dupe(u8, request.module_id) catch unreachable;
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
        const bytes = self.inner.load(self.inner.data, request) orelse return null;
        self.hits += 1;
        if (self.corrupt) {
            const changed = request.allocator.alignedAlloc(u8, .@"8", bytes.len) catch unreachable;
            @memcpy(changed, bytes);
            changed[0] ^= 0xff;
            return changed;
        }
        return bytes;
    }

    /// Borrows bytes/request through the real disk store; retains no V8 storage.
    fn store(data: ?*anyopaque, request: m.CodeCacheRequest, bytes: []const u8) void {
        const self: *GlueCacheProbe = @ptrCast(@alignCast(data.?));
        self.stores += 1;
        self.inner.store(self.inner.data, request, bytes);
    }

    fn rejected(data: ?*anyopaque, request: m.CodeCacheRequest) void {
        const self: *GlueCacheProbe = @ptrCast(@alignCast(data.?));
        self.rejects += 1;
        if (self.inner.rejected) |discard| discard(self.inner.data, request);
    }

    /// Releases all probe-owned IDs; inner cache ownership stays with the fixture.
    fn deinit(self: *GlueCacheProbe) void {
        var keys = self.loads.keyIterator();
        while (keys.next()) |key| t.allocator.free(key.*);
        self.loads.deinit(t.allocator);
    }
};

/// Installs a test global without applying the general guest-export hardener, so
/// assertions inspect exactly the immutable surface returned by Host.install.
/// Borrows both handles; the context retains the value until runtime teardown.
fn exposeApi(scope: *m.Scope, api: v8.Global.Of(v8.Value)) !void {
    var session: m.Scope.Session = undefined;
    session.init(scope);
    defer session.deinit();
    try t.expect(session.ctx.getGlobal().set(session.ctx, v8.String.initUtf8(session.isolate(), "api").name.primitive.value, api.deref()) orelse false);
}

test "api: ES module glue imports once and retains separate module code caches" {
    const glue_modules: usize = m.Api.glue.module_count;
    ensureV8();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // The second runtime must consume the first runtime's actual V8 code caches.
    for (0..4) |run| {
        const rt = try m.Runtime.create(t.allocator, .{});
        defer rt.destroy();
        const host = try m.Api.Host.create(t.allocator, .{ .runtime = .{}, .fs = .{ .root = .{ .handle = tmp.dir.handle }, .async = false } });
        defer host.destroy();
        var cache = m.Api.init_cache.CodeCacheState.init(host, .{ .handle = tmp.dir.handle });
        var probe: GlueCacheProbe = .{ .inner = cache.hook(), .corrupt = run == 2 };
        defer probe.deinit();
        var options = host.initOptions();
        options.code_cache = .{ .data = &probe, .load = GlueCacheProbe.load, .store = GlueCacheProbe.store, .rejected = GlueCacheProbe.rejected };
        const scope = try rt.createScope(options);
        const api = try host.install(scope, null);
        defer api.deinit();
        try exposeApi(scope, api);
        try check(scope,
            \\Object.isFrozen(api) && Object.keys(api).join(',') === 'fs,host,graph,context,isolate,io,net' &&
            \\Object.values(Object.getOwnPropertyDescriptors(api)).every(d =>
            \\  typeof d.get === 'function' && Object.isFrozen(d.get) && d.set === undefined && !d.configurable)
        );
        try t.expectEqual(glue_modules, probe.loads.count());
        try t.expect(probe.loads.contains("origine:glue.esm.index"));
        try t.expect(host.rust_isolate == null);
        try check(scope, "api.host.env === api.host.env && Object.isFrozen(api.host.env.args) && api.host.env.args().length === 0");
        try t.expect(probe.loads.contains("origine:glue.esm.fs"));
        try check(scope, "api.fs === api.fs && Object.isFrozen(api.fs.requestSync) && Object.isFrozen(api.fs)");
        try check(scope,
            \\(() => {
            \\  const sync = api.fs.requestSync({ handle: 'plain', access: 'r' });
            \\  sync.fileStat({});
            \\  const code = sync.errno[0];
            \\  return code !== 0 && api.context === api.context && Object.isFrozen(api.context.create) && sync.errno[0] === code;
            \\})()
        );
        try t.expect(host.rust_isolate == null);
        try check(scope, "api.io === api.io && Object.isFrozen(api.io.create)");
        try t.expect(host.rust_isolate != null);
        try check(scope, "api.net === api.net && Object.isFrozen(api.net.Socket.prototype) && Object.isFrozen(api.net.PullSocket.prototype)");
        try t.expectEqual(glue_modules, probe.loads.count());
        var counts = probe.loads.valueIterator();
        while (counts.next()) |count| try t.expectEqual(@as(usize, 1), count.*);
        try t.expectEqual(@as(usize, if (run == 2) glue_modules else 0), probe.rejects);
        host.flushGlueCache(scope);
        try t.expectEqual(@as(usize, if (run == 0 or run == 2) glue_modules else 0), probe.stores);
        try t.expectEqual(@as(usize, if (run == 0) 0 else glue_modules), probe.hits);
        host.flushGlueCache(scope);
        try t.expectEqual(@as(usize, if (run == 0 or run == 2) glue_modules else 0), probe.stores);
    }
}

test "api: snapshot restores immutable getters and network classes without compiling glue" {
    ensureV8();
    const blob = try m.snapshot.create(t.allocator);
    defer t.allocator.free(blob);
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const rt = try m.Runtime.create(t.allocator, .{ .snapshot = blob });
    defer rt.destroy();
    const host = try m.Api.Host.create(t.allocator, .{ .runtime = .{}, .fs = .{ .root = .{ .handle = tmp.dir.handle }, .async = false } });
    defer host.destroy();
    var cache = m.Api.init_cache.CodeCacheState.init(host, .{ .handle = tmp.dir.handle });
    var probe: GlueCacheProbe = .{ .inner = cache.hook() };
    defer probe.deinit();
    var options = host.initOptions();
    options.code_cache = .{ .data = &probe, .load = GlueCacheProbe.load, .store = GlueCacheProbe.store };
    const a = try rt.createScope(options);
    const b = try rt.createScope(options);
    const first = try host.install(a, null);
    defer first.deinit();
    const second = try host.install(b, null);
    defer second.deinit();
    try exposeApi(a, first);
    try exposeApi(b, second);
    try t.expect(host.rust_isolate == null);
    try check(a,
        \\Object.isFrozen(api) && !Reflect.set(api, 'fs', {}) && !Reflect.deleteProperty(api, 'net') &&
        \\Object.values(Object.getOwnPropertyDescriptors(api)).every(d =>
        \\  typeof d.get === 'function' && Object.isFrozen(d.get) && !d.configurable && d.set === undefined)
    );
    try check(a, "Object.isFrozen(api.fs) && Object.isFrozen(api.fs.requestSync) && Object.isFrozen(api.host.env.args) && Object.isFrozen(api.context.create)");
    try t.expect(host.rust_isolate == null);
    try check(a,
        \\[api.net.Handle, api.net.Server, api.net.PullServer, api.net.EventServer, api.net.Socket, api.net.PullSocket, api.net.EventSocket].every(C =>
        \\  Object.isFrozen(C) && Object.isFrozen(C.prototype) &&
        \\  Object.values(Object.getOwnPropertyDescriptors(C.prototype)).every(d =>
        \\    (typeof d.value !== 'function' || Object.isFrozen(d.value)) &&
        \\    (d.get === undefined || Object.isFrozen(d.get))))
    );
    try check(a, "api.io === api.io && Object.isFrozen(api.io.create)");
    // Separate deserialized contexts retain distinct memoization, errno and class identities.
    const first_net = try a.eval("api.net.Socket", "test:first-socket", null);
    defer first_net.deinit();
    const second_net = try b.eval("api.net.Socket", "test:second-socket", null);
    defer second_net.deinit();
    {
        var session: m.Runtime.Session = undefined;
        session.init(rt);
        defer session.deinit();
        try t.expect(!first_net.deref().strictEquals(second_net.deref()));
    }
    try check(a, "globalThis.sync = api.fs.requestSync({ handle: 'plain', access: 'r' }); sync.fileStat({}); sync.errno[0] !== 0");
    try check(b, "api.fs.requestSync({ handle: 'plain', access: 'r' }).errno[0] === 0");
    try check(a, "sync.errno[0] !== 0");
    const restricted_host = try m.Api.Host.create(t.allocator, .{});
    defer restricted_host.destroy();
    const restricted = try rt.createScope(options);
    const restricted_api = try restricted_host.install(restricted, null);
    defer restricted_api.deinit();
    try exposeApi(restricted, restricted_api);
    try check(restricted, "Object.keys(api).join(',') === 'fs,host,graph,context' && api.io === undefined && api.net === undefined && Object.isFrozen(api)");
    try check(restricted, "(() => { try { api.fs.requestSync({ handle: 'plain', access: 'r' }); return false; } catch (e) { return e.name === 'PermissionDenied'; } })()");
    try t.expect(restricted_host.rust_isolate == null);
    host.flushGlueCache(a);
    try t.expectEqual(@as(usize, 0), probe.loads.count());
    try t.expectEqual(@as(usize, 0), probe.stores);
}

test "api: init snapshot retains prepared network classes and their runtime bindings work" {
    ensureV8();
    const Init = struct {
        /// Borrows the request; returns static source for the snapshot's init module.
        fn load(_: ?*anyopaque, _: m.LoadRequest) !m.LoadResult {
            return .{ .source =
            \\export async function main(api) {
            \\  const frozen = Object.isFrozen(api.net.PullSocket.prototype.read);
            \\  const io = api.io.create({ backend: 'threaded' });
            \\  const server = api.net.listen(io, { port: 0, mode: 'pull', socketMode: 'pull' });
            \\  const serving = (async () => {
            \\    const peer = await server.accept();
            \\    let count = 0;
            \\    while (count < 3) {
            \\      const bytes = await peer.read(3);
            \\      count += bytes.length;
            \\      await peer.queued.send(bytes);
            \\    }
            \\    await peer.close();
            \\  })();
            \\  const client = await api.net.connect(io, { port: server.port, mode: 'pull' });
            \\  await client.queued.send(new Uint8Array([1, 2, 3]));
            \\  const received = [];
            \\  while (received.length < 3) received.push(...await client.read(3));
            \\  await client.close();
            \\  await serving;
            \\  await server.close();
            \\  await io.close();
            \\  globalThis.report = frozen && received.join(',') === '1,2,3';
            \\}
            };
        }
    };
    var image = try m.init_snapshot.create(t.allocator, .{
        .key = @splat(7),
        .specifier = "init",
        .scope = .{ .resolver = .{ .resolve = @import("support.zig").Memory.resolve }, .loader = .{ .load = Init.load } },
    });
    defer image.deinit();
    const rt = try m.Runtime.create(t.allocator, .{ .snapshot = image.blob });
    defer rt.destroy();
    const host = try m.Api.Host.create(t.allocator, .{ .runtime = .{} });
    defer host.destroy();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var cache = m.Api.init_cache.CodeCacheState.init(host, .{ .handle = tmp.dir.handle });
    var probe: GlueCacheProbe = .{ .inner = cache.hook() };
    defer probe.deinit();
    var options = host.initOptions();
    options.init_snapshot = &image.table;
    options.code_cache = .{ .data = &probe, .load = GlueCacheProbe.load, .store = GlueCacheProbe.store };
    const scope = try rt.createScope(options);
    var error_info: m.ErrorInfo = .{};
    defer error_info.deinit();
    try host.run(scope, support.engine.platform, "init", &error_info);
    try check(scope, "report === true");
    try t.expectEqual(@as(usize, 0), probe.loads.count());
    host.flushGlueCache(scope);
    try t.expectEqual(@as(usize, 0), probe.stores);
}

test "api: an init snapshot made on the engine snapshot hands the restored scope the handles module" {
    // The path of main.zig: the init snapshot is taken from a context restored out of the engine
    // snapshot, so the handles module's snapshot data must be added to the new blob again.
    ensureV8();
    const engine = try m.snapshot.create(t.allocator);
    defer t.allocator.free(engine);
    const Init = struct {
        fn load(_: ?*anyopaque, _: m.LoadRequest) !m.LoadResult {
            return .{ .source = "export function main(api) { globalThis.report = Object.isFrozen(api) && typeof api.fs.requestSync === 'function'; }" };
        }
    };
    var image = try m.init_snapshot.create(t.allocator, .{
        .key = @splat(7),
        .specifier = "init",
        .scope = .{ .resolver = .{ .resolve = @import("support.zig").Memory.resolve }, .loader = .{ .load = Init.load } },
        .base_snapshot = engine,
    });
    defer image.deinit();
    const rt = try m.Runtime.create(t.allocator, .{ .snapshot = image.blob });
    defer rt.destroy();
    const host = try m.Api.Host.create(t.allocator, .{ .runtime = .{} });
    defer host.destroy();
    var options = host.initOptions();
    options.init_snapshot = &image.table;
    const scope = try rt.createScope(options);
    var error_info: m.ErrorInfo = .{};
    defer error_info.deinit();
    try host.run(scope, support.engine.platform, "init", &error_info);
    try check(scope, "report === true");
    try t.expect(scope.module_map.adopted.contains(m.Api.glue.handles_id));
}

test "api: main receives env and an fs with sync and async variants" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Dir, IoError, HostError, Limit } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  out.args = api.host.env.args().join(',');
        \\  out.home = api.host.env.get('HOME');
        \\  const sync = api.fs.requestSync({ handle: 'plain', access: 'rw' });
        \\  const io = api.io.create({});
        \\  const async = await api.fs.requestAsync({ handle: 'plain', io, access: 'rw' });
        \\  const f = IoError.check(sync, sync.dirOpenFile(Dir.cwd(), 'a.txt', 'w'));
        \\  sync.fileWriteAll(f, Uint8Array.from([104, 105]));
        \\  sync.fileClose(f);
        \\  const g = await async.dirOpenFile(Dir.cwd(), 'a.txt', 'r');
        \\  out.text = String.fromCharCode(...await async.fileReadAll(g, { limit: Limit.unlimited }));
        \\  const h = await async.dirOpenFile(Dir.cwd(), 'a.txt', 'r');
        \\  out.limited = (await async.fileReadAll(h, { limit: Limit.limited(1) })).length;
        \\  const i = await async.dirOpenFile(Dir.cwd(), 'a.txt', 'r');
        \\  out.nothing = (await async.fileReadAll(i, { limit: Limit.nothing })).length;
        \\  try { IoError.check(sync, sync.dirOpenFile(Dir.cwd(), 'nope.txt', 'r')); } catch (e) { out.missing = IoError.is(e, IoError.NotFound); }
        \\  await async.dirOpenFile(Dir.cwd(), 'nope.txt', 'r').catch(e => { out.asyncMissing = IoError.is(e, IoError.NotFound); });
        \\  for (const bad of ['../x', '/etc/passwd', 'a/../../x']) {
        \\    sync.dirOpenFile(Dir.cwd(), bad, 'r');
        \\    (out.escapes ??= []).push(sync.errno[0] === IoError.PermissionDenied);
        \\    await async.dirOpenFile(Dir.cwd(), bad, 'r').catch(e => { (out.asyncEscapes ??= []).push(IoError.is(e, IoError.PermissionDenied)); });
        \\  }
        \\  sync.errno[0] = 0;
        \\  const entries = sync.dirRead(Dir.cwd());
        \\  out.listed = entries.some(e => e.name === 'a.txt');
        \\  out.stat = sync.dirStat(Dir.cwd(), 'a.txt').size;
        \\  out.asyncNoErrno = async.errno === undefined && sync.errno instanceof Uint32Array;
        \\  out.frozen = Object.isFrozen(sync) && Object.isFrozen(async) && sync.kind === 'sync' && async.kind === 'async';
        \\  await io.close();
        \\}
    , true, &.{ "x", "y" });
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.args === 'x,y' && report.home === '/home/test'");
    try check(fx.scope, "report.text === 'hi' && report.limited === 1 && report.nothing === 0");
    try check(fx.scope, "report.missing === true && report.asyncMissing === true");
    try check(fx.scope, "report.escapes.length === 3 && report.escapes.every(x => x)");
    try check(fx.scope, "report.listed === true && report.stat === 2 && report.asyncNoErrno && report.frozen && report.asyncEscapes.length === 3 && report.asyncEscapes.every(x => x)");
}

test "api: errno is one native-backed array and open modes are python-style" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Dir } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const a = api.fs.requestSync({ handle: 'plain', access: 'rw' });
        \\  const b = api.fs.requestSync({ handle: 'plain', access: 'rw' });
        \\  out.shared = a.errno === b.errno && a.errno instanceof Uint32Array && a.errno.length === 1;
        \\  try { structuredClone(a.errno.buffer, { transfer: [a.errno.buffer] }); } catch { out.pinned = true; }
        \\  const s = a, cwd = Dir.cwd();
        \\  const bits = [];
        \\  for (const mode of ['w+', 'x', 'x+', 'rw', 'r+', 'bogus', 42, {}]) {
        \\    const f = s.dirOpenFile(cwd, 'm.txt', mode);
        \\    bits.push(a.errno[0]);
        \\    a.errno[0] = 0;
        \\    if (f !== undefined) s.fileClose(f);
        \\  }
        \\  out.codes = bits.join(',');
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.run();
    // w+ creates (0); x/x+ hit the existing file (AlreadyExists 11); rw/r+ open it; junk is InvalidInput 30.
    try check(fx.scope, "report.shared && report.pinned && report.codes === '0,11,11,0,0,30,30,30'");
}

test "api: host.threading.parallelism is a positive integer" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\export function main(api) {
        \\  const n = api.host.threading.parallelism;
        \\  globalThis.report = { n, frozen: Object.isFrozen(api.host.threading) };
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "Number.isInteger(report.n) && report.n >= 1 && report.frozen");
}

test "api: io narrowing enforces quotas and env exposes only reads" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Dir, IoError, HostError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create({});
        \\  // The io ceiling is narrowable too: backend list and runtime count.
        \\  const capped = api.io.narrow({ maxRuntimes: 1, backends: ['threaded'] });
        \\  const first = capped.create({});
        \\  out.narrowedBackend = first.backend;
        \\  try { capped.create({}); } catch (e) { out.countCapped = IoError.is(e, IoError.Unsupported); }
        \\  try { api.io.narrow({ backends: ['threaded'] }).create({ backend: 'uring' }); } catch (e) { out.backendCapped = IoError.is(e, IoError.Unsupported); }
        \\  await first.close();
        \\  await capped.create({}).close();
        \\  // close() is one shared promise; the narrowing slot is held until it settles.
        \\  const slot = api.io.narrow({ maxRuntimes: 1 });
        \\  const solo = slot.create({ backend: 'threaded' });
        \\  const c1 = solo.close(), c2 = solo.close();
        \\  out.closeShared = c1 === c2;
        \\  try { slot.create({ backend: 'threaded' }); out.closeHeld = false; } catch (e) { out.closeHeld = IoError.is(e, IoError.Unsupported); }
        \\  await Promise.all([c1, c2]);
        \\  out.closeAfter = solo.close() === c1;
        \\  await slot.create({ backend: 'threaded' }).close();
        \\  await io.close();
        \\  out.home = api.host.env.get('HOME'); out.path = api.host.env.get('PATH');
        \\  out.envReads = Object.keys(api.host.env).join(',') === 'args,get,list' && Object.isFrozen(api.host.env);
        \\  out.noContextNarrow = api.context.narrow === undefined && api.graph.create !== undefined && api.graph.root !== undefined && api.graph.derive === undefined && api.graph.declare === undefined;
        \\  out.frozen = Object.isFrozen(api) && Object.isFrozen(api.fs) && api.fs.narrow === undefined;
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.narrowedBackend === 'threaded' && report.countCapped && report.backendCapped");
    try check(fx.scope, "report.home === '/home/test' && report.path === '/bin' && report.envReads");
    try check(fx.scope, "report.noContextNarrow === true && report.frozen === true && report.closeShared && report.closeHeld && report.closeAfter");
}

test "api: without a host grant fs is denied" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { IoError, HostError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const io = api.io.create({});
        \\  try { api.fs.requestSync({ handle: 'plain', access: 'r' }); } catch (e) { globalThis.denied = IoError.is(e, IoError.PermissionDenied); }
        \\  await api.fs.requestAsync({ handle: 'plain', io, access: 'r' }).catch(e => { globalThis.asyncDenied = IoError.is(e, IoError.PermissionDenied); });
        \\  await io.close();
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "denied === true && asyncDenied === true");
}

test "api: contexts with an import map layer, sync and async hooks and preload values" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { importMap } from 'origine:@std/graph/resolve/layers';
        \\import { fromLoader } from 'origine:@std/graph/providers';
        \\export async function main(api) {
        \\  const loader = id => id === 'app:/main.js' ? "import { v } from 'dep'; globalThis.seen = v + preloaded" : { source: 'export const v = 40' };
        \\  const handlerFor = load => ImportHandler.make({ resolver: ImportResolver.layered().layer(importMap({ imports: { dep: 'app:/dep.js', main: 'app:/main.js' } })), hooks: [fromLoader(load)] });
        \\  const preload = [{ source: '(values) => { globalThis.preloaded = values.n }', values: { n: 2 } }];
        \\  const a = await api.context.create({ graph: api.graph.root, import: handlerFor(loader), preload });
        \\  const b = await api.context.create({ graph: api.graph.root, import: handlerFor(async id => loader(id)), preload });
        \\  await a.import('main');
        \\  await b.import('main');
        \\  const c = await api.context.create({ graph: api.graph.root, import: handlerFor(() => { throw new Error('nope') }) });
        \\  await c.import('main').catch(e => { globalThis.failed = e.name; });
        \\  c.close();
        \\  try { await c.import('main') } catch (e) { globalThis.closed = e.errno }
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.rt.scopes.items[1], "seen === 42");
    try check(fx.rt.scopes.items[2], "seen === 42");
    try check(fx.scope, "failed === 'ModuleError' && closed === 3");
}

test "typescript: contexts get only the transformers the handler names" {
    if (!m.Api.oxc.enabled) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Transform, ImportHandler, MakeRecipe } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { importMap } from 'origine:@std/graph/resolve/layers';
        \\import { fromLoader } from 'origine:@std/graph/providers';
        \\import { ts } from 'origine:@std/transformer/oxc';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const transform = ts();
        \\  const sources = id => id === 'app:/main.ts' ? "import { n } from 'dep'; const x: number = n + 1; globalThis.seen = x;" : 'export const n: number = 41;';
        \\  const map = { dep: 'app:/dep.ts', main: 'app:/main.ts', note: 'app:/note.txt', bad: 'app:/bad.ts', x: 'app:/x.txt', plain: 'app:/plain.ts' };
        \\  const handlerFor = (load, transformer) => ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(importMap({ imports: map })),
        \\    hooks: [fromLoader(load)],
        \\    maker: MakeRecipe.inherit(transformer === undefined ? {} : { transformer }),
        \\  });
        \\  const load = async (load, transformer, specifier = 'main') => {
        \\    const ctx = await api.context.create({ graph: api.graph.root, import: handlerFor(load, transformer) });
        \\    return ctx.import(specifier);
        \\  };
        \\  const byTs = Transform.byExtension({ '.ts': transform });
        \\  // 1: a host transformer with a synchronous loader; 2: the same with an asynchronous one.
        \\  await load(sources, byTs);
        \\  await load(async id => sources(id), byTs);
        \\  // 3: a guest function as transformer (creating realm; it may now be async).
        \\  const ids = [];
        \\  await load(() => 'hello', Transform.byExtension({ '.txt': async (source, id) => { ids.push(id); return 'globalThis.seen = ' + JSON.stringify(source.toUpperCase()); } }), 'note');
        \\  out.ids = ids.join(',');
        \\  // Failures reach the importer as a ModuleError whose message holds the diagnostics.
        \\  await load(() => 'const x: number = ;', byTs, 'bad').catch(e => { out.hostError = e.message; });
        \\  await load(async () => 'const x: number = ;', byTs, 'bad').catch(e => { out.asyncError = e.message; });
        \\  await load(() => 'x', Transform.byExtension({ '.txt': () => { throw new Error('boom'); } }), 'x').catch(e => { out.jsError = e.message; });
        \\  // Without a transformer the TypeScript source reaches V8 as it is.
        \\  await load(() => 'const x: number = 1;', undefined, 'plain').catch(e => { out.plain = e.message; });
        \\  // Malformed tables are rejected: bad extension syntax, non-transformers.
        \\  const rejects = table => { try { Transform.byExtension(table); return false; } catch (e) { return e.name === 'InvalidInput'; } };
        \\  out.rejected = [rejects({ ts: transform }), rejects({ '.a/b': transform }), rejects({ '.': transform }), rejects({ '.ts': 1 }), rejects(null)].join(',');
        \\  out.options = typeof ts({ jsx: 'classic', pragma: 'h' }) === 'object' && (() => { try { ts({ jsx: 'bogus' }); return false; } catch (e) { return e instanceof TypeError; } })();
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.rt.scopes.items[1], "seen === 42");
    try check(fx.rt.scopes.items[2], "seen === 42");
    try check(fx.rt.scopes.items[3], "seen === 'HELLO'");
    try check(fx.scope, "report.ids === 'app:/note.txt'");
    try check(fx.scope, "report.hostError.includes('app:/bad.ts:1:') && report.asyncError.includes('app:/bad.ts:1:')");
    try check(fx.scope, "report.jsError.includes('boom') && report.plain.includes('SyntaxError') ");
    try check(fx.scope, "report.rejected === 'true,true,true,true,true' && report.options");
}

test "leaks: oxc descriptors validate options and run their diagnostics through every path" {
    if (!m.Api.oxc.enabled) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Transform, ImportHandler, MakeRecipe } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { importMap } from 'origine:@std/graph/resolve/layers';
        \\import { fromLoader } from 'origine:@std/graph/providers';
        \\import { ts } from 'origine:@std/transformer/oxc';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  // Option bags are validated in JS: nothing is allocated for a bad one.
        \\  let bad = 0;
        \\  for (let i = 0; i < 4; i++) {
        \\    try { ts({ importSource: 'x', pragma: 'y', pragmaFrag: 'z', development: 'nope' }); } catch (e) { if (e instanceof TypeError) bad++; }
        \\    try { ts({ importSource: 'x', pragma: 1 }); } catch (e) { if (e instanceof TypeError) bad++; }
        \\    try { ts({ importSource: 'x', jsx: 'bogus' }); } catch (e) { if (e instanceof TypeError) bad++; }
        \\  }
        \\  out.bad = bad;
        \\  // Through contexts, sync and async hooks, ok and failing, over a native maker.
        \\  const transformer = Transform.byExtension({ '.ts': ts({ jsx: 'classic', importSource: 'preact', pragma: 'h', pragmaFrag: 'Fragment' }) });
        \\  for (const source of ['export const n: number = 1', 'const x: number = ;']) {
        \\    for (const load of [() => source, async () => source]) {
        \\      const handler = ImportHandler.make({ resolver: ImportResolver.layered().layer(importMap({ imports: { m: 'app:/m.ts' } })), hooks: [fromLoader(load)], maker: MakeRecipe.inherit({ transformer }) });
        \\      const ctx = await api.context.create({ graph: api.graph.root, import: handler });
        \\      await ctx.import('m').catch(() => { out.childFailed = (out.childFailed ?? 0) + 1; });
        \\      ctx.close();
        \\    }
        \\  }
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.bad === 12 && report.childFailed === 2");
}

test "leaks: a rejecting context settles the parent's import promise, repeatedly" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { importMap } from 'origine:@std/graph/resolve/layers';
        \\import { fromLoader } from 'origine:@std/graph/providers';
        \\export async function main(api) {
        \\  const names = [];
        \\  const handlerFor = load => ImportHandler.make({ resolver: ImportResolver.layered().layer(importMap({ imports: { m: 'app:/m.js' } })), hooks: [fromLoader(load)] });
        \\  for (let i = 0; i < 5; i++) {
        \\    const child = await api.context.create({ graph: api.graph.root, import: handlerFor(() => 'throw new Error("boom")') });
        \\    await child.import('m').catch(e => { names.push(e.name + ':' + e.message.includes('boom')); });
        \\    child.close();
        \\  }
        \\  // A child whose module graph fails to load rejects through the same path.
        \\  const missing = await api.context.create({ graph: api.graph.root, import: handlerFor(async () => { throw new Error('nope'); }) });
        \\  await missing.import('m').catch(e => { names.push(e.name); });
        \\  globalThis.names = names.join(',');
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "names.startsWith('ModuleError:true,ModuleError:true,ModuleError:true,ModuleError:true,ModuleError:true,ModuleError')");
}

test "leaks: loads that never settle are freed with the host" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { importMap } from 'origine:@std/graph/resolve/layers';
        \\import { fromLoader } from 'origine:@std/graph/providers';
        \\export async function main(api) {
        \\  const handlerFor = (load, map) => ImportHandler.make({ resolver: ImportResolver.layered().layer(importMap({ imports: map })), hooks: [fromLoader(load)] });
        \\  // Never-settling hook promises; their imports are deliberately not awaited.
        \\  for (let i = 0; i < 3; i++) {
        \\    const child = await api.context.create({ graph: api.graph.root, import: handlerFor(() => new Promise(() => {}), { m: 'app:/m' + i + '.js', dep: 'app:/dep.js' }) });
        \\    child.import('m').catch(() => {});
        \\  }
        \\  // One load that settles next to one that does not.
        \\  const mixed = await api.context.create({ graph: api.graph.root, import: handlerFor(id => id === 'app:/main.js' ? Promise.resolve("import 'app:/hang.js'") : new Promise(() => {}), { main: 'app:/main.js', hang: 'app:/hang.js' }) });
        \\  mixed.import('main').catch(() => {});
        \\  globalThis.started = true;
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "started === true");
}

test "api: contexts inherit no authority and no capability" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { importMap } from 'origine:@std/graph/resolve/layers';
        \\import { fromLoader } from 'origine:@std/graph/providers';
        \\export async function main(api) {
        \\  const handler = ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(importMap({ imports: { main: 'app:/main.js' } })),
        \\    hooks: [fromLoader(() => "globalThis.keys = Object.getOwnPropertyNames(globalThis).filter(k => k === 'api' || k === 'context' || k === 'graph' || k === 'scope').length")],
        \\  });
        \\  const child = await api.context.create({ graph: api.graph.root, import: handler });
        \\  await child.import('main');
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.rt.scopes.items[1], "keys === 0 && typeof api === 'undefined'");
}

test "api: Zig-style Dir and File methods over sync and async io" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Dir, File, IoError, HostError, Limit, FileKind } from 'origine:@std/io';
        \\const text = bytes => String.fromCharCode(...bytes);
        \\const bytes = s => Uint8Array.from([...s].map(c => c.charCodeAt(0)));
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const rt = api.io.create({});
        \\  const io = api.fs.requestSync({ handle: 'plain', access: 'rw' }), cwd = Dir.cwd();
        \\  cwd.writeFile(io, { sub_path: 'w.txt', data: bytes('hello world') });
        \\  out.read = text(cwd.readFile(io, 'w.txt'));
        \\  out.limited = text(cwd.readFile(io, 'w.txt', Limit.limited(5)));
        \\  const f = cwd.openFile(io, 'w.txt', { mode: 'read_write' });
        \\  out.isFile = File.is(f) && Dir.is(cwd) && Object.isFrozen(f);
        \\  out.length = f.length(io);
        \\  const buf = new Uint8Array(5);
        \\  out.pread = f.readPositional(io, buf, 6) + ':' + text(buf);
        \\  out.stream = f.readStreaming(io, buf) + ':' + text(buf);
        \\  f.writePositionalAll(io, bytes('J'), 0);
        \\  f.setLength(io, 5);
        \\  f.sync(io);
        \\  out.afterTruncate = text(cwd.readFile(io, 'w.txt'));
        \\  out.kind = f.stat(io).kind === FileKind.file;
        \\  f.close(io);
        \\  cwd.createDirPath(io, 'a/b/c');
        \\  const sub = cwd.createDirPathOpen(io, 'a/b');
        \\  sub.writeFile(io, { sub_path: 'in.txt', data: bytes('x') });
        \\  out.names = cwd.openDir(io, 'a/b').iterate(io).map(e => e.name).sort().join(',');
        \\  cwd.rename(io, 'a/b/in.txt', cwd, 'moved.txt');
        \\  out.moved = text(cwd.readFile(io, 'moved.txt'));
        \\  cwd.access(io, 'moved.txt');
        \\  try { cwd.access(io, 'ghost'); } catch (e) { out.ghost = IoError.is(e, IoError.NotFound); }
        \\  try { cwd.deleteTree(io, '.'); } catch (e) { out.rootSafe = IoError.is(e, IoError.InvalidInput); }
        \\  cwd.deleteTree(io, 'a');
        \\  try { cwd.statFile(io, 'a'); } catch (e) { out.gone = IoError.is(e, IoError.NotFound); }
        \\  const aio = await api.fs.requestAsync({ handle: 'plain', io: rt, access: 'rw' });
        \\  await cwd.writeFile(aio, { sub_path: 'async.txt', data: bytes('async!') });
        \\  out.asyncRead = text(await cwd.readFile(aio, 'async.txt'));
        \\  const af = await cwd.openFile(aio, 'async.txt');
        \\  out.asyncLen = await af.length(aio);
        \\  await af.close(aio);
        \\  await cwd.openFile(aio, 'ghost').catch(e => { out.asyncGhost = IoError.is(e, IoError.NotFound); });
        \\  const ro = api.fs.requestSync({ handle: 'plain', access: 'r' });
        \\  try { Dir.cwd().deleteFile(ro, 'async.txt'); } catch (e) { out.roDelete = IoError.is(e, IoError.PermissionDenied); }
        \\  try { Dir.cwd().rename(ro, 'async.txt', Dir.cwd(), 'z'); } catch (e) { out.roRename = IoError.is(e, IoError.PermissionDenied); }
        \\  const aro = await api.fs.requestAsync({ handle: 'plain', io: rt, access: 'r' });
        \\  await Dir.cwd().deleteFile(aro, 'async.txt').catch(e => { out.asyncRoDelete = IoError.is(e, IoError.PermissionDenied); });
        \\  await Dir.cwd().rename(aro, 'async.txt', Dir.cwd(), 'z').catch(e => { out.asyncRoRename = IoError.is(e, IoError.PermissionDenied); });
        \\  await rt.close();
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.read === 'hello world' && report.limited === 'hello' && report.isFile && report.length === 11");
    try check(fx.scope, "report.pread === '5:world' && report.stream === '5:hello' && report.afterTruncate === 'Jello' && report.kind");
    try check(fx.scope, "report.names === 'c,in.txt' && report.moved === 'x'");
    try check(fx.scope, "report.ghost && report.rootSafe && report.gone");
    try check(fx.scope, "report.asyncRead === 'async!' && report.asyncLen === 6 && report.asyncGhost");
    try check(fx.scope, "report.roDelete && report.roRename && report.asyncRoDelete && report.asyncRoRename");
}

test "quansync: leaves, composites, yields, errors, finally and fast paths" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { quansync } from 'origine:@std/quansync';
        \\export async function main() {
        \\  const out = globalThis.report = {};
        \\  const add = quansync({ sync: (a, b) => a + b, async: async (a, b) => a + b });
        \\  const twice = quansync(function* (a) { const x = yield* add(a, a); return yield add(x, 1); });
        \\  out.sync = twice.sync(2);
        \\  out.async = await twice.async(2);
        \\  out.awaited = await twice(3);
        \\  out.leafSync = add.sync(1, 2);
        \\  out.leafAwaited = await add(1, 2);
        \\  const boom = quansync({ sync() { throw new Error('s'); }, async() { return Promise.reject(new Error('a')); } });
        \\  const guarded = quansync(function* () { try { yield* boom(); } catch (e) { return e.message; } });
        \\  out.errSync = guarded.sync();
        \\  out.errAsync = await guarded.async();
        \\  let cleaned = 0;
        \\  const withFinally = quansync(function* () { try { yield* boom(); } finally { cleaned++; } });
        \\  try { withFinally.sync(); } catch {}
        \\  await withFinally.async().catch(() => {});
        \\  out.cleaned = cleaned;
        \\  const fast = quansync(function* () { return 'gen'; }, { sync: () => 'fast' });
        \\  out.fast = fast.sync() + ':' + await fast.async();
        \\  const bad = quansync(function* () { yield 42; });
        \\  try { bad.sync(); } catch (e) { out.badYield = e instanceof TypeError; }
        \\  out.run = quansync.run('sync', twice(1)) + ':' + await quansync.run('async', twice(1));
        \\  out.byMode = add['sync'](2, 2) + ':' + await add['async'](2, 2);
        \\  out.frozen = Object.isFrozen(add) && Object.isFrozen(twice);
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.sync === 5 && report.async === 5 && report.awaited === 7 && report.leafSync === 3 && report.leafAwaited === 3");
    try check(fx.scope, "report.errSync === 's' && report.errAsync === 'a' && report.cleaned === 2");
    try check(fx.scope, "report.fast === 'fast:gen' && report.badYield === true && report.run === '3:3' && report.byMode === '4:4' && report.frozen");
}

test "graph: recipes, sources, resolvers, import handlers, providers and caches are immutable JS class instances" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource, SourceMap, ModuleImportPhase } from 'origine:@std/graph/module';
        \\import { ImportHandler, ImportHook, ImportError, MakeRecipe, Transform } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative, origine, importMap } from 'origine:@std/graph/resolve/layers';
        \\import { origineProvider, fsProvider, json, fromLoader } from 'origine:@std/graph/providers';
        \\import { ImportCache, ResolveCache, CodeCache } from 'origine:@std/graph/cache';
        \\const invalid = f => { try { f(); } catch (e) { return e.name === 'InvalidInput' && typeof e.message === 'string'; } return false; };
        \\export async function main() {
        \\  const out = globalThis.report = {};
        \\  const js = (source) => source;
        \\  const src = Object.freeze({});
        \\  // sources: immutable chain, the receiver never changes
        \\  const file = ModuleSource.file('./a.ts', { fs: src });
        \\  const chained = file.withTransformer(js).withTransformer(Transform.byExtension({ '.ts': js }));
        \\  out.chain = file.transformers.length === 0 && chained.transformers.length === 2 && file.native && !chained.native;
        \\  out.sourceFrozen = Object.isFrozen(file) && Object.isFrozen(chained.transformers) && ModuleSource.is(file);
        \\  out.sourceBad = invalid(() => ModuleSource.file('', { fs: src })) && invalid(() => ModuleSource.file('a\0b', { fs: src })) && invalid(() => ModuleSource.text(1))
        \\    && invalid(() => file.withTransformer(42)) && invalid(() => ModuleSource.file('x')) && invalid(() => ModuleSource.file('x', { fs: 1 }));
        \\  out.maps = SourceMap.None.kind === 'none' && SourceMap.url('a.map').value === 'a.map' && SourceMap.text('{}').kind === 'text' && invalid(() => SourceMap.url(''));
        \\  out.phases = ModuleImportPhase.Evaluation === 'evaluation' && Object.isFrozen(ModuleImportPhase);
        \\  // resolver: layers are appended to a copy
        \\  const empty = ImportResolver.layered();
        \\  const resolver = empty.layer(relative()).layer(origine()).layer(importMap({ imports: { a: 'app:/a.js' }, scopes: { 'app:/x/': { b: 'app:/b.js' } } }));
        \\  out.resolver = empty.layers.length === 0 && resolver.layers.length === 3 && ImportResolver.is(resolver) && Object.isFrozen(resolver.layers);
        \\  out.resolverBad = invalid(() => empty.layer(42)) && invalid(() => importMap({ imports: { a: 1 } })) && invalid(() => importMap(null));
        \\  out.mapCopy = resolver.layers[2].imports.a === 'app:/a.js' && resolver.layers[2].scopes['app:/x/'].b === 'app:/b.js' && Object.isFrozen(resolver.layers[2].imports);
        \\  // a chain made only of host descriptors is native; one function makes it js
        \\  const native = ImportHandler.make({
        \\    resolver,
        \\    hooks: [origineProvider({ std: { include: ['text'] } }), json({ fs: src }), fsProvider({ fs: src, read: 'copy' })],
        \\    maker: MakeRecipe.inherit({ transformer: Transform.byExtension({}) }),
        \\    cache: ImportCache.native({ retain: 'used' }),
        \\  });
        \\  out.native = native.native === true && native.plan.every(e => e.kind === 'native') && native.plan.length === 3 + 3 + 1 + 1 + 1
        \\    && native.plan[0].stage === 'resolver' && native.plan[0].name === 'relative' && native.plan[3].name === 'origine' && Object.isFrozen(native.plan);
        \\  const mixed = ImportHandler.make({ resolver, hooks: async () => ImportHook.next(), meta: ({ id }) => ({ url: id }) });
        \\  out.mixed = mixed.native === false && mixed.plan.filter(e => e.kind === 'js').length === 2 && mixed.hooks.length === 1 && typeof mixed.meta === 'function';
        \\  out.defaults = mixed.cache.retain === 'all' && mixed.maker.host === 'maker' && native.meta === null;
        \\  out.handlerBad = invalid(() => ImportHandler.make({ resolver, hooks: [] }) && ImportHandler.make({ resolver: ImportResolver.layered(), hooks: [] }))
        \\    && invalid(() => ImportHandler.make({ resolver })) && invalid(() => ImportHandler.make({ resolver, hooks: [42] }))
        \\    && invalid(() => ImportHandler.make({ resolver, hooks: [], maker: () => 1 })) && invalid(() => ImportHandler.make({ resolver, hooks: [], cache: ResolveCache.native() }))
        \\    && ImportHandler.make({ resolver, hooks: [] }) !== undefined;
        \\  const customMaker = ImportHandler.make({ resolver, hooks: [], maker: MakeRecipe.fn(() => ({})) });
        \\  out.customMaker = !customMaker.native && customMaker.plan.some(e => e.stage === 'maker' && e.kind === 'js');
        \\  out.makerImport = MakeRecipe.inherit({ import: native }).import === native && invalid(() => MakeRecipe.inherit({ import: {} })) && invalid(() => MakeRecipe.fn(1));
        \\  // recipes: the name defaults to the path, text needs one, native follows the parts
        \\  const recipe = ModuleRecipe({ source: ModuleSource.file('./main.js', { fs: src }), import: native });
        \\  const text = ModuleRecipe({ source: ModuleSource.text('export {}'), import: native, name: 'inline', codeCache: CodeCache.none });
        \\  const tainted = ModuleRecipe({ source: ModuleSource.file('./m.ts', { fs: src }).withTransformer(js), import: native });
        \\  out.recipe = recipe.name === './main.js' && recipe.native === true && recipe.codeCache === null && text.native && text.codeCache.host === 'codeCacheNone'
        \\    && !tainted.native && !ModuleRecipe({ source: file, import: mixed }).native && Object.isFrozen(recipe) && ModuleRecipe.is(recipe) && ImportHandler.is(native);
        \\  out.recipeBad = invalid(() => ModuleRecipe({ source: ModuleSource.text(''), import: native })) && invalid(() => ModuleRecipe({ source: file }))
        \\    && invalid(() => ModuleRecipe({ import: native })) && invalid(() => ModuleRecipe({ source: file, import: native, name: '' })) && invalid(() => ModuleRecipe({ source: file, import: native, codeCache: {} }));
        \\  // option bags are read as data: a getter is ignored, so the required option is missing
        \\  out.getter = invalid(() => ModuleRecipe({ source: file, get import() { return native; } }));
        \\  // verdicts
        \\  out.verdicts = ImportHook.next() === ImportHook.next() && ImportHook.accept({ fs: src }).kind === 'accept' && Object.isFrozen(ImportHook.next())
        \\    && ImportHook.source(file).source === file && ImportHook.source(file).kind === 'source' && ImportHook.recipe(recipe).recipe === recipe && ImportHook.recipe(recipe).kind === 'recipe' && invalid(() => ImportHook.source({})) && invalid(() => ImportHook.source(recipe)) && invalid(() => ImportHook.recipe(file)) && ImportHook.provide === undefined;
        \\  const rejected = ImportHook.reject(ImportError.NotFound);
        \\  const other = ImportHook.reject(ImportError.other('Not allowed'));
        \\  out.reject = rejected.error.name === 'NotFound' && ImportError.is(rejected.error, ImportError.NotFound) && other.error.message === 'Not allowed' && other.error.name === 'Unexpected'
        \\    && invalid(() => ImportHook.reject(123456)) && invalid(() => ImportHook.reject({})) && invalid(() => ImportError.other(1)) && ImportError.is(ImportHook.reject(ImportError.PermissionDenied).error, ImportError.PermissionDenied);
        \\  const ref = Object.freeze({});
        \\  out.link = ImportHook.link(ref).kind === 'link' && ImportHook.link(ref).reference === ref && ImportHook.link(ref).mode === undefined && invalid(() => ImportHook.link(null)) && invalid(() => ImportHook.link());
        \\  // transformers by extension
        \\  const byExt = Transform.byExtension({ '.ts': js, '.d.ts': js });
        \\  out.byExt = byExt.entries.length === 2 && byExt.native === false && Transform.byExtension({}).native === true
        \\    && invalid(() => Transform.byExtension({ ts: js })) && invalid(() => Transform.byExtension({ '.': js })) && invalid(() => Transform.byExtension({ '.a/b': js }))
        \\    && invalid(() => Transform.byExtension({ '.a..b': js })) && invalid(() => Transform.byExtension({ '.ts': 1 })) && invalid(() => Transform.byExtension(null));
        \\  // providers
        \\  const std = origineProvider({ std: { exclude: ['fs'] } });
        \\  out.providers = std.std.exclude[0] === 'fs' && origineProvider({ std: { include: ['text', 'text'] } }).std.include.length === 1 && fsProvider({ fs: src, read: 'mmap' }).read === 'mmap'
        \\    && json({ fs: src }).kind === 'provider' && invalid(() => origineProvider({ std: {} })) && invalid(() => origineProvider({ std: { include: [], exclude: [] } }))
        \\    && invalid(() => origineProvider({ std: { include: ['origine:@std/text'] } })) && origineProvider({}).std.all === true && origineProvider().std.all === true && origineProvider({ std: true }).std.all === true && invalid(() => origineProvider({ std: false })) && invalid(() => fsProvider({})) && invalid(() => fsProvider({ fs: src, read: 'map' }));
        \\  const hook = fromLoader(async (id, attributes) => id === 'a' ? 'export default 1' : id === 'b' ? { source: 'export default ' + attributes.type } : 42);
        \\  const a = await hook({ id: 'a', attributes: {} });
        \\  const b = await hook({ id: 'b', attributes: { type: 'json' } });
        \\  const c = await hook({ id: 'c', attributes: {} });
        \\  out.fromLoader = a.kind === 'source' && a.source.text === 'export default 1' && b.source.text === 'export default json' && c.kind === 'reject' && ImportError.is(c.error, ImportError.InvalidData) && invalid(() => fromLoader(1));
        \\  // caches
        \\  out.caches = ImportCache.native({ retain: 'all' }).retain === 'all' && !('entries' in ImportCache.native({ retain: 'all' }))
        \\    && invalid(() => ImportCache.native({})) && invalid(() => ImportCache.native({ retain: 'some' })) && invalid(() => ImportCache.native({ retain: 'all', entries: 10 })) && invalid(() => ImportCache.native({ retain: 'used', entries: 0 }))
        \\    && ResolveCache.native({ entries: 8 }).entries === 8 && ResolveCache.native().host === 'resolveCache'
        \\    && CodeCache.memory({ limits: { size: 1024 } }).limits.size === 1024 && CodeCache.dir({ fs: src, path: 'c' }).path === 'c' && invalid(() => CodeCache.dir(null)) && invalid(() => CodeCache.dir({ fs: src })) && invalid(() => CodeCache.memory({ limits: { size: -5 } }));
        \\  const custom = CodeCache.custom({ load: () => undefined, store: () => {} });
        \\  out.custom = custom.kind === 'codeCache' && custom.native === false && invalid(() => CodeCache.custom({ load: () => {} })) && Object.isFrozen(CodeCache);
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.chain && report.sourceFrozen && report.sourceBad && report.maps && report.phases");
    try check(fx.scope, "report.resolver && report.resolverBad && report.mapCopy");
    try check(fx.scope, "report.native && report.mixed && report.defaults && report.handlerBad && report.customMaker && report.makerImport");
    try check(fx.scope, "report.recipe && report.recipeBad && report.getter");
    try check(fx.scope, "report.verdicts && report.reject && report.link && report.byExt");
    try check(fx.scope, "report.providers && report.fromLoader && report.caches && report.custom");
}

test "graph: a native handler reads, links and evaluates modules without entering JS" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative } from 'origine:@std/graph/resolve/layers';
        \\import { fsProvider } from 'origine:@std/graph/providers';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const src = api.fs.requestSync({ handle: 'plain', access: 'r' });
        \\  const graph = api.graph.create();
        \\  const handler = ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [fsProvider({ fs: src, read: 'copy' })] });
        \\  out.native = handler.native;
        \\  const recipe = ModuleRecipe({ source: ModuleSource.file('main.js', { fs: src }), import: handler });
        \\  const ref = graph.declare(recipe);
        \\  out.declared = ref.status + ':' + graph.requests(ref);
        \\  await graph.load(ref);
        \\  out.loaded = ref.status + ':' + graph.requests(ref).map(r => r.specifier + '=' + r.reference.name + '/' + r.reference.status + '/' + r.phase).join(',');
        \\  const ctx = await api.context.create({ import: handler, graph });
        \\  await graph.evaluate(ref, ctx);
        \\  out.evaluated = ref.status + ':' + (ref.context === ctx) + ':' + ctx.references.length;
        \\  const dep = await ctx.import('./dep.js');
        \\  out.imported = dep.name + ':' + dep.status;
        \\  out.again = await graph.evaluate(ref, ctx).then(() => 'ok');
        \\  const other = await api.context.create({ import: handler, graph });
        \\  out.bound = await graph.evaluate(ref, other).then(() => 'no', e => e.name);
        \\  const fresh = graph.declare(recipe);
        \\  await graph.evaluate(fresh, other);
        \\  out.second = fresh.status;
        \\  const doomed = await api.context.create({ import: handler, graph });
        \\  doomed.close();
        \\  out.closed = await doomed.import('./dep.js').then(() => 'no', e => e.name);
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "dep.js", .data = "export const value = 41;" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "main.js", .data = "import { value } from './dep.js'; globalThis.answer = value + 1; globalThis.runs = (globalThis.runs ?? 0) + 1;" });
    try fx.run();
    try check(fx.scope, "report.native === true && report.declared === 'declared:undefined'");
    try check(fx.scope, "report.loaded === 'loaded:./dep.js=dep.js/declared/evaluation'");
    try check(fx.scope, "report.evaluated === 'evaluated:true:1' && report.imported === 'dep.js:evaluated' && report.again === 'ok'");
    try check(fx.scope, "report.bound === 'InvalidInput' && report.second === 'evaluated'");
    try check(fx.scope, "report.closed === 'StaleHandle'");
    try check(fx.rt.scopes.items[1], "answer === 42 && runs === 1");
    try check(fx.rt.scopes.items[2], "answer === 42 && runs === 1");
    // A handler with no JS function in it never calls the driver.
    try t.expectEqual(@as(usize, 0), fx.host.driver_calls);
}

test "graph: a reference is an inert ticket; the graph that declared it loads, runs, reads and frees it" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative } from 'origine:@std/graph/resolve/layers';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const name = f => { try { const r = f(); return r instanceof Promise ? r.then(() => 'ok', e => e.name) : 'ok'; } catch (e) { return e.name; } };
        \\  const handler = ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [] });
        \\  const recipe = ModuleRecipe({ source: ModuleSource.text('export const n = 1;'), import: handler, name: 'm.js' });
        \\  const ref = api.graph.root.declare(recipe);
        \\  // A reference can do nothing and has no dispose: the methods are gone, with no alias.
        \\  out.inert = ['load', 'evaluate', 'exports', 'release', 'requests', Symbol.dispose].every(key => ref[key] === undefined);
        \\  out.views = ref.name + ':' + ref.status + ':' + ref.context;
        \\  out.frozen = Object.isFrozen(ref);
        \\  out.notRecipe = [await name(() => api.graph.root.declare({})), await name(() => api.graph.root.declare(ref)), await name(() => api.graph.root.declare(undefined))].join(',');
        \\  out.notRef = [await name(() => api.graph.root.load({})), await name(() => api.graph.root.exports({ name: 'm.js' })), await name(() => api.graph.root.release(recipe))].join(',');
        \\  // A reference belongs to one graph: a derived graph cannot use its parent's, nor the parent the derived's.
        \\  const derived = api.graph.create();
        \\  const ctx = await api.context.create({ import: handler, graph: api.graph.root });
        \\  const dctx = await api.context.create({ import: handler, graph: derived });
        \\  out.derivedRef = [await name(() => derived.load(ref)), await name(() => derived.requests(ref)), await name(() => derived.evaluate(ref, dctx)), await name(() => derived.exports(ref)), await name(() => derived.release(ref))].join(',');
        \\  const mine = derived.declare(recipe);
        \\  out.parentRef = [await name(() => api.graph.root.load(mine)), await name(() => api.graph.root.evaluate(mine, ctx))].join(',');
        \\  // The context must be made with the same graph as the reference.
        \\  out.wrongContext = [await name(() => api.graph.root.evaluate(ref, dctx)), await name(() => derived.evaluate(mine, ctx)), await name(() => api.graph.root.evaluate(ref, {})), await name(() => api.graph.root.evaluate(ref, undefined))].join(',');
        \\  out.stillDeclared = ref.status + ':' + mine.status;
        \\  await api.graph.root.evaluate(ref, ctx);
        \\  await derived.evaluate(mine, dctx);
        \\  out.exports = api.graph.root.exports(ref).n + ':' + derived.exports(mine).n;
        \\  out.requests = api.graph.root.requests(ref) === undefined;
        \\  // Closing a derived graph makes its references stale; the parent's are untouched.
        \\  const loaded = derived.declare(recipe);
        \\  derived.close();
        \\  out.stale = [await name(() => derived.load(loaded)), await name(() => derived.evaluate(loaded, dctx)), await name(() => derived.exports(mine)), await name(() => derived.release(mine)), await name(() => derived.declare(recipe))].join(',');
        \\  out.parentFine = await name(() => api.graph.root.exports(ref));
        \\  api.graph.root.release(ref);
        \\  out.released = [await name(() => api.graph.root.load(ref)), await name(() => api.graph.root.exports(ref))].join(',');
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.inert === true && report.views === 'm.js:declared:undefined' && report.frozen === true");
    try check(fx.scope, "report.notRecipe === 'InvalidInput,InvalidInput,InvalidInput' && report.notRef === 'InvalidInput,InvalidInput,InvalidInput'");
    try check(fx.scope, "report.derivedRef === 'InvalidInput,InvalidInput,InvalidInput,InvalidInput,InvalidInput' && report.parentRef === 'InvalidInput,InvalidInput'");
    try check(fx.scope, "report.wrongContext === 'InvalidInput,InvalidInput,InvalidInput,InvalidInput' && report.stillDeclared === 'declared:declared'");
    try check(fx.scope, "report.exports === '1:1' && report.requests === true");
    try check(fx.scope, "report.stale === 'StaleHandle,StaleHandle,StaleHandle,StaleHandle,StaleHandle' && report.parentFine === 'ok'");
    try check(fx.scope, "report.released === 'BadHandle,BadHandle'");
}

test "errors: the sync detail is overwritten by every failure, never left over" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Dir } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.fs.requestSync({ handle: 'plain', access: 'rw' });
        \\  const cwd = Dir.cwd();
        \\  const run = work => { try { work(); return null; } catch (e) { return { name: e.name, subject: e.subject, os: e.os, keys: Object.keys(e).join(',') }; } };
        \\  const dir = cwd.openDir(io, 'dir');
        \\  dir.close(io);
        \\  out.named = JSON.stringify(run(() => cwd.openFile(io, 'nope.txt')));
        \\  out.unnamed = JSON.stringify(run(() => dir.close(io)));
        \\  out.after = JSON.stringify(run(() => cwd.statFile(io, 'also-missing')));
        \\  out.ok = JSON.stringify(run(() => cwd.statFile(io, 'dir')));
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.tmp.dir.createDir(t.io, "dir", .default_dir);
    try fx.run();
    // A failure that names nothing carries no subject from the failure before it, and a success leaves nothing.
    try check(fx.scope,
        \\(() => {
        \\  const named = JSON.parse(report.named), unnamed = JSON.parse(report.unnamed), after = JSON.parse(report.after);
        \\  return named.name === 'NotFound' && named.subject === 'nope.txt' && named.keys === 'errno,name,subject' &&
        \\    unnamed !== null && unnamed.subject === undefined && unnamed.keys === 'errno,name' &&
        \\    after.subject === 'also-missing' && report.ok === 'null';
        \\})()
    );
}

test "errors: a failed import is a ModuleError with the kind of its cause, the module it was for and a cause" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleError, OrigineError } from 'origine:@std/errors';
        \\import { ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler, ImportHook, ImportError } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { importMap } from 'origine:@std/graph/resolve/layers';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const handler = ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(importMap({ imports: { secret: 'app:/secret.js', boom: 'app:/boom.js', top: 'app:/top.js' } })),
        \\    hooks: [async resolved => {
        \\      if (resolved.id === 'app:/secret.js') return ImportHook.reject(ImportError.PermissionDenied);
        \\      if (resolved.id === 'app:/boom.js') return ImportHook.source(ModuleSource.text('throw new Error("boom")'));
        \\      if (resolved.id === 'app:/top.js') return ImportHook.source(ModuleSource.text("import 'secret'"));
        \\      return ImportHook.next();
        \\    }],
        \\  });
        \\  const ctx = await api.context.create({ import: handler, graph: api.graph.root });
        \\  const seen = {};
        \\  for (const specifier of ['secret', 'boom', 'nowhere', 'top']) {
        \\    seen[specifier] = await ctx.import(specifier).then(() => 'no', e => ({
        \\      isModuleError: e instanceof ModuleError, isOrigine: e instanceof OrigineError, name: e.name, errno: e.errno,
        \\      subject: e.subject, referrer: e.referrer ?? null, message: e.message, cause: e.cause === undefined ? null : e.cause.name,
        \\    }));
        \\  }
        \\  out.seen = JSON.stringify(seen);
        \\  out.transient = [OrigineError.transient(51), OrigineError.transient(10), OrigineError.transient({ errno: 50 }), OrigineError.transient(undefined)].join();
        \\  ctx.close();
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope,
        \\(() => {
        \\  const s = JSON.parse(report.seen);
        \\  return s.secret.isModuleError && s.secret.isOrigine && s.secret.name === 'ModuleError' && s.secret.subject === 'app:/secret.js' &&
        \\    s.secret.message === 'app:/secret.js: PermissionDenied' && s.secret.cause === 'PermissionDenied' && s.secret.referrer === null &&
        \\    s.nowhere.errno === 10 && s.nowhere.cause === 'NotFound' && s.nowhere.subject === 'nowhere' &&
        \\    s.top.errno === 20 && s.top.subject === 'app:/secret.js' && s.top.referrer === 'app:/top.js' &&
        \\    s.boom.errno === 1 && s.boom.cause === 'Error' && s.boom.message.includes('boom');
        \\})()
    );
    // WouldBlock (51) and TimedOut (50) may pass; NotFound (10) will not.
    try check(fx.scope, "report.transient === 'true,false,true,false'");
}

test "graph: JS layers, hooks, makers and transformers run in the creating realm" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler, ImportHook, ImportError, MakeRecipe } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative, importMap } from 'origine:@std/graph/resolve/layers';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const calls = [];
        \\  const src = api.fs.requestSync({ handle: 'plain', access: 'r' });
        \\  const leaf = ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [] });
        \\  const handler = ImportHandler.make({
        \\    resolver: ImportResolver.layered()
        \\      .layer(importMap({ imports: { alias: 'app:/value.js' } }))
        \\      .layer(async ({ specifier, referrer }) => { calls.push(specifier); return specifier.startsWith('mem:') ? { id: specifier } : undefined; })
        \\      .layer(relative()),
        \\    hooks: [
        \\      async resolved => {
        \\        if (resolved.id === 'mem:secret') return ImportHook.reject(ImportError.PermissionDenied);
        \\        if (resolved.id === 'mem:gone') return ImportHook.reject(ImportError.other('gone for good'));
        \\        if (resolved.id === 'app:/value.js') return ImportHook.source(ModuleSource.text('export const value = 40;'));
        \\        if (resolved.id === 'mem:ts') return ImportHook.source(ModuleSource.text('export const t = 1;').withTransformer(async s => s + ' export const u = 2;'));
        \\        if (resolved.id === 'mem:recipe') return ImportHook.recipe(ModuleRecipe({ source: ModuleSource.text('export const r = "recipe"; export const where = import.meta.url;'), import: leaf, name: 'mem:recipe' }));
        \\        if (resolved.id === 'mem:accept') return ImportHook.accept({ fs: src });
        \\        return ImportHook.next();
        \\      },
        \\    ],
        \\    maker: MakeRecipe.fn(({ id }) => ({ transformer: text => text + `\n/* made ${id} */` })),
        \\    meta: ({ id }) => ({ id, n: 7, nested: { ok: true } }),
        \\  });
        \\  out.mixed = handler.native === false;
        \\  const graph = api.graph.root;
        \\  const ctx = await api.context.create({ import: handler, graph });
        \\  const text = (name, source) => graph.declare(ModuleRecipe({ source: ModuleSource.text(source), import: handler, name }));
        \\  await graph.evaluate(text('main', "import { value } from 'alias'; import { t, u } from 'mem:ts'; import { r, where } from 'mem:recipe'; globalThis.sum = value + t + u; globalThis.r = r + where; globalThis.here = import.meta.id + import.meta.n + import.meta.nested.ok;"), ctx);
        \\  out.denied = await graph.evaluate(text('d1', "import 'mem:secret'"), ctx).then(() => 'no', e => e.message);
        \\  out.other = await graph.evaluate(text('d2', "import 'mem:gone'"), ctx).then(() => 'no', e => e.message);
        \\  out.accept = await graph.evaluate(text('d3', "import 'mem:accept'"), ctx).then(() => 'no', e => e.message);
        \\  out.missing = await graph.evaluate(text('d4', "import 'nowhere'"), ctx).then(() => 'no', e => e.message);
        \\  out.calls = calls.includes('mem:ts') && calls.includes('nowhere');
        \\  const scratch = await api.context.create({ import: handler, graph });
        \\  out.failed = await ctx.import('mem:secret').then(() => 'no', e => e.name);
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.mixed && report.calls");
    try check(fx.scope, "report.denied.includes('PermissionDenied') && report.other.includes('gone for good')");
    try check(fx.scope, "report.accept.includes('NotFound') && report.missing.includes('NotFound') && report.failed === 'ModuleError'");
    try check(fx.rt.scopes.items[1], "sum === 43");
    try check(fx.rt.scopes.items[1], "r === 'recipemem:recipe'");
    try check(fx.rt.scopes.items[1], "here === 'main7true'");
    try t.expect(fx.host.driver_calls > 0);
}

test "graph: JS layers and hooks never run on the stack of a child's import()" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler, ImportHook } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  // `marked` is 1 only while the child is inside its own synchronous import() call.
        \\  let marked = 0;
        \\  const seen = [];
        \\  const handler = ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(({ specifier }) => { seen.push('layer:' + marked); return { id: specifier }; }),
        \\    hooks: [async r => { seen.push('hook:' + marked); return ImportHook.source(ModuleSource.text('export const v = 1;')); }],
        \\  });
        \\  const ctx = await api.context.create({ graph: api.graph.root,
        \\    import: handler,
        \\    preload: [{ source: '(values) => { globalThis.start = () => { values.mark(1); const p = import("dyn"); values.mark(0); return p; }; }', values: { mark: n => { marked = n; } } }],
        \\  });
        \\  await api.graph.root.evaluate(api.graph.root.declare(ModuleRecipe({ source: ModuleSource.text('await start(); globalThis.done = 1;'), import: handler, name: 'root' })), ctx);
        \\  out.seen = seen.join(',');
        \\  // A hook may create a context: it runs from the microtask checkpoint.
        \\  const maker = ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(({ specifier }) => ({ id: specifier })),
        \\    hooks: [async r => { const inner = await api.context.create({ graph: api.graph.root, import: handler }); inner.close(); return ImportHook.source(ModuleSource.text('export const w = 2;')); }],
        \\  });
        \\  const outer = await api.context.create({ graph: api.graph.root, import: maker });
        \\  out.nested = await outer.import('x').then(r => r.status, e => e.name + ':' + e.message);
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.seen === 'layer:0,hook:0'");
    try check(fx.scope, "report.nested === 'evaluated'");
    try check(fx.rt.scopes.items[1], "done === 1");
}

test "graph: a settled driver call is freed and a second evaluate waits for the first" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler, ImportHook } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative } from 'origine:@std/graph/resolve/layers';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const js = ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(({ specifier }) => ({ id: specifier })),
        \\    hooks: [async r => ImportHook.source(ModuleSource.text(`export const id = '${r.id}';`))],
        \\  });
        \\  const kept = await api.context.create({ graph: api.graph.root, import: js });
        \\  for (const id of ['a', 'b', 'c', 'd', 'e', 'f']) await kept.import(id);
        \\  out.imports = kept.references.length;
        \\  // Two evaluate calls for one context: the second settles with the first, after the module ran.
        \\  let done = 0;
        \\  const plain = ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [] });
        \\  const ctx = await api.context.create({ graph: api.graph.root, import: plain, preload: [{ source: '(values) => { globalThis.finish = values.finish; }', values: { finish: () => { done++; } } }] });
        \\  const ref = api.graph.root.declare(ModuleRecipe({ source: ModuleSource.text('await Promise.resolve(); await Promise.resolve(); finish();'), import: plain, name: 'tla' }));
        \\  const first = api.graph.root.evaluate(ref, ctx);
        \\  const second = api.graph.root.evaluate(ref, ctx);
        \\  out.same = first === second;
        \\  await second;
        \\  out.afterSecond = done;
        \\  await first;
        \\  out.runs = done;
        \\  // A failure reaches both callers, and the reference can be tried again.
        \\  const bad = api.graph.root.declare(ModuleRecipe({ source: ModuleSource.text('await Promise.resolve(); throw new Error("boom");'), import: plain, name: 'bad' }));
        \\  const failures = await Promise.all([api.graph.root.evaluate(bad, ctx).then(() => 'ok', e => e.name), api.graph.root.evaluate(bad, ctx).then(() => 'ok', e => e.name)]);
        \\  out.failures = failures.join(',') + ':' + bad.status;
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.imports === 6 && report.same && report.afterSecond === 1 && report.runs === 1 && report.failures === 'ModuleError,ModuleError:errored'");
    // Every call into the driver settled, so none is kept.
    try t.expectEqual(@as(usize, 0), fx.host.contexts.values()[0].pendings.items.len);
}

test "graph: a handler with functions in it runs its host elements natively and calls the driver only for the functions" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler, ImportHook, MakeRecipe, Transform } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative } from 'origine:@std/graph/resolve/layers';
        \\import { fsProvider } from 'origine:@std/graph/providers';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const src = api.fs.requestSync({ handle: 'plain', access: 'r' });
        \\  const graph = api.graph.create();
        \\  const calls = [];
        \\  const handler = ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(relative()).layer(({ specifier }) => { calls.push('layer:' + specifier); return specifier === 'virtual' ? { id: 'virtual' } : undefined; }),
        \\    hooks: [
        \\      async r => { calls.push('hook:' + r.id); return r.id === 'virtual' ? ImportHook.source(ModuleSource.text('export const v = 5;')) : ImportHook.next(); },
        \\      fsProvider({ fs: src, read: 'copy' }),
        \\    ],
        \\    maker: MakeRecipe.inherit({ transformer: Transform.byExtension({ '.txt': async text => { calls.push('transform'); return text + ' export const t = 1;'; } }) }),
        \\  });
        \\  out.plan = handler.plan.map(e => e.stage + ':' + e.kind).join(',');
        \\  const ctx = await api.context.create({ import: handler, graph });
        \\  await graph.evaluate(graph.declare(ModuleRecipe({ source: ModuleSource.file('main.js', { fs: src }), import: handler })), ctx);
        \\  out.calls = calls.sort().join(',');
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "dep.js", .data = "export const k = 10;" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "native.js", .data = "export const n = 20;" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "x.txt", .data = "export const base = 1;" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "main.js", .data = "import { v } from 'virtual'; import { k } from './dep.js'; import { n } from './native.js'; import { t } from './x.txt'; globalThis.sum = v + k + n + t;" });
    try fx.run();
    try check(fx.scope, "report.plan === 'resolver:native,resolver:js,hooks:js,hooks:native,maker:native,transformer:js,cache:native'");
    // './dep.js', './native.js' and './x.txt' resolve in the host's relative layer, so the layer function only
    // sees 'virtual'; the hook function sees each of the four modules; the transformer function only the .txt.
    try check(fx.scope, "report.calls === 'hook:dep.js,hook:native.js,hook:virtual,hook:x.txt,layer:virtual,transform'");
    try check(fx.rt.scopes.items[1], "sum === 36");
    try t.expectEqual(@as(usize, 6), fx.host.driver_calls);
}

test "graph: origineProvider serves an allowlist and JS cannot forge origine: modules" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler, ImportHook } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { origine } from 'origine:@std/graph/resolve/layers';
        \\import { origineProvider } from 'origine:@std/graph/providers';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const make = hooks => ImportHandler.make({ resolver: ImportResolver.layered().layer(origine()), hooks });
        \\  const text = origineProvider({ std: { include: ['text'] } });
        \\  const forging = make([async resolved => (resolved.id === 'origine:evil' || resolved.id === 'origine:@std/text' ? ImportHook.source(ModuleSource.text('export const encodeUtf8 = () => ({ length: 99 }); export const x = 1;')) : ImportHook.next())]);
        \\  const handler = make([text]);
        \\  out.native = handler.native;
        \\  const run = async (h, name, source) => {
        \\    const ctx = await api.context.create({ graph: api.graph.root, import: h });
        \\    return api.graph.root.evaluate(api.graph.root.declare(ModuleRecipe({ source: ModuleSource.text(source), import: h, name })), ctx).then(() => 'ok', e => e.message);
        \\  };
        \\  out.served = await run(handler, 'a', "import { encodeUtf8 } from 'origine:@std/text'; globalThis.len = encodeUtf8('héllo').length;");
        \\  out.excluded = await run(handler, 'b', "import 'origine:@std/fs'");
        \\  const everything = make([origineProvider({ std: { exclude: [] } })]);
        \\  out.unknown = await run(everything, 'c', "import 'origine:nothing'");
        \\  out.unlisted = await run(handler, 'c2', "import 'origine:nothing'");
        \\  out.forged = await run(forging, 'd', "import 'origine:evil'");
        \\  out.forgedStd = await run(forging, 'e', "import { encodeUtf8 } from 'origine:@std/text'; globalThis.len = encodeUtf8('x').length;");
        \\  const all = make([origineProvider({ std: { exclude: ['fs'] } })]);
        \\  out.excludeServed = await run(all, 'f', "import { eprintln } from 'origine:@std/debug'; globalThis.debugOk = typeof eprintln;");
        \\  out.excludeDenied = await run(all, 'g', "import 'origine:@std/fs'");
        \\  const bad = await api.context.create({ graph: api.graph.root, import: handler }).then(() => 'ok');
        \\  out.bad = bad;
        \\  out.empty = await run(make([]), 'h', "import 'origine:@std/text'");
        \\  // No options, or std: true, serves every origine:@std/* the creating context has.
        \\  out.defaultServed = await run(make([origineProvider()]), 'i', "import { eprintln } from 'origine:@std/debug'; import { encodeUtf8 } from 'origine:@std/text'; globalThis.both = typeof eprintln + typeof encodeUtf8;");
        \\  out.trueServed = await run(make([origineProvider({ std: true })]), 'j', "import { encodeUtf8 } from 'origine:@std/text'; globalThis.len2 = encodeUtf8('é').length;");
        \\  out.unknownStillMissing = await run(make([origineProvider()]), 'k', "import 'origine:nothing'");
        \\  out.falseBad = (() => { try { origineProvider({ std: false }); return 'ok'; } catch (e) { return e.name; } })();
        \\  out.emptyStd = (() => { try { origineProvider({ std: {} }); return 'ok'; } catch (e) { return e.name; } })();
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.native === true && report.served === 'ok'");
    try check(fx.scope, "report.excluded.includes('PermissionDenied') && report.unlisted.includes('PermissionDenied') && report.unknown.includes('NotFound')");
    try check(fx.scope, "report.forged.includes('PermissionDenied') && report.forgedStd.includes('PermissionDenied')");
    try check(fx.scope, "report.excludeServed === 'ok' && report.excludeDenied.includes('PermissionDenied') && report.empty.includes('NotFound')");
    try check(fx.scope, "report.defaultServed === 'ok' && report.trueServed === 'ok' && report.unknownStillMissing.includes('NotFound') && report.falseBad === 'InvalidInput' && report.emptyStd === 'InvalidInput'");
    try check(fx.rt.scopes.items[1], "len === 6");
    // Only the two imports through the handler with a JS hook entered the driver, and only for the hook
    // (its resolver layer is a host layer).
    try t.expectEqual(@as(usize, 2), fx.host.driver_calls);
}

test "graph: the origine ceiling of a context is the exact union of its hooks" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { origine } from 'origine:@std/graph/resolve/layers';
        \\import { origineProvider } from 'origine:@std/graph/providers';
        \\export async function main(api) {
        \\  const make = (...std) => ImportHandler.make({ resolver: ImportResolver.layered().layer(origine()), hooks: std.map(s => origineProvider({ std: s })) });
        \\  const contexts = [
        \\    make({ include: ['text'] }, { exclude: ['fs'] }),                // everything but fs
        \\    make({ exclude: ['fs'] }, { exclude: ['io'] }),                  // everything
        \\    make({ include: ['text'] }, { include: ['io'] }),                // text and io
        \\    make({ include: ['text', 'fs'] }, { exclude: ['fs', 'io'] }),    // everything but io
        \\    make({ exclude: ['fs', 'io'] }, { exclude: ['fs'] }),            // everything but fs
        \\    make(),                                                          // nothing
        \\    make(true),                                                      // everything the creator has
        \\    make(undefined, { include: ['text'] }),                          // the same, plus text
        \\  ];
        \\  for (const handler of contexts) await api.context.create({ graph: api.graph.root, import: handler });
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    const names = [_][]const u8{ "text", "fs", "io" };
    const expected = [_][3]bool{
        .{ true, false, true },
        .{ true, true, true },
        .{ true, false, true },
        .{ true, true, false },
        .{ true, false, true },
        .{ false, false, false },
        .{ true, true, true },
        .{ true, true, true },
    };
    try t.expectEqual(expected.len, fx.host.contexts.count());
    for (fx.host.contexts.values(), expected) |context, row| {
        const ceiling = context.ceiling.?;
        for (names, row) |name, allowed| try t.expectEqual(allowed, ceiling.allows(name));
    }
}

/// The native-state record of the realm a context runs in (what a guest calling the graph natives from there would use).
fn stateOfContext(host: *m.Api.Host, context: anytype) @TypeOf(host.states.items[0]) {
    for (host.states.items) |state| if (state.scope == context.scope) return state;
    unreachable;
}

test "api: context.create needs a graph the host made: missing, forged and closed ones are InvalidInput naming graph" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\export async function main(api) {
        \\  const handler = ImportHandler.make({ resolver: ImportResolver.layered().layer(({ specifier }) => ({ id: specifier })), hooks: [] });
        \\  const attempt = async options => api.context.create({ import: handler, ...options }).then(ctx => { ctx.close(); return 'ok'; }, e => e.name + ':' + e.message);
        \\  const closed = api.graph.create();
        \\  closed.close();
        \\  globalThis.report = {
        \\    missing: await attempt({}),
        \\    undefinedGraph: await attempt({ graph: undefined }),
        \\    forged: await attempt({ graph: {} }),
        \\    lookalike: await attempt({ graph: { ...api.graph.root, id: 1 } }),
        \\    notAnObject: await attempt({ graph: 'api.graph' }),
        \\    closed: await attempt({ graph: closed }),
        \\    root: await attempt({ graph: api.graph.root }),
        \\    derived: await attempt({ graph: api.graph.create() }),
        \\  };
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "['missing', 'undefinedGraph', 'forged', 'lookalike', 'notAnObject', 'closed'].every(k => report[k].startsWith('InvalidInput:') && report[k].includes('graph'))");
    try check(fx.scope, "report.root === 'ok' && report.derived === 'ok'");
}

test "graph: an origineProvider with no std serves what its creator has and cannot widen a narrower context" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { origine } from 'origine:@std/graph/resolve/layers';
        \\import { origineProvider } from 'origine:@std/graph/providers';
        \\export async function main(api) {
        \\  const make = std => ImportHandler.make({ resolver: ImportResolver.layered().layer(origine()), hooks: [origineProvider({ std })] });
        \\  // A context that may import only text and io.
        \\  await api.context.create({ graph: api.graph.root, import: make({ include: ['text', 'io'] }) });
        \\  // One that may import everything but fs.
        \\  await api.context.create({ graph: api.graph.root, import: make({ exclude: ['fs'] }) });
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const graph_api = m.Api.graph_api;
    const cache = try graph_api.cacheCreate(stateOfContext(fx.host, fx.host.contexts.values()[0]), 0);
    const spec = struct {
        fn of(alloc: std.mem.Allocator, filter_json: []const u8, table: u32) ![]u8 {
            return std.fmt.allocPrint(alloc, "{{\"layers\":[{{\"host\":\"origine\"}}],\"hooks\":[{{\"host\":\"origine\",\"std\":{s}}}],\"maker\":{{\"host\":\"maker\",\"import\":0,\"transformer\":null}},\"cache\":{{\"id\":{d}}},\"meta\":false}}", .{ filter_json, table });
        }
    };
    const narrow_state = stateOfContext(fx.host, fx.host.contexts.values()[0]);
    // The default is the creating context's own set, no more.
    const inherited = try graph_api.handler(narrow_state, try spec.of(arena.allocator(), "{\"all\":true}", cache));
    const filter = fx.host.handlers.get(inherited).?.hooks[0].origine;
    try t.expect(filter.allows("text") and filter.allows("io") and !filter.allows("fs") and !filter.allows("debug"));
    // Asking for more by name is still refused.
    try t.expectError(error.PermissionDenied, graph_api.handler(narrow_state, try spec.of(arena.allocator(), "{\"include\":[\"fs\"]}", cache)));
    try t.expectError(error.PermissionDenied, graph_api.handler(narrow_state, try spec.of(arena.allocator(), "{\"exclude\":[]}", cache)));
    // An exclude-style creator passes its exclusions on.
    const wide_state = stateOfContext(fx.host, fx.host.contexts.values()[1]);
    const wide = fx.host.handlers.get(try graph_api.handler(wide_state, try spec.of(arena.allocator(), "{\"all\":true}", cache))).?.hooks[0].origine;
    try t.expect(wide.allows("text") and wide.allows("debug") and !wide.allows("fs"));
}

test "graph: a file of the graph never serves an origine: id, not even as json" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { origine, relative } from 'origine:@std/graph/resolve/layers';
        \\import { fsProvider, json } from 'origine:@std/graph/providers';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const src = api.fs.requestSync({ handle: 'plain', access: 'r' });
        \\  const graph = api.graph.create();
        \\  const handler = ImportHandler.make({ resolver: ImportResolver.layered().layer(origine()).layer(relative()), hooks: [json({ fs: src }), fsProvider({ fs: src, read: 'copy' })] });
        \\  const ctx = await api.context.create({ import: handler, graph });
        \\  const run = (name, text) => graph.evaluate(graph.declare(ModuleRecipe({ source: ModuleSource.text(text), import: handler, name })), ctx).then(() => 'ok', e => e.message);
        \\  out.json = await run('a', "import d from 'origine:@std/text' with { type: 'json' }; globalThis.d = d;");
        \\  out.plain = await run('b', "import 'origine:@std/text'");
        \\  out.file = await run('c', "import d from './data.json' with { type: 'json' }; globalThis.k = d.k;");
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.tmp.dir.createDirPath(t.io, "origine:@std");
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "origine:@std/text", .data = "{\"shadow\": true}" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "data.json", .data = "{\"k\": 7}" });
    try fx.run();
    // No hook serves it (the host's own provider is not in the chain): not found, nothing read from the file.
    try check(fx.scope, "report.json.includes('NotFound') && report.plain.includes('NotFound') && report.file === 'ok'");
    try check(fx.rt.scopes.items[1], "typeof d === 'undefined' && k === 7");
}

test "graph: only a grant that api.fs made can be named by a hook, a source or a code cache" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { CodeCache } from 'origine:@std/graph/cache';
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative } from 'origine:@std/graph/resolve/layers';
        \\import { fsProvider, json } from 'origine:@std/graph/providers';
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create({});
        \\  const real = api.fs.requestSync({ handle: 'plain', access: 'r' });
        \\  const rw = api.fs.requestSync({ handle: 'plain', access: 'rw' });
        \\  const remote = await api.fs.requestAsync({ handle: 'plain', io, access: 'r' });
        \\  const resolver = ImportResolver.layered().layer(relative());
        \\  const name = async f => { try { await f(); return 'ok'; } catch (e) { return e.name; } };
        \\  // The grant is checked when a context takes the handler (the hook), or when a source is read.
        \\  const hooked = fs => name(async () => (await api.context.create({ import: ImportHandler.make({ resolver, hooks: [fsProvider({ fs, read: 'copy' })] }), graph: api.graph.root })).close());
        \\  const jsoned = fs => name(async () => (await api.context.create({ import: ImportHandler.make({ resolver, hooks: [json({ fs })] }), graph: api.graph.root })).close());
        \\  const cached = fs => name(async () => (await api.context.create({ import: ImportHandler.make({ resolver, hooks: [], codeCache: CodeCache.dir({ fs, path: 'c' }) }), graph: api.graph.root })).close());
        \\  const sourced = fs => name(async () => {
        \\    const handler = ImportHandler.make({ resolver, hooks: [] });
        \\    const ref = api.graph.root.declare(ModuleRecipe({ source: ModuleSource.file('main.js', { fs }), import: handler }));
        \\    await api.graph.root.load(ref);
        \\  });
        \\  // Every way a script can copy a grant: the copy has all of its properties and is not a grant, because
        \\  // the host's secret on the real object cannot be read, copied, cloned, spread, proxied or inherited.
        \\  const copies = grant => [
        \\    { kind: grant.kind, id: grant.id },
        \\    Object.freeze({ kind: grant.kind, id: grant.id, errno: grant.errno }),
        \\    { ...grant },
        \\    Object.assign({}, grant),
        \\    Object.defineProperties({}, Object.getOwnPropertyDescriptors(grant)),
        \\    Object.freeze(Object.defineProperties({}, Object.getOwnPropertyDescriptors(grant))),
        \\    Object.create(grant),
        \\    new Proxy(grant, {}),
        \\    new Proxy(grant, { getOwnPropertyDescriptor: (target, key) => Reflect.getOwnPropertyDescriptor(target, key), get: (target, key) => target[key] }),
        \\  ];
        \\  out.forged = await Promise.all([...copies(real), ...copies(remote)].map(hooked));
        \\  out.forgedJson = await Promise.all(copies(real).map(jsoned));
        \\  out.forgedCache = await Promise.all(copies(rw).map(cached));
        \\  out.forgedSource = await Promise.all(copies(real).map(sourced));
        \\  out.notObjects = [1, 'sync', () => {}, 0n].map(value => { try { fsProvider({ fs: value, read: 'copy' }); return 'ok'; } catch (e) { return e.name; } });
        \\  // A real grant still works in each place, sync or async.
        \\  out.real = [await hooked(real), await jsoned(real), await cached(rw), await hooked(remote)];
        \\  // An async grant cannot be a cache directory (the cache is written with the host's own file calls).
        \\  out.asyncCache = await cached(remote);
        \\  // A grant without write access cannot be a cache directory either.
        \\  out.readOnlyCache = await cached(real);
        \\  // Subclasses, prototypes and clones of a real grant are not grants either.
        \\  class Sub { constructor(grant) { return Object.defineProperties(Object.create(grant), { kind: { value: grant.kind }, id: { value: grant.id } }); } }
        \\  class Derived extends Object { constructor(grant) { super(); Object.defineProperties(this, Object.getOwnPropertyDescriptors(grant)); } }
        \\  const clone = grant => { try { return structuredClone(grant); } catch (e) { return { ...grant, cloneFailed: e.name }; } };
        \\  out.exotic = await Promise.all([real, remote].flatMap(grant => [new Sub(grant), new Derived(grant), Object.setPrototypeOf({ kind: grant.kind, id: grant.id }, grant), clone(grant)]).map(hooked));
        \\  // Closing the io runtime ends the async grants opened on it: the host refuses them.
        \\  await io.close();
        \\  out.closedAsync = await hooked(remote);
        \\  out.stillSync = await hooked(real);
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.forged.length === 18 && report.forged.every(n => n === 'InvalidInput') && report.forgedCache.every(n => n === 'InvalidInput')");
    try check(fx.scope, "report.forgedJson.every(n => n === 'InvalidInput') && report.forgedSource.every(n => n === 'InvalidInput')");
    try check(fx.scope, "report.notObjects.every(n => n === 'InvalidInput') && report.real.every(n => n === 'ok') && report.asyncCache === 'InvalidInput' && report.readOnlyCache === 'PermissionDenied'");
    try check(fx.scope, "report.exotic.length === 8 && report.exotic.every(n => n === 'InvalidInput') && report.closedAsync === 'InvalidInput' && report.stillSync === 'ok'");
}

test "graph: graph.exports(ref) is the live namespace of the context: no copy, every export type, bindings follow" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative } from 'origine:@std/graph/resolve/layers';
        \\import { fromLoader } from 'origine:@std/graph/providers';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const handler = ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [fromLoader(() => '')] });
        \\  const make = (text, name) => api.graph.root.declare(ModuleRecipe({ source: ModuleSource.text(text), import: handler, name }));
        \\  const ctx = await api.context.create({ graph: api.graph.root, import: handler });
        \\  const good = make("export let n = 41; export function inc() { n++; return n; } export const obj = { tag: 'a', list: [1] }; export const getTag = () => obj.tag; export const m = new Map([[1, 2]]); export const t = new Uint8Array(2); export const g = { get x() { return 7; } }; export class Box { static kind = 'box'; } export default 5;", 'good.js');
        \\  const code = f => { try { f(); return 'ok'; } catch (e) { return e.name; } };
        \\  out.before = code(() => api.graph.root.exports(good));
        \\  await api.graph.root.evaluate(good, ctx);
        \\  const ns = api.graph.root.exports(good);
        \\  // The namespace of the context itself: the same object each call, no prototype of this realm.
        \\  out.same = ns === api.graph.root.exports(good) && Object.keys(ns).join(',') === 'Box,default,g,getTag,inc,m,n,obj,t';
        \\  // Bindings are live: the module changes `n`, and the namespace shows it.
        \\  out.live = ns.n + ',' + ns.inc() + ',' + ns.n;
        \\  // Nothing is copied or frozen: the objects are the context's own, in another realm, and stay writable.
        \\  out.shared = ns.obj.constructor !== Object && !Object.isFrozen(ns.obj) && !Object.isFrozen(ns.inc);
        \\  ns.obj.tag = 'b'; ns.obj.list.push(2);
        \\  out.mutated = ns.getTag() + ',' + ns.obj.list.length;
        \\  // Every export type works: a Map, a typed array, an accessor, a class and the default.
        \\  out.types = [ns.m.get(1), ns.t.length, ns.g.x, ns.Box.kind, ns.default].join(',');
        \\  out.map = Object.prototype.toString.call(ns.m) + ':' + (ns.m instanceof Map);
        \\  // A reference that is not evaluated has no namespace; neither has one of a closed context.
        \\  out.declared = code(() => api.graph.root.exports(make('export {}', 'd.js')));
        \\  ctx.close();
        \\  out.closed = code(() => api.graph.root.exports(good));
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.before === 'InvalidInput' && report.same && report.live === '41,42,42' && report.shared && report.mutated === 'b,2'");
    try check(fx.scope, "report.types === '2,2,7,box,5' && report.map === '[object Map]:false' && report.declared === 'InvalidInput' && report.closed === 'StaleHandle'");
}

test "graph: load() goes one level at a time, through dependency references, three levels deep" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative } from 'origine:@std/graph/resolve/layers';
        \\import { fromLoader } from 'origine:@std/graph/providers';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const sources = {
        \\    'b.js': "import './c.js'; export const b = 1;",
        \\    'c.js': "import './d.js'; import './e.js'; export const c = 2;",
        \\    'd.js': "export const d = 3;",
        \\    'e.js': "import './b.js'; export const e = 4;",
        \\  };
        \\  const handler = ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [fromLoader(id => sources[id])] });
        \\  const root = api.graph.root.declare(ModuleRecipe({ source: ModuleSource.text("import './b.js'; export const a = 0;"), import: handler, name: 'a.js' }));
        \\  await api.graph.root.load(root);
        \\  const names = ref => api.graph.root.requests(ref).map(r => r.reference.name + '/' + r.reference.status).join(',');
        \\  out.level1 = names(root);
        \\  const b = api.graph.root.requests(root)[0].reference;
        \\  out.beforeB = api.graph.root.requests(b) === undefined;
        \\  // A dependency loads the same way, and a second call (also one that overlaps the first) shares it.
        \\  await Promise.all([api.graph.root.load(b), api.graph.root.load(b)]);
        \\  out.level2 = names(b);
        \\  const c = api.graph.root.requests(b)[0].reference;
        \\  await api.graph.root.load(c);
        \\  out.level3 = names(c);
        \\  const e = api.graph.root.requests(c)[1].reference;
        \\  await api.graph.root.load(e);
        \\  out.level4 = names(e);
        \\  // d imports nothing; loading it twice changes nothing.
        \\  const d = api.graph.root.requests(c)[0].reference;
        \\  await api.graph.root.load(d);
        \\  await api.graph.root.load(d);
        \\  out.leaf = names(d) === '' && d.status === 'loaded';
        \\  out.status = [root, b, c, e].map(ref => ref.status).join(',');
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.level1 === 'b.js/declared' && report.beforeB && report.level2 === 'c.js/declared' && report.level3 === 'd.js/declared,e.js/declared' && report.level4 === 'b.js/declared'");
    try check(fx.scope, "report.leaf && report.status === 'loaded,loaded,loaded,loaded'");
}

test "graph: an async fs grant serves source files on its io runtime without entering JS" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler, ImportHook } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative } from 'origine:@std/graph/resolve/layers';
        \\import { fsProvider, json } from 'origine:@std/graph/providers';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create({});
        \\  const src = await api.fs.requestAsync({ handle: 'plain', io, access: 'r' });
        \\  const graph = api.graph.create();
        \\  const handler = ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [json({ fs: src }), fsProvider({ fs: src, read: 'copy' })] });
        \\  out.native = handler.native;
        \\  const ctx = await api.context.create({ import: handler, graph });
        \\  const main = graph.declare(ModuleRecipe({ source: ModuleSource.file('main.js', { fs: src }), import: handler }));
        \\  await graph.load(main);
        \\  out.requests = graph.requests(main).map(r => r.specifier + '=' + r.reference.name + '/' + r.reference.status).join(',');
        \\  await graph.evaluate(main, ctx);
        \\  out.status = main.status;
        \\  out.imported = (await ctx.import('./dep.js')).status;
        \\  const run = async (g, c, text, name) => g.evaluate(g.declare(ModuleRecipe({ source: ModuleSource.text(text), import: handler, name })), c).then(() => 'ok', e => e.message);
        \\  out.missing = await run(graph, ctx, "import './nope.js'", 'm1');
        \\  const wo = await api.fs.requestAsync({ handle: 'plain', io, access: 'w' });
        \\  // Its own handler: one that shared the cache of `handler` would take dep.js from `ctx`, which read it with more authority.
        \\  const narrower = ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [json({ fs: wo }), fsProvider({ fs: wo, read: 'copy' })] });
        \\  const wctx = await api.context.create({ import: narrower, graph });
        \\  out.writeOnly = await graph.evaluate(graph.declare(ModuleRecipe({ source: ModuleSource.text("import './dep.js'"), import: narrower, name: 'm3' })), wctx).then(() => 'ok', e => e.message);
        \\  out.accept = await (async () => {
        \\    const accepting = ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [async () => ImportHook.accept({ fs: src })] });
        \\    const actx = await api.context.create({ import: accepting, graph });
        \\    return graph.evaluate(graph.declare(ModuleRecipe({ source: ModuleSource.text("import { k } from './dep.js'; globalThis.k2 = k;"), import: accepting, name: 'm4' })), actx).then(() => 'ok', e => e.message);
        \\  })();
        \\  await io.close();
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "dep.js", .data = "export const k = 41;" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "data.json", .data = "{\"v\": 1}" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "main.js", .data = "import { k } from './dep.js'; import data from './data.json' with { type: 'json' }; globalThis.answer = k + data.v;" });
    try fx.run();
    try check(fx.scope, "report.native === true && report.status === 'evaluated' && report.imported === 'evaluated'");
    try check(fx.scope, "report.requests === './dep.js=dep.js/declared,./data.json=data.json/declared'");
    try check(fx.scope, "report.missing.includes('NotFound') && report.writeOnly.includes('PermissionDenied')");
    try check(fx.scope, "report.accept === 'ok'");
    try check(fx.rt.scopes.items[1], "answer === 42");
    // The native handler and the accept hook's own read: only the JS hook (accept) entered the driver.
    try t.expectEqual(@as(usize, 1), fx.host.driver_calls);
}

test "graph: link makes a context use the module of another context itself: live bindings, same objects" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler, ImportHook } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const graph = api.graph.root;
        \\  const layer = ({ specifier }) => (specifier.startsWith('link:') ? { id: specifier } : undefined);
        \\  const leaf = ImportHandler.make({ resolver: ImportResolver.layered().layer(layer), hooks: [] });
        \\  const a = await api.context.create({ graph: api.graph.root, import: leaf });
        \\  const source = graph.declare(ModuleRecipe({ source: ModuleSource.text('export let n = 1; export function inc() { n++; } export const obj = { tag: "a" };'), import: leaf, name: 'a-mod' }));
        \\  out.unbound = await (async () => { try { ImportHook.link(source); return 'made'; } catch (e) { return e.name; } })();
        \\  await graph.evaluate(source, a);
        \\  const linker = ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(layer),
        \\    hooks: [async r => (r.id === 'link:shared' ? ImportHook.link(source) : ImportHook.next())],
        \\  });
        \\  const b = await api.context.create({ graph: api.graph.root, import: linker });
        \\  const run = (name, text) => graph.evaluate(graph.declare(ModuleRecipe({ source: ModuleSource.text(text), import: linker, name })), b).then(() => 'ok', e => e.message);
        \\  out.shared = await run('s', "import { n, inc, obj } from 'link:shared'; inc(); obj.tag = 'b'; globalThis.shared = [n, obj.tag, Object.isFrozen(obj), Object.isFrozen(inc), obj.constructor === Object];");
        \\  // The exporter sees what the importer did: the same objects, nothing copied.
        \\  out.seen = api.graph.root.exports(source).obj.tag + ',' + api.graph.root.exports(source).n;
        \\  const stale = graph.declare(ModuleRecipe({ source: ModuleSource.text('export const z = 1;'), import: leaf, name: 'declared-only' }));
        \\  const unbound = ImportHandler.make({ resolver: ImportResolver.layered().layer(layer), hooks: [async () => ImportHook.link(stale)] });
        \\  const c = await api.context.create({ graph: api.graph.root, import: unbound });
        \\  out.notBound = await graph.evaluate(graph.declare(ModuleRecipe({ source: ModuleSource.text("import 'link:x'"), import: unbound, name: 'u' })), c).then(() => 'ok', e => e.message);
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.unbound === 'made' && report.shared === 'ok' && report.seen === 'b,2' && report.notBound.includes('InvalidInput')");
    try check(fx.rt.scopes.items[2], "shared[0] === 2 && shared[1] === 'b' && shared[2] === false && shared[3] === false && shared[4] === false");
}

test "graph: ImportHook.exports gives the importer a synthetic module of the values, shared as they are" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler, ImportHook } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const code = f => { try { f(); return 'ok'; } catch (e) { return e.name; } };
        \\  // The verdict: a snapshot of own data properties; accessors and non-objects are InvalidInput when it is built.
        \\  const verdict = ImportHook.exports({ a: 1 });
        \\  out.verdict = verdict.kind === 'exports' && verdict.values.a === 1 && Object.isFrozen(verdict.values);
        \\  out.invalid = [code(() => ImportHook.exports({ get x() { return 1; } })), code(() => ImportHook.exports(null)), code(() => ImportHook.exports(() => {})), code(() => ImportHook.exports(1))].join(',');
        \\  const shared = { tag: 'a', list: [1] };
        \\  let pinned = 0;
        \\  const values = { answer: 42, shared, bump: () => ++pinned, default: () => 'dflt', 'odd name': 7 };
        \\  const layer = ({ specifier }) => (specifier.startsWith('values:') || specifier.startsWith('origine:') ? { id: specifier } : undefined);
        \\  const handler = ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(layer),
        \\    hooks: [async r => (r.id === 'values:x' ? ImportHook.exports(values) : r.id === 'origine:evil' ? ImportHook.exports({ x: 1 }) : ImportHook.next())],
        \\  });
        \\  const ctx = await api.context.create({ graph: api.graph.root, import: handler });
        \\  const run = (name, text) => api.graph.root.evaluate(api.graph.root.declare(ModuleRecipe({ source: ModuleSource.text(text), import: handler, name })), ctx).then(() => 'ok', e => e.message);
        \\  out.ok = await run('m', "import dflt, { answer, shared, bump, 'odd name' as odd } from 'values:x'; import * as ns from 'values:x'; globalThis.got = [answer, dflt(), bump(), odd, Object.keys(ns).sort().join('|'), Object.isFrozen(shared), shared.constructor === Object, Object.isFrozen(bump)]; globalThis.sharedInside = shared;");
        \\  // Nothing was copied or frozen: the importer holds the caller's own objects.
        \\  shared.tag = 'z';
        \\  out.same = await run('n', "import { shared } from 'values:x'; globalThis.seen = shared.tag + shared.list.length;");
        \\  out.frozen = Object.isFrozen(shared) || Object.isFrozen(values.bump);
        \\  out.pinned = pinned;
        \\  // An origine: id is never served by JS, not even this way.
        \\  out.origine = await run('o', "import { x } from 'origine:evil';");
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.verdict === true && report.invalid === 'InvalidInput,InvalidInput,InvalidInput,InvalidInput' && report.ok === 'ok' && report.same === 'ok'");
    try check(fx.scope, "report.frozen === false && report.pinned === 1 && report.origine.includes('PermissionDenied')");
    try check(fx.rt.scopes.items[1], "got.join(',') === '42,dflt,1,7,answer|bump|default|odd name|shared,false,false,false' && sharedInside.tag === 'z' && seen === 'z1'");
}

test "data: snapshot copies plain data, deepFreeze freezes in place, and they compose with the live namespace" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { snapshot, deepFreeze } from 'origine:@std/data';
        \\import { IoError } from 'origine:@std/errors';
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative } from 'origine:@std/graph/resolve/layers';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const code = f => { try { f(); return 'ok'; } catch (e) { return e instanceof IoError ? e.name : 'other:' + e.name; } };
        \\  const text = f => { try { f(); return ''; } catch (e) { return e.message; } };
        \\  // snapshot: a copy in this realm; the source is not touched; cycles and shared references are kept.
        \\  const shared = { n: 1 };
        \\  const src = { a: [1, { b: shared }], c: shared, d: 'x', e: 10n, f: null, g: undefined, [Symbol('s')]: 1, nul: Object.assign(Object.create(null), { z: 1 }) };
        \\  src.self = src;
        \\  const copy = snapshot(src);
        \\  out.copy = copy !== src && copy.a !== src.a && copy.self === copy && copy.a[1].b === copy.c && copy.c !== shared && copy.e === 10n && copy.g === undefined && 'g' in copy && Object.getPrototypeOf(copy.nul) === null && Object.getOwnPropertySymbols(copy).length === 0;
        \\  out.defaultNotFrozen = !Object.isFrozen(copy) && !Object.isFrozen(copy.a) && !Object.isFrozen(snapshot(src, {})) && !Object.isFrozen(snapshot(src, { deepFreeze: false }));
        \\  const frozen = snapshot(src, { deepFreeze: true });
        \\  out.frozen = Object.isFrozen(frozen) && Object.isFrozen(frozen.a) && Object.isFrozen(frozen.a[1].b) && !Object.isFrozen(src) && !Object.isFrozen(shared);
        \\  out.primitive = snapshot(5) === 5 && snapshot('s') === 's' && snapshot(null) === null;
        \\  // What cannot be copied is Unsupported and says where; nothing is shared silently.
        \\  class Point { constructor() { this.x = 1; } }
        \\  const bad = {
        \\    fn: { f: () => 1 }, cls: { k: Point }, map: { m: new Map() }, set: { s: new Set() }, typed: { t: new Uint8Array(1) },
        \\    promise: { p: Promise.resolve() }, inst: { i: new Point() }, accessor: { get g() { return 1; } }, proxy: { p: new Proxy({}, {}) }, topFn: () => 1,
        \\  };
        \\  out.bad = Object.entries(bad).map(([k, v]) => k + ':' + code(() => snapshot(v))).join(',');
        \\  out.path = text(() => snapshot({ a: [{ b: new Map() }] })).includes('$.a.0.b');
        \\  out.options = [code(() => snapshot({}, null)), code(() => snapshot({}, { deepFreeze: 'yes' }))].join(',');
        \\  // deepFreeze: in place, returns its argument, reaches data, functions, classes and the prototype chain.
        \\  class Box { static kind = 'box'; get() { return 1; } }
        \\  const target = { list: [1, { deep: true }], fn() { return 2; }, Box, inst: new Box() };
        \\  out.same = deepFreeze(target) === target && deepFreeze(5) === 5 && deepFreeze(null) === null;
        \\  out.reached = Object.isFrozen(target) && Object.isFrozen(target.list) && Object.isFrozen(target.list[1]) && Object.isFrozen(target.fn) && Object.isFrozen(Box) && Object.isFrozen(Box.prototype);
        \\  out.refused = [code(() => deepFreeze({ m: new Map() })), code(() => deepFreeze({ t: new Uint8Array(1) })), code(() => deepFreeze({ get g() { return 1; } })), code(() => deepFreeze({ p: new Proxy({}, {}) })), code(() => deepFreeze({ p: Promise.resolve() }))].join(',');
        \\  // Frozen in place means the owner's own writes fail too.
        \\  const owned = { n: 1 };
        \\  deepFreeze(owned);
        \\  out.ownerFails = code(() => { owned.n = 2; });
        \\  // Composed with the live namespace of another context: data is copied, a function is refused.
        \\  const handler = ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [] });
        \\  const ctx = await api.context.create({ graph: api.graph.root, import: handler });
        \\  const ref = api.graph.root.declare(ModuleRecipe({ source: ModuleSource.text('export const data = { n: 1, list: [1, 2] }; export const bump = () => 1;'), import: handler, name: 'a.js' }));
        \\  await api.graph.root.evaluate(ref, ctx);
        \\  const ns = api.graph.root.exports(ref);
        \\  const data = snapshot(ns.data, { deepFreeze: true });
        \\  out.composed = data.n === 1 && data.list.length === 2 && data.constructor === Object && Object.isFrozen(data) && ns.data.constructor !== Object && !Object.isFrozen(ns.data);
        \\  out.nsFn = code(() => snapshot(ns)) + ':' + text(() => snapshot(ns)).includes('$.bump');
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.copy === true && report.defaultNotFrozen === true && report.frozen === true && report.primitive === true && report.path === true");
    try check(fx.scope, "report.bad === 'fn:Unsupported,cls:Unsupported,map:Unsupported,set:Unsupported,typed:Unsupported,promise:Unsupported,inst:Unsupported,accessor:Unsupported,proxy:Unsupported,topFn:Unsupported' && report.options === 'InvalidInput,InvalidInput'");
    try check(fx.scope, "report.same === true && report.reached === true");
    try check(fx.scope, "report.refused.split(',')[0] === 'Unsupported' && report.refused.split(',')[1] === 'Unsupported'");
    try check(fx.scope, "report.refused.split(',')[2] === 'ok'");
    try check(fx.scope, "report.refused.split(',')[3] === 'Unsupported' && report.refused.split(',')[4] === 'Unsupported'");
    try check(fx.scope, "report.ownerFails === 'other:TypeError'");
    try check(fx.scope, "report.composed === true && report.nsFn === 'Unsupported:true'");
}

test "context: string-to-code is off by default, per realm, and security.codeGeneration opts a realm in" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler, ImportHook } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { deepFreeze } from 'origine:@std/data';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const code = f => { try { return String(f()); } catch (e) { return e.name; } };
        \\  const layer = ({ specifier }) => (specifier.startsWith('link:') ? { id: specifier } : undefined);
        \\  const plain = ImportHandler.make({ resolver: ImportResolver.layered().layer(layer), hooks: [] });
        \\  const make = (security, handler = plain) => api.context.create({ graph: api.graph.root, import: handler, ...(security === undefined ? {} : { security }) });
        \\  const run = (ctx, handler, name, text) => api.graph.root.evaluate(api.graph.root.declare(ModuleRecipe({ source: ModuleSource.text(text), import: handler, name })), ctx).then(() => 'ok', e => e.message);
        \\  // (a) every string-to-code door is shut by default; (c) security.codeGeneration opens them in that realm only.
        \\  const probe = "const t = f => { try { return typeof f(); } catch (e) { return e.name; } }; globalThis.doors = [t(() => eval('1')), t(() => new Function('return 1')), t(() => (async () => {}).constructor('return 1')), t(() => (function* () {}).constructor('return 1')), t(() => (async function* () {}).constructor('return 1'))].join(','); globalThis.message = (() => { try { eval('1'); } catch (e) { return e.message; } })(); globalThis.wasm = t(() => new WebAssembly.Module(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]))); globalThis.marker = 'closed';";
        \\  const closed = await make();
        \\  const explicit = await make({ codeGeneration: false });
        \\  const empty = await make({});
        \\  const open = await make({ codeGeneration: true });
        \\  for (const [name, ctx] of [['closed', closed], ['explicit', explicit], ['empty', empty], ['open', open]]) out['probe_' + name] = await run(ctx, plain, 'probe-' + name, probe.replace("'closed'", "'" + name + "'"));
        \\  out.badSecurity = (await Promise.all([make(null), make(1), make({ codeGeneration: 'yes' }), make({ allow: true }), make({ codeGeneration: true, extra: 1 }), make({ get codeGeneration() { return true; } })].map(p => p.then(() => 'ok', e => e.name + ':' + e.message.includes('security')))))
        \\    .join(',');
        \\  // (b) a function shared out of a realm keeps that realm's setting: V8 checks the realm the constructor or `eval`
        \\  // belongs to. Called directly from another realm, V8 also refuses on the security tokens (`fn.constructor(...)` is a
        \\  // TypeError, `eval` returns undefined) whether or not the realm opted in; run from a microtask the call is made in the
        \\  // function's own realm and only the flag decides. (c) So a realm that opted in can be made to compile strings.
        \\  const a = await make();
        \\  const a2 = await make({ codeGeneration: true });
        \\  const exporter = (text, name) => ModuleRecipe({ source: ModuleSource.text(text), import: plain, name });
        \\  const refA = api.graph.root.declare(exporter("export const f = () => 1; export const e = eval; globalThis.marker = 'A';", 'exporter-a'));
        \\  const refA2 = api.graph.root.declare(exporter("export const f = () => 1; export const e = eval; globalThis.marker = 'A2';", 'exporter-a2'));
        \\  await api.graph.root.evaluate(refA, a);
        \\  await api.graph.root.evaluate(refA2, a2);
        \\  const nsA = api.graph.root.exports(refA), nsA2 = api.graph.root.exports(refA2);
        \\  const direct = fn => { try { return String(fn.constructor('return globalThis.marker')()); } catch (e) { return e.name + ':' + e.message; } };
        \\  const directEval = fn => { try { return String(fn('globalThis.marker')); } catch (e) { return e.name; } };
        \\  const micro = async fn => { try { return String((await Promise.resolve('return globalThis.marker').then(fn.constructor))()); } catch (e) { return e.name; } };
        \\  const microEval = async fn => { try { return String(await Promise.resolve('globalThis.marker').then(fn)); } catch (e) { return e.name; } };
        \\  out.hostDirect = [direct(nsA.f), direct(nsA2.f), directEval(nsA.e), directEval(nsA2.e)].join(',');
        \\  out.hostMicro = (await Promise.all([micro(nsA.f), micro(nsA2.f), microEval(nsA.e), microEval(nsA2.e)])).join(',');
        \\  const importer = ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(layer),
        \\    hooks: [async r => (r.id === 'link:a' ? ImportHook.link(refA) : r.id === 'link:a2' ? ImportHook.link(refA2) : r.id === 'link:ex' ? ImportHook.exports({ f: nsA.f, e: nsA.e, f2: deepFreeze(nsA2.f), e2: nsA2.e }) : ImportHook.next())],
        \\  });
        \\  const b = await make(undefined, importer);
        \\  const reach = "const micro = async fn => { try { return String((await Promise.resolve('return globalThis.marker').then(fn.constructor))()); } catch (e) { return e.name; } }; const microEval = async fn => { try { return String(await Promise.resolve('globalThis.marker').then(fn)); } catch (e) { return e.name; } }; const direct = fn => { try { return String(fn.constructor('return globalThis.marker')()); } catch (e) { return e.name; } };";
        \\  out.link = await run(b, importer, 'via-link', reach + "import { f, e } from 'link:a'; import { f as f2, e as e2 } from 'link:a2'; globalThis.linkDirect = [direct(f), direct(f2)].join(','); globalThis.linkMicro = (await Promise.all([micro(f), micro(f2), microEval(e), microEval(e2)])).join(',');");
        \\  out.exportsVerdict = await run(b, importer, 'via-exports', reach + "import { f, e, f2, e2 } from 'link:ex'; globalThis.exportsMicro = (await Promise.all([micro(f), micro(f2), microEval(e), microEval(e2)])).join(',');");
        \\  // A function from the init realm (preload values) is in a realm that is shut too.
        \\  const indirect = eval;
        \\  const pre = await api.context.create({ graph: api.graph.root, import: plain, preload: [{ source: "(values) => { globalThis.initF = values.f; globalThis.initE = values.e; }", values: { f: () => 1, e: indirect } }] });
        \\  out.preloadMicro = await run(pre, plain, 'init-fns', "const micro = async fn => { try { return String((await Promise.resolve('return 1').then(fn.constructor))()); } catch (e) { return e.name; } }; globalThis.fromInit = [await micro(initF), await Promise.resolve('1').then(initE).then(String, e => e.name)].join(',');");
        \\  globalThis.keep = { closed, explicit, empty, open, a, a2, b, pre };
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.rt.scopes.items[1], "doors === 'EvalError,EvalError,EvalError,EvalError,EvalError' && message === 'Code generation from strings disallowed for this context' && marker === 'closed'");
    // WebAssembly compiles bytes, not strings: the flag does not touch it, and wasm code cannot reach the realm's globals.
    try check(fx.rt.scopes.items[1], "wasm === 'object'");
    try check(fx.rt.scopes.items[2], "doors === 'EvalError,EvalError,EvalError,EvalError,EvalError' && marker === 'explicit'");
    try check(fx.rt.scopes.items[3], "doors === 'EvalError,EvalError,EvalError,EvalError,EvalError' && marker === 'empty'");
    try check(fx.rt.scopes.items[4], "doors === 'number,function,function,function,function' && message === undefined && marker === 'open'");
    try check(fx.scope, "report.probe_closed === 'ok' && report.probe_explicit === 'ok' && report.probe_empty === 'ok' && report.probe_open === 'ok'");
    try check(fx.scope, "report.badSecurity === 'InvalidInput:true,InvalidInput:true,InvalidInput:true,InvalidInput:true,InvalidInput:true,InvalidInput:true'");
    try check(fx.scope, "report.hostDirect === 'TypeError:no access,TypeError:no access,undefined,undefined'");
    try check(fx.scope, "report.hostMicro === 'EvalError,A2,EvalError,A2'");
    try check(fx.scope, "report.link === 'ok' && report.exportsVerdict === 'ok' && report.preloadMicro === 'ok'");
    try check(fx.rt.scopes.items[7], "linkDirect === 'TypeError,TypeError' && linkMicro === 'EvalError,A2,EvalError,A2' && exportsMicro === 'EvalError,A2,EvalError,A2'");
    try check(fx.rt.scopes.items[8], "fromInit === 'EvalError,EvalError'");
}

test "graph: link refuses a module that is still evaluating and a failed import does not break later ones" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler, ImportHook } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative } from 'origine:@std/graph/resolve/layers';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  let parked;
        \\  const leaf = ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [] });
        \\  const a = await api.context.create({ graph: api.graph.root, import: leaf, preload: [{ source: '(values) => { globalThis.park = values.park; }', values: { park: resolve => { parked = resolve; } } }] });
        \\  const slow = api.graph.root.declare(ModuleRecipe({ source: ModuleSource.text('export const n = 1; await new Promise(r => park(r));'), import: leaf, name: 'slow' }));
        \\  const running = api.graph.root.evaluate(slow, a);
        \\  for (let i = 0; i < 1000 && parked === undefined; i++) await Promise.resolve();
        \\  out.status = slow.status;
        \\  const linker = ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(({ specifier }) => ({ id: specifier })),
        \\    hooks: [async r => (r.id === 'slow' ? ImportHook.link(slow) : ImportHook.next())],
        \\  });
        \\  const run = async (name, text) => api.graph.root.evaluate(api.graph.root.declare(ModuleRecipe({ source: ModuleSource.text(text), import: linker, name })), await api.context.create({ graph: api.graph.root, import: linker })).then(() => 'ok', e => e.message);
        \\  out.early = await run('early', "import { n } from 'slow';");
        \\  parked();
        \\  await running;
        \\  out.late = await run('late', "import { n } from 'slow'; globalThis.n = n;");
        \\  // A failed import leaves modules that were compiled but never instantiated in the table;
        \\  // a later successful import in the same context must not trip over them.
        \\  const ctx = await api.context.create({ graph: api.graph.root, import: linker });
        \\  const make = (name, text) => api.graph.root.declare(ModuleRecipe({ source: ModuleSource.text(text), import: linker, name }));
        \\  out.failed = await api.graph.root.evaluate(make('f1', "import 'nowhere'; import 'also-nowhere'"), ctx).then(() => 'ok', e => e.message);
        \\  out.after = await api.graph.root.evaluate(make('ok1', 'globalThis.fine = 1;'), ctx).then(() => 'ok', e => e.message);
        \\  out.imported = await ctx.import('slow').then(r => r.status, e => e.message);
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.status === 'evaluating' && report.early.includes('InvalidInput') && report.late === 'ok'");
    try check(fx.scope, "report.failed.includes('NotFound') && report.after === 'ok' && report.imported === 'evaluated'");
}

test "graph: native plans with oxc, json, import maps and accept never enter JS" {
    if (!m.Api.oxc.enabled) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler, ImportHook, MakeRecipe, Transform } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative, importMap } from 'origine:@std/graph/resolve/layers';
        \\import { fsProvider, json } from 'origine:@std/graph/providers';
        \\import { ts } from 'origine:@std/transformer/oxc';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const src = api.fs.requestSync({ handle: 'plain', access: 'r' });
        \\  const graph = api.graph.create();
        \\  const handler = ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(importMap({ imports: { dep: './dep.js' } })).layer(relative()),
        \\    hooks: [json({ fs: src }), fsProvider({ fs: src, read: 'mmap' })],
        \\    maker: MakeRecipe.inherit({ transformer: Transform.byExtension({ '.ts': ts() }) }),
        \\  });
        \\  out.native = handler.native + ':' + handler.plan.map(e => e.kind).join(',');
        \\  const ctx = await api.context.create({ import: handler, graph });
        \\  const main = graph.declare(ModuleRecipe({ source: ModuleSource.file('main.ts', { fs: src }).withTransformer(ts()), import: handler }));
        \\  out.recipeNative = main.status;
        \\  await graph.load(main);
        \\  out.requests = graph.requests(main).map(r => r.specifier + '=' + r.reference.name).join(',');
        \\  await graph.evaluate(main, ctx);
        \\  out.evaluated = main.status;
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.tmp.dir.createDirPath(t.io, "app:");
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "app:/dep.js", .data = "export const k = 1;" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "a.ts", .data = "export const n: number = 40;" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "data.json", .data = "{\"k\": 1}" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "main.ts", .data = "import { n } from './a.ts'; import { k } from 'dep'; import data from './data.json' with { type: 'json' }; const total: number = n + k + data.k; globalThis.answer = total;" });
    try fx.run();
    try check(fx.scope, "report.native === 'true:native,native,native,native,native,native,native'");
    try check(fx.scope, "report.requests === './a.ts=a.ts,dep=app:/dep.js,./data.json=data.json' && report.evaluated === 'evaluated'");
    try check(fx.rt.scopes.items[1], "answer === 42");
    try t.expectEqual(@as(usize, 0), fx.host.driver_calls);
}

test "graph: a second reference of one recipe reuses the code cache; dir and custom persist it" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative } from 'origine:@std/graph/resolve/layers';
        \\import { fsProvider } from 'origine:@std/graph/providers';
        \\import { CodeCache } from 'origine:@std/graph/cache';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const src = api.fs.requestSync({ handle: 'plain', access: 'r' });
        \\  const graph = api.graph.create();
        \\  // A handler per context: contexts of one handler share its modules and would compile nothing the second time.
        \\  const make = codeCache => ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [fsProvider({ fs: src, read: 'copy' })], codeCache });
        \\  const run = async cache => {
        \\    const one = make(cache);
        \\    const a = await api.context.create({ import: one, graph });
        \\    await graph.evaluate(graph.declare(ModuleRecipe({ source: ModuleSource.file('main.js', { fs: src }), import: one })), a);
        \\    const first = await cache.flush();
        \\    const two = make(cache);
        \\    const b = await api.context.create({ import: two, graph });
        \\    await graph.evaluate(graph.declare(ModuleRecipe({ source: ModuleSource.file('main.js', { fs: src }), import: two })), b);
        \\    return [first, await cache.flush()];
        \\  };
        \\  out.memory = (await run(CodeCache.memory())).join(':');
        \\  out.none = (await run(CodeCache.none)).join(':');
        \\  const stored = [];
        \\  const custom = CodeCache.custom({ load: () => undefined, store: (key, bytes) => { stored.push(key.id + ':' + (bytes instanceof Uint8Array) + ':' + (bytes.length > 0)); } });
        \\  out.custom = (await run(custom)).join(':');
        \\  out.stored = stored.join(',');
        \\  const rw = api.fs.requestSync({ handle: 'plain', access: 'rw' });
        \\  out.dir = (await run(CodeCache.dir({ fs: rw, path: 'kept' }))).join(':');
        \\  out.dirAgain = (await run(CodeCache.dir({ fs: rw, path: 'kept' }))).join(':');
        \\  // A closed cache is no longer named.
        \\  const closing = CodeCache.memory();
        \\  await run(closing);
        \\  closing.close();
        \\  out.closed = await run(closing).then(() => 'ok', e => e.name);
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "dep.js", .data = "export function add(a, b) { return a + b; }" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "main.js", .data = "import { add } from './dep.js'; globalThis.sum = add(20, 22);" });
    try fx.run();
    // Two modules compile without a cache in the first context; the second one finds both cached.
    try check(fx.scope, "report.memory === '2:0'");
    try check(fx.scope, "report.none === '0:0'");
    try check(fx.scope, "report.custom === '2:0' && report.stored.split(',').length === 2 && report.stored.includes('dep.js:true:true')");
    try check(fx.scope, "report.dir === '2:0' && report.dirAgain === '0:0' && report.closed === 'InvalidInput'");
    // The files sit directly in the directory the program chose.
    var cache_dir = try fx.tmp.dir.openDir(t.io, "kept", .{ .iterate = true });
    defer cache_dir.close(t.io);
    var seen: usize = 0;
    var it = cache_dir.iterate();
    while (try it.next(t.io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".v8-code-cache")) seen += 1;
    }
    try t.expect(seen >= 2);
}

test "graph: CodeCache.custom loads before a module compiles and treats anything but its own blob as a miss" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative } from 'origine:@std/graph/resolve/layers';
        \\import { fsProvider } from 'origine:@std/graph/providers';
        \\import { CodeCache } from 'origine:@std/graph/cache';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const src = api.fs.requestSync({ handle: 'plain', access: 'r' });
        \\  const graph = api.graph.create();
        \\  const make = codeCache => ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [fsProvider({ fs: src, read: 'copy' })], codeCache });
        \\  const store = new Map();
        \\  const calls = [];
        \\  const keyOf = k => k.id + '@' + k.hash;
        \\  const custom = answer => CodeCache.custom({
        \\    load: async (key, source) => { calls.push('load:' + key.id + ':' + key.hash.length + ':' + (typeof source === 'string' && source.includes('add'))); return answer ? answer(key) : store.get(keyOf(key)); },
        \\    store: async (key, blob) => { store.set(keyOf(key), blob); },
        \\  });
        \\  const run = async codeCache => {
        \\    const handler = make(codeCache);
        \\    const ctx = await api.context.create({ import: handler, graph });
        \\    await graph.evaluate(graph.declare(ModuleRecipe({ source: ModuleSource.file('main.js', { fs: src }), import: handler })), ctx);
        \\    return codeCache.flush();
        \\  };
        \\  out.first = await run(custom());
        \\  out.stored = store.size;
        \\  out.loads = calls.filter(c => c.startsWith('load:')).sort().join(',');
        \\  out.hit = await run(custom());
        \\  // every key gets the same blob: only the module it was made for takes it, the other one is a miss
        \\  const first = [...store.values()][0];
        \\  out.wrong = await run(custom(() => first));
        \\  out.throwing = await run(custom(() => { throw new Error('store down'); }));
        \\  out.junk = await run(custom(() => new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8])));
        \\  out.notBytes = await run(custom(() => 'text'));
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "dep.js", .data = "export function add(a, b) { return a + b; }" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "main.js", .data = "import { add } from './dep.js'; globalThis.sum = add(20, 22);" });
    try fx.run();
    try check(fx.scope, "report.first === 1 + 1 && report.stored === 2 && report.hit === 0");
    // load sees the module id, a 64 hex digit key and the source text; main.js has no `add` call text... it does: 'add'.
    try check(fx.scope, "report.loads.startsWith('load:dep.js:64:true,load:main.js:64:true')");
    try check(fx.scope, "report.wrong === 1 && report.throwing === 2 && report.junk === 2 && report.notBytes === 2");
}

test "graph: CodeCache.dir keeps the files of virtual and escaping module ids inside its directory" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler, ImportHook } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { CodeCache } from 'origine:@std/graph/cache';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const rw = api.fs.requestSync({ handle: 'plain', access: 'rw' });
        \\  const graph = api.graph.create();
        \\  const cache = CodeCache.dir({ fs: rw, path: 'cache' });
        \\  const handler = ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(({ specifier }) => ({ id: specifier })),
        \\    hooks: [async r => ImportHook.source(ModuleSource.text(`export const id = ${JSON.stringify(r.id)}; export function f() { return 1; }`))],
        \\    codeCache: cache,
        \\  });
        \\  const ids = ['app:/x.js', '../../escape.js', 'https://example.com/a/b.js', 'mem:y'];
        \\  const run = async () => {
        \\    const ctx = await api.context.create({ import: handler, graph });
        \\    for (const id of ids) await ctx.import(id);
        \\    return cache.flush();
        \\  };
        \\  out.first = await run();
        \\  out.second = await run();
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.run();
    // Four modules compile without a cache once, and a second context finds all four on disk.
    try check(fx.scope, "report.first === 4 && report.second === 0");
    var cache_dir = try fx.tmp.dir.openDir(t.io, "cache", .{ .iterate = true });
    defer cache_dir.close(t.io);
    var files: usize = 0;
    var it = cache_dir.iterate();
    while (try it.next(t.io)) |entry| {
        try t.expect(std.mem.endsWith(u8, entry.name, ".v8-code-cache"));
        files += 1;
    }
    try t.expectEqual(@as(usize, 4), files);
    // Nothing else appeared in the working directory or above it.
    var root = try fx.tmp.dir.openDir(t.io, ".", .{ .iterate = true });
    defer root.close(t.io);
    var names: usize = 0;
    var top = root.iterate();
    while (try top.next(t.io)) |entry| {
        try t.expect(std.mem.eql(u8, entry.name, "cache") or std.mem.eql(u8, entry.name, "init.js"));
        names += 1;
    }
    try t.expectEqual(@as(usize, 2), names);
}

test "graph: ImportCache objects name separate tables, also inside one context" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler, ImportHook } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { ImportCache } from 'origine:@std/graph/cache';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const handlerFor = cache => ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(({ specifier }) => ({ id: specifier })),
        \\    hooks: [async r => ImportHook.source(ModuleSource.text(`globalThis.count = (globalThis.count ?? 0) + 1; export const n = globalThis.count;`))],
        \\    cache,
        \\  });
        \\  const entry = (handler, name) => api.graph.root.declare(ModuleRecipe({ source: ModuleSource.text("import { n } from 'dep'; globalThis['seen' + n] = true;"), import: handler, name }));
        \\  // One cache object for two handlers: the module 'dep' is one module in the context.
        \\  const shared = ImportCache.native({ retain: 'all' });
        \\  const one = await api.context.create({ graph: api.graph.root, import: handlerFor(shared) });
        \\  await api.graph.root.evaluate(entry(handlerFor(shared), 'a.js'), one);
        \\  out.sameCache = (await one.import('dep')).name + ':' + shared.size;
        \\  // Two cache objects: one module per object, in the same context.
        \\  const left = ImportCache.native({ retain: 'all' });
        \\  const right = ImportCache.native({ retain: 'all' });
        \\  const two = await api.context.create({ graph: api.graph.root, import: handlerFor(left) });
        \\  await api.graph.root.evaluate(entry(handlerFor(right), 'b.js'), two);
        \\  await two.import('dep');
        \\  out.sizes = left.size + ',' + right.size;
        \\  // delete() on one is not seen by the other.
        \\  out.deleted = left.delete('dep') + ':' + left.size + ',' + right.size;
        \\  // Retention is per object: a 'used' table frees what a reference does not hold, an 'all' one keeps it.
        \\  const used = ImportCache.native({ retain: 'used' });
        \\  const keep = ImportCache.native({ retain: 'all' });
        \\  const mixed = await api.context.create({ graph: api.graph.root, import: handlerFor(used) });
        \\  await api.graph.root.evaluate(entry(handlerFor(keep), 'c.js'), mixed);
        \\  api.graph.root.release(await mixed.import('dep'));
        \\  out.mixed = used.size + ',' + keep.size;
        \\  out.cleared = keep.clear() + ':' + keep.size + ',' + right.size;
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.sameCache === 'dep:2'");
    // Context one: dep and a.js; context two: left holds dep (from ctx.import) and right holds b.js and its dep.
    try check(fx.scope, "report.sizes === '1,2' && report.deleted === '1:0,2' && report.mixed === '0,2' && report.cleared === '2:0,2'");
    try check(fx.rt.scopes.items[1], "count === 1");
    try check(fx.rt.scopes.items[2], "count === 2");
}

test "graph: contexts that use one ImportCache object share its modules; two objects do not" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler, ImportHook } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { ImportCache } from 'origine:@std/graph/cache';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const text = "globalThis.count = (globalThis.count ?? 0) + 1; export let n = 0; export function inc() { return ++n; } export const o = { v: 1 };";
        \\  const handlerFor = options => ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(({ specifier }) => ({ id: specifier })),
        \\    hooks: [async r => ImportHook.source(ModuleSource.text(text))],
        \\    ...options,
        \\  });
        \\  // Two contexts made from the SAME handler object share the default cache it made, so one module.
        \\  const same = handlerFor();
        \\  const a = await api.context.create({ graph: api.graph.root, import: same });
        \\  const b = await api.context.create({ graph: api.graph.root, import: same });
        \\  const ma = await a.import('m');
        \\  const mb = await b.import('m');
        \\  out.once = api.graph.root.exports(ma).n + ':' + api.graph.root.exports(mb).n;
        \\  // Live bindings and the same objects: a change through one context is seen through the other.
        \\  api.graph.root.exports(ma).inc();
        \\  out.live = api.graph.root.exports(mb).n;
        \\  // Two handlers with two cache objects do not.
        \\  const c = await api.context.create({ graph: api.graph.root, import: handlerFor({ cache: ImportCache.native({ retain: 'all' }) }) });
        \\  const d = await api.context.create({ graph: api.graph.root, import: handlerFor({ cache: ImportCache.native({ retain: 'all' }) }) });
        \\  await c.import('m');
        \\  await d.import('m');
        \\  out.separate = api.graph.root.exports(await c.import('m')).n + ':' + api.graph.root.exports(await d.import('m')).o.v;
        \\  // Imports that start together still run the module once: the later waits for the home.
        \\  const cache = ImportCache.native({ retain: 'all' });
        \\  const shared = handlerFor({ cache });
        \\  const e = await api.context.create({ graph: api.graph.root, import: shared });
        \\  const f = await api.context.create({ graph: api.graph.root, import: shared });
        \\  const both = await Promise.all([e.import('m'), f.import('m')]);
        \\  api.graph.root.exports(both[0]).inc();
        \\  out.together = api.graph.root.exports(both[1]).n;
        \\  out.size = cache.size;
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.once === '0:0' && report.live === 1 && report.separate === '0:1' && report.together === 1 && report.size === 1");
    // The module ran in its home only: context a (scope 1) counts one, b (scope 2) never ran it.
    try check(fx.rt.scopes.items[1], "count === 1");
    try check(fx.rt.scopes.items[2], "typeof count === 'undefined'");
    // Separate caches: each of c and d ran it.
    try check(fx.rt.scopes.items[3], "count === 1");
    try check(fx.rt.scopes.items[4], "count === 1");
    // Imports that start together: e (scope 5) is the home, f (scope 6) never ran it.
    try check(fx.rt.scopes.items[5], "count === 1");
    try check(fx.rt.scopes.items[6], "typeof count === 'undefined'");
}

test "graph: delete in one context is seen by all, a closed home hands the module over, retain used counts users" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ImportHandler, ImportHook } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportCache } from 'origine:@std/graph/cache';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const text = "globalThis.count = (globalThis.count ?? 0) + 1; export let n = globalThis.count;";
        \\  const handlerFor = cache => ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(({ specifier }) => ({ id: specifier })),
        \\    hooks: [async r => ImportHook.source(ModuleSource.text(text))],
        \\    cache,
        \\  });
        \\  // delete(id) forgets the module in every context that holds it; the next import makes a new one.
        \\  const cache = ImportCache.native({ retain: 'all' });
        \\  const handler = handlerFor(cache);
        \\  const a = await api.context.create({ graph: api.graph.root, import: handler });
        \\  const b = await api.context.create({ graph: api.graph.root, import: handler });
        \\  await a.import('m');
        \\  await b.import('m');
        \\  out.before = cache.size;
        \\  out.deleted = cache.delete('m');
        \\  out.after = cache.size;
        \\  // b imports first now, so b is the new home.
        \\  const again = await b.import('m');
        \\  await a.import('m');
        \\  out.reimported = api.graph.root.exports(again).n + ':' + cache.size;
        \\  // The home closes: the context that used its module drops it, and the next import evaluates a new one there.
        \\  const c = await api.context.create({ graph: api.graph.root, import: handler });
        \\  const d = await api.context.create({ graph: api.graph.root, import: handler });
        \\  cache.clear();
        \\  await c.import('m');
        \\  const linked = await d.import('m');
        \\  c.close();
        \\  out.closedHome = (() => { try { api.graph.root.exports(linked); return 'readable'; } catch (e) { return e.name; } })();
        \\  const fresh = await d.import('m');
        \\  out.handedOver = api.graph.root.exports(fresh).n;
        \\  // retain 'used': the home keeps a module while another context still uses it.
        \\  const used = ImportCache.native({ retain: 'used' });
        \\  const hu = handlerFor(used);
        \\  const e = await api.context.create({ graph: api.graph.root, import: hu });
        \\  const f = await api.context.create({ graph: api.graph.root, import: hu });
        \\  const me = await e.import('m');
        \\  const mf = await f.import('m');
        \\  out.usedStart = used.size;
        \\  api.graph.root.release(me);
        \\  out.homeReleased = used.size;
        \\  api.graph.root.release(mf);
        \\  out.allReleased = used.size;
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.before === 1 && report.deleted === 2 && report.after === 0 && report.reimported === '1:1' && report.closedHome === 'NotFound'");
    try check(fx.scope, "report.handedOver >= 1 && report.usedStart === 1 && report.homeReleased === 1 && report.allReleased === 0");
}

test "graph: retain used frees unused modules, delete resets identity, release unpins" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\import { ImportHandler, ImportHook } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { ImportCache } from 'origine:@std/graph/cache';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e && e.stack || '')); } }
        \\async function body(api) {
        \\  const out = globalThis.report = {};
        \\  const handlerFor = cache => ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(({ specifier }) => ({ id: specifier })),
        \\    hooks: [async r => ImportHook.source(ModuleSource.text(`globalThis.count = (globalThis.count ?? 0) + 1; export const id = '${r.id}';`))],
        \\    cache,
        \\  });
        \\  // retain 'used': a module lives while a reference holds it.
        \\  const used = ImportCache.native({ retain: 'used' });
        \\  const handler = handlerFor(used);
        \\  const ctx = await api.context.create({ graph: api.graph.root, import: handler });
        \\  const first = await ctx.import('m1');
        \\  out.held = used.size + ':' + ctx.references.length;
        \\  const same = await ctx.import('m1');
        \\  out.same = same === first;
        \\  api.graph.root.release(first);
        \\  out.released = used.size + ':' + ctx.references.length + ':' + first.status;
        \\  await ctx.import('m1').then(r => api.graph.root.release(r));
        \\  out.afterRelease = used.size;
        \\  // retain 'all': delete is an identity reset.
        \\  const all = ImportCache.native({ retain: 'all' });
        \\  const keep = await api.context.create({ graph: api.graph.root, import: handlerFor(all) });
        \\  const one = await keep.import('m2');
        \\  out.table = all.size;
        \\  out.deleted = all.delete('m2');
        \\  out.afterDelete = all.size;
        \\  const two = await keep.import('m2');
        \\  out.reimported = (two !== one) + ':' + all.size;
        \\  out.cleared = all.clear() + ':' + all.size;
        \\  out.bad = (() => { try { all.delete(1); } catch (e) { return e.name; } })();
        \\  // there is no cap: a table never evicts one module while others stay.
        \\  const wide = ImportCache.native({ retain: 'all' });
        \\  const many = await api.context.create({ graph: api.graph.root, import: handlerFor(wide) });
        \\  for (const id of ['a', 'b', 'c', 'd']) api.graph.root.release(await many.import(id));
        \\  out.uncapped = wide.size;
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.held === '1:1' && report.same && report.released === '0:0:evaluated' && report.afterRelease === 0");
    try check(fx.scope, "report.table === 1 && report.deleted === 1 && report.afterDelete === 0 && report.reimported === 'true:1'");
    try check(fx.scope, "report.cleared === '1:0' && report.bad === 'InvalidInput' && report.uncapped === 4");
    // 'used': the module was evaluated again after the release; 'all': once, then again after delete.
    try check(fx.rt.scopes.items[1], "count === 2");
    try check(fx.rt.scopes.items[2], "count === 2");
}

test "api: Rust-style fs over sync and async io" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { IoError, HostError } from 'origine:@std/io';
        \\import { fs } from 'origine:@std/fs';
        \\import { encodeUtf8, decodeUtf8, tryDecodeUtf8 } from 'origine:@std/text';
        \\const rejects = async (promiseOrThrow, code) => {
        \\  try { await promiseOrThrow(); } catch (e) { return IoError.is(e, code); }
        \\  return false;
        \\};
        \\async function exercise(rs, label, out) {
        \\  const p = 'rust-' + label;
        \\  await rs.create_dir_all(p + '/a/b');
        \\  const text = 'héllo ✓ \u{1F600}';
        \\  await rs.write(p + '/a/x.txt', text);
        \\  out[label + 'text'] = (await rs.read_to_string(p + '/a/x.txt')) === text;
        \\  out[label + 'len'] = (await rs.read(p + '/a/x.txt')).length === encodeUtf8(text).length;
        \\  const md = await rs.metadata(p + '/a/x.txt');
        \\  out[label + 'meta'] = md.is_file() && !md.is_dir() && md.len() === encodeUtf8(text).length && md.file_type().is_file();
        \\  out[label + 'dirmeta'] = (await rs.metadata(p + '/a')).is_dir();
        \\  const entries = await rs.read_dir(p + '/a');
        \\  out[label + 'entries'] = entries.map(e => e.file_name()).sort().join(',') + '|' + entries.find(e => e.file_name() === 'x.txt').path() + '|' + entries.find(e => e.file_name() === 'b').file_type().is_dir();
        \\  out[label + 'copy'] = (await rs.copy(p + '/a/x.txt', p + '/y.txt')) === encodeUtf8(text).length && (await rs.read_to_string(p + '/y.txt')) === text;
        \\  await rs.rename(p + '/y.txt', p + '/z.txt');
        \\  out[label + 'exists'] = (await rs.try_exists(p + '/z.txt')) && !(await rs.try_exists(p + '/y.txt')) && (await rs.exists(p + '/z.txt')) && !(await rs.exists(p + '/nope'));
        \\  const f = await rs.File.create(p + '/f.bin');
        \\  await f.write_all('abc');
        \\  out[label + 'partial'] = (await f.write(Uint8Array.from([100, 101]))) > 0;
        \\  await f.sync_all();
        \\  await f.flush();
        \\  await f.close();
        \\  const g = await rs.File.open(p + '/f.bin');
        \\  const buf = new Uint8Array(3);
        \\  out[label + 'read'] = (await g.read(buf)) === 3 && decodeUtf8(buf) === 'abc';
        \\  const rest = await g.read_to_end();
        \\  out[label + 'rest'] = decodeUtf8(rest) === 'de' && (await g.metadata()).len() === 5;
        \\  await g.close();
        \\  const h = await rs.OpenOptions.new().read(true).write(true).create(true).open(p + '/h.bin');
        \\  await h.write_all('xyz');
        \\  await h.set_len(2);
        \\  await h.close();
        \\  out[label + 'options'] = (await rs.read_to_string(p + '/h.bin')) === 'xy';
        \\  const exact = await rs.File.open(p + '/h.bin');
        \\  out[label + 'exact'] = (await rejects(() => exact.read_exact(new Uint8Array(9)), IoError.InvalidData));
        \\  await exact.close();
        \\  out[label + 'append'] = await rejects(() => rs.OpenOptions.new().write(true).append(true).open(p + '/h.bin'), IoError.Unsupported);
        \\  out[label + 'noflags'] = await rejects(() => rs.OpenOptions.new().open(p + '/h.bin'), IoError.InvalidInput);
        \\  out[label + 'createWithoutWrite'] = await rejects(() => rs.OpenOptions.new().read(true).create(true).open(p + '/h.bin'), IoError.InvalidInput);
        \\  out[label + 'createNew'] = await rejects(() => rs.File.create_new(p + '/h.bin'), IoError.AlreadyExists);
        \\  await rs.write(p + '/bad.bin', Uint8Array.from([0xff, 0xfe]));
        \\  out[label + 'invalidUtf8'] = await rejects(() => rs.read_to_string(p + '/bad.bin'), IoError.InvalidData);
        \\  out[label + 'missing'] = await rejects(() => rs.read(p + '/ghost'), IoError.NotFound);
        \\  await rs.remove_file(p + '/z.txt');
        \\  await rs.create_dir(p + '/empty');
        \\  await rs.remove_dir(p + '/empty');
        \\  await rs.remove_dir_all(p + '/a');
        \\  out[label + 'removed'] = !(await rs.exists(p + '/a')) && !(await rs.exists(p + '/z.txt'));
        \\}
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const rt = api.io.create({});
        \\  const sio = api.fs.requestSync({ handle: 'plain', access: 'rw' });
        \\  const aio = await api.fs.requestAsync({ handle: 'plain', io: rt, access: 'rw' });
        \\  await exercise(fs(sio), 'sync', out);
        \\  await exercise(fs(aio), 'async', out);
        \\  out.kinds = fs(sio).kind + ',' + fs(aio).kind;
        \\  out.syncIsSync = !(fs(sio).read('rust-sync/h.bin') instanceof Promise);
        \\  out.asyncIsPromise = fs(aio).read('rust-async/h.bin') instanceof Promise;
        \\  await rt.close();
        \\  const strings = ['', 'abc', 'é', '✓', '\u{1F600}', 'a\ud800b', '\udc00', '\ud83d', 'x\ud83d\ude00y', 'aé✓\u{1F600}'.repeat(300), 'z'.repeat(20000)];
        \\  out.utf8Encode = strings.every(t => tryDecodeUtf8(encodeUtf8(t)) !== null);
        \\  const blobs = [[], [0x61], [0xc3, 0xa9], [0xc0, 0x80], [0xc3], [0xe2, 0x9c], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xf0, 0x9f, 0x98, 0x80], [0xff], [0x61, 0x80], [0xe0, 0x80, 0x80], [0xf0, 0x80, 0x80, 0x80]].map(b => Uint8Array.from(b)).concat(strings.map(t => encodeUtf8(t)));
        \\  // A valid blob decodes to its strict string, minus a leading BOM unless `ignoreBOM`.
        \\  out.utf8Decode = blobs.every(b => { const s = tryDecodeUtf8(b); return s === null || (decodeUtf8(b, { ignoreBOM: true }) === s && decodeUtf8(b) === s.replace(/^﻿/, '')); }) && tryDecodeUtf8(new Uint8Array(0)) === ''&& decodeUtf8(new Uint8Array(new SharedArrayBuffer(4)).fill(97)) === 'aaaa' && decodeUtf8(encodeUtf8('x😀y').subarray(1, 5)) === '\u{1F600}';
        \\  out.utf8 = tryDecodeUtf8(encodeUtf8('aé✓\u{1F600}')) === 'aé✓\u{1F600}' && tryDecodeUtf8(Uint8Array.from([0xc0, 0x80])) === null && tryDecodeUtf8(Uint8Array.from([0xed, 0xa0, 0x80])) === null && tryDecodeUtf8(Uint8Array.from([0xef, 0xbb, 0xbf, 0x61])) === '﻿a' && encodeUtf8('\ud800').length === 3 && [1, null, undefined, new Uint8Array(1)].every(v => { try { encodeUtf8(v); return false; } catch (e) { return e instanceof TypeError; } });
        \\  // WHATWG TextDecoder edge cases.
        \\  const cases = [
        \\    [[0xc0, 0x80], '��'], [[0xc1, 0xbf], '��'], [[0xe0, 0x80, 0x80], '���'], [[0xe0, 0x9f, 0xbf], '���'],
        \\    [[0xf0, 0x80, 0x80, 0x80], '����'], [[0xed, 0xa0, 0x80], '���'], [[0xed, 0xbf, 0xbf], '���'],
        \\    [[0xf4, 0x90, 0x80, 0x80], '����'], [[0xf5, 0x80], '��'], [[0xff, 0xfe], '��'],
        \\    [[0xe2, 0x9c], '�'], [[0xf0, 0x9f, 0x98], '�'], [[0xc3], '�'], [[0x61, 0xe2, 0x9c, 0x61], 'a�a'],
        \\    [[0xf0, 0x9f, 0x61], '�a'], [[0x80, 0x61], '�a'], [[0xf0, 0x9f, 0x98, 0x80, 0x80], '\u{1F600}�'],
        \\    [[0xef, 0xbb, 0xbf, 0x61], 'a'], [[0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf], '﻿'], [[0xef, 0xbb], '�'], [[0x61, 0xef, 0xbb, 0xbf], 'a﻿'],
        \\  ];
        \\  out.utf8Whatwg = cases.every(([b, want]) => decodeUtf8(Uint8Array.from(b)) === want);
        \\  out.utf8Bom = decodeUtf8(Uint8Array.from([0xef, 0xbb, 0xbf, 0x61]), { ignoreBOM: true }) === '﻿a';
        \\  out.utf8Fatal = (() => { try { decodeUtf8(Uint8Array.from([0x61, 0xff]), { fatal: true }); return false; } catch (e) { return e instanceof TypeError; } })() && decodeUtf8(Uint8Array.from([0xef, 0xbb, 0xbf, 0xc3, 0xa9]), { fatal: true }) === 'é';
        \\  out.utf8PlainArray = decodeUtf8(Object.assign([0x61, 0xff], { subarray(a, b) { return this.slice(a, b); } })) === 'a�';
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.run();
    inline for (.{ "sync", "async" }) |label| {
        const prefix = "report." ++ label;
        try check(fx.scope, prefix ++ "text && " ++ prefix ++ "len && " ++ prefix ++ "meta && " ++ prefix ++ "dirmeta");
        try check(fx.scope, prefix ++ "entries === 'b,x.txt|rust-" ++ label ++ "/a/x.txt|true' && " ++ prefix ++ "copy && " ++ prefix ++ "exists");
        try check(fx.scope, prefix ++ "partial && " ++ prefix ++ "read && " ++ prefix ++ "rest && " ++ prefix ++ "options && " ++ prefix ++ "exact");
        try check(fx.scope, prefix ++ "append && " ++ prefix ++ "noflags && " ++ prefix ++ "createWithoutWrite && " ++ prefix ++ "createNew");
        try check(fx.scope, prefix ++ "invalidUtf8 && " ++ prefix ++ "missing && " ++ prefix ++ "removed");
    }
    try check(fx.scope, "report.kinds === 'sync,async' && report.syncIsSync && report.asyncIsPromise && report.utf8 && report.utf8Encode && report.utf8Decode && report.utf8Whatwg && report.utf8Bom && report.utf8Fatal && report.utf8PlainArray");
}

/// Runs an init module whose `@BACKEND@` placeholder is replaced by `backend`.
fn setupBackend(fx: *Fixture, template: []const u8, backend: []const u8, runtime: ?m.Api.RuntimeConfig) !void {
    const source = try std.mem.replaceOwned(u8, t.allocator, template, "@BACKEND@", backend);
    defer t.allocator.free(source);
    try fx.setupRuntime(source, true, runtime);
}

const async_concurrent_source =
    \\import { Dir, IoError, HostError } from 'origine:@std/io';
    \\const bytes = s => Uint8Array.from([...s].map(c => c.charCodeAt(0)));
    \\const text = b => String.fromCharCode(...b);
    \\export async function main(api) {
    \\  const out = globalThis.report = {};
    \\  const rt = api.io.create({ backend: '@BACKEND@' });
    \\  out.handle = rt.kind === 'io' && typeof rt.id === 'number' && typeof rt.backend === 'string' && Object.isFrozen(rt);
    \\  const sync = api.fs.requestSync({ handle: 'plain', access: 'rw' });
    \\  const fs = await api.fs.requestAsync({ handle: 'plain', io: rt, access: 'rw' });
    \\  const cwd = Dir.cwd();
    \\  // Many writes, then many reads, all in flight together.
    \\  const names = Array.from({ length: 24 }, (_, i) => 'f' + i + '.txt');
    \\  await Promise.all(names.map((n, i) => cwd.writeFile(fs, { sub_path: n, data: bytes('data-' + i) })));
    \\  const texts = await Promise.all(names.map(n => cwd.readFile(fs, n)));
    \\  out.roundTrip = texts.every((b, i) => text(b) === 'data-' + i);
    \\  out.listed = (await cwd.iterate(fs)).filter(e => e.name.startsWith('f')).length === 24;
    \\  // Concurrent failures: each rejection carries its own errno and the sync cell stays clean.
    \\  const results = await Promise.allSettled([
    \\    cwd.openFile(fs, 'missing.txt'),
    \\    cwd.openFile(fs, '../escape'),
    \\    cwd.createDir(fs, 'f0.txt'),
    \\    cwd.openDir(fs, 'f1.txt'),
    \\    cwd.readFile(fs, 'f2.txt'),
    \\    cwd.openFile(fs, 'f3.txt', { mode: 'read_only' }).then(f => f.close(fs)),
    \\  ]);
    \\  out.codes = results.map(r => (r.status === 'fulfilled' ? 0 : r.reason.errno)).join(',');
    \\  out.names = results.filter(r => r.status === 'rejected').map(r => r.reason.name).join(',');
    \\  out.cellClean = sync.errno[0] === 0;
    \\  // Directories.
    \\  await cwd.createDirPath(fs, 'a/b/c');
    \\  const sub = await cwd.createDirPathOpen(fs, 'a/b');
    \\  await sub.writeFile(fs, { sub_path: 'in.txt', data: bytes('x') });
    \\  out.sub = (await sub.iterate(fs)).map(e => e.name).sort().join(',');
    \\  await sub.close(fs);
    \\  await cwd.rename(fs, 'a/b/in.txt', cwd, 'moved.txt');
    \\  out.moved = text(await cwd.readFile(fs, 'moved.txt'));
    \\  await cwd.deleteTree(fs, 'a');
    \\  await cwd.statFile(fs, 'a').catch(e => { out.treeGone = IoError.is(e, IoError.NotFound); });
    \\  out.rootSafe = await cwd.deleteTree(fs, '.').then(() => false, e => IoError.is(e, IoError.InvalidInput));
    \\  await cwd.createDir(fs, 'empty');
    \\  await cwd.deleteDir(fs, 'empty');
    \\  await cwd.deleteFile(fs, 'moved.txt');
    \\  // Positional and streaming file operations, several preads at once.
    \\  const file = await cwd.createFile(fs, 'p.bin');
    \\  await file.writeStreamingAll(fs, bytes('hello world'));
    \\  await file.writePositionalAll(fs, bytes('J'), 0);
    \\  const parts = [new Uint8Array(5), new Uint8Array(5), new Uint8Array(5)];
    \\  const counts = await Promise.all(parts.map((buf, i) => file.readPositional(fs, buf, i * 3)));
    \\  out.preads = counts.join(',') + ':' + parts.map(text).join('|');
    \\  out.length = await file.length(fs);
    \\  await file.setLength(fs, 5);
    \\  await file.sync(fs);
    \\  out.truncated = (await file.stat(fs)).size + ':' + text(await cwd.readFile(fs, 'p.bin'));
    \\  const buf = new Uint8Array(8);
    \\  out.streamEnd = (await file.readStreaming(fs, buf)) + ':' + (await file.readStreaming(fs, buf));
    \\  await file.close(fs);
    \\  out.closedFile = await file.stat(fs).then(() => false, e => e.errno === HostError.BadHandle || e.errno === HostError.StaleHandle);
    \\  // A read-only grant on the same runtime.
    \\  const ro = await api.fs.requestAsync({ handle: 'plain', io: rt, access: 'r' });
    \\  out.roRead = text(await cwd.readFile(ro, 'f5.txt')) === 'data-5';
    \\  const denied = e => IoError.is(e, IoError.PermissionDenied);
    \\  out.roDenied = [
    \\    await cwd.writeFile(ro, { sub_path: 'f5.txt', data: bytes('z') }).then(() => false, denied),
    \\    await cwd.createDir(ro, 'nope').then(() => false, denied),
    \\    await cwd.createDirPath(ro, 'n/o').then(() => false, denied),
    \\    await cwd.deleteFile(ro, 'f5.txt').then(() => false, denied),
    \\    await cwd.deleteTree(ro, 'f5.txt').then(() => false, denied),
    \\    await cwd.rename(ro, 'f5.txt', cwd, 'g').then(() => false, denied),
    \\  ].join(',');
    \\  // A sub-root grant resolves paths inside the root only.
    \\  await cwd.createDir(fs, 'inner');
    \\  const inner = await api.fs.requestAsync({ handle: 'plain', io: rt, root: 'inner', access: 'rw' });
    \\  await cwd.writeFile(inner, { sub_path: 'x.txt', data: bytes('in') });
    \\  out.inner = text(await cwd.readFile(fs, 'inner/x.txt'));
    \\  out.innerEscape = await cwd.readFile(inner, '../f0.txt').then(() => false, e => IoError.is(e, IoError.PermissionDenied));
    \\  // Closing the runtime: the handle is dead for new grants and idempotent to close again.
    \\  await rt.close();
    \\  await rt.close();
    \\  out.afterClose = await api.fs.requestAsync({ handle: 'plain', io: rt, access: 'r' }).then(() => 'ok', e => e.errno);
    \\  out.opAfterClose = await cwd.readFile(fs, 'f0.txt').then(() => 'ok', e => e.errno !== 0);
    \\}
;

test "api: async fs runs concurrently on an io runtime (auto and threaded backends)" {
    inline for (.{ "auto", "threaded" }) |backend| {
        var fx: Fixture = undefined;
        try setupBackend(&fx, async_concurrent_source, backend, .{});
        defer fx.deinit();
        try fx.run();
        try check(fx.scope, "report.handle && report.roundTrip && report.listed");
        try check(fx.scope, "report.codes === '10,20,11,12,0,0' && report.names === 'NotFound,PermissionDenied,AlreadyExists,NotADirectory' && report.cellClean");
        try check(fx.scope, "report.sub === 'c,in.txt' && report.moved === 'x' && report.treeGone && report.rootSafe");
        try check(fx.scope, "report.preads === '5,5,5:Jello|lo wo|world' && report.length === 11 && report.truncated === '5:Jello'");
        try check(fx.scope, "report.streamEnd === '0:0' && report.closedFile");
        try check(fx.scope, "report.roRead && report.roDenied === 'true,true,true,true,true,true'");
        try check(fx.scope, "report.inner === 'in' && report.innerEscape && report.afterClose === 2 && report.opAfterClose === true");
    }
}

test "api: closing an io runtime cancels in-flight operations and frees its slot" {
    var fx: Fixture = undefined;
    try setupBackend(&fx,
        \\import { Dir, IoError, HostError } from 'origine:@std/io';
        \\const bytes = s => Uint8Array.from([...s].map(c => c.charCodeAt(0)));
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const first = api.io.create({ backend: '@BACKEND@' });
        \\  const second = api.io.create({});
        \\  // The embedder ceiling (max_runtimes = 2) applies to live runtimes.
        \\  try { api.io.create({}); out.third = false; } catch (e) { out.third = true; }
        \\  const fs = await api.fs.requestAsync({ handle: 'plain', io: first, access: 'rw' });
        \\  const cwd = Dir.cwd();
        \\  await cwd.writeFile(fs, { sub_path: 'big.bin', data: new Uint8Array(1 << 20).fill(97) });
        \\  const pending = [];
        \\  for (let i = 0; i < 64; i++) pending.push(cwd.readFile(fs, 'big.bin'), cwd.writeFile(fs, { sub_path: 'w' + i, data: bytes('z') }), cwd.deleteTree(fs, 'nothing' + i));
        \\  const closing = first.close();
        \\  const settled = await Promise.allSettled(pending);
        \\  await closing;
        \\  // Every operation settled: finished before the close, or canceled/stale after it.
        \\  const allowed = [HostError.Canceled, HostError.StaleHandle, HostError.BadHandle, IoError.NotFound];
        \\  out.settled = settled.length === pending.length && settled.every(r => r.status === 'fulfilled' || allowed.includes(r.reason.errno));
        \\  out.canceledKnown = HostError.Canceled === 4 && HostError.name(4) === 'Canceled';
        \\  // The slot is free again; the other runtime is unaffected.
        \\  const third = api.io.create({});
        \\  const other = await api.fs.requestAsync({ handle: 'plain', io: second, access: 'r' });
        \\  out.otherWorks = (await cwd.readFile(other, 'big.bin')).length === 1 << 20;
        \\  await third.close();
        \\  await second.close();
        \\  // Left in flight: Host.destroy drains them without leaking.
        \\  const last = api.io.create({});
        \\  const lastFs = await api.fs.requestAsync({ handle: 'plain', io: last, access: 'r' });
        \\  globalThis.dangling = [cwd.readFile(lastFs, 'big.bin'), cwd.readFile(lastFs, 'big.bin')].map(p => p.catch(() => undefined));
        \\}
    , "threaded", .{ .max_runtimes = 2 });
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.third && report.settled && report.canceledKnown && report.otherWorks");
}

test "api: requestAsync needs a live io handle of this scope" {
    var fx: Fixture = undefined;
    try fx.setupRuntime(
        \\import { IoError, HostError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const code = p => p.then(() => 0, e => e.errno);
        \\  const rt = api.io.create({});
        \\  const other = api.io.create({});
        \\  out.missing = await code(api.fs.requestAsync({}));
        \\  out.notHandle = await code(api.fs.requestAsync({ handle: 'plain', io: 7, access: 'r' }));
        \\  out.forged = await code(api.fs.requestAsync({ handle: 'plain', io: Object.freeze({ kind: 'io', id: rt.id, backend: 'auto' }) }));
        \\  out.getter = await code(api.fs.requestAsync({ handle: 'plain', get io() { return rt; } }));
        \\  out.badRoot = await code(api.fs.requestAsync({ handle: 'plain', io: rt, root: 42, access: 'r' }));
        \\  out.escape = await code(api.fs.requestAsync({ handle: 'plain', io: rt, root: '../x', access: 'r' }));
        \\  await other.close();
        \\  out.closed = await code(api.fs.requestAsync({ handle: 'plain', io: other, access: 'r' }));
        \\  out.live = await code(api.fs.requestAsync({ handle: 'plain', io: rt, access: 'r' }));
        \\  const kind = f => { try { f().close(); return 'ok'; } catch (e) { return e instanceof TypeError ? 'T' : e.errno; } };
        \\  out.badOpts = [undefined, null, 1, 'x'].map(o => kind(() => api.io.create(o))).join(',');
        \\  out.badBackend = kind(() => api.io.create({ backend: 'epoll' }));
        \\  out.badEntries = kind(() => api.io.create({ entries: -1 }));
        \\  out.frozen = Object.isFrozen(api.io) && Object.isFrozen(rt);
        \\  await rt.close();
        \\}
    , true, .{});
    defer fx.deinit();
    try fx.run();
    // BadHandle 2, InvalidInput 30; create() accepts an absent option bag and throws a TypeError for malformed ones.
    try check(fx.scope, "report.missing === 2 && report.notHandle === 2 && report.forged === 2 && report.getter === 2 && report.closed === 2");
    try check(fx.scope, "report.badRoot === 30 && report.escape === 20 && report.live === 0 && report.frozen");
    try check(fx.scope, "report.badOpts === 'ok,T,T,T' && report.badBackend === 'T' && report.badEntries === 'T'");
}

test "api: without a runtime ceiling there is no api.io and no async fs" {
    var fx: Fixture = undefined;
    try fx.setupRuntime(
        \\import { IoError, HostError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  out.noIo = !('io' in api);
        \\  out.asyncDenied = await api.fs.requestAsync({ handle: 'plain', io: undefined, access: 'r' }).then(() => 0, e => e.errno);
        \\  out.syncWorks = typeof api.fs.requestSync({ handle: 'plain', access: 'r' }) === 'object';
        \\}
    , true, null);
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.noIo && report.asyncDenied === 2 && report.syncWorks");
}

test "api: import.meta natives reach only the embedded std modules" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import * as text from 'origine:@std/text';
        \\export async function main() {
        \\  const out = globalThis.report = {};
        \\  out.exports = Object.keys(text).sort().join(',');
        \\  // User code sees a bare import.meta, no natives on the global, and no way to import std internals.
        \\  out.bareMeta = Object.keys(import.meta).join(',') === 'url' && import.meta.native === undefined;
        \\  out.noGlobal = !('__engineText' in globalThis);
        \\  out.reserved = await import('origine:@std/unknown').then(() => false, () => true);
        \\  out.reservedPrivate = await import('origine:private/bindings').then(() => false, () => true);
        \\  out.handlesPrivate = await import('origine:@internal/handles').then(() => false, () => true);
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.exports === 'decodeUtf8,encodeUtf8,tryDecodeUtf8'");
    try check(fx.scope, "report.bareMeta && report.noGlobal && report.reserved && report.reservedPrivate && report.handlesPrivate");
}

/// State a test module keeps for one scope; `torn_down` records `deinit` runs.
const CounterState = struct {
    var created: u32 = 0;
    var torn_down: u32 = 0;
    count: u32 = 0,

    pub fn init(_: *m.Api.module.ScopeState) !CounterState {
        created += 1;
        return .{ .count = 100 };
    }
    pub fn deinit(_: *CounterState) void {
        torn_down += 1;
    }
    fn next(cell: *m.Api.module.Cell(CounterState)) u32 {
        cell.data.count += 1;
        return cell.data.count;
    }
};

test "api: embedded modules evaluate and create native state only on first import" {
    CounterState.created = 0;
    CounterState.torn_down = 0;
    const modules = m.Api.std_modules ++ [_]m.Api.module.Module{
        .{
            .id = "origine:test/lazy",
            .source = "const { next } = import.meta.native; globalThis.evaluations = (globalThis.evaluations ?? 0) + 1; export const bump = () => next();",
            .bindings = m.Api.module.stateful(CounterState, .{ .next = m.Api.binding.func(CounterState.next, .{ .side_effect = .any }) }),
        },
        .{ .id = "origine:test/unused", .source = "throw new Error('unused module evaluated');" },
    };
    var fx: Fixture = undefined;
    try fx.setupWith("export function main() {}", false, &.{}, &modules);
    defer fx.deinit();
    try fx.run();
    try t.expectEqual(@as(u32, 0), CounterState.created);
    try check(fx.scope, "globalThis.evaluations === undefined");
    try @import("support.zig").exposeModule(fx.scope, "origine:test/lazy", "first");
    try t.expectEqual(@as(u32, 1), CounterState.created);
    try check(fx.scope, "evaluations === 1 && first.bump() === 101");
    try @import("support.zig").exposeModule(fx.scope, "origine:test/lazy", "second");
    try t.expectEqual(@as(u32, 1), CounterState.created);
    try check(fx.scope, "evaluations === 1 && first === second && second.bump() === 102");
}

test "api: a module owns per-scope state that lives until the host is destroyed" {
    CounterState.created = 0;
    CounterState.torn_down = 0;
    const counter_module = m.Api.module.Module{
        .id = "origine:test/counter",
        .source = "const { next } = import.meta.native; export const bump = () => next();",
        .bindings = m.Api.module.stateful(CounterState, .{ .next = m.Api.binding.func(CounterState.next, .{ .side_effect = .any }) }),
    };
    const modules = m.Api.std_modules ++ [_]m.Api.module.Module{counter_module};
    var fx: Fixture = undefined;
    try fx.setupWith(
        \\import { bump } from 'origine:test/counter';
        \\export async function main() {
        \\  globalThis.report = { first: bump(), second: bump(), third: bump() };
        \\  // A second import of the module sees the same instance and the same state.
        \\  globalThis.report.again = (await import('origine:test/counter')).bump();
        \\}
    , false, &.{}, &modules);
    try fx.run();
    try check(fx.scope, "report.first === 101 && report.second === 102 && report.third === 103 && report.again === 104");
    try t.expectEqual(@as(u32, 1), CounterState.created);
    try t.expectEqual(@as(u32, 0), CounterState.torn_down);
    fx.deinit();
    try t.expectEqual(@as(u32, 1), CounterState.torn_down);
}

/// Test natives are classified `.any`: nothing here is side-effect free.
fn any(comptime f: anytype) m.Api.binding.Wrapped(@TypeOf(f)) {
    return m.Api.binding.func(f, .{ .side_effect = .any });
}

const BindingState = struct {
    cell: u32 = 0,
    total: u32 = 0,

    pub fn errnoCell(self: *BindingState) *u32 {
        return &self.cell;
    }
    pub fn allocator(_: *BindingState) std.mem.Allocator {
        return t.allocator;
    }
};

const Pair = struct { u32, bool };
const Point = struct { x: u32, y: f64 };

const typed = struct {
    fn add(state: *BindingState, a: u32, b: u32) u32 {
        state.total += a + b;
        return a + b;
    }
    fn greet(_: *BindingState, call: *m.Api.Call, name: []const u8, suffix: ?[]const u8) []const u8 {
        return call.print("hi {s}{s}", .{ name, suffix orelse "" });
    }
    fn middle(_: *BindingState, a: u32, _: *m.Api.Call, b: u32) u32 {
        return a * 10 + b;
    }
    fn pair(_: *BindingState) Pair {
        return .{ 7, true };
    }
    fn point(_: *BindingState) Point {
        return .{ .x = 3, .y = 0.5 };
    }
    fn missing(_: *BindingState) !void {
        return error.FileNotFound;
    }
    fn failing(_: *BindingState, fail: bool) !u32 {
        if (fail) return error.FileNotFound;
        return 4;
    }
    fn maybe(_: *BindingState, yes: bool) ?u32 {
        return if (yes) 1 else null;
    }
    fn sum(_: *BindingState, bytes: []u8) u32 {
        var total: u32 = 0;
        for (bytes) |byte| total += byte;
        return total;
    }
    fn names(_: *BindingState, call: *m.Api.Call) []const []const u8 {
        const out = call.allocSlice([]const u8, 2);
        out[0] = "a";
        out[1] = "b";
        return out;
    }
    fn big(_: *BindingState) u64 {
        return 1 << 40;
    }
    fn fill(_: *BindingState, bytes: []u8) void {
        @memset(bytes, 9);
    }
};

test "binding: typed natives decode arguments, encode results and report errors" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    var state: BindingState = .{};
    {
        var session: m.Scope.Session = undefined;
        session.init(scope);
        defer session.deinit();
        const env: m.Api.binding.Env = .{ .isolate = session.isolate(), .ctx = session.ctx };
        const table = try m.Api.binding.object(env, BindingState, &state, .{
            .add = any(typed.add),
            .greet = any(typed.greet),
            .middle = any(typed.middle),
            .pair = any(typed.pair),
            .point = any(typed.point),
            .missing = any(typed.missing),
            .failing = any(typed.failing),
            .maybe = any(typed.maybe),
            .sum = any(typed.sum),
            .names = any(typed.names),
            .big = any(typed.big),
            .fill = any(typed.fill),
            .label = "native",
            .nested = .{ .add = any(typed.add), .deeper = .{ .pair = any(typed.pair) } },
        });
        try m.Api.binding.set(env, session.ctx.getGlobal(), "native", table.value);
    }
    try check(scope, "native.add(2, 3) === 5");
    try t.expectEqual(@as(u32, 5), state.total);
    try t.expectEqual(@as(u32, 0), state.cell);
    try check(scope, "native.greet('x') === 'hi x' && native.greet('x', '!') === 'hi x!' && native.greet('x', null) === 'hi x'");
    // *Call takes no JS argument: (a, b) map to the parameters around it.
    try check(scope, "native.middle(4, 2) === 42");
    try check(scope, "Array.isArray(native.pair()) && native.pair()[0] === 7 && native.pair()[1] === true");
    try check(scope, "native.point().x === 3 && native.point().y === 0.5");
    try check(scope, "native.maybe(true) === 1 && native.maybe(false) === undefined");
    try check(scope, "native.sum(Uint8Array.from([1, 2, 3])) === 6 && native.sum(new Uint8Array(0)) === 0");
    try check(scope, "native.names().join() === 'a,b' && native.big() === 1099511627776");
    try check(scope, "native.label === 'native' && native.nested.add(1, 1) === 2 && native.nested.deeper.pair()[0] === 7");
    try check(scope, "(() => { const b = new Uint8Array(3); native.fill(b); return b.join() === '9,9,9'; })()");
    try t.expectEqual(@as(u32, 0), state.cell);
    // A returned Zig error lands in the errno cell and the call returns undefined.
    try check(scope, "native.missing() === undefined");
    try t.expectEqual(@backingInt(m.Api.Errno.NotFound), state.cell);
    // Mistyped or missing arguments fail before the function runs (InvalidArgument -> InvalidInput).
    const before = state.total;
    for ([_][]const u8{ "native.add('x', 1)", "native.add(1)", "native.greet(5)", "native.sum([1, 2])", "native.sum(new Uint8Array(new SharedArrayBuffer(4)))", "native.greet('x', 5)", "native.maybe(1)" }) |call_source| {
        const source = try std.fmt.allocPrint(t.allocator, "{s} === undefined", .{call_source});
        defer t.allocator.free(source);
        try check(scope, source);
        try t.expectEqual(@backingInt(m.Api.Errno.InvalidInput), state.cell);
        state.cell = 0;
    }
    try t.expectEqual(before, state.total);
    // The cell is cleared on entry to every call.
    try check(scope, "native.missing() === undefined && native.add(1, 1) === 2");
    try t.expectEqual(@as(u32, 0), state.cell);
}

test "binding: hot natives take V8's fast API path and still agree with the slow path" {
    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    var state: BindingState = .{};
    {
        var session: m.Scope.Session = undefined;
        session.init(scope);
        defer session.deinit();
        const env: m.Api.binding.Env = .{ .isolate = session.isolate(), .ctx = session.ctx };
        const table = try m.Api.binding.object(env, BindingState, &state, .{ .add = any(typed.add), .failing = any(typed.failing) });
        try m.Api.binding.set(env, session.ctx.getGlobal(), "native", table.value);
    }
    // Once optimized, V8 calls the fast entry: results agree, and an error yields 0 (the cell is still set).
    try check(scope,
        \\(() => {
        \\  const f = (x) => native.failing(x);
        \\  %PrepareFunctionForOptimization(f);
        \\  f(false); f(false);
        \\  %OptimizeFunctionOnNextCall(f);
        \\  return f(true) === 0 && f(false) === 4;
        \\})()
    );
    try check(scope, "native.add(3, 4) === 7");
    try t.expectEqual(@as(u32, 0), state.cell);
}

test "binding: func options pick side effect, fast path and constructor behavior" {
    const binding = m.Api.binding;
    // Builder style and options struct agree.
    const by_options = comptime binding.func(typed.failing, .{ .side_effect = .none, .nofast = true, .constructor = .allow });
    const by_builder = comptime binding.func(typed.failing, .{}).side_effect(.none).nofast(true).constructor(.allow);
    comptime std.debug.assert(by_options.options.side_effect.? == by_builder.options.side_effect.? and
        by_options.options.nofast == by_builder.options.nofast and by_options.options.constructor == by_builder.options.constructor);
    comptime std.debug.assert(binding.func(typed.add, .{}).options.side_effect == null);

    ensureV8();
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const scope = try rt.createScope(.{});
    var state: BindingState = .{};
    {
        var session: m.Scope.Session = undefined;
        session.init(scope);
        defer session.deinit();
        const env: binding.Env = .{ .isolate = session.isolate(), .ctx = session.ctx };
        const table = try binding.object(env, BindingState, &state, .{
            .fast = binding.func(typed.failing, .{}).side_effect(.receiver),
            .slow = binding.func(typed.failing, .{}).side_effect(.none).nofast(true),
            .ctor = binding.func(typed.add, .{ .side_effect = .any, .constructor = .allow }),
            .plain = binding.func(typed.add, .{ .side_effect = .any }),
        });
        try binding.set(env, session.ctx.getGlobal(), "native", table.value);
    }
    // The fast entry yields 0 for an error; the same native with nofast stays on the slow path (undefined).
    try check(scope,
        \\(() => {
        \\  const g = (x) => native.fast(x), h = (x) => native.slow(x);
        \\  %PrepareFunctionForOptimization(g); %PrepareFunctionForOptimization(h);
        \\  g(false); g(false); h(false); h(false);
        \\  %OptimizeFunctionOnNextCall(g); %OptimizeFunctionOnNextCall(h);
        \\  return g(true) === 0 && h(true) === undefined && h(false) === 4;
        \\})()
    );
    // Constructor behavior: throws by default, allowed on request.
    try check(scope, "(() => { try { new native.plain(1, 2); return false } catch (e) { return e instanceof TypeError } })() && typeof new native.ctor(1, 2) === 'object'");
}

test "transformer registry: longest suffix, query and fragment stripped, case-sensitive" {
    const T = m.Api.transformer;
    const nop = struct {
        fn run(_: ?*anyopaque, request: T.Request) anyerror!T.Outcome {
            return .{ .source = request.source };
        }
    }.run;
    var one: u8 = 1;
    var two: u8 = 2;
    const registry: T.Registry = .{ .entries = &.{
        .{ .ext = ".ts", .transformer = .{ .data = &one, .run = nop } },
        .{ .ext = ".d.ts", .transformer = .{ .data = &two, .run = nop } },
    } };
    try t.expectEqual(@as(?*anyopaque, &one), registry.find("a/b.ts").?.data);
    try t.expectEqual(@as(?*anyopaque, &one), registry.find("b.ts?v=1#x").?.data);
    try t.expectEqual(@as(?*anyopaque, &two), registry.find("types.d.ts").?.data);
    try t.expect(registry.find("b.TS") == null);
    try t.expect(registry.find("b.js") == null);
    try t.expect(registry.find(".ts") == null);
    try t.expect(registry.find("ts") == null);
    try t.expect((T.Registry{}).find("a.ts") == null);
}

test "typescript: .ts and .tsx imports are transformed by extension" {
    if (!m.Api.oxc.enabled) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.setupFull("init.ts",
        \\import { sum, Color } from './lib.ts';
        \\import { make } from './view.tsx';
        \\interface Shape { kind: string }
        \\namespace Space { export const value: number = 7 }
        \\class Point { constructor(public x: number, private y: number) {} total(): number { return this.x + this.y } }
        \\export async function main(): Promise<void> {
        \\  const shape: Shape = { kind: 'k' };
        \\  globalThis.report = { sum: sum(1, 2), color: Color[Color.Green], space: Space.value, kind: shape.kind, point: new Point(3, 4).total(), view: JSON.stringify(make()) };
        \\}
    , false, &.{}, &m.Api.std_modules, m.Api.transformers.defaults, .{});
    defer fx.deinit();
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "lib.ts", .data = "export enum Color { Red, Green }\nexport const sum = (a: number, b: number): number => a + b;\n" });
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "view.tsx", .data = "/** @jsxRuntime classic */\n/** @jsx h */\nconst h = (tag: string, props: Record<string, string> | null) => ({ tag, props });\nexport const make = () => <div id=\"a\" />;\n" });
    try fx.run();
    try check(fx.scope, "report.sum === 3 && report.color === 'Green' && report.space === 7 && report.kind === 'k' && report.point === 7");
    try check(fx.scope, "report.view === '{\"tag\":\"div\",\"props\":{\"id\":\"a\"}}'");
}

test "typescript: syntax errors carry file:line:col and an empty map leaves .ts alone" {
    if (!m.Api.oxc.enabled) return error.SkipZigTest;
    var bad: Fixture = undefined;
    try bad.setupFull("init.ts", "export function main() {\n  const x: number = ;\n}\n", false, &.{}, &m.Api.std_modules, m.Api.transformers.defaults, .{});
    defer bad.deinit();
    var error_info: m.ErrorInfo = .{};
    defer error_info.deinit();
    try t.expectError(error.InitFailed, bad.host.run(bad.scope, support.engine.platform, bad.init_path, &error_info));
    {
        var session: m.Scope.Session = undefined;
        session.init(bad.scope);
        defer session.deinit();
        const exception = error_info.exception.?.deref();
        const stack = exception.toObject(session.ctx).?.get(session.ctx, v8.String.initUtf8(session.isolate(), "stack").name.primitive.value).?;
        var buffer: [512]u8 = undefined;
        const length = stack.toString(session.ctx).?.writeUtf8(session.isolate(), &buffer);
        try t.expect(std.mem.indexOf(u8, buffer[0..length], "init.ts:2:21: error:") != null);
    }
    var off: Fixture = undefined;
    try off.setupFull("init.ts", "export function main(): void {}\n", false, &.{}, &m.Api.std_modules, &.{}, .{});
    defer off.deinit();
    var off_info: m.ErrorInfo = .{};
    defer off_info.deinit();
    // Without a transformer the type annotation reaches V8 as plain JavaScript.
    try t.expectError(error.InitFailed, off.host.run(off.scope, support.engine.platform, off.init_path, &off_info));
}

test "errno: binding errors map strictly, fs errors by name" {
    const E = m.Api.Errno;
    const Api = m.Api;
    // Binding domain: the closed `Error` set; every member has a code.
    const bound: Api.Error = error.StaleHandle;
    try t.expectEqual(E.StaleHandle, Api.errnoOf(bound));
    try t.expectEqual(E.InvalidInput, Api.errnoOf(error.InvalidArgument));
    inline for (@typeInfo(Api.Error).error_set.error_names.?) |name| {
        try t.expect(Api.errnoOf(@field(Api.Error, name)) != .ok);
    }
    // fs domain: concrete sets resolve at compile time.
    try t.expectEqual(E.NotFound, Api.errnoOfFs(@as(error{FileNotFound}, error.FileNotFound)));
    try t.expectEqual(E.PermissionDenied, Api.errnoOfFs(@as(error{ PermissionDenied, Other }, error.PermissionDenied)));
    try t.expectEqual(E.PermissionDenied, Api.errnoOfFs(@as(error{AccessDenied}, error.AccessDenied)));
    try t.expectEqual(E.Unexpected, Api.errnoOfFs(@as(error{Other}, error.Other)));
    // The canonical table: every std name of a failure maps to its Rust ErrorKind-named member
    // (the Rust half is `errno_of`, checked by the sync/async parity test below).
    try t.expectEqual(E.ReadOnlyFilesystem, Api.errnoOfFs(@as(error{ReadOnlyFileSystem}, error.ReadOnlyFileSystem)));
    try t.expectEqual(E.FilesystemLoop, Api.errnoOfFs(@as(error{SymLinkLoop}, error.SymLinkLoop)));
    try t.expectEqual(E.InvalidFilename, Api.errnoOfFs(@as(error{NameTooLong}, error.NameTooLong)));
    try t.expectEqual(E.InvalidFilename, Api.errnoOfFs(@as(error{BadPathName}, error.BadPathName)));
    try t.expectEqual(E.ResourceBusy, Api.errnoOfFs(@as(error{FileBusy}, error.FileBusy)));
    try t.expectEqual(E.ResourceBusy, Api.errnoOfFs(@as(error{DeviceBusy}, error.DeviceBusy)));
    try t.expectEqual(E.CrossesDevices, Api.errnoOfFs(@as(error{CrossDevice}, error.CrossDevice)));
    try t.expectEqual(E.QuotaExceeded, Api.errnoOfFs(@as(error{DiskQuota}, error.DiskQuota)));
    try t.expectEqual(E.TooManyOpenFiles, Api.errnoOfFs(@as(error{ProcessFdQuotaExceeded}, error.ProcessFdQuotaExceeded)));
    try t.expectEqual(E.TooManyOpenFiles, Api.errnoOfFs(@as(error{SystemFdQuotaExceeded}, error.SystemFdQuotaExceeded)));
    try t.expectEqual(E.Io, Api.errnoOfFs(@as(error{InputOutput}, error.InputOutput)));
    try t.expectEqual(E.StorageFull, Api.errnoOfFs(@as(error{NoSpaceLeft}, error.NoSpaceLeft)));
    try t.expectEqual(E.FileTooLarge, Api.errnoOfFs(@as(error{FileTooBig}, error.FileTooBig)));
    try t.expectEqual(E.NotADirectory, Api.errnoOfFs(@as(error{NotDir}, error.NotDir)));
    try t.expectEqual(E.IsADirectory, Api.errnoOfFs(@as(error{IsDir}, error.IsDir)));
    try t.expectEqual(E.AlreadyExists, Api.errnoOfFs(@as(error{PathAlreadyExists}, error.PathAlreadyExists)));
    try t.expectEqual(E.DirectoryNotEmpty, Api.errnoOfFs(@as(error{DirNotEmpty}, error.DirNotEmpty)));
    // narrow() is the explicit boundary for non-fs code.
    try t.expectEqual(@as(Api.Error, error.NotFound), Api.narrowError(error.FileNotFound));
    try t.expectEqual(@as(Api.Error, error.BadHandle), Api.narrowError(error.BadHandle));
    try t.expectEqual(@as(Api.Error, error.Unexpected), Api.narrowError(error.SomethingElse));
    // isBinding tells the domains apart.
    try t.expect(Api.binding_errors.isBinding(Api.Error));
    try t.expect(Api.binding_errors.isBinding(error{ BadHandle, InvalidArgument }));
    try t.expect(!Api.binding_errors.isBinding(error{ BadHandle, EndOfStream }));
    try t.expect(!Api.binding_errors.isBinding(error{OutOfMemory}));
}

test "errno: the guest table is generated from Errno, not hard-coded" {
    var count: usize = 0;
    inline for (std.enums.values(m.Api.Errno)) |tag| {
        if (tag == .ok) continue;
        const needle = try std.fmt.allocPrint(t.allocator, "  {s}: {d},", .{ @tagName(tag), @backingInt(tag) });
        defer t.allocator.free(needle);
        try t.expect(std.mem.indexOf(u8, m.Api.errno_module_source, needle) != null);
        count += 1;
    }
    try t.expect(count > 0);
    // The generated module is served, and std_io.js no longer carries its own table.
    var served = false;
    inline for (m.Api.std_modules) |module| {
        if (std.mem.eql(u8, module.id, "origine:@std/errno")) served = module.source.ptr == m.Api.errno_module_source.ptr;
    }
    try t.expect(served);
    try t.expect(std.mem.indexOf(u8, m.Api.std_io_source, "NotFound: 1") == null);
    try t.expect(std.mem.indexOf(u8, m.Api.std_io_source, "origine:@std/errno") != null);
}

test "rust native: api.io.create runs a v8-crate native on the Zig isolate" {
    var f: Fixture = undefined;
    try f.setup(
        \\export async function main(api) {
        \\  const io = api.io.create({});
        \\  if (io.kind !== 'io' || io.backend !== 'auto' || typeof io.id !== 'number') throw new Error('bad handle');
        \\  if (!Object.isFrozen(io)) throw new Error('not frozen');
        \\  const second = api.io.create({ backend: 'threaded' });
        \\  if (second.id === io.id || second.backend !== 'threaded') throw new Error('bad second');
        \\  let threw = false;
        \\  try { api.io.create({ backend: 'nope' }); } catch (e) { threw = e instanceof TypeError; }
        \\  if (!threw) throw new Error('bad backend accepted');
        \\}
    , false, &.{});
    defer f.deinit();
    try f.run();
}

// ---- phase 5: zero-copy buffers (pin + detach, BYOB, host-allocated) -----------------------------

const zero_copy_source =
    \\import { Dir, IoError, HostError } from 'origine:@std/io';
    \\import { fs as rustFs } from 'origine:@std/fs';
    \\const bytes = s => Uint8Array.from([...s].map(c => c.charCodeAt(0)));
    \\const text = b => String.fromCharCode(...b);
    \\export async function main(api) {
    \\  const out = globalThis.report = {};
    \\  const rt = api.io.create({ backend: '@BACKEND@' });
    \\  const fs = await api.fs.requestAsync({ handle: 'plain', io: rt, access: 'rw' });
    \\  const sync = api.fs.requestSync({ handle: 'plain', access: 'rw' });
    \\  const cwd = Dir.cwd();
    \\  const read = name => cwd.readFile(fs, name);
    \\
    \\  // Plain writes ALWAYS copy: the caller's buffer (and every view over it) is never detached.
    \\  const w = new Uint8Array(bytes('copied!!!'));
    \\  const wView = w.subarray(2, 5);
    \\  await cwd.writeFile(fs, { sub_path: 'w.txt', data: w });
    \\  out.copyKeeps = w.buffer.byteLength === 9 && w.length === 9 && wView.length === 3 && text(w) === 'copied!!!';
    \\  out.copyWritten = text(await read('w.txt')) === 'copied!!!';
    \\  const file = await cwd.createFile(fs, 'w2.txt');
    \\  const c1 = bytes('ab');
    \\  await file.writeStreamingAll(fs, c1);
    \\  const c2 = bytes('cd');
    \\  out.partialCopy = (await file.writeStreaming(fs, c2)) <= 2;
    \\  await file.writePositionalAll(fs, c2, 0);
    \\  out.plainKeeps = c1.buffer.byteLength === 2 && c2.buffer.byteLength === 2;
    \\  // The *Move variants transfer: the whole ArrayBuffer is detached and written in place.
    \\  const w2 = bytes('MV');
    \\  await file.writeStreamingMoveAll(fs, w2);
    \\  out.writeAllDetached = w2.buffer.byteLength === 0;
    \\  const w3 = bytes('mv');
    \\  out.partial = (await file.writeStreamingMove(fs, w3)) <= 2 && w3.buffer.byteLength === 0;
    \\  const w4 = bytes('XY');
    \\  await file.writePositionalMoveAll(fs, w4, 0);
    \\  out.positionalDetached = w4.buffer.byteLength === 0;
    \\  const emptyBuf = new Uint8Array(0);
    \\  await file.writeStreamingMoveAll(fs, emptyBuf);
    \\  await file.close(fs);
    \\  out.afterWrites = text(await read('w2.txt')).startsWith('XY');
    \\  // A copy (slice) of a moved buffer keeps the data.
    \\  const keep = bytes('keep');
    \\  await cwd.writeFile(fs, { sub_path: 'keep.txt', data: keep.slice() });
    \\  out.sliceKeeps = text(keep) === 'keep';
    \\  // Rust-style API: write() copies, write_move() transfers; copy() and strings are unaffected.
    \\  const rs = rustFs(fs);
    \\  const rsBuf = bytes('rust');
    \\  await rs.write('rs.txt', rsBuf);
    \\  out.rustCopies = rsBuf.buffer.byteLength === 4 && text(await read('rs.txt')) === 'rust';
    \\  const rf0 = await rs.File.create('rs3.txt');
    \\  const rsMove = bytes('move');
    \\  await rf0.write_move_all(rsMove);
    \\  const rsMove2 = bytes('MOVE');
    \\  await rf0.write_move(rsMove2);
    \\  await rf0.write_move_all('str');
    \\  await rf0.close();
    \\  out.rustDetached = rsMove.buffer.byteLength === 0 && rsMove2.buffer.byteLength === 0 && text(await read('rs3.txt')).startsWith('move');
    \\  out.rustString = (await rs.write('rs2.txt', 'str'), text(await read('rs2.txt'))) === 'str';
    \\  await cwd.writeFile(fs, { sub_path: 'chunks.bin', data: new Uint8Array(200000).fill(7) });
    \\  out.copied = (await rs.copy('chunks.bin', 'chunks2.bin')) === 200000 && (await read('chunks2.bin')).every(b => b === 7);
    \\  out.copiedSync = rustFs(sync).copy('chunks.bin', 'chunks3.bin') === 200000 && (await read('chunks3.bin')).length === 200000;
    \\
    \\  // Ineligible buffers are copied at call time and stay intact.
    \\  const sab = typeof SharedArrayBuffer === 'function' ? new Uint8Array(new SharedArrayBuffer(4)) : null;
    \\  if (sab) sab.set(bytes('sabx'));
    \\  const resizable = new Uint8Array(new ArrayBuffer(4, { maxByteLength: 8 }));
    \\  resizable.set(bytes('rsiz'));
    \\  const wasm = typeof WebAssembly === 'object' ? new Uint8Array(new WebAssembly.Memory({ initial: 1 }).buffer, 16, 4) : null;
    \\  if (wasm) wasm.set(bytes('wasm'));
    \\  const intact = [];
    \\  for (const [name, view, expected] of [['sab', sab, 'sabx'], ['resizable', resizable, 'rsiz'], ['wasm', wasm, 'wasm']]) {
    \\    if (!view) continue;
    \\    const before = view.buffer.byteLength;
    \\    await cwd.writeFile(fs, { sub_path: name + '.txt', data: view });
    \\    intact.push(name + ':' + (view.buffer.byteLength === before && text(view) === expected && text(await read(name + '.txt')) === expected));
    \\  }
    \\  out.copyFallback = intact.join(',');
    \\  out.copyFallbackAll = intact.every(entry => entry.endsWith(':true')) && intact.length >= 1;
    \\  // A move never copies: an ineligible buffer is refused Unsupported, untouched, nothing written.
    \\  const refused = [];
    \\  const refusedFile = await cwd.createFile(fs, 'refused.txt');
    \\  for (const [name, view, expected] of [['sab', sab, 'sabx'], ['resizable', resizable, 'rsiz'], ['wasm', wasm, 'wasm']]) {
    \\    if (!view) continue;
    \\    const before = view.buffer.byteLength;
    \\    const results = await Promise.all([
    \\      refusedFile.writeStreamingMoveAll(fs, view).then(() => false, e => IoError.is(e, IoError.Unsupported)),
    \\      refusedFile.writeStreamingMove(fs, view).then(() => false, e => IoError.is(e, IoError.Unsupported)),
    \\      refusedFile.writePositionalMoveAll(fs, view, 0).then(() => false, e => IoError.is(e, IoError.Unsupported)),
    \\    ]);
    \\    refused.push(name + ':' + (results.every(Boolean) && view.buffer.byteLength === before && text(view) === expected));
    \\  }
    \\  await refusedFile.close(fs);
    \\  out.moveRefused = refused.join(',');
    \\  out.moveRefusedAll = refused.every(entry => entry.endsWith(':true')) && refused.length >= 1 && (await read('refused.txt')).length === 0;
    \\  // A buffer already detached by a move is StaleHandle for another write.
    \\  const stale = bytes('zz');
    \\  const staleFile = await cwd.createFile(fs, 'stale.txt');
    \\  await staleFile.writeStreamingMoveAll(fs, stale);
    \\  out.staleWrite = await staleFile.writeStreamingAll(fs, stale).then(() => 'ok', e => IoError.is(e, HostError.StaleHandle));
    \\  await staleFile.close(fs);
    \\  // Sync io has no move variant: Unsupported (same as the sync zero-copy reads).
    \\  const syncMoveFile = Dir.cwd().createFile(sync, 'syncmove.txt');
    \\  try { syncMoveFile.writeStreamingMoveAll(sync, bytes('s')); out.syncMove = false; } catch (e) { out.syncMove = IoError.is(e, IoError.Unsupported); }
    \\  syncMoveFile.close(sync);
    \\
    \\  // BYOB: the data lands in the returned view; the original buffer is dead.
    \\  await cwd.writeFile(fs, { sub_path: 'r.txt', data: bytes('0123456789') });
    \\  const rf = await cwd.openFile(fs, 'r.txt');
    \\  const target = new Uint8Array(6);
    \\  const got = await rf.readInto(fs, target);
    \\  out.byob = got.bytes === 6 && got.buffer instanceof Uint8Array && text(got.buffer) === '012345' && Object.isFrozen(got);
    \\  out.byobDead = target.buffer.byteLength === 0 && target.length === 0 && got.buffer.buffer !== target.buffer;
    \\  // Subarray views keep their offset and length through the round trip; the head stays zero.
    \\  const whole = new Uint8Array(12);
    \\  const sub = whole.subarray(3, 9);
    \\  const subGot = await rf.readInto(fs, sub, 2);
    \\  out.subView = subGot.bytes === 6 && subGot.buffer.byteOffset === 3 && subGot.buffer.length === 6 && text(subGot.buffer) === '234567'
    \\    && subGot.buffer.buffer.byteLength === 12 && new Uint8Array(subGot.buffer.buffer).slice(0, 3).every(b => b === 0);
    \\  // Other typed arrays and DataView come back as the same kind.
    \\  const u16 = await rf.readInto(fs, new Uint16Array(2), 0);
    \\  out.u16 = u16.buffer instanceof Uint16Array && u16.buffer.length === 2 && u16.bytes === 4 && u16.buffer[0] === 0x3130;
    \\  const dv = await rf.readInto(fs, new DataView(new ArrayBuffer(4)), 4);
    \\  out.dataView = dv.buffer instanceof DataView && dv.buffer.byteLength === 4 && dv.buffer.getUint8(0) === 0x34;
    \\  const bare = await rf.readInto(fs, new ArrayBuffer(3), 7);
    \\  out.bareBuffer = bare.buffer instanceof ArrayBuffer && bare.bytes === 3 && text(new Uint8Array(bare.buffer)) === '789';
    \\  // Short read at the end of the file and an empty buffer.
    \\  const tail = await rf.readInto(fs, new Uint8Array(8), 8);
    \\  out.shortByob = tail.bytes === 2 && tail.buffer.length === 8 && text(tail.buffer.subarray(0, 2)) === '89';
    \\  const atEnd = await rf.readInto(fs, new Uint8Array(4), 10);
    \\  out.eofByob = atEnd.bytes === 0 && atEnd.buffer.length === 4;
    \\  const empty = await rf.readInto(fs, new Uint8Array(0), 0);
    \\  out.emptyByob = empty.bytes === 0 && empty.buffer.length === 0;
    \\  // Streaming BYOB advances the position; ineligible buffers fall back to copy-out.
    \\  const sf = await cwd.openFile(fs, 'r.txt');
    \\  const s1 = await sf.readInto(fs, new Uint8Array(4));
    \\  const s2 = await sf.readInto(fs, new Uint8Array(4));
    \\  out.streamByob = text(s1.buffer) === '0123' && text(s2.buffer) === '4567';
    \\  const shared = sab ? new Uint8Array(new SharedArrayBuffer(4)) : new Uint8Array(new ArrayBuffer(4, { maxByteLength: 8 }));
    \\  const sh = await rf.readInto(fs, shared, 1);
    \\  out.byobFallback = sh.bytes === 4 && text(sh.buffer) === '1234' && text(shared) === '1234' && shared.buffer.byteLength === 4;
    \\  await sf.close(fs);
    \\
    \\  // Host-allocated reads: exactly the bytes read.
    \\  const a1 = await rf.readAlloc(fs, 4, 2);
    \\  out.alloc = a1 instanceof Uint8Array && a1.length === 4 && text(a1) === '2345';
    \\  const a2 = await rf.readAlloc(fs, 100, 6);
    \\  out.allocShort = a2.length === 4 && text(a2) === '6789' && a2.buffer.byteLength >= 4;
    \\  const big = await rf.readAlloc(fs, 1 << 20, 6);
    \\  out.allocCompact = big.length === 4 && text(big) === '6789' && big.buffer.byteLength === 4;
    \\  const a3 = await rf.readAlloc(fs, 100, 10);
    \\  out.allocEof = a3 instanceof Uint8Array && a3.length === 0;
    \\  const a4 = await rf.readAlloc(fs, 0, 0);
    \\  out.allocZero = a4.length === 0;
    \\  const sa = await cwd.openFile(fs, 'r.txt');
    \\  out.allocStream = text(await sa.readAlloc(fs, 3)) + text(await sa.readAlloc(fs, 3)) + ':' + (await sa.readAlloc(fs, 100)).length;
    \\  await sa.close(fs);
    \\  // The sync arm has neither.
    \\  const syncFile = cwd.openFile(sync, 'r.txt');
    \\  const unsupported = f => { try { f(); return false; } catch (e) { return IoError.is(e, IoError.Unsupported); } };
    \\  out.syncUnsupported = unsupported(() => syncFile.readInto(sync, new Uint8Array(1))) && unsupported(() => syncFile.readAlloc(sync, 1));
    \\  syncFile.close(sync);
    \\
    \\  // Raw glue validation: rejects InvalidInput without touching the buffer.
    \\  const raw = await fs.dirOpenFile(cwd, 'r.txt', 'r');
    \\  const code = p => p.then(() => 0, e => e.errno);
    \\  const untouched = new Uint8Array(4);
    \\  out.validation = [
    \\    await code(fs.fileReadInto(raw, [1, 2])),
    \\    await code(fs.fileReadInto(raw, 'x')),
    \\    await code(fs.fileReadInto({ kind: 'dir', fs: 0, id: 0 }, untouched)),
    \\    await code(fs.filePreadInto(raw, untouched, -1)),
    \\    await code(fs.filePreadInto(raw, untouched, '0')),
    \\    await code(fs.filePreadInto(raw, untouched, 1.5)),
    \\    await code(fs.fileReadAlloc(raw, -1)),
    \\    await code(fs.fileReadAlloc(raw, '4')),
    \\    await code(fs.filePreadAlloc(raw, 4, NaN)),
    \\    await code(fs.filePreadAlloc({}, 4, 0)),
    \\  ].join(',');
    \\  out.validationUntouched = untouched.buffer.byteLength === 4;
    \\  out.rawOk = (await fs.fileReadInto(raw, untouched)).bytes === 4 && untouched.buffer.byteLength === 0;
    \\  out.rawFrozen = Object.isFrozen(await fs.filePreadInto(raw, new Uint8Array(2), 0));
    \\  await fs.fileClose(raw);
    \\  // Use after close rejects.
    \\  await rf.close(fs);
    \\  out.afterClose = await code(rf.readInto(fs, new Uint8Array(1), 0)) !== 0 && await code(rf.readAlloc(fs, 1, 0)) !== 0;
    \\  await rt.close();
    \\}
;

test "api: async buffers are pinned and detached, BYOB and host-allocated reads (auto and threaded backends)" {
    inline for (.{ "auto", "threaded" }) |backend| {
        var fx: Fixture = undefined;
        try setupBackend(&fx, zero_copy_source, backend, .{});
        defer fx.deinit();
        try fx.run();
        try check(fx.scope, "report.copyKeeps && report.copyWritten && report.partialCopy && report.plainKeeps && report.writeAllDetached && report.partial && report.positionalDetached && report.afterWrites && report.sliceKeeps");
        try check(fx.scope, "report.moveRefusedAll && report.staleWrite === true && report.syncMove === true && report.rustCopies");
        try check(fx.scope, "report.rustDetached && report.rustString && report.copied && report.copiedSync");
        try check(fx.scope, "report.copyFallbackAll");
        try check(fx.scope, "report.byob && report.byobDead && report.subView && report.u16 && report.dataView && report.bareBuffer");
        try check(fx.scope, "report.shortByob && report.eofByob && report.emptyByob && report.streamByob && report.byobFallback");
        try check(fx.scope, "report.alloc && report.allocShort && report.allocCompact && report.allocEof && report.allocZero && report.allocStream === '012345:4'");
        try check(fx.scope, "report.syncUnsupported && report.validation === '30,30,30,30,30,30,30,30,30,30' && report.validationUntouched && report.rawOk && report.rawFrozen && report.afterClose");
    }
}

test "api: closing an io runtime with pinned reads and writes in flight is safe" {
    var fx: Fixture = undefined;
    try setupBackend(&fx,
        \\import { Dir, IoError, HostError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const rt = api.io.create({ backend: '@BACKEND@' });
        \\  const fs = await api.fs.requestAsync({ handle: 'plain', io: rt, access: 'rw' });
        \\  const cwd = Dir.cwd();
        \\  await cwd.writeFile(fs, { sub_path: 'big.bin', data: new Uint8Array(4 << 20).fill(65) });
        \\  const file = await cwd.openFile(fs, 'big.bin');
        \\  const out_file = await cwd.createFile(fs, 'out.bin');
        \\  const views = [];
        \\  const pending = [];
        \\  for (let i = 0; i < 32; i++) {
        \\    const v = new Uint8Array(1 << 20);
        \\    views.push(v);
        \\    pending.push(file.readInto(fs, v, i * 1024));
        \\    pending.push(out_file.writePositionalAll(fs, new Uint8Array(1 << 18).fill(66), i << 18));
        \\    pending.push(file.readAlloc(fs, 1 << 20, i * 4096));
        \\  }
        \\  const closing = rt.close();
        \\  const settled = await Promise.allSettled(pending);
        \\  await closing;
        \\  out.settled = settled.length === pending.length;
        \\  const allowed = [HostError.Canceled, HostError.StaleHandle, HostError.BadHandle];
        \\  out.errors = settled.every(r => r.status === 'fulfilled' || allowed.includes(r.reason.errno));
        \\  out.canceled = settled.some(r => r.status === 'rejected' && r.reason.errno === HostError.Canceled) || settled.every(r => r.status === 'fulfilled');
        \\  // Whatever completed holds exactly what was read; nothing is resurrected into the dead buffers.
        \\  out.results = settled.every((r, i) => r.status !== 'fulfilled' || i % 3 === 1 || (r.value instanceof Uint8Array ? r.value.every(b => b === 65) : r.value.buffer.subarray(0, r.value.bytes).every(b => b === 65)));
        \\  out.deadViews = views.every(v => v.length === 0 || v.byteLength === 1 << 20);
        \\  // A new runtime still works.
        \\  const rt2 = api.io.create({});
        \\  const fs2 = await api.fs.requestAsync({ handle: 'plain', io: rt2, access: 'r' });
        \\  out.after = (await cwd.readFile(fs2, 'big.bin')).length === 4 << 20;
        \\  await rt2.close();
        \\  // Left in flight at Host.destroy.
        \\  const last = api.io.create({});
        \\  const lastFs = await api.fs.requestAsync({ handle: 'plain', io: last, access: 'r' });
        \\  const lastFile = await cwd.openFile(lastFs, 'big.bin');
        \\  globalThis.dangling = [lastFile.readInto(lastFs, new Uint8Array(1 << 20), 0), lastFile.readAlloc(lastFs, 1 << 20, 0)].map(p => p.catch(() => undefined));
        \\}
    , "threaded", .{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.settled && report.errors && report.canceled && report.results && report.deadViews && report.after");
}

test "api: several BYOB reads over one ArrayBuffer settle cleanly and re-wrapped stores are sound" {
    var fx: Fixture = undefined;
    try setupBackend(&fx,
        \\import { Dir } from 'origine:@std/io';
        \\const text = b => String.fromCharCode(...b);
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const rt = api.io.create({ backend: '@BACKEND@' });
        \\  const fs = await api.fs.requestAsync({ handle: 'plain', io: rt, access: 'rw' });
        \\  const cwd = Dir.cwd();
        \\  await cwd.writeFile(fs, { sub_path: 'd.txt', data: Uint8Array.from('abcdefghijklmnopqrstuvwx', c => c.charCodeAt(0)) });
        \\  const file = await cwd.openFile(fs, 'd.txt');
        \\  // Different views of ONE ArrayBuffer in flight together: the buffer can be pinned once. Every
        \\  // call settles (no hang, no crash); the ones that win hold the right bytes.
        \\  const one = new ArrayBuffer(24);
        \\  const views = [new Uint8Array(one, 0, 8), new Uint8Array(one, 8, 8), new Uint8Array(one, 16, 8)];
        \\  const settled = await Promise.allSettled(views.map((v, i) => file.readInto(fs, v, i * 8)));
        \\  out.settled = settled.length === 3;
        \\  out.won = settled.some(r => r.status === 'fulfilled');
        \\  out.right = settled.every((r, i) => r.status !== 'fulfilled' || r.value.bytes === 0 || text(r.value.buffer.subarray(0, r.value.bytes)) === 'abcdefghijklmnopqrstuvwx'.slice(i * 8, i * 8 + r.value.bytes));
        \\  out.cleanRejections = settled.every(r => r.status === 'fulfilled' || typeof r.reason.errno === 'number');
        \\  out.bufferDetachedOnce = one.byteLength === 0;
        \\  // Re-wrapped stores (get_backing_store -> with_backing_store under the V8 sandbox): many rounds,
        \\  // each result is a fresh ArrayBuffer over the filled memory and the old views stay empty.
        \\  let sound = true;
        \\  for (let i = 0; i < 200; i++) {
        \\    const v = new Uint8Array(24);
        \\    const old = v.subarray(4, 8);
        \\    const r = await file.readInto(fs, v, 0);
        \\    sound = sound && r.bytes === 24 && text(r.buffer) === 'abcdefghijklmnopqrstuvwx' && v.length === 0 && old.length === 0
        \\      && v.buffer.byteLength === 0 && r.buffer.buffer.byteLength === 24 && r.buffer.buffer !== v.buffer;
        \\    // The returned buffer is itself eligible again: a round trip through a second read.
        \\    const again = await file.readInto(fs, r.buffer, 0);
        \\    sound = sound && again.bytes === 24 && r.buffer.length === 0 && text(again.buffer) === 'abcdefghijklmnopqrstuvwx';
        \\  }
        \\  out.sound = sound;
        \\  await file.close(fs);
        \\  await rt.close();
        \\}
    , "threaded", .{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.settled && report.won && report.right && report.cleanRejections && report.bufferDetachedOnce && report.sound");
}

const net_source =
    \\export async function main(api) {
    \\  try {
    \\    await body(api);
    \\  } catch (e) {
    \\    throw new Error('net test failed: ' + (e instanceof Error ? e.stack : JSON.stringify(e)));
    \\  }
    \\}
    \\async function body(api) {
    \\  const out = globalThis.report = {};
    \\  const { Handle, Server, Socket, PullServer, PullSocket, EventSocket } = api.net;
    \\  const io = api.io.create({ backend: '@BACKEND@' });
    \\  const server = api.net.listen(io, { port: 0, mode: 'pull', socketMode: 'pull' });
    \\  out.server = server instanceof PullServer && server instanceof Server && server instanceof Handle && server.port > 0 && server.io === io && !server.closed &&
    \\    server.register === undefined && typeof server.accept === 'function';
    \\
    \\  // Echo server: one connection, echo until end of stream.
    \\  const echoed = (async () => {
    \\    const conn = await server.accept();
    \\    let total = 0;
    \\    for (;;) {
    \\      const chunk = await conn.read(4096);
    \\      if (chunk.length === 0) break;
    \\      await conn.queued.send(chunk);
    \\      total += chunk.length;
    \\    }
    \\    await conn.close();
    \\    return total;
    \\  })();
    \\
    \\  const client = await api.net.connect(io, { host: '127.0.0.1', port: server.port, mode: 'pull' });
    \\  out.client = client instanceof PullSocket && client instanceof Socket && client instanceof Handle && client.remotePort === server.port &&
    \\    client.register === undefined && client.pause === undefined && client.toPull === undefined && typeof client.read === 'function';
    \\  const message = Uint8Array.from('ping-pong', c => c.charCodeAt(0));
    \\  let reply = '';
    \\  for (let i = 0; i < 3; i++) {
    \\    out.wrote = (await client.queued.send(message)) === undefined;
    \\    let got = new Uint8Array(0);
    \\    while (got.length < message.length) {
    \\      const part = await client.read(64);
    \\      const next = new Uint8Array(got.length + part.length);
    \\      next.set(got);
    \\      next.set(part, got.length);
    \\      got = next;
    \\    }
    \\    reply += String.fromCharCode(...got) + ';';
    \\  }
    \\  out.reply = reply === 'ping-pong;ping-pong;ping-pong;';
    \\
    \\  // readInto: a reusable guest buffer, nothing detached, partial windows, end of stream.
    \\  await client.queued.send(message);
    \\  const reuse = new Uint8Array(32);
    \\  let have = 0;
    \\  while (have < message.length) have += await client.readCopy(reuse.subarray(have));
    \\  out.readCopy = have === message.length && String.fromCharCode(...reuse.subarray(0, have)) === 'ping-pong' && reuse.buffer.byteLength === 32 &&
    \\    (await client.readCopy(new Uint8Array(0))) === 0 &&
    \\    (await client.readCopy({}).then(() => false, e => e instanceof TypeError));
    \\
    \\  // readInto: the buffer is detached and handed back as a new ArrayBuffer; undetachable buffers are refused untouched.
    \\  await client.queued.send(message);
    \\  const pinned = new Uint8Array(32);
    \\  const got = await client.readInto(pinned);
    \\  out.readInto = got.bytes === message.length && got.buffer instanceof ArrayBuffer && got.buffer.byteLength === 32 && pinned.length === 0 &&
    \\    String.fromCharCode(...new Uint8Array(got.buffer, 0, got.bytes)) === 'ping-pong';
    \\  const sab = new Uint8Array(new SharedArrayBuffer(8));
    \\  out.readIntoRefused = (await client.readInto(sab).then(() => false, e => e.name === 'Unsupported')) && sab.length === 8 &&
    \\    (await client.readInto(new Uint8Array(0)).then(() => false, e => e instanceof TypeError)) &&
    \\    (await client.readInto({}).then(() => false, e => e instanceof TypeError));
    \\
    \\  // A large write is sent whole and echoed back in order.
    \\  const big = new Uint8Array(1 << 20).map((_, i) => i & 255);
    \\  const sending = client.queued.send(big);
    \\  let received = 0, ordered = true;
    \\  while (received < big.length) {
    \\    const part = await client.read(1 << 16);
    \\    for (let i = 0; i < part.length; i++) ordered &&= part[i] === ((received + i) & 255);
    \\    received += part.length;
    \\  }
    \\  out.big = (await sending) === undefined && received === big.length && ordered;
    \\
    \\  // Closing the client ends the echo loop; reads after close reject.
    \\  await client.close();
    \\  out.echoTotal = (await echoed) === 27 + 9 + 9 + (1 << 20);
    \\  out.closed = client.closed && (await client.read(1).then(() => false, e => e.name === 'BadHandle'));
    \\
    \\  // Errors and validation.
    \\  const refused = await api.net.connect(io, { port: server.port, mode: 'pull' }).then(() => 'ok', e => e.name);
    \\  await server.close();
    \\  out.refused = refused === 'ConnectionRefused' || refused === 'ok';
    \\  out.denied = await api.net.connect(io, { host: '8.8.8.8', port: 53, mode: 'pull' }).then(() => false, e => e.name === 'PermissionDenied');
    \\  out.badIo = (() => { try { api.net.listen({}, { mode: 'pull', socketMode: 'pull' }); return false; } catch (e) { return e.name === 'BadHandle'; } })();
    \\  out.badArgs = (() => { try { api.net.listen(io, { port: 70000, mode: 'pull', socketMode: 'pull' }); return false; } catch (e) { return e instanceof TypeError; } })() &&
    \\    (() => { try { api.net.listen(io, { port: 0, socketMode: 'pull' }); return false; } catch (e) { return e instanceof TypeError; } })() &&
    \\    (() => { try { api.net.listen(io, { port: 0, mode: 'pull' }); return false; } catch (e) { return e instanceof TypeError; } })() &&
    \\    (() => { try { api.net.listen(io, { port: 0, mode: 'both', socketMode: 'pull' }); return false; } catch (e) { return e instanceof TypeError; } })() &&
    \\    (await api.net.connect(io, { mode: 'pull' }).then(() => false, e => e instanceof TypeError)) &&
    \\    (await api.net.connect(io, { port: 1 }).then(() => false, e => e instanceof TypeError));
    \\  out.noForge = (() => { try { new PullSocket({}, {}); return false; } catch (e) { return e instanceof TypeError; } })() &&
    \\    await PullSocket.prototype.read.call({}, 1).then(() => false, e => e instanceof TypeError) &&
    \\    Object.isFrozen(api.net) && Object.isFrozen(Socket) && Object.isFrozen(Socket.prototype);
    \\
    \\  // Closing the runtime invalidates open handles.
    \\  const second = api.net.listen(io, { mode: 'pull', socketMode: 'pull' });
    \\  await io.close();
    \\  out.afterIoClose = second.closed && (await second.accept().then(() => false, e => e.name === 'BadHandle'));
    \\}
;

const events_source =
    \\export async function main(api) {
    \\  try {
    \\    await body(api);
    \\  } catch (e) {
    \\    throw new Error('events test failed: ' + (e instanceof Error ? e.stack : JSON.stringify(e)));
    \\  }
    \\}
    \\async function body(api) {
    \\  const out = globalThis.report = {};
    \\  const io = api.io.create({ backend: '@BACKEND@' });
    \\  const server = api.net.listen(io, { port: 0, mode: 'event', socketMode: 'event' });
    \\  const enc = s => Uint8Array.from(s, c => c.charCodeAt(0));
    \\  let serverEnded = false, serverClosed = false, serverEvent = false, accepted = 0;
    \\
    \\  // Echo server over events: lease the chunk, send it back, give the lease back.
    \\  const reg = server.register('connection', conn => {
    \\    accepted++;
    \\    // Paused while the echo is queued: a slow peer holds the reads back instead of piling up sends.
    \\    conn.register('data', ev => {
    \\      const buf = ev.buffer();
    \\      conn.pause();
    \\      conn.queued.send(buf).then(() => { buf.unref(); conn.resume(); });
    \\    });
    \\    conn.register('end', () => { serverEnded = true; conn.end('write'); poke(); });
    \\    conn.register('close', () => { serverClosed = true; poke(); });
    \\  });
    \\  server.register('close', () => { serverEvent = true; });
    \\  // Handlers do not keep the program alive; a pending `io.run()` does (until every flowing handle closed).
    \\  const running = io.run();
    \\  let settled = false;
    \\  running.then(() => { settled = true; });
    \\
    \\  const client = await api.net.connect(io, { host: '127.0.0.1', port: server.port, mode: 'event' });
    \\  const waiters = [];
    \\  const poke = () => { for (const w of waiters.splice(0)) w(); };
    \\  const until = pred => new Promise(resolve => {
    \\    const check = () => (pred() ? resolve() : waiters.push(check));
    \\    check();
    \\  });
    \\
    \\  let text = '', total = 0, position = 0, ordered = true, countBytes = false;
    \\  let leak = false, count = 0, ready = 0, retained = null, keptEvent = null, sameLease = false, extra = 0;
    \\  const errors = [];
    \\  client.register('error', e => { errors.push(e); poke(); });
    \\  client.register('drain', () => { ready++; poke(); });
    \\  client.register('data', ev => {
    \\    keptEvent = ev;
    \\    const buf = ev.buffer();
    \\    sameLease = ev.buffer() === buf && ev.length === buf.length && buf.buffer.byteLength === buf.length;
    \\    total += buf.length;
    \\    if (countBytes) {
    \\      for (let i = 0; i < buf.length; i++) ordered &&= buf[i] === ((position + i) & 255);
    \\      position += buf.length;
    \\    } else {
    \\      text += String.fromCharCode(...buf);
    \\    }
    \\    if (text === 'ping-pong' && retained === null) retained = buf; // kept past the callback
    \\    else if (!leak) buf.unref();
    \\    poke();
    \\  });
    \\  // A throwing handler is routed to the error handlers; the other handlers still run.
    \\  client.register('data', ev => { if (ev.length === 4) throw new Error('boom'); });
    \\  // unregister stops delivery to that handler only.
    \\  const counted = client.register('data', () => { count++; });
    \\
    \\  out.sendTrue = client.queued.put(enc('ping-pong')) === 9;
    \\  await until(() => text === 'ping-pong');
    \\  out.echo = true;
    \\  out.eventValid = sameLease;
    \\
    \\  // A retained lease stays valid until it is given back, then it is empty.
    \\  out.retained = retained.length === 9 && String.fromCharCode(...retained) === 'ping-pong' && !retained.released;
    \\  retained.unref();
    \\  retained.unref();
    \\  out.released = retained.released && retained.length === 0 && retained.buffer.byteLength === 0;
    \\  out.eventOver = keptEvent.length === 0 && (() => { try { keptEvent.buffer(); return false; } catch (e) { return e instanceof TypeError; } })();
    \\
    \\  // Pooled stores are reused across many chunks without mixing them up.
    \\  let pooled = true;
    \\  for (let i = 0; i < 200; i++) {
    \\    const message = `msg-${i}-${'x'.repeat(i % 37)}`;
    \\    text = '';
    \\    client.queued.put(enc(message));
    \\    await until(() => text.length >= message.length);
    \\    pooled &&= text === message;
    \\  }
    \\  out.pooled = pooled;
    \\
    \\  // Leases that are never released (left to the garbage collector) neither leak nor starve the pump:
    \\  // the pool is refilled with fresh stores.
    \\  leak = true;
    \\  let leaky = true;
    \\  for (let i = 0; i < 60; i++) {
    \\    const message = `leak-${i}`;
    \\    text = '';
    \\    client.queued.put(enc(message));
    \\    await until(() => text === message);
    \\    leaky &&= text === message;
    \\  }
    \\  leak = false;
    \\  out.leaky = leaky;
    \\
    \\  // Symbol.dispose releases like unref.
    \\  if (typeof Symbol.dispose === 'symbol') {
    \\    const lease = (() => { let got; const r = client.register('data', ev => { got ??= ev.buffer(); }); return { r, get: () => got }; })();
    \\    text = '';
    \\    client.queued.put(enc('dispose'));
    \\    await until(() => text === 'dispose');
    \\    lease.r.unregister();
    \\    const buf = lease.get();
    \\    buf[Symbol.dispose]();
    \\    out.dispose = buf.released && buf.length === 0;
    \\  } else {
    \\    out.dispose = true;
    \\  }
    \\
    \\  // A handler that throws reaches the error handlers.
    \\  text = '';
    \\  client.queued.put(enc('boom'));
    \\  await until(() => errors.length === 1);
    \\  out.thrown = errors[0] instanceof Error && errors[0].message === 'boom' && text === 'boom';
    \\
    \\  const before = count;
    \\  counted.unregister();
    \\  text = '';
    \\  client.queued.put(enc('after'));
    \\  await until(() => text === 'after');
    \\  out.unregistered = count === before && count > 0 && counted.unregister() === false;
    \\
    \\  // A large send is queued whole (the queue was empty); while it drains the queue has priority over
    \\  // direct writes and `put` takes nothing; `drain` follows, and everything comes back in order.
    \\  const big = new Uint8Array(4 << 20).map((_, i) => i & 255);
    \\  countBytes = true;
    \\  total = 0;
    \\  const sent = client.queued.send(big);
    \\  out.backpressure = client.queued.bytes > client.queued.limit && client.direct.write(enc('x')) === 0 && client.queued.put(enc('x')) === 0;
    \\  await sent;
    \\  await until(() => ready > 0);
    \\  await until(() => total === big.length);
    \\  out.big = total === big.length && ordered;
    \\
    \\  // Closing: the peer sees the end and closes; a closed handle refuses everything.
    \\  const closing = new Promise(resolve => client.register('close', resolve));
    \\  await client.close();
    \\  await closing;
    \\  await until(() => serverEnded && serverClosed);
    \\  out.closed = client.closed && accepted === 1 &&
    \\    (() => { try { client.register('data', () => {}); return false; } catch (e) { return e.name === 'BadHandle'; } })() &&
    \\    (() => { try { client.queued.put(enc('x')); return false; } catch (e) { return e.name === 'BadHandle'; } })();
    \\
    \\  // Unregistering the connection handler stops new deliveries; `io.run()` resolves once the server closes.
    \\  out.unreg = reg.unregister() === true;
    \\  for (let i = 0; i < 5; i++) await null;
    \\  out.runWaits = settled === false;
    \\  await server.close();
    \\  await running;
    \\  out.run = settled && serverEvent && server.closed && (await io.run().then(() => true, () => false));
    \\  await io.close();
    \\  out.runAfterClose = await io.run().then(() => false, e => e.name === 'BadHandle');
    \\}
;

const events_idle_source =
    \\export async function main(api) {
    \\  const io = api.io.create({ backend: '@BACKEND@' });
    \\  const server = api.net.listen(io, { port: 0, mode: 'event', socketMode: 'event' });
    \\  server.register('connection', () => {});
    \\  globalThis.report = { registered: true, port: server.port > 0 };
    \\}
;

test "api: net events with pooled leases, backpressure and io.run (auto and threaded backends)" {
    inline for (.{ "auto", "threaded" }) |backend| {
        var fx: Fixture = undefined;
        try setupBackend(&fx, events_source, backend, .{});
        defer fx.deinit();
        try fx.run();
        try check(fx.scope, "report.sendTrue && report.echo && report.eventValid && report.retained && report.released && report.eventOver && report.pooled && report.leaky && report.dispose");
        try check(fx.scope, "report.thrown && report.unregistered && report.backpressure && report.big && report.closed && report.unreg");
        try check(fx.scope, "report.runWaits && report.run && report.runAfterClose");
    }
}

const flow_source =
    \\export async function main(api) {
    \\  try {
    \\    await body(api);
    \\  } catch (e) {
    \\    throw new Error('flow test failed: ' + (e instanceof Error ? e.stack : JSON.stringify(e)));
    \\  }
    \\}
    \\async function body(api) {
    \\  const out = globalThis.report = {};
    \\  const io = api.io.create({ backend: '@BACKEND@' });
    \\  const server = api.net.listen(io, { port: 0, mode: 'pull', socketMode: 'pull' });
    \\  const enc = s => Uint8Array.from(s, c => c.charCodeAt(0));
    \\  const text = bytes => String.fromCharCode(...bytes);
    \\  const names = async promise => promise.then(() => 'ok', e => e.name);
    \\  const pair = async options => {
    \\    const accepting = server.accept();
    \\    const client = await api.net.connect(io, { port: server.port, mode: 'pull', ...options });
    \\    return [client, await accepting];
    \\  };
    \\  const sleep = () => io.sleep(30);
    \\
    \\  // Queue state and the two lanes: a peer that does not read fills the kernel, then the queue.
    \\  const [pulled, peer] = await pair({ sendQueueLimit: 65536 });
    \\  const client = pulled.toEvent();
    \\  let drains = 0;
    \\  client.register('drain', () => { drains++; });
    \\  out.defaults = client.queued.limit === 65536 && peer.queued.limit === (1 << 20) && client.queued.bytes === 0 && client.queued.waiting === 0;
    \\  out.directSmall = client.direct.write(enc('hi')) === 2;
    \\  const chunk = new Uint8Array(65536);
    \\  let direct = 2;
    \\  for (;;) { const n = client.direct.write(chunk); direct += n; if (n === 0) break; }
    \\  let queued = 0;
    \\  while (client.queued.bytes === 0) queued += client.queued.put(chunk); // the kernel takes what it can first
    \\  out.putFillsQueue = client.queued.bytes > 0 && client.queued.bytes <= 65536;
    \\  out.queueWins = client.direct.write(enc('x')) === 0;
    \\  let more;
    \\  while ((more = client.queued.put(chunk)) > 0) queued += more;
    \\  out.putFull = client.queued.bytes === 65536 && client.queued.put(chunk) === 0;
    \\
    \\  // `send` waits for room, keeps its place, and `end` goes after it; `put` yields to waiting sends.
    \\  let sent = false, ended = false;
    \\  const tail = client.queued.send(enc('tail')).then(() => { sent = true; });
    \\  const closing = client.end('write').then(() => { ended = true; });
    \\  const idle = client.queued.drained();
    \\  out.waits = client.queued.waiting === 2 && !sent && client.queued.put(enc('z')) === 0;
    \\
    \\  // The peer reads it all: in call order, then end of stream.
    \\  const scratch = new Uint8Array(1 << 16);
    \\  let total = 0, head = '', last = '';
    \\  for (;;) {
    \\    const n = await peer.readCopy(scratch);
    \\    if (n === 0) break;
    \\    if (total < 2) head += text(scratch.subarray(0, Math.min(n, 2 - total)));
    \\    last = (last + text(scratch.subarray(0, n))).slice(-4);
    \\    total += n;
    \\  }
    \\  await Promise.all([tail, closing, idle]);
    \\  out.order = head === 'hi' && last === 'tail' && total === direct + queued + 4;
    \\  out.settled = sent && ended && client.queued.bytes === 0 && client.queued.waiting === 0 && drains > 0;
    \\  out.afterEnd = (() => { try { client.direct.write(enc('x')); return false; } catch (e) { return e.name === 'BrokenPipe'; } })() &&
    \\    (() => { try { client.queued.put(enc('x')); return false; } catch (e) { return e.name === 'BrokenPipe'; } })() &&
    \\    (await names(client.queued.send(enc('x')))) === 'BrokenPipe';
    \\  await client.close();
    \\  await peer.close();
    \\
    \\  // Closing rejects what is queued and what waits.
    \\  const [c2, p2] = await pair({ sendQueueLimit: 1024 });
    \\  while (c2.direct.write(chunk) > 0);
    \\  const inflight = c2.queued.send(new Uint8Array(1 << 25));
    \\  const waiting = c2.queued.send(enc('more'));
    \\  const emptied = c2.queued.drained();
    \\  out.cancelWaits = c2.queued.waiting === 1;
    \\  await c2.close();
    \\  out.canceled = (await names(inflight)) === 'Canceled' && (await names(waiting)) === 'Canceled' && (await names(emptied)) === 'Canceled';
    \\  await p2.close();
    \\
    \\  // Bad arguments.
    \\  const [c3, p3pull] = await pair();
    \\  const p3 = p3pull.toEvent();
    \\  out.badArgs = (() => { try { c3.queued.put('x'); return false; } catch (e) { return e instanceof TypeError; } })() &&
    \\    (() => { try { c3.direct.write({}); return false; } catch (e) { return e instanceof TypeError; } })() &&
    \\    (() => { try { c3.queued.limit = 0; return false; } catch (e) { return e instanceof TypeError; } })() &&
    \\    (await c3.queued.send({}).then(() => false, e => e instanceof TypeError));
    \\
    \\  // pause: nothing is dispatched until resume, then everything, in order.
    \\  const got = [];
    \\  let ends = 0;
    \\  p3.register('data', ev => { using chunk = ev.buffer(); got.push(text(chunk)); });
    \\  p3.register('end', () => { ends++; });
    \\  p3.pause();
    \\  out.paused = p3.paused === true;
    \\  await c3.queued.send(enc('one'));
    \\  await sleep();
    \\  await c3.queued.send(enc('two'));
    \\  await c3.end('write');
    \\  await sleep();
    \\  out.heldBack = got.length === 0 && ends === 0 && p3.paused;
    \\  p3.resume();
    \\  out.resumed = !p3.paused;
    \\  for (let i = 0; i < 50 && ends === 0; i++) await sleep();
    \\  out.replayed = got.join('') === 'onetwo' && ends === 1;
    \\
    \\  // No handler, no drop: the socket waits for the next one.
    \\  const [c4, p4pull] = await pair();
    \\  const p4 = p4pull.toEvent();
    \\  const first = p4.register('data', () => {});
    \\  first.unregister();
    \\  out.autoPaused = p4.paused;
    \\  await c4.queued.send(enc('kept'));
    \\  await sleep();
    \\  let late = '';
    \\  p4.register('data', ev => { using chunk = ev.buffer(); late += text(chunk); });
    \\  for (let i = 0; i < 50 && late === ''; i++) await sleep();
    \\  out.noDrop = late === 'kept' && !p4.paused;
    \\
    \\  // A paused server stops accepting; the connection waits in the backlog until resume.
    \\  const l2 = api.net.listen(io, { port: 0, mode: 'event', socketMode: 'pull' });
    \\  const seen = [];
    \\  l2.register('connection', conn => { seen.push(conn); conn.close(); });
    \\  l2.pause();
    \\  const c5 = await api.net.connect(io, { port: l2.port, mode: 'pull' });
    \\  await sleep();
    \\  out.serverPaused = seen.length === 0 && l2.paused;
    \\  l2.resume();
    \\  for (let i = 0; i < 50 && seen.length === 0; i++) await sleep();
    \\  out.serverResumed = seen.length === 1;
    \\
    \\  await io.close();
    \\}
;

test "api: net send queue, direct lane, end and pause/resume (auto and threaded backends)" {
    inline for (.{ "auto", "threaded" }) |backend| {
        var fx: Fixture = undefined;
        try setupBackend(&fx, flow_source, backend, .{});
        defer fx.deinit();
        try fx.run();
        try check(fx.scope, "report.defaults");
        try check(fx.scope, "report.directSmall");
        try check(fx.scope, "report.putFillsQueue");
        try check(fx.scope, "report.queueWins");
        try check(fx.scope, "report.putFull");
        try check(fx.scope, "report.waits");
        try check(fx.scope, "report.order");
        try check(fx.scope, "report.settled");
        try check(fx.scope, "report.afterEnd");
        try check(fx.scope, "report.cancelWaits");
        try check(fx.scope, "report.canceled");
        try check(fx.scope, "report.badArgs");
        try check(fx.scope, "report.paused");
        try check(fx.scope, "report.heldBack");
        try check(fx.scope, "report.resumed");
        try check(fx.scope, "report.replayed");
        try check(fx.scope, "report.autoPaused");
        try check(fx.scope, "report.noDrop");
        try check(fx.scope, "report.serverPaused");
        try check(fx.scope, "report.serverResumed");
    }
}

const modes_source =
    \\export async function main(api) {
    \\  try {
    \\    await body(api);
    \\  } catch (e) {
    \\    throw new Error('modes test failed: ' + (e instanceof Error ? e.stack : JSON.stringify(e)));
    \\  }
    \\}
    \\async function body(api) {
    \\  const out = globalThis.report = {};
    \\  const { EventSocket, PullSocket, EventServer, PullServer } = api.net;
    \\  const io = api.io.create({ backend: '@BACKEND@' });
    \\  const enc = s => Uint8Array.from(s, c => c.charCodeAt(0));
    \\  const text = bytes => String.fromCharCode(...bytes);
    \\  const sleep = () => io.sleep(30);
    \\  const waitFor = async pred => { for (let i = 0; i < 100 && !pred(); i++) await sleep(); return pred(); };
    \\  // Half-close: the client ends its write side, the server still replies, then ends its own: both close.
    \\  let got = '', serverEnded = false, halfOpen = false, closeEvent = false, conn;
    \\  const half = api.net.listen(io, { port: 0, mode: 'event', socketMode: 'event' });
    \\  half.register('connection', socket => {
    \\    conn = socket;
    \\    socket.register('data', ev => { using chunk = ev.buffer(); got += text(chunk); });
    \\    socket.register('end', async () => {
    \\      serverEnded = true;
    \\      await sleep();
    \\      halfOpen = !socket.closed;
    \\      await socket.queued.send(enc('reply:' + got));
    \\      await socket.end('write');
    \\    });
    \\    socket.register('close', () => { closeEvent = true; });
    \\  });
    \\  const client = await api.net.connect(io, { port: half.port, mode: 'pull' });
    \\  await client.queued.send(enc('hello'));
    \\  await client.end('write');
    \\  let reply = '';
    \\  for (;;) { const part = await client.read(64); if (part.length === 0) break; reply += text(part); }
    \\  out.halfClose = reply === 'reply:hello' && serverEnded && halfOpen && await waitFor(() => closeEvent) && conn.closed && client.closed;
    \\  await half.close();
    \\
    \\  // A peer's FIN alone closes nothing: the socket stays open and writable until the user acts.
    \\  const hold = api.net.listen(io, { port: 0, mode: 'event', socketMode: 'event' });
    \\  let held, ended = false, heldClosed = false;
    \\  hold.register('connection', socket => {
    \\    held = socket;
    \\    socket.register('data', ev => ev.buffer().unref());
    \\    socket.register('end', () => { ended = true; });
    \\    socket.register('close', () => { heldClosed = true; });
    \\  });
    \\  const running = io.run();
    \\  let settled = false;
    \\  running.then(() => { settled = true; });
    \\  const other = await api.net.connect(io, { port: hold.port, mode: 'pull' });
    \\  await other.queued.send(enc('x'));
    \\  await other.end('write');
    \\  await waitFor(() => ended);
    \\  await hold.close();
    \\  await sleep();
    \\  out.finAlone = ended && !held.closed && !heldClosed && !settled;
    \\  await held.queued.send(enc('late'));
    \\  out.writableAfterFin = text(await other.read(16)) === 'late' && !held.closed;
    \\  await held.end('write');
    \\  out.endClosesBoth = (await other.read(1)).length === 0 && other.closed && await waitFor(() => heldClosed) && held.closed;
    \\  await running;
    \\  out.runAfterClose = settled;
    \\
    \\  // end() needs a side; 'read' discards what arrives and reads resolve empty; 'both' closes after the flush.
    \\  const sides = api.net.listen(io, { port: 0, mode: 'pull', socketMode: 'pull' });
    \\  const sideAccept = sides.accept();
    \\  const mine = await api.net.connect(io, { port: sides.port, mode: 'pull' });
    \\  const theirs = await sideAccept;
    \\  out.sideRequired = (() => { try { mine.end(); return false; } catch (e) { return e instanceof TypeError; } })() &&
    \\    (() => { try { mine.end('bogus'); return false; } catch (e) { return e instanceof TypeError; } })();
    \\  await mine.end('read');
    \\  await theirs.queued.send(enc('ignored'));
    \\  out.endRead = (await mine.read(8)).length === 0 && !mine.closed && (await mine.queued.send(enc('still'))) === undefined &&
    \\    text(await theirs.read(16)) === 'still';
    \\  await mine.end('write');
    \\  out.readThenWrite = mine.closed;
    \\  await theirs.close();
    \\  const bothAccept = sides.accept();
    \\  const b1 = await api.net.connect(io, { port: sides.port, mode: 'pull' });
    \\  const b2 = await bothAccept;
    \\  await b1.queued.send(enc('last'));
    \\  await b1.end('both');
    \\  out.endBoth = b1.closed && text(await b2.read(16)) === 'last' && (await b2.read(1)).length === 0 && !b2.closed;
    \\  await b2.close();
    \\  await sides.close();
    \\
    \\  // Leases carry exactly the bytes received, whatever the chunks before them held.
    \\  const sizes = [100, 1, 7000, 3, 16384, 40000, 5, 1000];
    \\  const lengths = [];
    \\  let exact = true, clean = true, total = 0, inOrder = true, byteLengths = [];
    \\  const eventServer = api.net.listen(io, { port: 0, mode: 'event', socketMode: 'event' });
    \\  const echo = [];
    \\  eventServer.register('connection', socket => {
    \\    socket.register('data', ev => {
    \\      const buf = ev.buffer();
    \\      exact &&= buf.buffer.byteLength === buf.length && buf.buffer.byteLength === ev.length && buf.byteOffset === 0;
    \\      byteLengths.push(buf.buffer.byteLength);
    \\      // Nothing but the received bytes is reachable through the buffer.
    \\      const view = new Uint8Array(buf.buffer);
    \\      for (let i = 0; i < view.length; i++) { clean &&= view[i] === (total + i) % 251 + 1; }
    \\      total += buf.length;
    \\      buf.unref();
    \\    });
    \\  });
    \\  const feeder = await api.net.connect(io, { port: eventServer.port, mode: 'pull' });
    \\  let sent = 0;
    \\  for (const size of sizes) {
    \\    const chunk = new Uint8Array(size).map((_, i) => (sent + i) % 251 + 1);
    \\    await feeder.queued.send(chunk);
    \\    sent += size;
    \\    await waitFor(() => total === sent);
    \\  }
    \\  out.exactLeases = exact && clean && total === sent && byteLengths.every(n => n >= 1 && n <= 16384) && byteLengths.reduce((a, b) => a + b, 0) === sent;
    \\  await feeder.close();
    \\  await eventServer.close();
    \\
    \\  // Mode transfer: the old handle is consumed, the writers carry over, the new class has only its own methods.
    \\  const pullServer = api.net.listen(io, { port: 0, mode: 'pull', socketMode: 'pull' });
    \\  const accepting = pullServer.accept();
    \\  const busyServer = (() => { try { pullServer.toEvent(); return false; } catch (e) { return e.name === 'WouldBlock'; } })();
    \\  const pulled = await api.net.connect(io, { port: pullServer.port, mode: 'pull' });
    \\  const accepted = await accepting;
    \\  const queue = pulled.queued;
    \\  const pending = pulled.read(8);
    \\  const busy = (() => { try { pulled.toEvent(); return false; } catch (e) { return e.name === 'WouldBlock'; } })();
    \\  await accepted.queued.send(enc('go'));
    \\  await pending;
    \\  const evented = pulled.toEvent();
    \\  out.toEvent = busy && busyServer && evented instanceof EventSocket && evented.queued === queue && typeof evented.direct.write === 'function' &&
    \\    pulled.closed && !evented.closed && evented.read === undefined && typeof evented.register === 'function' &&
    \\    (() => { try { pulled.queued; return false; } catch (e) { return e.name === 'BadHandle'; } })() &&
    \\    (await pulled.read(1).then(() => false, e => e.name === 'BadHandle')) &&
    \\    (() => { try { pulled.toEvent(); return false; } catch (e) { return e.name === 'BadHandle'; } })();
    \\  const echoed = [];
    \\  evented.register('data', ev => { using chunk = ev.buffer(); echoed.push(text(chunk)); });
    \\  await accepted.queued.send(enc('more'));
    \\  await waitFor(() => echoed.join('') === 'more');
    \\  out.eventedWorks = echoed.join('') === 'more' &&
    \\    (() => { try { evented.toPull(); return false; } catch (e) { return e.name === 'Unsupported'; } })() && !evented.closed;
    \\  await evented.close();
    \\  await accepted.close();
    \\
    \\  // A socket that never started reading goes back to pull mode (handlers dropped, writers kept).
    \\  const second = await api.net.connect(io, { port: pullServer.port, mode: 'event' });
    \\  const secondPeer = await pullServer.accept();
    \\  let stray = 0;
    \\  second.register('end', () => { stray++; });
    \\  const back = second.toPull();
    \\  out.toPull = back instanceof PullSocket && back.read !== undefined && back.register === undefined && second.closed && !back.closed;
    \\  await secondPeer.queued.send(enc('pulled'));
    \\  out.toPullReads = text(await back.read(16)) === 'pulled';
    \\  await secondPeer.close();
    \\  out.toPullEnd = (await back.read(1)).length === 0 && stray === 0;
    \\  await back.close();
    \\
    \\  // Servers: pull to event and back; accepted sockets take the server's socketMode.
    \\  const eventing = pullServer.toEvent();
    \\  out.serverTransfer = eventing instanceof EventServer && pullServer.closed && eventing.port === pullServer.port &&
    \\    (await pullServer.accept().then(() => false, e => e.name === 'BadHandle'));
    \\  const seen = [];
    \\  const registration = eventing.register('connection', socket => { seen.push(socket); });
    \\  const third = await api.net.connect(io, { port: eventing.port, mode: 'pull' });
    \\  await waitFor(() => seen.length === 1);
    \\  out.socketMode = seen[0] instanceof PullSocket && seen[0].read !== undefined;
    \\  registration.unregister();
    \\  await third.close();
    \\  await seen[0].close();
    \\  out.serverBack = (() => { try { eventing.toPull(); return false; } catch (e) { return e.name === 'Unsupported'; } })();
    \\  await eventing.close();
    \\  const idleServer = api.net.listen(io, { port: 0, mode: 'event', socketMode: 'event' });
    \\  const idleBack = idleServer.toPull();
    \\  out.serverBackIdle = idleBack instanceof PullServer && idleServer.closed && idleBack.accept !== undefined;
    \\  await idleBack.close();
    \\
    \\  // `localhost` is not resolved: 127.0.0.1 first, then ::1; listen binds 127.0.0.1.
    \\  const lo = api.net.listen(io, { host: 'localhost', port: 0, mode: 'pull', socketMode: 'pull' });
    \\  const loAccept = lo.accept();
    \\  const viaName = await api.net.connect(io, { host: 'localhost', port: lo.port, mode: 'pull' });
    \\  const loPeer = await loAccept;
    \\  const viaIp = await api.net.connect(io, { host: '127.0.0.1', port: lo.port, mode: 'pull' });
    \\  out.localhost = viaName.remotePort === lo.port && viaIp.remotePort === lo.port;
    \\  await Promise.all([viaName.close(), viaIp.close(), loPeer.close(), lo.close()]);
    \\  let v6;
    \\  try { v6 = api.net.listen(io, { host: '::1', port: 0, mode: 'pull', socketMode: 'pull' }); } catch { v6 = null; }
    \\  if (v6 === null) {
    \\    out.localhostV6 = true;
    \\  } else {
    \\    const v6Accept = v6.accept();
    \\    const viaFallback = await api.net.connect(io, { host: 'localhost', port: v6.port, mode: 'pull' });
    \\    const v6Peer = await v6Accept;
    \\    out.localhostV6 = viaFallback.remotePort === v6.port;
    \\    await Promise.all([viaFallback.close(), v6Peer.close(), v6.close()]);
    \\  }
    \\  const gone = api.net.listen(io, { port: 0, mode: 'pull', socketMode: 'pull' });
    \\  const goneAt = gone.port;
    \\  await gone.close();
    \\  const refused = await api.net.connect(io, { host: 'localhost', port: goneAt, mode: 'pull' }).then(() => 'ok', e => e.name);
    \\  out.refused = refused === 'ConnectionRefused' || refused === 'ok';
    \\  out.denied = (await api.net.connect(io, { host: 'example.com', port: 80, mode: 'pull' }).then(() => false, e => e.name === 'PermissionDenied')) &&
    \\    (await api.net.connect(io, { host: '10.0.0.1', port: 80, mode: 'pull' }).then(() => false, e => e.name === 'PermissionDenied'));
    \\  await io.close();
    \\}
;

test "api: net modes, half-close, mode transfer, exact leases and localhost (auto and threaded backends)" {
    inline for (.{ "auto", "threaded" }) |backend| {
        var fx: Fixture = undefined;
        try setupBackend(&fx, modes_source, backend, .{});
        defer fx.deinit();
        try fx.run();
        try check(fx.scope, "report.halfClose");
        try check(fx.scope, "report.finAlone");
        try check(fx.scope, "report.writableAfterFin");
        try check(fx.scope, "report.endClosesBoth");
        try check(fx.scope, "report.sideRequired");
        try check(fx.scope, "report.endRead");
        try check(fx.scope, "report.readThenWrite");
        try check(fx.scope, "report.endBoth");
        try check(fx.scope, "report.runAfterClose");
        try check(fx.scope, "report.exactLeases");
        try check(fx.scope, "report.toEvent");
        try check(fx.scope, "report.eventedWorks");
        try check(fx.scope, "report.toPull");
        try check(fx.scope, "report.toPullReads");
        try check(fx.scope, "report.toPullEnd");
        try check(fx.scope, "report.serverTransfer");
        try check(fx.scope, "report.socketMode");
        try check(fx.scope, "report.serverBack");
        try check(fx.scope, "report.serverBackIdle");
        try check(fx.scope, "report.localhost");
        try check(fx.scope, "report.localhostV6");
        try check(fx.scope, "report.refused");
        try check(fx.scope, "report.denied");
    }
}

test "api: registered handlers alone do not keep the program alive" {
    inline for (.{ "auto", "threaded" }) |backend| {
        var fx: Fixture = undefined;
        try setupBackend(&fx, events_idle_source, backend, .{});
        defer fx.deinit();
        try fx.run();
        try check(fx.scope, "report.registered && report.port");
    }
}

test "api: net echo over loopback with Handle classes (auto and threaded backends)" {
    inline for (.{ "auto", "threaded" }) |backend| {
        var fx: Fixture = undefined;
        try setupBackend(&fx, net_source, backend, .{});
        defer fx.deinit();
        try fx.run();
        try check(fx.scope, "report.server && report.client && report.wrote && report.reply && report.readCopy && report.readInto && report.readIntoRefused && report.big && report.echoTotal && report.closed");
        try check(fx.scope, "report.refused && report.denied && report.badIo && report.badArgs && report.noForge && report.afterIoClose");
    }
}

const timers_source =
    \\export async function main(api) {
    \\  const io = api.io.create({ backend: '@BACKEND@' });
    \\  const out = globalThis.report = {};
    \\  const start = io.now();
    \\  let synchronous = true;
    \\  const zero = io.sleep(0).then(value => { out.async = !synchronous && value === undefined; });
    \\  synchronous = false;
    \\  await zero;
    \\  const deadline = io.now() + 5;
    \\  await io.sleepUntil(deadline);
    \\  out.monotonic = io.now() >= deadline && io.now() >= start;
    \\  const past = io.timerAt(0);
    \\  await past.promise;
    \\  out.expired = past.cancel() === false;
    \\  const siblings = await Promise.all([io.sleep(5).then(() => 2), io.sleep(1).then(() => 1)]);
    \\  out.siblings = siblings.join() === '2,1';
    \\  const long = io.timer(60000);
    \\  const rejected = long.promise.then(() => false, e => e.name === 'Canceled');
    \\  out.frozen = Object.isFrozen(long);
    \\  out.cancel = long.cancel() === true && long.cancel() === false && await rejected;
    \\  const newer = io.timer(1);
    \\  out.stale = long.cancel() === false;
    \\  await newer.promise;
    \\  out.validation = [-1, NaN, Infinity, 2147483648, '1', null, undefined].every(ms => {
    \\    try { io.timer(ms); return false; } catch (e) { return e instanceof TypeError; }
    \\  }) && [-1, NaN, Infinity, '1'].every(at => {
    \\    try { io.timerAt(at); return false; } catch (e) { return e instanceof TypeError; }
    \\  });
    \\  const closing = io.timer(60000);
    \\  const closingResult = closing.promise.then(() => false, e => e.name === 'Canceled');
    \\  await io.close();
    \\  out.close = await closingResult && closing.cancel() === false;
    \\  try { io.sleep(1); out.closed = false; } catch (e) { out.closed = e.name === 'BadHandle'; }
    \\  // Leave the second runtime open: cancellation must remove its work without close().
    \\  const second = api.io.create({ backend: '@BACKEND@' });
    \\  const canceled = second.timer(60000);
    \\  const done = canceled.promise.catch(e => e.name === 'Canceled');
    \\  canceled.cancel();
    \\  out.noLiveTimer = await done;
    \\  await second.sleep(0.5);
    \\}
;

test "api: monotonic timers, deadlines, cancellation and close (auto and threaded backends)" {
    inline for (.{ "auto", "threaded" }) |backend| {
        var fx: Fixture = undefined;
        try setupBackend(&fx, timers_source, backend, .{});
        defer fx.deinit();
        try fx.run();
        try check(fx.scope, "report.async && report.monotonic && report.expired && report.siblings && report.frozen && report.cancel && report.stale && report.validation && report.close && report.closed && report.noLiveTimer");
        try t.expect(!fx.host.hasWork());
    }
}

test "json modules embed the file as an escaped string literal for JSON.parse" {
    const json = m.Api.json_module;
    const source = try json.wrap(t.allocator, "{\"k\": \"a\\nb\"}");
    defer t.allocator.free(source);
    try t.expectEqualStrings("export default JSON.parse(\"{\\\"k\\\": \\\"a\\\\nb\\\"}\");", source);
    try t.expect(json.requested(&.{.{ .key = "type", .value = "json" }}));
    try t.expect(!json.requested(&.{.{ .key = "type", .value = "css" }}));
    try t.expect(!json.requested(&.{}));
}

test "api: closing a context disposes it, including one with a load in flight" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { importMap } from 'origine:@std/graph/resolve/layers';
        \\import { fromLoader } from 'origine:@std/graph/providers';
        \\export async function main(api) {
        \\  const ids = [];
        \\  const handlerFor = load => ImportHandler.make({ resolver: ImportResolver.layered().layer(importMap({ imports: { m: 'app:/m.js', late: 'app:/late.js' } })), hooks: [fromLoader(load)] });
        \\  for (let n = 0; n < 20; n++) {
        \\    const child = await api.context.create({ graph: api.graph.root, import: handlerFor(id => 'export const x = ' + id.length) });
        \\    await child.import('m');
        \\    child.close();
        \\    try { child.close(); ids.push('twice'); } catch (e) { ids.push('stale'); }
        \\  }
        \\  const disposable = await api.context.create({ graph: api.graph.root, import: handlerFor(() => '') });
        \\  disposable[Symbol.dispose]();
        \\  disposable[Symbol.dispose]();
        \\  ids.push(await disposable.import('m').then(() => 'imported', e => e.name));
        \\  // A context whose hook promise settles only after the context was closed.
        \\  let release;
        \\  const gate = new Promise(resolve => { release = resolve; });
        \\  const late = await api.context.create({ graph: api.graph.root, import: handlerFor(() => gate.then(() => 'export const y = 1')) });
        \\  const running = late.import('late').then(() => 'ran', () => 'rejected');
        \\  await Promise.resolve();
        \\  late.close();
        \\  release('export const y = 1');
        \\  globalThis.report = { stale: ids.slice(0, 20).every(entry => entry === 'stale'), disposed: ids[20], late: await running };
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.stale === true && report.late === 'rejected' && report.disposed === 'StaleHandle'");
    fx.rt.pump();
    // Only the init scope is left: every context was freed, not just closed.
    try t.expectEqual(@as(usize, 1), fx.rt.scopes.items.len);
}

test "api: a closed context is freed with its imports and driver calls; ids are not reused" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { importMap } from 'origine:@std/graph/resolve/layers';
        \\import { fromLoader } from 'origine:@std/graph/providers';
        \\export async function main(api) {
        \\  const handlerFor = load => ImportHandler.make({ resolver: ImportResolver.layered().layer(importMap({ imports: { m: 'app:/m.js', late: 'app:/late.js' } })), hooks: [fromLoader(load)] });
        \\  for (let n = 0; n < 30; n++) {
        \\    const child = await api.context.create({ graph: api.graph.root, import: handlerFor(() => 'export const x = 1'), preload: [{ module: 'export default () => {};', values: {} }] });
        \\    await child.import('m');
        \\    child.close();
        \\  }
        \\  // A hook that settles after its context was closed, and one that never settles.
        \\  let release;
        \\  const gate = new Promise(resolve => { release = resolve; });
        \\  const late = await api.context.create({ graph: api.graph.root, import: handlerFor(() => gate.then(() => 'export const y = 1')) });
        \\  const running = late.import('late').then(() => 'ran', () => 'rejected');
        \\  const stuck = await api.context.create({ graph: api.graph.root, import: handlerFor(() => new Promise(() => {})) });
        \\  stuck.import('m').catch(() => {});
        \\  await Promise.resolve();
        \\  late.close();
        \\  stuck.close();
        \\  globalThis.hold = () => { release('export const y = 1'); return running; };
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    fx.rt.pump();
    // Every context is gone, and so are the finished imports and preloads. The settled-later hook is
    // still in flight; the one that never settles keeps only its small record.
    try t.expectEqual(@as(usize, 0), fx.host.contexts.count());
    try t.expectEqual(@as(u32, 33), fx.host.contexts.next);
    try t.expect(fx.host.imports.items.len <= 2);
    try t.expectEqual(@as(usize, 0), fx.host.preloads.items.len);
    const orphans = fx.host.orphans.items.len;
    try t.expect(orphans >= 1);
    try check(fx.scope, "(hold().then(() => { globalThis.settled = true; }), true)");
    fx.rt.pump();
    try check(fx.scope, "globalThis.settled === true");
    try t.expectEqual(@as(usize, 0), fx.host.imports.items.len);
    // The gated call's record was freed by its callback; only the one that never settles remains.
    try t.expectEqual(orphans - 1, fx.host.orphans.items.len);
}

test "api: a handler no live context reaches is freed, and a handler object registers again when it is used later" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { importMap } from 'origine:@std/graph/resolve/layers';
        \\import { fromLoader } from 'origine:@std/graph/providers';
        \\import { ModuleRecipe, ModuleSource } from 'origine:@std/graph/module';
        \\export async function main(api) {
        \\  const make = body => ImportHandler.make({ resolver: ImportResolver.layered().layer(importMap({ imports: { m: 'app:/m.js' } })), hooks: [fromLoader(body)] });
        \\  const kept = make(() => 'export const x = 1');
        \\  const ref = api.graph.root.declare(ModuleRecipe({ source: ModuleSource.text("import { x } from 'm'; globalThis.seenX = x; export {};"), import: kept, name: 'app:/entry.js' }));
        \\  // Many contexts, each with a handler of its own that closes over something; the last pump
        \\  // of the host frees them when they are closed.
        \\  globalThis.phase1 = async () => {
        \\    const first = await api.context.create({ graph: api.graph.root, import: kept });
        \\    await api.graph.root.load(ref);
        \\    first.close();
        \\    for (let n = 0; n < 40; n++) {
        \\      const held = new Array(1000).fill(n);
        \\    const child = await api.context.create({ graph: api.graph.root, import: make(() => 'export const x = ' + held.length) });
        \\      await child.import('m');
        \\      child.close();
        \\    }
        \\  };
        \\  // The handler of the first context was freed with it; its object works again.
        \\  globalThis.phase2 = async () => {
        \\    const second = await api.context.create({ graph: api.graph.root, import: kept });
        \\    const report = { reused: (await second.import('m')).name };
        \\    await api.graph.root.evaluate(api.graph.root.declare(ModuleRecipe({ source: ModuleSource.text("export const y = 2;"), import: kept, name: 'app:/y.js' })), second);
        \\    await api.graph.root.evaluate(ref, second);
        \\    report.status = ref.status;
        \\    globalThis.report = report;
        \\  };
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try runPhase(&fx, "phase1");
    fx.rt.pump();
    // Every context is closed and freed, so no handler is reachable.
    try t.expectEqual(@as(usize, 0), fx.host.contexts.count());
    try t.expectEqual(@as(usize, 0), fx.host.handlers.count());
    try runPhase(&fx, "phase2");
    try check(fx.scope, "report.reused === 'app:/m.js' && report.status === 'evaluated'");
    // The first context's handler registered again for the second one.
    try t.expectEqual(@as(usize, 1), fx.host.handlers.count());
}

/// Starts `globalThis[name]()` and pumps until it settles.
fn runPhase(fx: *Fixture, name: []const u8) !void {
    const source = try std.fmt.allocPrint(t.allocator, "(globalThis.phaseDone = false, globalThis.phaseError = undefined, {s}().then(() => {{ phaseDone = true; }}, e => {{ phaseDone = true; phaseError = String(e && e.stack || e); }}), true)", .{name});
    defer t.allocator.free(source);
    try check(fx.scope, source);
    var turns: usize = 0;
    while (turns < 50) : (turns += 1) {
        fx.rt.pump();
        check(fx.scope, "phaseDone") catch continue;
        break;
    }
    try check(fx.scope, "phaseDone && phaseError === undefined");
}

test "api: a closed graph is freed with the last context that uses it" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { importMap } from 'origine:@std/graph/resolve/layers';
        \\import { fromLoader } from 'origine:@std/graph/providers';
        \\import { CodeCache } from 'origine:@std/graph/cache';
        \\export async function main(api) {
        \\  const handler = ImportHandler.make({ resolver: ImportResolver.layered().layer(importMap({ imports: { m: 'app:/m.js' } })), hooks: [fromLoader(() => 'export const x = 1')] });
        \\  globalThis.phase1 = async () => {
        \\    const names = [];
        \\    for (let n = 0; n < 30; n++) {
        \\      const graph = api.graph.create();
        \\      const child = await api.context.create({ import: handler, graph });
        \\      await child.import('m');
        \\      graph.close();
        \\      // The context keeps working with a closed graph, which takes no more of them.
        \\      names.push(await child.import('m').then(ref => ref.name, e => e.name));
        \\      names.push(await api.context.create({ import: handler, graph }).then(() => 'created', e => e.name));
        \\      names.push((() => { try { graph.close(); return 'closed'; } catch (e) { return e.name; } })());
        \\      child.close();
        \\    }
        \\    {
        \\      using scoped = api.graph.create();
        \\      void scoped;
        \\    }
        \\    let rootClose;
        \\    try { api.graph.root.close(); rootClose = 'closed'; } catch (e) { rootClose = e.name; }
        \\    globalThis.report = { names: names.join(','), rootClose };
        \\  };
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try runPhase(&fx, "phase1");
    fx.rt.pump();
    try check(fx.scope, "report.names.split(',').every((name, i) => name === ['app:/m.js', 'InvalidInput', 'StaleHandle'][i % 3]) && report.rootClose === 'TypeError'");
    // Only the root graph (made for the contexts that took the default) is left.
    try t.expect(fx.host.graphs.count() <= 1);
    try t.expectEqual(@as(usize, 0), fx.host.contexts.count());
}

test "api: module preloads, with the origine allowlist per context" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { origine, importMap } from 'origine:@std/graph/resolve/layers';
        \\import { origineProvider, fromLoader } from 'origine:@std/graph/providers';
        \\export async function main(api) {
        \\  const report = {};
        \\  const resolver = ImportResolver.layered().layer(origine()).layer(importMap({ imports: { m: 'app:/m.js' } }));
        \\  const withText = ImportHandler.make({ resolver, hooks: [origineProvider({ std: { include: ['text'] } }), fromLoader(() => "if (globalThis.seen !== 5) throw new Error('seen ' + globalThis.seen);")] });
        \\  const without = ImportHandler.make({ resolver, hooks: [fromLoader(() => '')] });
        \\  // A module preload imports host modules when the handler serves them, and its default
        \\  // export receives the (frozen) values.
        \\  const child = await api.context.create({ graph: api.graph.root,
        \\    import: withText,
        \\    preload: [
        \\      { source: '(values) => { globalThis.first = values.n; }', values: { n: 2 } },
        \\      { module: "import { encodeUtf8 } from 'origine:@std/text'; export default async (values) => { await null; globalThis.seen = encodeUtf8('abc').length + first; };", values: {} },
        \\    ],
        \\  });
        \\  await child.import('m');
        \\  child.close();
        \\  report.ok = true;
        \\  // Without a provider the same import is refused, and a failing preload rejects create.
        \\  report.refused = await api.context.create({ graph: api.graph.root, import: without, preload: [{ module: "import 'origine:@std/text';" }] }).then(() => false, () => true);
        \\  report.thrown = await api.context.create({ graph: api.graph.root, import: without, preload: [{ module: 'export default () => { throw new Error("boom"); };', values: {} }] }).then(() => false, e => e.name === 'ModuleError');
        \\  report.both = await api.context.create({ graph: api.graph.root, import: without, preload: [{ source: '() => 1', module: 'export {}' }] }).then(() => false, () => true);
        \\  globalThis.report = report;
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.ok && report.refused && report.thrown && report.both");
    fx.rt.pump();
    // The closed context and the three whose preloads failed (create closes them) are all freed.
    try t.expectEqual(@as(usize, 1), fx.rt.scopes.items.len);
}

// ---- fs: access grants, symlink semantics, error parity -------------------------------------------

test "api: fs requests need an access and never exceed the host ceiling" {
    var fx: Fixture = undefined;
    try fx.setupReadOnlyCeiling(
        \\import { Dir, IoError, HostError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const rt = api.io.create({});
        \\  const syncCode = hint => { try { api.fs.requestSync({ handle: 'plain', ...hint }); return 0; } catch (e) { return e.errno; } };
        \\  const asyncCode = hint => api.fs.requestAsync({ handle: 'plain', io: rt, ...hint }).then(() => 0, e => e.errno);
        \\  const hints = [{ access: 'r' }, { access: 'rw' }, { access: 'w' }, {}, { access: 'x' }, { access: 'R' }, { access: ['r'] }, { access: 1 }, { write: true }, { read: true }, { access: 'r', root: 42 }, { access: 'r', root: '../x' }];
        \\  out.sync = hints.map(syncCode).join(',');
        \\  out.async = (await Promise.all(hints.map(asyncCode))).join(',');
        \\  // A read-only grant works and cannot mutate.
        \\  const ro = api.fs.requestSync({ handle: 'plain', access: 'r' });
        \\  try { Dir.cwd().createDir(ro, 'nope'); out.roDenied = false; } catch (e) { out.roDenied = IoError.is(e, IoError.PermissionDenied); }
        \\  const aro = await api.fs.requestAsync({ handle: 'plain', io: rt, access: 'r' });
        \\  out.aroDenied = await Dir.cwd().createDir(aro, 'nope').then(() => false, e => IoError.is(e, IoError.PermissionDenied));
        \\  out.narrowGone = api.fs.narrow === undefined;
        \\  await rt.close();
        \\}
    );
    defer fx.deinit();
    try fx.run();
    // PermissionDenied 20 (a write above the ceiling is never downgraded), InvalidInput 30 (no or a bad access, bad root),
    // a lexical escape of the root is a policy denial 20.
    try check(fx.scope, "report.sync === '0,20,20,30,30,30,30,30,30,30,30,20' && report.async === '0,20,20,30,30,30,30,30,30,30,30,20'");
    try check(fx.scope, "report.roDenied && report.aroDenied && report.narrowGone");
}

test "api: a write-only grant denies everything that observes, sync and async" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Dir, IoError, HostError } from 'origine:@std/io';
        \\import { fs as rustFs } from 'origine:@std/fs';
        \\const bytes = s => Uint8Array.from([...s].map(c => c.charCodeAt(0)));
        \\const text = b => String.fromCharCode(...b);
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const rt = api.io.create({});
        \\  const cwd = Dir.cwd();
        \\  const sync = api.fs.requestSync({ handle: 'plain', access: 'w' });
        \\  const async = await api.fs.requestAsync({ handle: 'plain', io: rt, access: 'w' });
        \\  const full = api.fs.requestSync({ handle: 'plain', access: 'rw' });
        \\  cwd.writeFile(full, { sub_path: 'secret.txt', data: bytes('secret') });
        \\  for (const [label, io] of [['sync', sync], ['async', async]]) {
        \\    const denied = async work => { try { await work(); return false; } catch (e) { return IoError.is(e, IoError.PermissionDenied); } };
        \\    const results = [];
        \\    results.push(await denied(() => cwd.openFile(io, 'secret.txt')));
        \\    results.push(await denied(() => cwd.readFile(io, 'secret.txt')));
        \\    results.push(await denied(() => cwd.statFile(io, 'secret.txt')));
        \\    results.push(await denied(() => cwd.statFile(io, 'secret.txt', { follow_symlinks: false })));
        \\    results.push(await denied(() => cwd.access(io, 'secret.txt')));
        \\    results.push(await denied(() => cwd.iterate(io)));
        \\    // Opening for writing works, and the native handle could read, but the grant does not allow it.
        \\    const f = await cwd.openFile(io, 'secret.txt', { mode: 'write_only' });
        \\    results.push(await denied(() => f.readStreaming(io, new Uint8Array(4))));
        \\    results.push(await denied(() => f.readPositional(io, new Uint8Array(4), 0)));
        \\    results.push(await denied(() => f.readAll(io)));
        \\    results.push(await denied(() => f.length(io)));
        \\    results.push(await denied(() => f.stat(io)));
        \\    if (label === 'async') {
        \\      results.push(await denied(() => f.readInto(io, new Uint8Array(4))));
        \\      results.push(await denied(() => f.readAlloc(io, 4)));
        \\    }
        \\    await f.writePositionalAll(io, bytes('S'), 0);
        \\    await f.sync(io);
        \\    await f.close(io);
        \\    await cwd.writeFile(io, { sub_path: label + '.txt', data: bytes(label) });
        \\    await cwd.createDirPath(io, label + '-dir/a');
        \\    // Rust-style: exists is false on any error (Path::exists), try_exists says why.
        \\    const rs = rustFs(io);
        \\    results.push((await rs.exists('secret.txt')) === false);
        \\    results.push(await denied(() => rs.try_exists('secret.txt')));
        \\    results.push(await denied(() => rs.read('secret.txt')));
        \\    results.push(await denied(() => rs.metadata('secret.txt')));
        \\    out[label] = results.join(',');
        \\    out[label + 'Written'] = text(await cwd.readFile(full, label + '.txt')) === label;
        \\  }
        \\  out.patched = text(await cwd.readFile(full, 'secret.txt'));
        \\  await rt.close();
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.sync.split(',').every(x => x === 'true') && report.sync.split(',').length === 15");
    try check(fx.scope, "report.async.split(',').every(x => x === 'true') && report.async.split(',').length === 17");
    try check(fx.scope, "report.syncWritten && report.asyncWritten && report.patched === 'Secret'");
}

test "api: stat and metadata follow symlinks, symlink_metadata and try_exists keep their Rust meaning" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Dir, IoError, HostError, FileKind } from 'origine:@std/io';
        \\import { fs as rustFs } from 'origine:@std/fs';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const rt = api.io.create({});
        \\  const cwd = Dir.cwd();
        \\  const caught = async work => { try { await work(); return 'ok'; } catch (e) { return e.name; } };
        \\  for (const [label, io] of [['sync', api.fs.requestSync({ handle: 'plain', access: 'r' })], ['async', await api.fs.requestAsync({ handle: 'plain', io: rt, access: 'r' })]]) {
        \\    const rs = rustFs(io);
        \\    const r = [];
        \\    r.push((await rs.metadata('link')).is_file() && (await rs.metadata('link')).len() === 5);
        \\    r.push((await rs.symlink_metadata('link')).is_symlink() && !(await rs.symlink_metadata('link')).is_file());
        \\    r.push((await rs.metadata('dirlink')).is_dir());
        \\    r.push(await caught(() => rs.metadata('dangling')));
        \\    r.push((await rs.symlink_metadata('dangling')).is_symlink());
        \\    r.push(await rs.try_exists('link'), await rs.try_exists('dangling'), await rs.try_exists('missing'));
        \\    r.push(await caught(() => rs.try_exists('loop')));
        \\    r.push(await caught(() => rs.try_exists('f.txt/below')));
        \\    r.push(await rs.exists('link'), await rs.exists('dangling'), await rs.exists('loop'), await rs.exists('missing'));
        \\    // The Zig-style names: statFile follows by default, `{ follow_symlinks: false }` does not.
        \\    r.push((await cwd.statFile(io, 'link')).kind === FileKind.file && (await cwd.statFile(io, 'link', { follow_symlinks: false })).kind === FileKind.sym_link);
        \\    r.push(await caught(() => cwd.access(io, 'dangling')));
        \\    out[label] = r.join('|');
        \\  }
        \\  await rt.close();
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.tmp.dir.writeFile(t.io, .{ .sub_path = "f.txt", .data = "12345" });
    try fx.tmp.dir.createDir(t.io, "d", .default_dir);
    try fx.tmp.dir.symLink(t.io, "f.txt", "link", .{});
    try fx.tmp.dir.symLink(t.io, "d", "dirlink", .{ .is_directory = true });
    try fx.tmp.dir.symLink(t.io, "nowhere", "dangling", .{});
    try fx.tmp.dir.symLink(t.io, "loop", "loop", .{});
    try fx.run();
    // loop: try_exists throws FilesystemLoop (not NotFound), exists is false; a file used as a directory is NotADirectory.
    const expected = "true|true|true|NotFound|true|true|false|false|FilesystemLoop|NotADirectory|true|false|false|false|true|NotFound";
    try check(fx.scope, "(() => { for (const k of ['sync', 'async']) if (report[k] !== '" ++ expected ++ "') throw new Error(k + ': ' + report[k]); return true; })()");
}

test "api: the same failures through sync and async fs give the same errno" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Dir } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const rt = api.io.create({});
        \\  const cwd = Dir.cwd();
        \\  const cases = {
        \\    missing: io => cwd.openFile(io, 'nope.txt'),
        \\    mkdirExisting: io => cwd.createDir(io, 'dir'),
        \\    openFileAsDir: io => cwd.openDir(io, 'f.txt'),
        \\    openDirAsFile: io => cwd.openFile(io, 'dir'),
        \\    rmdirNotEmpty: io => cwd.deleteDir(io, 'full'),
        \\    renameOntoNotEmpty: io => cwd.rename(io, 'dir', cwd, 'full'),
        \\    exclusive: io => cwd.createFile(io, 'f.txt', { exclusive: true }),
        \\    mkdirPathOverFile: io => cwd.createDirPath(io, 'f.txt/sub'),
        \\    nul: io => cwd.openFile(io, 'a\0b'),
        \\    emptyEntry: io => cwd.createDir(io, ''),
        \\    dotdot: io => cwd.openFile(io, '../x'),
        \\    absolute: io => cwd.openFile(io, '/etc/passwd'),
        \\    nameTooLong: io => cwd.createFile(io, 'a'.repeat(300)),
        \\    loopStat: io => cwd.statFile(io, 'loop'),
        \\    loopOpen: io => cwd.openFile(io, 'loop'),
        \\    locked: io => cwd.openFile(io, 'locked.txt'),
        \\  };
        \\  const attempt = async (io, work) => { try { await work(io); return 'ok'; } catch (e) { return e.name + '|' + e.subject; } };
        \\  const sync = api.fs.requestSync({ handle: 'plain', access: 'rw' });
        \\  const async = await api.fs.requestAsync({ handle: 'plain', io: rt, access: 'rw' });
        \\  const s = {}, a = {};
        \\  for (const [name, work] of Object.entries(cases)) {
        \\    s[name] = await attempt(sync, work);
        \\    a[name] = await attempt(async, work);
        \\  }
        \\  out.same = JSON.stringify(s) === JSON.stringify(a);
        \\  out.mismatch = Object.keys(s).filter(k => s[k] !== a[k]).map(k => k + ':' + s[k] + '/' + a[k]).join(',');
        \\  out.names = JSON.stringify(Object.fromEntries(Object.entries(s).map(([k, v]) => [k, v.split('|')[0]])));
        \\  out.subjects = JSON.stringify(s);
        \\  await rt.close();
        \\}
    , true, &.{});
    defer fx.deinit();
    const dir = fx.tmp.dir;
    try dir.writeFile(t.io, .{ .sub_path = "f.txt", .data = "x" });
    try dir.createDir(t.io, "dir", .default_dir);
    try dir.createDirPath(t.io, "full/inner");
    try dir.symLink(t.io, "loop", "loop", .{});
    try dir.writeFile(t.io, .{ .sub_path = "locked.txt", .data = "x" });
    try dir.setFilePermissions(t.io, "locked.txt", std.Io.File.Permissions.fromMode(0), .{});
    try fx.run();
    try check(fx.scope, "report.same === true || (() => { throw new Error(report.mismatch); })()");
    // The canonical names (Rust ErrorKind vocabulary). `locked` is PermissionDenied unless the tests run as root.
    try check(fx.scope,
        \\(() => {
        \\  const n = JSON.parse(report.names);
        \\  return n.missing === 'NotFound' && n.mkdirExisting === 'AlreadyExists' && n.openFileAsDir === 'NotADirectory' &&
        \\    n.openDirAsFile === 'IsADirectory' && n.rmdirNotEmpty === 'DirectoryNotEmpty' && n.renameOntoNotEmpty === 'DirectoryNotEmpty' &&
        \\    n.exclusive === 'AlreadyExists' && n.mkdirPathOverFile === 'NotADirectory' && n.nul === 'InvalidInput' && n.emptyEntry === 'InvalidInput' &&
        \\    n.dotdot === 'PermissionDenied' && n.absolute === 'PermissionDenied' &&
        \\    n.nameTooLong === 'InvalidFilename' && n.loopStat === 'FilesystemLoop' && n.loopOpen === 'FilesystemLoop' &&
        \\    (n.locked === 'PermissionDenied' || n.locked === 'ok');
        \\})()
    );
    // Both backends name what the failure was about, as the caller wrote it, and only the Rust one has the raw OS code.
    try check(fx.scope,
        \\(() => {
        \\  const n = JSON.parse(report.subjects);
        \\  return n.missing === 'NotFound|nope.txt' && n.rmdirNotEmpty === 'DirectoryNotEmpty|full' &&
        \\    n.renameOntoNotEmpty === 'DirectoryNotEmpty|dir' && n.dotdot === 'PermissionDenied|../x' && n.absolute === 'PermissionDenied|/etc/passwd';
        \\})()
    );
}

test "api: graph records have private JS identity and errors share Error subclasses" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { relative, importMap } from 'origine:@std/graph/resolve/layers';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { OrigineError, IoError, HostError, ImportError } from 'origine:@std/errors';
        \\import { Dir, IoError as FromIo } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const layer = relative();
        \\  let forged = false, constructed = false;
        \\  try { ImportResolver.layered().layer({ host: 'relative', kind: 'layer' }); } catch (e) { forged = e instanceof IoError; }
        \\  constructed = new layer.constructor({ host: 'relative', kind: 'layer' }) instanceof layer.constructor;
        \\  const data = { imports: { x: './x.js' } };
        \\  const map = importMap(data);
        \\  data.imports.x = './changed.js';
        \\  let runtime;
        \\  try { api.fs.requestSync({ handle: 'plain', access: 'invalid' }); } catch (e) { runtime = e; }
        \\  const sync = api.fs.requestSync({ handle: 'plain', access: 'rw' });
        \\  let badRef = false;
        \\  try { sync.dirStat({ kind: 'dir', fs: 0, id: 0 }, '.'); FromIo.check(sync); } catch (e) { badRef = e instanceof IoError; }
        \\  const stat = sync.dirStat(Dir.cwd(), '.');
        \\  const io = api.io.create({ backend: 'threaded' });
        \\  const asyncFs = await api.fs.requestAsync({ handle: 'plain', io, access: 'r' });
        \\  let missing = false;
        \\  try { await asyncFs.dirOpenFile(Dir.cwd(), 'missing-file', 'r'); } catch (e) { missing = e instanceof IoError && e instanceof OrigineError && typeof e.stack === 'string'; }
        \\  await io.close();
        \\  globalThis.nativeRecords = badRef && missing && Object.getPrototypeOf(stat) !== Object.prototype && forged && constructed && Object.isFrozen(layer) &&
        \\    Object.getPrototypeOf(layer) !== Object.prototype && map.imports.x === './x.js' &&
        \\    FromIo === IoError && new IoError(IoError.NotFound) instanceof OrigineError &&
        \\    new HostError(HostError.BadHandle) instanceof Error &&
        \\    ImportError.other('broken') instanceof OrigineError && runtime instanceof OrigineError &&
        \\    typeof runtime.stack === 'string';
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "nativeRecords");
}

test "api: std factories import private JS records without native metadata" {
    for (m.Api.std_modules) |module| {
        if (std.mem.startsWith(u8, module.id, "origine:@std/graph/") or
            std.mem.eql(u8, module.id, "origine:@std/io") or
            std.mem.eql(u8, module.id, "origine:@std/fs") or
            std.mem.eql(u8, module.id, "origine:@std/transformer/oxc"))
            try t.expect(module.bindings == null);
    }
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative, origine, importMap } from 'origine:@std/graph/resolve/layers';
        \\import { origineProvider, fromLoader } from 'origine:@std/graph/providers';
        \\export async function main(api) { try { await body(api); } catch (e) { throw new Error(JSON.stringify(e) + (e?.stack || '')); } }
        \\async function body(api) {
        \\  globalThis.privateDenied = await import('origine:@internal/handles').then(() => false, () => true);
        \\  const handler = ImportHandler.make({
        \\    resolver: ImportResolver.layered().layer(relative()).layer(origine()).layer(importMap({ imports: { main: 'app:/main.js' } })),
        \\    hooks: [origineProvider({ std: { include: ['graph/resolve', 'graph/resolve/layers', 'errors', 'errno'] } }), fromLoader(() => `
        \\      import { relative } from 'origine:@std/graph/resolve/layers';
        \\      import { ImportResolver } from 'origine:@std/graph/resolve';
        \\      globalThis.sharedBrand = ImportResolver.layered().layer(relative()).layers.length === 1;
        \\      globalThis.privateDenied = await import('origine:@internal/handles').then(() => false, () => true);
        \\    `)],
        \\  });
        \\  const ctx = await api.context.create({ graph: api.graph.root, import: handler });
        \\  await ctx.import('main');
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "privateDenied");
    try check(fx.rt.scopes.items[1], "sharedBrand && privateDenied");
}
