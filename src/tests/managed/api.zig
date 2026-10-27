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
        return bytes;
    }

    /// Borrows bytes/request through the real disk store; retains no V8 storage.
    fn store(data: ?*anyopaque, request: m.CodeCacheRequest, bytes: []const u8) void {
        const self: *GlueCacheProbe = @ptrCast(@alignCast(data.?));
        self.stores += 1;
        self.inner.store(self.inner.data, request, bytes);
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

test "api: getters load and harden capabilities once and retain separate disk code caches" {
    ensureV8();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // The second runtime must consume the first runtime's actual V8 code caches.
    for (0..2) |run| {
        const rt = try m.Runtime.create(t.allocator, .{});
        defer rt.destroy();
        const host = try m.Api.Host.create(t.allocator, .{ .runtime = .{}, .fs = .{ .root = .{ .handle = tmp.dir.handle }, .async = false } });
        defer host.destroy();
        var cache = m.Api.init_cache.CodeCacheState.init(host, .{ .handle = tmp.dir.handle });
        var probe: GlueCacheProbe = .{ .inner = cache.hook() };
        defer probe.deinit();
        var options = host.initOptions();
        options.code_cache = .{ .data = &probe, .load = GlueCacheProbe.load, .store = GlueCacheProbe.store };
        const scope = try rt.createScope(options);
        const api = try host.install(scope, null);
        defer api.deinit();
        try exposeApi(scope, api);
        try check(scope,
            \\Object.isFrozen(api) && Object.keys(api).join(',') === 'fs,env,scope,io,net' &&
            \\Object.values(Object.getOwnPropertyDescriptors(api)).every(d =>
            \\  typeof d.get === 'function' && Object.isFrozen(d.get) && d.set === undefined && !d.configurable)
        );
        try t.expectEqual(@as(usize, 1), probe.loads.count());
        try t.expect(probe.loads.contains("origine:glue"));
        try t.expect(host.rust_isolate == null);
        try check(scope, "api.env === api.env && Object.isFrozen(api.env.args) && api.env.args().length === 0");
        try t.expect(!probe.loads.contains("origine:glue.fs"));
        try check(scope, "api.fs === api.fs && Object.isFrozen(api.fs.requestSync) && Object.isFrozen(api.fs)");
        try check(scope,
            \\(() => {
            \\  const sync = api.fs.requestSync({ access: 'r' });
            \\  sync.fileStat({});
            \\  const code = sync.errno[0];
            \\  return code !== 0 && api.scope === api.scope && Object.isFrozen(api.scope.create) && sync.errno[0] === code;
            \\})()
        );
        try t.expect(host.rust_isolate == null);
        try check(scope, "api.io === api.io && Object.isFrozen(api.io.create)");
        try t.expect(host.rust_isolate != null);
        try check(scope, "api.net === api.net && Object.isFrozen(api.net.Socket.prototype) && Object.isFrozen(api.net.PullSocket.prototype)");
        try t.expectEqual(@as(usize, 6), probe.loads.count());
        var counts = probe.loads.valueIterator();
        while (counts.next()) |count| try t.expectEqual(@as(usize, 1), count.*);
        host.flushGlueCache(scope);
        try t.expectEqual(@as(usize, if (run == 0) 6 else 0), probe.stores);
        try t.expectEqual(@as(usize, if (run == 0) 0 else 6), probe.hits);
        host.flushGlueCache(scope);
        try t.expectEqual(@as(usize, if (run == 0) 6 else 0), probe.stores);
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
    try check(a, "Object.isFrozen(api.fs) && Object.isFrozen(api.fs.requestSync) && Object.isFrozen(api.env.args) && Object.isFrozen(api.scope.create)");
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
    try check(a, "globalThis.sync = api.fs.requestSync({ access: 'r' }); sync.fileStat({}); sync.errno[0] !== 0");
    try check(b, "api.fs.requestSync({ access: 'r' }).errno[0] === 0");
    try check(a, "sync.errno[0] !== 0");
    const restricted_host = try m.Api.Host.create(t.allocator, .{});
    defer restricted_host.destroy();
    const restricted = try rt.createScope(options);
    const restricted_api = try restricted_host.install(restricted, null);
    defer restricted_api.deinit();
    try exposeApi(restricted, restricted_api);
    try check(restricted, "Object.keys(api).join(',') === 'fs,env,scope' && api.io === undefined && api.net === undefined && Object.isFrozen(api)");
    try check(restricted, "(() => { try { api.fs.requestSync({ access: 'r' }); return false; } catch (e) { return e.name === 'PermissionDenied'; } })()");
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

test "api: main receives env and an fs with sync and async variants" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Dir, IoError, HostError, Limit } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  out.args = api.env.args().join(',');
        \\  out.home = api.env.get('HOME');
        \\  const sync = api.fs.requestSync({ access: 'rw' });
        \\  const io = api.io.create({});
        \\  const async = await api.fs.requestAsync({ io, access: 'rw' });
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
        \\  const a = api.fs.requestSync({ access: 'rw' });
        \\  const b = api.fs.requestSync({ access: 'rw' });
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

test "api: io and env narrowing are monotonic" {
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
        \\  const one = api.env.narrow({ allow: ['HOME'] });
        \\  out.home = one.get('HOME'); out.path = one.get('PATH');
        \\  const none = one.narrow({ allow: ['PATH'] });
        \\  out.widened = none.get('PATH') !== undefined || none.get('HOME') !== undefined;
        \\  out.noScopeNarrow = api.scope.narrow === undefined;
        \\  out.frozen = Object.isFrozen(api) && Object.isFrozen(api.fs) && api.fs.narrow === undefined;
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.narrowedBackend === 'threaded' && report.countCapped && report.backendCapped");
    try check(fx.scope, "report.home === '/home/test' && report.path === undefined && report.widened === false");
    try check(fx.scope, "report.noScopeNarrow === true && report.frozen === true && report.closeShared && report.closeHeld && report.closeAfter");
}

test "api: without a host grant fs is denied" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { IoError, HostError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const io = api.io.create({});
        \\  try { api.fs.requestSync({ access: 'r' }); } catch (e) { globalThis.denied = IoError.is(e, IoError.PermissionDenied); }
        \\  await api.fs.requestAsync({ io, access: 'r' }).catch(e => { globalThis.asyncDenied = IoError.is(e, IoError.PermissionDenied); });
        \\  await io.close();
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "denied === true && asyncDenied === true");
}

test "api: child scopes with import map, sync and async loaders and preload values" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\export async function main(api) {
        \\  const loader = id => id === 'app:/main.js' ? "import { v } from 'dep'; globalThis.seen = v + preloaded" : { source: 'export const v = 40' };
        \\  const spec = { main: 'app:/main.js', importMap: { imports: { dep: 'app:/dep.js' } }, preload: [{ source: '(values) => { globalThis.preloaded = values.n }', values: { n: 2 } }] };
        \\  const a = await api.scope.create({ ...spec, loader });
        \\  const b = await api.scope.create({ ...spec, loader: async id => loader(id) });
        \\  await a.run();
        \\  await b.run();
        \\  const c = await api.scope.create({ main: 'app:/missing.js', loader: () => { throw new Error('nope') } });
        \\  await c.run().catch(e => { globalThis.failed = e.name; });
        \\  c.close();
        \\  try { await c.run() } catch (e) { globalThis.closed = e.errno }
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.rt.scopes.items[1], "seen === 42");
    try check(fx.rt.scopes.items[2], "seen === 42");
    try check(fx.scope, "failed === 'ModuleError' && closed === 3");
}

