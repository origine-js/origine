const std = @import("std");
const t = std.testing;
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
        ensureV8();
        self.tmp = t.tmpDir(.{ .iterate = true });
        errdefer self.tmp.cleanup();
        try self.tmp.dir.writeFile(t.io, .{ .sub_path = "init.js", .data = source });
        self.init_path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/init.js", .{self.tmp.sub_path});
        errdefer t.allocator.free(self.init_path);
        self.rt = try m.Runtime.create(t.allocator, .{});
        errdefer self.rt.destroy();
        self.host = try m.Api.Host.create(t.allocator, .{
            .io = t.io,
            .args = args,
            .env = &.{ .{ .name = "HOME", .value = "/home/test" }, .{ .name = "PATH", .value = "/bin" } },
            .fs = if (grant_fs) .{ .root = self.tmp.dir } else null,
        });
        errdefer self.host.destroy();
        self.scope = try self.rt.createScope(self.host.initOptions());
    }

    fn run(self: *Fixture) !void {
        var error_info: m.ErrorInfo = .{};
        defer error_info.deinit();
        try self.host.run(self.scope, support.engine.platform, self.init_path, &error_info);
    }

    fn deinit(self: *Fixture) void {
        self.host.destroy();
        self.rt.destroy();
        t.allocator.free(self.init_path);
        self.tmp.cleanup();
    }
};

test "api: main receives env and an fs with sync and async variants" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Dir, IoError, Limit } from '@engine/std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  out.args = api.env.args().join(',');
        \\  out.home = api.env.get('HOME');
        \\  const fs = await api.fs.request({ write: true, mode: { async: true, sync: true } });
        \\  const f = IoError.check(fs, fs.sync.dirOpenFile(Dir.cwd(), 'a.txt', { mode: 'write', create: true, truncate: true }));
        \\  fs.sync.fileWriteAll(f, Uint8Array.from([104, 105]));
        \\  fs.sync.fileClose(f);
        \\  const g = await fs.async.dirOpenFile(Dir.cwd(), 'a.txt', {});
        \\  out.text = String.fromCharCode(...await fs.async.fileReadAll(g, { limit: Limit.unlimited }));
        \\  const h = await fs.async.dirOpenFile(Dir.cwd(), 'a.txt', {});
        \\  out.limited = (await fs.async.fileReadAll(h, { limit: Limit.limited(1) })).length;
        \\  const i = await fs.async.dirOpenFile(Dir.cwd(), 'a.txt', {});
        \\  out.nothing = (await fs.async.fileReadAll(i, { limit: Limit.nothing })).length;
        \\  try { IoError.check(fs, fs.sync.dirOpenFile(Dir.cwd(), 'nope.txt', {})); } catch (e) { out.missing = IoError.is(e, IoError.FileNotFound); }
        \\  await fs.async.dirOpenFile(Dir.cwd(), 'nope.txt', {}).catch(e => { out.asyncMissing = IoError.is(e, IoError.FileNotFound); });
        \\  for (const bad of ['../x', '/etc/passwd', 'a/../../x']) {
        \\    fs.sync.dirOpenFile(Dir.cwd(), bad, {});
        \\    (out.escapes ??= []).push(fs.errno[0] === IoError.InvalidPath);
        \\  }
        \\  fs.errno[0] = 0;
        \\  const entries = fs.sync.dirRead(Dir.cwd());
        \\  out.listed = entries.some(e => e.name === 'a.txt');
        \\  out.stat = fs.sync.dirStat(Dir.cwd(), 'a.txt').size;
        \\  out.deleted = delete fs.sync && fs.sync === undefined && fs.async !== undefined;
        \\}
    , true, &.{ "x", "y" });
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.args === 'x,y' && report.home === '/home/test'");
    try check(fx.scope, "report.text === 'hi' && report.limited === 1 && report.nothing === 0");
    try check(fx.scope, "report.missing === true && report.asyncMissing === true");
    try check(fx.scope, "report.escapes.length === 3 && report.escapes.every(x => x)");
    try check(fx.scope, "report.listed === true && report.stat === 2 && report.deleted === true");
}

test "api: narrowing is monotonic and the host grant is the ceiling" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Dir, IoError } from '@engine/std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const ro = api.fs.narrow({ write: false, mode: { sync: false } });
        \\  const rfs = await ro.request({ write: true, mode: { async: true, sync: true } });
        \\  out.syncAbsent = rfs.sync === undefined;
        \\  await rfs.async.dirOpenFile(Dir.cwd(), 'b.txt', { mode: 'write', create: true }).catch(e => { out.denied = IoError.is(e, IoError.AccessDenied); });
        \\  const again = ro.narrow({ write: true, mode: { sync: true } });
        \\  const afs = await again.request({ write: true, mode: { async: true, sync: true } });
        \\  out.stillRo = afs.sync === undefined;
        \\  const syncOnly = await api.fs.request({ mode: { sync: true } });
        \\  out.modes = syncOnly.async === undefined && typeof syncOnly.sync === 'object';
        \\  out.defaultMode = (await api.fs.request({})).sync === undefined;
        \\  const one = api.env.narrow({ allow: ['HOME'] });
        \\  out.home = one.get('HOME'); out.path = one.get('PATH');
        \\  const none = one.narrow({ allow: ['PATH'] });
        \\  out.widened = none.get('PATH') !== undefined || none.get('HOME') !== undefined;
        \\  const scopes = api.scope.narrow({ count: 0 });
        \\  await scopes.create({ main: 'app:/x.js' }).catch(e => { out.noScopes = e.errno === IoError.Unsupported; });
        \\  out.frozen = Object.isFrozen(api) && Object.isFrozen(api.fs);
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.syncAbsent && report.denied && report.stillRo && report.modes && report.defaultMode");
    try check(fx.scope, "report.home === '/home/test' && report.path === undefined && report.widened === false");
    try check(fx.scope, "report.noScopes === true && report.frozen === true");
}

test "api: without a host grant fs is denied" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { IoError } from '@engine/std/io';
        \\export async function main(api) {
        \\  await api.fs.request({}).catch(e => { globalThis.denied = IoError.is(e, IoError.AccessDenied); });
        \\}
    , false, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "denied === true");
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
    try check(fx.scope, "failed === 'ModuleError' && closed === 7");
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

test "api: errno table in std_io.js matches Errno" {
    inline for (std.enums.values(m.Api.Errno)) |tag| {
        if (tag == .ok) continue;
        const needle = try std.fmt.allocPrint(t.allocator, "  {s}: {d},", .{ @tagName(tag), @intFromEnum(tag) });
        defer t.allocator.free(needle);
        try t.expect(std.mem.indexOf(u8, m.Api.std_io_source, needle) != null);
    }
}
