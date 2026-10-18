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

test "api: main receives env and an fs with sync and async variants" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Dir, IoError, Limit } from '@engine/std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  out.args = api.env.args().join(',');
        \\  out.home = api.env.get('HOME');
        \\  const fs = await api.fs.request({ write: true, mode: { async: true, sync: true } });
        \\  const f = IoError.check(fs, fs.sync.dirOpenFile(Dir.cwd(), 'a.txt', 'w'));
        \\  fs.sync.fileWriteAll(f, Uint8Array.from([104, 105]));
        \\  fs.sync.fileClose(f);
        \\  const g = await fs.async.dirOpenFile(Dir.cwd(), 'a.txt', 'r');
        \\  out.text = String.fromCharCode(...await fs.async.fileReadAll(g, { limit: Limit.unlimited }));
        \\  const h = await fs.async.dirOpenFile(Dir.cwd(), 'a.txt', 'r');
        \\  out.limited = (await fs.async.fileReadAll(h, { limit: Limit.limited(1) })).length;
        \\  const i = await fs.async.dirOpenFile(Dir.cwd(), 'a.txt', 'r');
        \\  out.nothing = (await fs.async.fileReadAll(i, { limit: Limit.nothing })).length;
        \\  try { IoError.check(fs, fs.sync.dirOpenFile(Dir.cwd(), 'nope.txt', 'r')); } catch (e) { out.missing = IoError.is(e, IoError.FileNotFound); }
        \\  await fs.async.dirOpenFile(Dir.cwd(), 'nope.txt', 'r').catch(e => { out.asyncMissing = IoError.is(e, IoError.FileNotFound); });
        \\  for (const bad of ['../x', '/etc/passwd', 'a/../../x']) {
        \\    fs.sync.dirOpenFile(Dir.cwd(), bad, 'r');
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

test "api: errno is one native-backed array and open modes are python-style" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Dir } from '@engine/std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const a = await api.fs.request({ write: true, mode: { sync: true } });
        \\  const b = await api.fs.request({ write: true, mode: { sync: true } });
        \\  out.shared = a.errno === b.errno && a.errno instanceof Uint32Array && a.errno.length === 1;
        \\  try { structuredClone(a.errno.buffer, { transfer: [a.errno.buffer] }); } catch { out.pinned = true; }
        \\  const s = a.sync, cwd = Dir.cwd();
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
    // w+ creates (0); x/x+ hit the existing file (PathAlreadyExists 5); rw/r+ open it; junk is InvalidPath 8.
    try check(fx.scope, "report.shared && report.pinned && report.codes === '0,5,5,0,0,8,8,8'");
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
        \\  await rfs.async.dirOpenFile(Dir.cwd(), 'b.txt', 'c').catch(e => { out.denied = IoError.is(e, IoError.AccessDenied); });
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

test "api: Zig-style Dir and File methods over sync and async io" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Dir, File, IoError, Limit, FileKind } from '@engine/std/io';
        \\const text = bytes => String.fromCharCode(...bytes);
        \\const bytes = s => Uint8Array.from([...s].map(c => c.charCodeAt(0)));
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const fs = await api.fs.request({ write: true, mode: { async: true, sync: true } });
        \\  const io = fs.sync, cwd = Dir.cwd();
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
        \\  try { cwd.access(io, 'ghost'); } catch (e) { out.ghost = IoError.is(e, IoError.FileNotFound); }
        \\  try { cwd.deleteTree(io, '.'); } catch (e) { out.rootSafe = IoError.is(e, IoError.InvalidPath); }
        \\  cwd.deleteTree(io, 'a');
        \\  try { cwd.statFile(io, 'a'); } catch (e) { out.gone = IoError.is(e, IoError.FileNotFound); }
        \\  const aio = fs.async;
        \\  await cwd.writeFile(aio, { sub_path: 'async.txt', data: bytes('async!') });
        \\  out.asyncRead = text(await cwd.readFile(aio, 'async.txt'));
        \\  const af = await cwd.openFile(aio, 'async.txt');
        \\  out.asyncLen = await af.length(aio);
        \\  await af.close(aio);
        \\  await cwd.openFile(aio, 'ghost').catch(e => { out.asyncGhost = IoError.is(e, IoError.FileNotFound); });
        \\  const ro = await api.fs.narrow({ write: false }).request({ write: true, mode: { sync: true } });
        \\  try { Dir.cwd().deleteFile(ro.sync, 'async.txt'); } catch (e) { out.roDelete = IoError.is(e, IoError.AccessDenied); }
        \\  try { Dir.cwd().rename(ro.sync, 'async.txt', Dir.cwd(), 'z'); } catch (e) { out.roRename = IoError.is(e, IoError.AccessDenied); }
        \\}
    , true, &.{});
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.read === 'hello world' && report.limited === 'hello' && report.isFile && report.length === 11");
    try check(fx.scope, "report.pread === '5:world' && report.stream === '5:hello' && report.afterTruncate === 'Jello' && report.kind");
    try check(fx.scope, "report.names === 'c,in.txt' && report.moved === 'x'");
    try check(fx.scope, "report.ghost && report.rootSafe && report.gone");
    try check(fx.scope, "report.asyncRead === 'async!' && report.asyncLen === 6 && report.asyncGhost");
    try check(fx.scope, "report.roDelete && report.roRename");
}