test "typescript: child scopes get only the transformers the init passes" {
    if (!m.Api.oxc.enabled) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ts } from 'origine:@std/transformer/oxc';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const transform = ts();
        \\  const sources = id => id === 'app:/main.ts' ? "import { n } from 'dep'; const x: number = n + 1; globalThis.seen = x;" : 'export const n: number = 41;';
        \\  const spec = { main: 'app:/main.ts', importMap: { imports: { dep: 'app:/dep.ts' } } };
        \\  // 1: a host transformer with a synchronous loader; 2: the same with an asynchronous one.
        \\  await (await api.scope.create({ ...spec, loader: sources, transformers: { '.ts': transform } })).run();
        \\  await (await api.scope.create({ ...spec, loader: async id => sources(id), transformers: { '.ts': transform } })).run();
        \\  // 3: a guest function as transformer (parent realm, synchronous).
        \\  const ids = [];
        \\  await (await api.scope.create({ main: 'app:/note.txt', loader: () => 'hello', transformers: { '.txt': (source, id) => { ids.push(id); return 'globalThis.seen = ' + JSON.stringify(source.toUpperCase()); } } })).run();
        \\  out.ids = ids.join(',');
        \\  // Failures reach the importer as a ModuleError whose message holds the diagnostics.
        \\  await (await api.scope.create({ main: 'app:/bad.ts', loader: () => 'const x: number = ;', transformers: { '.ts': transform } })).run().catch(e => { out.hostError = e.message; });
        \\  await (await api.scope.create({ main: 'app:/bad.ts', loader: async () => 'const x: number = ;', transformers: { '.ts': transform } })).run().catch(e => { out.asyncError = e.message; });
        \\  await (await api.scope.create({ main: 'app:/x.txt', loader: () => 'x', transformers: { '.txt': () => { throw new Error('boom'); } } })).run().catch(e => { out.jsError = e.message; });
        \\  // Without a map the TypeScript source reaches V8 as it is.
        \\  await (await api.scope.create({ main: 'app:/plain.ts', loader: () => 'const x: number = 1;' })).run().catch(e => { out.plain = e.message; });
        \\  // Malformed maps are rejected: bad extension syntax, non-functions, no loader.
        \\  const rejects = options => api.scope.create({ main: 'app:/m.ts', ...options }).then(() => false, () => true);
        \\  out.rejected = [
        \\    await rejects({ loader: () => '', transformers: { transform } }),
        \\    await rejects({ loader: () => '', transformers: { '.a/b': transform } }),
        \\    await rejects({ loader: () => '', transformers: { '.': transform } }),
        \\    await rejects({ loader: () => '', transformers: { '.ts': 1 } }),
        \\    await rejects({ transformers: { '.ts': transform } }),
        \\    await rejects({ loader: () => '', transformers: 'nope' }),
        \\  ].join(',');
        \\  // A host transformer is also a plain function (source, id) => string.
        \\  out.direct = transform('const a: number = 1; export { a }', 'x.ts').includes('const a = 1');
        \\  out.options = typeof ts({ jsx: 'classic', pragma: 'h' }) === 'function' && (() => { try { ts({ jsx: 'bogus' }); return false; } catch (e) { return e instanceof TypeError; } })();
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
    try check(fx.scope, "report.rejected === 'true,true,true,true,true,true' && report.direct && report.options");
}

