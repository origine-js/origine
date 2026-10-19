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
        return self.setupFull("init.js", source, grant_fs, args, modules, m.Api.transformers.defaults);
    }

    /// Writes `source` as `name` in the tmp dir (the init module) and runs with the given
    /// embedded modules and transformer map.
    fn setupFull(self: *Fixture, name: []const u8, source: []const u8, grant_fs: bool, args: []const []const u8, modules: []const m.Api.module.Module, transformers: []const m.Api.transformer.Entry) !void {
        ensureV8();
        self.tmp = t.tmpDir(.{ .iterate = true });
        errdefer self.tmp.cleanup();
        try self.tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = source });
        self.init_path = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/{s}", .{ self.tmp.sub_path, name });
        errdefer t.allocator.free(self.init_path);
        self.rt = try m.Runtime.create(t.allocator, .{});
        errdefer self.rt.destroy();
        self.host = try m.Api.Host.create(t.allocator, .{
            .io = t.io,
            .args = args,
            .env = &.{ .{ .name = "HOME", .value = "/home/test" }, .{ .name = "PATH", .value = "/bin" } },
            .fs = if (grant_fs) .{ .root = self.tmp.dir } else null,
            .modules = modules,
            .transformers = transformers,
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
        \\import { Dir, IoError, Limit } from 'origine:@std/io';
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
        \\import { Dir } from 'origine:@std/io';
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
        \\import { Dir, IoError } from 'origine:@std/io';
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
        \\import { IoError } from 'origine:@std/io';
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

test "typescript: child scopes get only the transformers the init passes" {
    if (!m.Api.oxc.enabled) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { typescript } from 'origine:@std/typescript';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const ts = typescript();
        \\  const sources = id => id === 'app:/main.ts' ? "import { n } from 'dep'; const x: number = n + 1; globalThis.seen = x;" : 'export const n: number = 41;';
        \\  const spec = { main: 'app:/main.ts', importMap: { imports: { dep: 'app:/dep.ts' } } };
        \\  // 1: a host transformer with a synchronous loader; 2: the same with an asynchronous one.
        \\  await (await api.scope.create({ ...spec, loader: sources, transformers: { '.ts': ts } })).run();
        \\  await (await api.scope.create({ ...spec, loader: async id => sources(id), transformers: { '.ts': ts } })).run();
        \\  // 3: a guest function as transformer (parent realm, synchronous).
        \\  const ids = [];
        \\  await (await api.scope.create({ main: 'app:/note.txt', loader: () => 'hello', transformers: { '.txt': (source, id) => { ids.push(id); return 'globalThis.seen = ' + JSON.stringify(source.toUpperCase()); } } })).run();
        \\  out.ids = ids.join(',');
        \\  // Failures reach the importer as a ModuleError whose message holds the diagnostics.
        \\  await (await api.scope.create({ main: 'app:/bad.ts', loader: () => 'const x: number = ;', transformers: { '.ts': ts } })).run().catch(e => { out.hostError = e.message; });
        \\  await (await api.scope.create({ main: 'app:/bad.ts', loader: async () => 'const x: number = ;', transformers: { '.ts': ts } })).run().catch(e => { out.asyncError = e.message; });
        \\  await (await api.scope.create({ main: 'app:/x.txt', loader: () => 'x', transformers: { '.txt': () => { throw new Error('boom'); } } })).run().catch(e => { out.jsError = e.message; });
        \\  // Without a map the TypeScript source reaches V8 as it is.
        \\  await (await api.scope.create({ main: 'app:/plain.ts', loader: () => 'const x: number = 1;' })).run().catch(e => { out.plain = e.message; });
        \\  // Malformed maps are rejected: bad extension syntax, non-functions, no loader.
        \\  const rejects = options => api.scope.create({ main: 'app:/m.ts', ...options }).then(() => false, () => true);
        \\  out.rejected = [
        \\    await rejects({ loader: () => '', transformers: { ts } }),
        \\    await rejects({ loader: () => '', transformers: { '.a/b': ts } }),
        \\    await rejects({ loader: () => '', transformers: { '.': ts } }),
        \\    await rejects({ loader: () => '', transformers: { '.ts': 1 } }),
        \\    await rejects({ transformers: { '.ts': ts } }),
        \\    await rejects({ loader: () => '', transformers: 'nope' }),
        \\  ].join(',');
        \\  // A host transformer is also a plain function (source, id) => string.
        \\  out.direct = ts('const a: number = 1; export { a }', 'x.ts').includes('const a = 1');
        \\  out.options = typeof typescript({ jsx: 'classic', pragma: 'h' }) === 'function' && (() => { try { typescript({ jsx: 'bogus' }); return false; } catch (e) { return e instanceof TypeError; } })();
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
        \\import { Dir, File, IoError, Limit, FileKind } from 'origine:@std/io';
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
        \\import { IoError } from 'origine:@std/io';
        \\import { fs } from 'origine:@std/fs';
        \\import { encodeUtf8, decodeUtf8, utf8Js } from 'origine:@std/text';
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
        \\  const strings = ['', 'abc', 'é', '✓', '\u{1F600}', 'a\ud800b', '\udc00', '\ud83d', 'x\ud83d\ude00y', 'aé✓\u{1F600}'.repeat(300), 'z'.repeat(20000)];
        \\  const same = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
        \\  out.utf8Encode = strings.every(t => same(encodeUtf8(t), utf8Js.encode(t)));
        \\  const blobs = [[], [0x61], [0xc3, 0xa9], [0xc0, 0x80], [0xc3], [0xe2, 0x9c], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xf0, 0x9f, 0x98, 0x80], [0xff], [0x61, 0x80], [0xe0, 0x80, 0x80], [0xf0, 0x80, 0x80, 0x80]].map(b => Uint8Array.from(b)).concat(strings.map(t => utf8Js.encode(t)));
        \\  out.utf8Decode = blobs.every(b => decodeUtf8(b) === utf8Js.decode(b)) && decodeUtf8(new Uint8Array(0)) === '' && decodeUtf8(encodeUtf8('x\ud83d\ude00y').subarray(1, 5)) === '\u{1F600}';
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
    try check(fx.scope, "report.kinds === 'sync,async' && report.syncIsSync && report.asyncIsPromise && report.utf8 && report.utf8Encode && report.utf8Decode");
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
    try check(fx.scope, "report.native && report.exports === 'decodeUtf8,encodeUtf8,utf8Js'");
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

test "api: a module owns per-scope state that lives until the host is destroyed" {
    CounterState.created = 0;
    CounterState.torn_down = 0;
    const counter_module = m.Api.module.Module{
        .id = "origine:test/counter",
        .source = "const { next } = import.meta.native; delete import.meta.native; export const bump = () => next();",
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
    , false, &.{}, &m.Api.std_modules, m.Api.transformers.defaults);
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
    try bad.setupFull("init.ts", "export function main() {\n  const x: number = ;\n}\n", false, &.{}, &m.Api.std_modules, m.Api.transformers.defaults);
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
    try off.setupFull("init.ts", "export function main(): void {}\n", false, &.{}, &m.Api.std_modules, &.{});
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
        if (std.mem.eql(u8, module.id, "origine:@std/errno")) served = module.source.ptr == m.Api.errno_module_source.ptr;
    }
    try t.expect(served);
    try t.expect(std.mem.indexOf(u8, m.Api.std_io_source, "FileNotFound: 1") == null);
    try t.expect(std.mem.indexOf(u8, m.Api.std_io_source, "origine:@std/errno") != null);
}