test "quansync: leaves, composites, yields, errors, finally and fast paths" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { quansync } from '@engine/std/quansync';
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
        \\import { IoError } from '@engine/std/io';
        \\import { fs } from '@engine/std/fs';
        \\import { encodeUtf8, decodeUtf8 } from '@engine/std/text';
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
        \\  out[label + 'noflags'] = await rejects(() => rs.OpenOptions.new().open(p + '/h.bin'), IoError.InvalidPath);
        \\  out[label + 'createWithoutWrite'] = await rejects(() => rs.OpenOptions.new().read(true).create(true).open(p + '/h.bin'), IoError.InvalidPath);
        \\  out[label + 'createNew'] = await rejects(() => rs.File.create_new(p + '/h.bin'), IoError.PathAlreadyExists);
        \\  await rs.write(p + '/bad.bin', Uint8Array.from([0xff, 0xfe]));
        \\  out[label + 'invalidUtf8'] = await rejects(() => rs.read_to_string(p + '/bad.bin'), IoError.InvalidData);
        \\  out[label + 'missing'] = await rejects(() => rs.read(p + '/ghost'), IoError.FileNotFound);
        \\  await rs.remove_file(p + '/z.txt');
        \\  await rs.create_dir(p + '/empty');
        \\  await rs.remove_dir(p + '/empty');
        \\  await rs.remove_dir_all(p + '/a');
        \\  out[label + 'removed'] = !(await rs.exists(p + '/a')) && !(await rs.exists(p + '/z.txt'));
        \\}
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = await api.fs.request({ write: true, mode: { sync: true, async: true } });
        \\  await exercise(fs(io.sync), 'sync', out);
        \\  await exercise(fs(io.async), 'async', out);
        \\  out.kinds = fs(io.sync).kind + ',' + fs(io.async).kind;
        \\  out.syncIsSync = !(fs(io.sync).read('rust-sync/h.bin') instanceof Promise);
        \\  out.asyncIsPromise = fs(io.async).read('rust-async/h.bin') instanceof Promise;
        \\  out.utf8 = decodeUtf8(encodeUtf8('aé✓\u{1F600}')) === 'aé✓\u{1F600}' && decodeUtf8(Uint8Array.from([0xc0, 0x80])) === undefined && decodeUtf8(Uint8Array.from([0xed, 0xa0, 0x80])) === undefined && encodeUtf8('\ud800').length === 3;
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
    try check(fx.scope, "report.kinds === 'sync,async' && report.syncIsSync && report.asyncIsPromise && report.utf8");
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
            .add = typed.add,
            .greet = typed.greet,
            .middle = typed.middle,
            .pair = typed.pair,
            .point = typed.point,
            .missing = typed.missing,
            .failing = typed.failing,
            .maybe = typed.maybe,
            .sum = typed.sum,
            .names = typed.names,
            .big = typed.big,
            .fill = typed.fill,
            .label = "native",
            .nested = .{ .add = typed.add, .deeper = .{ .pair = typed.pair } },
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
    try t.expectEqual(@intFromEnum(m.Api.Errno.FileNotFound), state.cell);
    // Mistyped or missing arguments fail before the function runs (InvalidArgument -> InvalidPath).
    const before = state.total;
    for ([_][]const u8{ "native.add('x', 1)", "native.add(1)", "native.greet(5)", "native.sum([1, 2])", "native.greet('x', 5)", "native.maybe(1)" }) |call_source| {
        const source = try std.fmt.allocPrint(t.allocator, "{s} === undefined", .{call_source});
        defer t.allocator.free(source);
        try check(scope, source);
        try t.expectEqual(@intFromEnum(m.Api.Errno.InvalidPath), state.cell);
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
        const table = try m.Api.binding.object(env, BindingState, &state, .{ .add = typed.add, .failing = typed.failing });
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

test "errno: binding errors map strictly, fs errors by name" {
    const E = m.Api.Errno;
    const Api = m.Api;
    // Binding domain: the closed `Error` set; every member has a code.
    const bound: Api.Error = error.StaleHandle;
    try t.expectEqual(E.StaleHandle, Api.errnoOf(bound));
    try t.expectEqual(E.InvalidPath, Api.errnoOf(error.InvalidArgument));
    inline for (@typeInfo(Api.Error).error_set.error_names.?) |name| {
        try t.expect(Api.errnoOf(@field(Api.Error, name)) != .ok);
    }
    // fs domain: concrete sets resolve at compile time.
    try t.expectEqual(E.FileNotFound, Api.errnoOfFs(@as(error{FileNotFound}, error.FileNotFound)));
    try t.expectEqual(E.AccessDenied, Api.errnoOfFs(@as(error{ PermissionDenied, Other }, error.PermissionDenied)));
    try t.expectEqual(E.AccessDenied, Api.errnoOfFs(@as(error{ReadOnlyFileSystem}, error.ReadOnlyFileSystem)));
    try t.expectEqual(E.Unexpected, Api.errnoOfFs(@as(error{Other}, error.Other)));
    // narrow() is the explicit boundary for non-fs code.
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
        const needle = try std.fmt.allocPrint(t.allocator, "  {s}: {d},", .{ @tagName(tag), @intFromEnum(tag) });
        defer t.allocator.free(needle);
        try t.expect(std.mem.indexOf(u8, m.Api.errno_module_source, needle) != null);
        count += 1;
    }
    try t.expect(count > 0);
    // The generated module is served, and std_io.js no longer carries its own table.
    var served = false;
    inline for (m.Api.std_modules) |module| {
        if (std.mem.eql(u8, module.id, "@engine/std/errno")) served = module.source.ptr == m.Api.errno_module_source.ptr;
    }
    try t.expect(served);
    try t.expect(std.mem.indexOf(u8, m.Api.std_io_source, "FileNotFound: 1") == null);
    try t.expect(std.mem.indexOf(u8, m.Api.std_io_source, "@engine/std/errno") != null);
}