test "leaks: oxc transformers free options, diagnostics and instances on every path" {
    if (!m.Api.oxc.enabled) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { ts } from 'origine:@std/transformer/oxc';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  // Instances with owned strings, kept until Host.destroy.
        \\  const kept = [];
        \\  for (let i = 0; i < 8; i++) kept.push(ts({ jsx: 'classic', importSource: 'preact' + i, pragma: 'h', pragmaFrag: 'Fragment' }));
        \\  // Strings allocated, then a later option is invalid: the half-built instance is released.
        \\  let bad = 0;
        \\  for (let i = 0; i < 4; i++) {
        \\    try { ts({ importSource: 'x', pragma: 'y', pragmaFrag: 'z', development: 'nope' }); } catch (e) { if (e instanceof TypeError) bad++; }
        \\    try { ts({ importSource: 'x', pragma: 1 }); } catch (e) { if (e instanceof TypeError) bad++; }
        \\    try { ts({ importSource: 'x', jsx: 'bogus' }); } catch (e) { if (e instanceof TypeError) bad++; }
        \\  }
        \\  out.bad = bad;
        \\  // Direct calls: success and failure (the failure string is copied, thrown and freed).
        \\  let failures = 0;
        \\  for (let i = 0; i < 4; i++) {
        \\    if (!kept[i].call(undefined, 'const a: number = 1; export { a }', 'a.ts').includes('const a = 1')) throw new Error('transform');
        \\    try { kept[i].call(undefined, 'const x: number = ;', 'bad.ts'); } catch (e) { if (e instanceof SyntaxError) failures++; }
        \\  }
        \\  out.failures = failures;
        \\  // Through child scopes, sync and async, ok and failing.
        \\  const transform = ts();
        \\  for (const source of ['export const n: number = 1', 'const x: number = ;']) {
        \\    for (const loader of [() => source, async () => source]) {
        \\      const child = await api.scope.create({ main: 'app:/m.ts', loader, transformers: { '.ts': transform } });
        \\      await child.run().catch(() => { out.childFailed = (out.childFailed ?? 0) + 1; });
        \\      child.close();
        \\    }
        \\  }
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.bad === 12 && report.failures === 4 && report.childFailed === 2");
}

test "leaks: a rejecting child settles the parent's run promise, repeatedly" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\export async function main(api) {
        \\  const names = [];
        \\  for (let i = 0; i < 5; i++) {
        \\    const child = await api.scope.create({ main: 'app:/m.js', loader: () => 'throw new Error("boom")' });
        \\    await child.run().catch(e => { names.push(e.name + ':' + e.message.includes('boom')); });
        \\    child.close();
        \\  }
        \\  // A child whose module graph fails to load rejects through the same path.
        \\  const missing = await api.scope.create({ main: 'app:/m.js', loader: async () => { throw new Error('nope'); } });
        \\  await missing.run().catch(e => { names.push(e.name); });
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
        \\export async function main(api) {
        \\  // Never-settling loader promises; their runs are deliberately not awaited.
        \\  for (let i = 0; i < 3; i++) {
        \\    const child = await api.scope.create({ main: 'app:/m' + i + '.js', importMap: { imports: { dep: 'app:/dep.js' } }, loader: () => new Promise(() => {}) });
        \\    child.run().catch(() => {});
        \\  }
        \\  // One load that settles (released from `pendings`) next to one that does not.
        \\  const mixed = await api.scope.create({ main: 'app:/main.js', loader: id => id === 'app:/main.js' ? Promise.resolve("import 'app:/hang.js'") : new Promise(() => {}) });
        \\  mixed.run().catch(() => {});
        \\  globalThis.started = true;
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "started === true");
}

test "api: child scopes inherit no authority and no scope capability" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\export async function main(api) {
        \\  const child = await api.scope.create({ main: 'app:/main.js', loader: () => "globalThis.keys = Object.getOwnPropertyNames(globalThis).filter(k => k === 'api' || k === 'scope').length" });
        \\  await child.run();
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
        \\  const io = api.fs.requestSync({ access: 'rw' }), cwd = Dir.cwd();
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
        \\  const aio = await api.fs.requestAsync({ io: rt, access: 'rw' });
        \\  await cwd.writeFile(aio, { sub_path: 'async.txt', data: bytes('async!') });
        \\  out.asyncRead = text(await cwd.readFile(aio, 'async.txt'));
        \\  const af = await cwd.openFile(aio, 'async.txt');
        \\  out.asyncLen = await af.length(aio);
        \\  await af.close(aio);
        \\  await cwd.openFile(aio, 'ghost').catch(e => { out.asyncGhost = IoError.is(e, IoError.NotFound); });
        \\  const ro = api.fs.requestSync({ access: 'r' });
        \\  try { Dir.cwd().deleteFile(ro, 'async.txt'); } catch (e) { out.roDelete = IoError.is(e, IoError.PermissionDenied); }
        \\  try { Dir.cwd().rename(ro, 'async.txt', Dir.cwd(), 'z'); } catch (e) { out.roRename = IoError.is(e, IoError.PermissionDenied); }
        \\  const aro = await api.fs.requestAsync({ io: rt, access: 'r' });
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

test "api: Rust-style fs over sync and async io" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { IoError, HostError } from 'origine:@std/io';
        \\import { fs } from 'origine:@std/fs';
        \\import { encodeUtf8, decodeUtf8, tryDecodeUtf8, utf8Js } from 'origine:@std/text';
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
        \\  const sio = api.fs.requestSync({ access: 'rw' });
        \\  const aio = await api.fs.requestAsync({ io: rt, access: 'rw' });
        \\  await exercise(fs(sio), 'sync', out);
        \\  await exercise(fs(aio), 'async', out);
        \\  out.kinds = fs(sio).kind + ',' + fs(aio).kind;
        \\  out.syncIsSync = !(fs(sio).read('rust-sync/h.bin') instanceof Promise);
        \\  out.asyncIsPromise = fs(aio).read('rust-async/h.bin') instanceof Promise;
        \\  await rt.close();
        \\  const strings = ['', 'abc', 'é', '✓', '\u{1F600}', 'a\ud800b', '\udc00', '\ud83d', 'x\ud83d\ude00y', 'aé✓\u{1F600}'.repeat(300), 'z'.repeat(20000)];
        \\  const same = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
        \\  out.utf8Encode = strings.every(t => same(encodeUtf8(t), utf8Js.encode(t)));
        \\  const blobs = [[], [0x61], [0xc3, 0xa9], [0xc0, 0x80], [0xc3], [0xe2, 0x9c], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xf0, 0x9f, 0x98, 0x80], [0xff], [0x61, 0x80], [0xe0, 0x80, 0x80], [0xf0, 0x80, 0x80, 0x80]].map(b => Uint8Array.from(b)).concat(strings.map(t => utf8Js.encode(t)));
        \\  out.utf8Decode = blobs.every(b => tryDecodeUtf8(b) === utf8Js.tryDecode(b) && decodeUtf8(b) === utf8Js.decode(b) && decodeUtf8(b, { ignoreBOM: true }) === utf8Js.decode(b, { ignoreBOM: true })) && tryDecodeUtf8(new Uint8Array(0)) === '' && decodeUtf8(new Uint8Array(new SharedArrayBuffer(4)).fill(97)) === 'aaaa' && decodeUtf8(encodeUtf8('x😀y').subarray(1, 5)) === '\u{1F600}';
        \\  out.utf8 = tryDecodeUtf8(encodeUtf8('aé✓\u{1F600}')) === 'aé✓\u{1F600}' && tryDecodeUtf8(Uint8Array.from([0xc0, 0x80])) === null && tryDecodeUtf8(Uint8Array.from([0xed, 0xa0, 0x80])) === null && tryDecodeUtf8(Uint8Array.from([0xef, 0xbb, 0xbf, 0x61])) === '﻿a' && encodeUtf8('\ud800').length === 3;
        \\  // WHATWG TextDecoder edge cases, on both the native and the JS implementation.
        \\  const cases = [
        \\    [[0xc0, 0x80], '��'], [[0xc1, 0xbf], '��'], [[0xe0, 0x80, 0x80], '���'], [[0xe0, 0x9f, 0xbf], '���'],
        \\    [[0xf0, 0x80, 0x80, 0x80], '����'], [[0xed, 0xa0, 0x80], '���'], [[0xed, 0xbf, 0xbf], '���'],
        \\    [[0xf4, 0x90, 0x80, 0x80], '����'], [[0xf5, 0x80], '��'], [[0xff, 0xfe], '��'],
        \\    [[0xe2, 0x9c], '�'], [[0xf0, 0x9f, 0x98], '�'], [[0xc3], '�'], [[0x61, 0xe2, 0x9c, 0x61], 'a�a'],
        \\    [[0xf0, 0x9f, 0x61], '�a'], [[0x80, 0x61], '�a'], [[0xf0, 0x9f, 0x98, 0x80, 0x80], '\u{1F600}�'],
        \\    [[0xef, 0xbb, 0xbf, 0x61], 'a'], [[0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf], '﻿'], [[0xef, 0xbb], '�'], [[0x61, 0xef, 0xbb, 0xbf], 'a﻿'],
        \\  ];
        \\  const impls = [decodeUtf8, utf8Js.decode];
        \\  out.utf8Whatwg = cases.every(([b, want]) => impls.every(f => f(Uint8Array.from(b)) === want));
        \\  out.utf8Bom = impls.every(f => f(Uint8Array.from([0xef, 0xbb, 0xbf, 0x61]), { ignoreBOM: true }) === '﻿a');
        \\  out.utf8Fatal = impls.every(f => { try { f(Uint8Array.from([0x61, 0xff]), { fatal: true }); return false; } catch (e) { return e instanceof TypeError; } } ) && impls.every(f => f(Uint8Array.from([0xef, 0xbb, 0xbf, 0xc3, 0xa9]), { fatal: true }) === 'é');
        \\  out.utf8PlainArray = utf8Js.decode(Object.assign([0x61, 0xff], { subarray(a, b) { return this.slice(a, b); } })) === 'a�';
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
    \\  const sync = api.fs.requestSync({ access: 'rw' });
    \\  const fs = await api.fs.requestAsync({ io: rt, access: 'rw' });
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
    \\  const ro = await api.fs.requestAsync({ io: rt, access: 'r' });
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
    \\  const inner = await api.fs.requestAsync({ io: rt, root: 'inner', access: 'rw' });
    \\  await cwd.writeFile(inner, { sub_path: 'x.txt', data: bytes('in') });
    \\  out.inner = text(await cwd.readFile(fs, 'inner/x.txt'));
    \\  out.innerEscape = await cwd.readFile(inner, '../f0.txt').then(() => false, e => IoError.is(e, IoError.PermissionDenied));
    \\  // Closing the runtime: the handle is dead for new grants and idempotent to close again.
    \\  await rt.close();
    \\  await rt.close();
    \\  out.afterClose = await api.fs.requestAsync({ io: rt, access: 'r' }).then(() => 'ok', e => e.errno);
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
        \\  const fs = await api.fs.requestAsync({ io: first, access: 'rw' });
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
        \\  const other = await api.fs.requestAsync({ io: second, access: 'r' });
        \\  out.otherWorks = (await cwd.readFile(other, 'big.bin')).length === 1 << 20;
        \\  await third.close();
        \\  await second.close();
        \\  // Left in flight: Host.destroy drains them without leaking.
        \\  const last = api.io.create({});
        \\  const lastFs = await api.fs.requestAsync({ io: last, access: 'r' });
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
        \\  out.notHandle = await code(api.fs.requestAsync({ io: 7, access: 'r' }));
        \\  out.forged = await code(api.fs.requestAsync({ io: Object.freeze({ kind: 'io', id: rt.id, backend: 'auto' }) }));
        \\  out.getter = await code(api.fs.requestAsync({ get io() { return rt; } }));
        \\  out.badRoot = await code(api.fs.requestAsync({ io: rt, root: 42, access: 'r' }));
        \\  out.escape = await code(api.fs.requestAsync({ io: rt, root: '../x', access: 'r' }));
        \\  await other.close();
        \\  out.closed = await code(api.fs.requestAsync({ io: other, access: 'r' }));
        \\  out.live = await code(api.fs.requestAsync({ io: rt, access: 'r' }));
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
        \\  out.asyncDenied = await api.fs.requestAsync({ io: undefined, access: 'r' }).then(() => 0, e => e.errno);
        \\  out.syncWorks = typeof api.fs.requestSync({ access: 'r' }) === 'object';
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
        \\  // The std module got native versions (its exports are not the JS reference ones).
        \\  out.native = text.encodeUtf8 !== text.utf8Js.encode && text.decodeUtf8 !== text.utf8Js.decode;
        \\  out.exports = Object.keys(text).sort().join(',');
        \\  // User code sees a bare import.meta, no natives on the global, and no way to import std internals.
        \\  out.bareMeta = Object.keys(import.meta).join(',') === 'url' && import.meta.native === undefined;
        \\  out.noGlobal = !('__engineText' in globalThis);
        \\  out.reserved = await import('origine:@std/unknown').then(() => false, () => true);
        \\  out.reservedPrivate = await import('origine:private/bindings').then(() => false, () => true);
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.native && report.exports === 'decodeUtf8,encodeUtf8,tryDecodeUtf8,utf8Js'");
    try check(fx.scope, "report.bareMeta && report.noGlobal && report.reserved && report.reservedPrivate");
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
    \\  const fs = await api.fs.requestAsync({ io: rt, access: 'rw' });
    \\  const sync = api.fs.requestSync({ access: 'rw' });
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
    \\  syncMoveFile.close(sync);
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
        \\  const fs = await api.fs.requestAsync({ io: rt, access: 'rw' });
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
        \\  const fs2 = await api.fs.requestAsync({ io: rt2, access: 'r' });
        \\  out.after = (await cwd.readFile(fs2, 'big.bin')).length === 4 << 20;
        \\  await rt2.close();
        \\  // Left in flight at Host.destroy.
        \\  const last = api.io.create({});
        \\  const lastFs = await api.fs.requestAsync({ io: last, access: 'r' });
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
        \\  const fs = await api.fs.requestAsync({ io: rt, access: 'rw' });
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

test "api: closing a child scope disposes it, including one with a load in flight" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\export async function main(api) {
        \\  const ids = [];
        \\  for (let n = 0; n < 20; n++) {
        \\    const child = await api.scope.create({ main: 'm.js', loader: id => 'export const x = ' + id.length });
        \\    await child.run();
        \\    child.close();
        \\    try { child.close(); ids.push('twice'); } catch (e) { ids.push('stale'); }
        \\  }
        \\  // A child whose loader promise settles only after the child was closed.
        \\  let release;
        \\  const gate = new Promise(resolve => { release = resolve; });
        \\  const late = await api.scope.create({ main: 'late.js', loader: () => gate.then(() => 'export const y = 1') });
        \\  const running = late.run().then(() => 'ran', () => 'rejected');
        \\  await Promise.resolve();
        \\  late.close();
        \\  release('export const y = 1');
        \\  globalThis.report = { stale: ids.every(entry => entry === 'stale'), late: await running };
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.stale === true && report.late === 'rejected'");
    fx.rt.pump();
    // Only the init scope is left: every child was freed, not just closed.
    try t.expectEqual(@as(usize, 1), fx.rt.scopes.items.len);
}

test "api: module preloads, with the origine namespace enabled per child" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\export async function main(api) {
        \\  const report = {};
        \\  // A module preload imports host modules when the child asks for the namespace, and its
        \\  // default export receives the (frozen) values.
        \\  const child = await api.scope.create({
        \\    main: 'm.js',
        \\    origineNamespace: true,
        \\    loader: () => "if (globalThis.seen !== 5) throw new Error('seen ' + globalThis.seen);",
        \\    preload: [
        \\      { source: '(values) => { globalThis.first = values.n; }', values: { n: 2 } },
        \\      { module: "import { encodeUtf8 } from 'origine:@std/text'; export default async (values) => { await null; globalThis.seen = encodeUtf8('abc').length + first; };", values: {} },
        \\    ],
        \\  });
        \\  await child.run();
        \\  child.close();
        \\  report.ok = true;
        \\  // Without the flag the same import is refused, and a failing preload rejects create.
        \\  report.refused = await api.scope.create({ main: 'm.js', loader: () => '', preload: [{ module: "import 'origine:@std/text';" }] }).then(() => false, () => true);
        \\  report.thrown = await api.scope.create({ main: 'm.js', loader: () => '', preload: [{ module: 'export default () => { throw new Error("boom"); };', values: {} }] }).then(() => false, e => e.name === 'ModuleError');
        \\  report.both = await api.scope.create({ main: 'm.js', loader: () => '', preload: [{ source: '() => 1', module: 'export {}' }] }).then(() => false, () => true);
        \\  globalThis.report = report;
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.ok && report.refused && report.thrown && report.both");
    fx.rt.pump();
    // The closed child and the three whose preloads failed (create closes them) are all freed.
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
        \\  const syncCode = hint => { try { api.fs.requestSync(hint); return 0; } catch (e) { return e.errno; } };
        \\  const asyncCode = hint => api.fs.requestAsync({ io: rt, ...hint }).then(() => 0, e => e.errno);
        \\  const hints = [{ access: 'r' }, { access: 'rw' }, { access: 'w' }, {}, { access: 'x' }, { access: 'R' }, { access: ['r'] }, { access: 1 }, { write: true }, { read: true }, { access: 'r', root: 42 }, { access: 'r', root: '../x' }];
        \\  out.sync = hints.map(syncCode).join(',');
        \\  out.async = (await Promise.all(hints.map(asyncCode))).join(',');
        \\  // A read-only grant works and cannot mutate.
        \\  const ro = api.fs.requestSync({ access: 'r' });
        \\  try { Dir.cwd().createDir(ro, 'nope'); out.roDenied = false; } catch (e) { out.roDenied = IoError.is(e, IoError.PermissionDenied); }
        \\  const aro = await api.fs.requestAsync({ io: rt, access: 'r' });
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
        \\  const sync = api.fs.requestSync({ access: 'w' });
        \\  const async = await api.fs.requestAsync({ io: rt, access: 'w' });
        \\  const full = api.fs.requestSync({ access: 'rw' });
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
        \\  for (const [label, io] of [['sync', api.fs.requestSync({ access: 'r' })], ['async', await api.fs.requestAsync({ io: rt, access: 'r' })]]) {
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
        \\    cacheDir: io => cwd.createFile(io, 'a/__oricache__/x'),
        \\    nameTooLong: io => cwd.createFile(io, 'a'.repeat(300)),
        \\    loopStat: io => cwd.statFile(io, 'loop'),
        \\    loopOpen: io => cwd.openFile(io, 'loop'),
        \\    locked: io => cwd.openFile(io, 'locked.txt'),
        \\  };
        \\  const attempt = async (io, work) => { try { await work(io); return 'ok'; } catch (e) { return e.name; } };
        \\  const sync = api.fs.requestSync({ access: 'rw' });
        \\  const async = await api.fs.requestAsync({ io: rt, access: 'rw' });
        \\  const s = {}, a = {};
        \\  for (const [name, work] of Object.entries(cases)) {
        \\    s[name] = await attempt(sync, work);
        \\    a[name] = await attempt(async, work);
        \\  }
        \\  out.same = JSON.stringify(s) === JSON.stringify(a);
        \\  out.mismatch = Object.keys(s).filter(k => s[k] !== a[k]).map(k => k + ':' + s[k] + '/' + a[k]).join(',');
        \\  out.names = JSON.stringify(s);
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
        \\    n.dotdot === 'PermissionDenied' && n.absolute === 'PermissionDenied' && n.cacheDir === 'PermissionDenied' &&
        \\    n.nameTooLong === 'InvalidFilename' && n.loopStat === 'FilesystemLoop' && n.loopOpen === 'FilesystemLoop' &&
        \\    (n.locked === 'PermissionDenied' || n.locked === 'ok');
        \\})()
    );
}
