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

test "api: main receives env and an fs with sync and async variants" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { Dir, IoError, Limit } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  out.args = api.env.args().join(',');
        \\  out.home = api.env.get('HOME');
        \\  const sync = api.fs.requestSync({ write: true });
        \\  const io = api.io.create({});
        \\  const async = await api.fs.requestAsync({ io, write: true });
        \\  const f = IoError.check(sync, sync.dirOpenFile(Dir.cwd(), 'a.txt', 'w'));
        \\  sync.fileWriteAll(f, Uint8Array.from([104, 105]));
        \\  sync.fileClose(f);
        \\  const g = await async.dirOpenFile(Dir.cwd(), 'a.txt', 'r');
        \\  out.text = String.fromCharCode(...await async.fileReadAll(g, { limit: Limit.unlimited }));
        \\  const h = await async.dirOpenFile(Dir.cwd(), 'a.txt', 'r');
        \\  out.limited = (await async.fileReadAll(h, { limit: Limit.limited(1) })).length;
        \\  const i = await async.dirOpenFile(Dir.cwd(), 'a.txt', 'r');
        \\  out.nothing = (await async.fileReadAll(i, { limit: Limit.nothing })).length;
        \\  try { IoError.check(sync, sync.dirOpenFile(Dir.cwd(), 'nope.txt', 'r')); } catch (e) { out.missing = IoError.is(e, IoError.FileNotFound); }
        \\  await async.dirOpenFile(Dir.cwd(), 'nope.txt', 'r').catch(e => { out.asyncMissing = IoError.is(e, IoError.FileNotFound); });
        \\  for (const bad of ['../x', '/etc/passwd', 'a/../../x']) {
        \\    sync.dirOpenFile(Dir.cwd(), bad, 'r');
        \\    (out.escapes ??= []).push(sync.errno[0] === IoError.InvalidPath);
        \\    await async.dirOpenFile(Dir.cwd(), bad, 'r').catch(e => { (out.asyncEscapes ??= []).push(IoError.is(e, IoError.InvalidPath)); });
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
        \\  const a = api.fs.requestSync({ write: true });
        \\  const b = api.fs.requestSync({ write: true });
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
        \\  const io = api.io.create({});
        \\  const rfs = await ro.requestAsync({ io, write: true });
        \\  try { ro.requestSync({}); } catch (e) { out.syncAbsent = IoError.is(e, IoError.AccessDenied); }
        \\  await rfs.dirOpenFile(Dir.cwd(), 'b.txt', 'c').catch(e => { out.denied = IoError.is(e, IoError.AccessDenied); });
        \\  const again = ro.narrow({ write: true, mode: { sync: true } });
        \\  const afs = await again.requestAsync({ io, write: true });
        \\  await afs.dirOpenFile(Dir.cwd(), 'b.txt', 'c').catch(e => { out.stillRo = IoError.is(e, IoError.AccessDenied); });
        \\  try { again.requestSync({ write: true }); out.syncStillOff = false; } catch (e) { out.syncStillOff = IoError.is(e, IoError.AccessDenied); }
        \\  const syncOnly = api.fs.narrow({ mode: { async: false } });
        \\  out.modes = typeof syncOnly.requestSync({}) === 'object' && await syncOnly.requestAsync({ io }).then(() => false, e => IoError.is(e, IoError.AccessDenied));
        \\  const asyncOnly = api.fs.narrow({ mode: { sync: false } });
        \\  out.defaultMode = typeof (await asyncOnly.requestAsync({ io })) === 'object';
        \\  // The io ceiling is narrowable too: backend list and runtime count.
        \\  const capped = api.io.narrow({ maxRuntimes: 1, backends: ['threaded'] });
        \\  const first = capped.create({});
        \\  out.narrowedBackend = first.backend;
        \\  try { capped.create({}); } catch (e) { out.countCapped = IoError.is(e, IoError.Unsupported); }
        \\  try { api.io.narrow({ backends: ['threaded'] }).create({ backend: 'uring' }); } catch (e) { out.backendCapped = IoError.is(e, IoError.Unsupported); }
        \\  await first.close();
        \\  await capped.create({}).close();
        \\  await io.close();
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
    try check(fx.scope, "report.syncAbsent && report.denied && report.stillRo && report.syncStillOff && report.modes && report.defaultMode");
    try check(fx.scope, "report.narrowedBackend === 'threaded' && report.countCapped && report.backendCapped");
    try check(fx.scope, "report.home === '/home/test' && report.path === undefined && report.widened === false");
    try check(fx.scope, "report.noScopes === true && report.frozen === true");
}

test "api: without a host grant fs is denied" {
    var fx: Fixture = undefined;
    try fx.setup(
        \\import { IoError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const io = api.io.create({});
        \\  try { api.fs.requestSync({}); } catch (e) { globalThis.denied = IoError.is(e, IoError.AccessDenied); }
        \\  await api.fs.requestAsync({ io }).catch(e => { globalThis.asyncDenied = IoError.is(e, IoError.AccessDenied); });
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
    try check(fx.scope, "failed === 'ModuleError' && closed === 7");
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
        \\import { Dir, File, IoError, Limit, FileKind } from 'origine:@std/io';
        \\const text = bytes => String.fromCharCode(...bytes);
        \\const bytes = s => Uint8Array.from([...s].map(c => c.charCodeAt(0)));
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const rt = api.io.create({});
        \\  const io = api.fs.requestSync({ write: true }), cwd = Dir.cwd();
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
        \\  const aio = await api.fs.requestAsync({ io: rt, write: true });
        \\  await cwd.writeFile(aio, { sub_path: 'async.txt', data: bytes('async!') });
        \\  out.asyncRead = text(await cwd.readFile(aio, 'async.txt'));
        \\  const af = await cwd.openFile(aio, 'async.txt');
        \\  out.asyncLen = await af.length(aio);
        \\  await af.close(aio);
        \\  await cwd.openFile(aio, 'ghost').catch(e => { out.asyncGhost = IoError.is(e, IoError.FileNotFound); });
        \\  const ro = api.fs.narrow({ write: false }).requestSync({ write: true });
        \\  try { Dir.cwd().deleteFile(ro, 'async.txt'); } catch (e) { out.roDelete = IoError.is(e, IoError.AccessDenied); }
        \\  try { Dir.cwd().rename(ro, 'async.txt', Dir.cwd(), 'z'); } catch (e) { out.roRename = IoError.is(e, IoError.AccessDenied); }
        \\  const aro = await api.fs.narrow({ write: false }).requestAsync({ io: rt, write: true });
        \\  await Dir.cwd().deleteFile(aro, 'async.txt').catch(e => { out.asyncRoDelete = IoError.is(e, IoError.AccessDenied); });
        \\  await Dir.cwd().rename(aro, 'async.txt', Dir.cwd(), 'z').catch(e => { out.asyncRoRename = IoError.is(e, IoError.AccessDenied); });
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
        \\  const rt = api.io.create({});
        \\  const sio = api.fs.requestSync({ write: true });
        \\  const aio = await api.fs.requestAsync({ io: rt, write: true });
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
        \\  out.utf8Decode = blobs.every(b => decodeUtf8(b) === utf8Js.decode(b)) && decodeUtf8(new Uint8Array(0)) === '' && decodeUtf8(new Uint8Array(new SharedArrayBuffer(4)).fill(97)) === 'aaaa' && decodeUtf8(encodeUtf8('x\ud83d\ude00y').subarray(1, 5)) === '\u{1F600}';
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

/// Runs an init module whose `@BACKEND@` placeholder is replaced by `backend`.
fn setupBackend(fx: *Fixture, template: []const u8, backend: []const u8, runtime: ?m.Api.RuntimeConfig) !void {
    const source = try std.mem.replaceOwned(u8, t.allocator, template, "@BACKEND@", backend);
    defer t.allocator.free(source);
    try fx.setupRuntime(source, true, runtime);
}

const async_concurrent_source =
    \\import { Dir, IoError } from 'origine:@std/io';
    \\const bytes = s => Uint8Array.from([...s].map(c => c.charCodeAt(0)));
    \\const text = b => String.fromCharCode(...b);
    \\export async function main(api) {
    \\  const out = globalThis.report = {};
    \\  const rt = api.io.create({ backend: '@BACKEND@' });
    \\  out.handle = rt.kind === 'io' && typeof rt.id === 'number' && typeof rt.backend === 'string' && Object.isFrozen(rt);
    \\  const sync = api.fs.requestSync({ write: true });
    \\  const fs = await api.fs.requestAsync({ io: rt, write: true });
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
    \\  await cwd.statFile(fs, 'a').catch(e => { out.treeGone = IoError.is(e, IoError.FileNotFound); });
    \\  out.rootSafe = await cwd.deleteTree(fs, '.').then(() => false, e => IoError.is(e, IoError.InvalidPath));
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
    \\  out.closedFile = await file.stat(fs).then(() => false, e => e.errno === IoError.BadHandle || e.errno === IoError.StaleHandle);
    \\  // A read-only grant on the same runtime.
    \\  const ro = await api.fs.narrow({ write: false }).requestAsync({ io: rt, write: true });
    \\  out.roRead = text(await cwd.readFile(ro, 'f5.txt')) === 'data-5';
    \\  const denied = e => IoError.is(e, IoError.AccessDenied);
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
    \\  const inner = await api.fs.requestAsync({ io: rt, root: 'inner', write: true });
    \\  await cwd.writeFile(inner, { sub_path: 'x.txt', data: bytes('in') });
    \\  out.inner = text(await cwd.readFile(fs, 'inner/x.txt'));
    \\  out.innerEscape = await cwd.readFile(inner, '../f0.txt').then(() => false, e => IoError.is(e, IoError.InvalidPath));
    \\  // Closing the runtime: the handle is dead for new grants and idempotent to close again.
    \\  await rt.close();
    \\  await rt.close();
    \\  out.afterClose = await api.fs.requestAsync({ io: rt }).then(() => 'ok', e => e.errno);
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
        try check(fx.scope, "report.codes === '1,8,5,3,0,0' && report.names === 'FileNotFound,InvalidPath,PathAlreadyExists,NotDir' && report.cellClean");
        try check(fx.scope, "report.sub === 'c,in.txt' && report.moved === 'x' && report.treeGone && report.rootSafe");
        try check(fx.scope, "report.preads === '5,5,5:Jello|lo wo|world' && report.length === 11 && report.truncated === '5:Jello'");
        try check(fx.scope, "report.streamEnd === '0:0' && report.closedFile");
        try check(fx.scope, "report.roRead && report.roDenied === 'true,true,true,true,true,true'");
        try check(fx.scope, "report.inner === 'in' && report.innerEscape && report.afterClose === 6 && report.opAfterClose === true");
    }
}

test "api: closing an io runtime cancels in-flight operations and frees its slot" {
    var fx: Fixture = undefined;
    try setupBackend(&fx,
        \\import { Dir, IoError } from 'origine:@std/io';
        \\const bytes = s => Uint8Array.from([...s].map(c => c.charCodeAt(0)));
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const first = api.io.create({ backend: '@BACKEND@' });
        \\  const second = api.io.create({});
        \\  // The embedder ceiling (max_runtimes = 2) applies to live runtimes.
        \\  try { api.io.create({}); out.third = false; } catch (e) { out.third = true; }
        \\  const fs = await api.fs.requestAsync({ io: first, write: true });
        \\  const cwd = Dir.cwd();
        \\  await cwd.writeFile(fs, { sub_path: 'big.bin', data: new Uint8Array(1 << 20).fill(97) });
        \\  const pending = [];
        \\  for (let i = 0; i < 64; i++) pending.push(cwd.readFile(fs, 'big.bin'), cwd.writeFile(fs, { sub_path: 'w' + i, data: bytes('z') }), cwd.deleteTree(fs, 'nothing' + i));
        \\  const closing = first.close();
        \\  const settled = await Promise.allSettled(pending);
        \\  await closing;
        \\  // Every operation settled: finished before the close, or canceled/stale after it.
        \\  const allowed = [IoError.Canceled, IoError.StaleHandle, IoError.BadHandle, IoError.FileNotFound];
        \\  out.settled = settled.length === pending.length && settled.every(r => r.status === 'fulfilled' || allowed.includes(r.reason.errno));
        \\  out.canceledKnown = IoError.Canceled === 14 && IoError.name(14) === 'Canceled';
        \\  // The slot is free again; the other runtime is unaffected.
        \\  const third = api.io.create({});
        \\  const other = await api.fs.requestAsync({ io: second });
        \\  out.otherWorks = (await cwd.readFile(other, 'big.bin')).length === 1 << 20;
        \\  await third.close();
        \\  await second.close();
        \\  // Left in flight: Host.destroy drains them without leaking.
        \\  const last = api.io.create({});
        \\  const lastFs = await api.fs.requestAsync({ io: last });
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
        \\import { IoError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const code = p => p.then(() => 0, e => e.errno);
        \\  const rt = api.io.create({});
        \\  const other = api.io.create({});
        \\  out.missing = await code(api.fs.requestAsync({}));
        \\  out.notHandle = await code(api.fs.requestAsync({ io: 7 }));
        \\  out.forged = await code(api.fs.requestAsync({ io: Object.freeze({ kind: 'io', id: rt.id, backend: 'auto' }) }));
        \\  out.getter = await code(api.fs.requestAsync({ get io() { return rt; } }));
        \\  out.badRoot = await code(api.fs.requestAsync({ io: rt, root: 42 }));
        \\  out.escape = await code(api.fs.requestAsync({ io: rt, root: '../x' }));
        \\  await other.close();
        \\  out.closed = await code(api.fs.requestAsync({ io: other }));
        \\  out.live = await code(api.fs.requestAsync({ io: rt }));
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
    // BadHandle 6, InvalidPath 8; create() accepts an absent option bag and throws a TypeError for malformed ones.
    try check(fx.scope, "report.missing === 6 && report.notHandle === 6 && report.forged === 6 && report.getter === 6 && report.closed === 6");
    try check(fx.scope, "report.badRoot === 8 && report.escape === 8 && report.live === 0 && report.frozen");
    try check(fx.scope, "report.badOpts === 'ok,T,T,T' && report.badBackend === 'T' && report.badEntries === 'T'");
}

test "api: without a runtime ceiling there is no api.io and no async fs" {
    var fx: Fixture = undefined;
    try fx.setupRuntime(
        \\import { IoError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  out.noIo = !('io' in api);
        \\  out.asyncDenied = await api.fs.requestAsync({ io: undefined }).then(() => 0, e => e.errno);
        \\  out.syncWorks = typeof api.fs.requestSync({}) === 'object';
        \\}
    , true, null);
    defer fx.deinit();
    try fx.run();
    try check(fx.scope, "report.noIo && report.asyncDenied === 6 && report.syncWorks");
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
    try t.expectEqual(@backingInt(m.Api.Errno.FileNotFound), state.cell);
    // Mistyped or missing arguments fail before the function runs (InvalidArgument -> InvalidPath).
    const before = state.total;
    for ([_][]const u8{ "native.add('x', 1)", "native.add(1)", "native.greet(5)", "native.sum([1, 2])", "native.sum(new Uint8Array(new SharedArrayBuffer(4)))", "native.greet('x', 5)", "native.maybe(1)" }) |call_source| {
        const source = try std.fmt.allocPrint(t.allocator, "{s} === undefined", .{call_source});
        defer t.allocator.free(source);
        try check(scope, source);
        try t.expectEqual(@backingInt(m.Api.Errno.InvalidPath), state.cell);
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
    try t.expect(std.mem.indexOf(u8, m.Api.std_io_source, "FileNotFound: 1") == null);
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
    \\import { Dir, IoError } from 'origine:@std/io';
    \\import { fs as rustFs } from 'origine:@std/fs';
    \\const bytes = s => Uint8Array.from([...s].map(c => c.charCodeAt(0)));
    \\const text = b => String.fromCharCode(...b);
    \\export async function main(api) {
    \\  const out = globalThis.report = {};
    \\  const rt = api.io.create({ backend: '@BACKEND@' });
    \\  const fs = await api.fs.requestAsync({ io: rt, write: true });
    \\  const sync = api.fs.requestSync({ write: true });
    \\  const cwd = Dir.cwd();
    \\  const read = name => cwd.readFile(fs, name);
    \\
    \\  // Writes detach an eligible buffer (and every view over it) and copy an ineligible one.
    \\  const w = new Uint8Array(bytes('detached!'));
    \\  const wView = w.subarray(2, 5);
    \\  await cwd.writeFile(fs, { sub_path: 'w.txt', data: w });
    \\  out.detached = w.buffer.byteLength === 0 && w.length === 0 && w.byteLength === 0 && wView.length === 0;
    \\  out.detachedWritten = text(await read('w.txt')) === 'detached!';
    \\  const file = await cwd.createFile(fs, 'w2.txt');
    \\  const w2 = bytes('ab');
    \\  const w3 = bytes('cd');
    \\  await file.writeStreamingAll(fs, w2);
    \\  out.writeAllDetached = w2.buffer.byteLength === 0;
    \\  out.partial = (await file.writeStreaming(fs, w3)) <= 2 && w3.buffer.byteLength === 0;
    \\  await file.writePositionalAll(fs, bytes('XY'), 0);
    \\  await file.close(fs);
    \\  out.afterWrites = text(await read('w2.txt')).startsWith('XY');
    \\  // A failed write still consumes the buffer; a copy (slice) keeps the data.
    \\  const keep = bytes('keep');
    \\  await cwd.writeFile(fs, { sub_path: 'keep.txt', data: keep.slice() });
    \\  out.sliceKeeps = text(keep) === 'keep';
    \\  // Rust-style API: write() detaches a Uint8Array argument; copy() and strings are unaffected.
    \\  const rs = rustFs(fs);
    \\  const rsBuf = bytes('rust');
    \\  await rs.write('rs.txt', rsBuf);
    \\  out.rustDetached = rsBuf.buffer.byteLength === 0;
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
    \\  // Raw glue validation: rejects InvalidPath without touching the buffer.
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
        try check(fx.scope, "report.detached && report.detachedWritten && report.writeAllDetached && report.partial && report.afterWrites && report.sliceKeeps");
        try check(fx.scope, "report.rustDetached && report.rustString && report.copied && report.copiedSync");
        try check(fx.scope, "report.copyFallbackAll");
        try check(fx.scope, "report.byob && report.byobDead && report.subView && report.u16 && report.dataView && report.bareBuffer");
        try check(fx.scope, "report.shortByob && report.eofByob && report.emptyByob && report.streamByob && report.byobFallback");
        try check(fx.scope, "report.alloc && report.allocShort && report.allocCompact && report.allocEof && report.allocZero && report.allocStream === '012345:4'");
        try check(fx.scope, "report.syncUnsupported && report.validation === '8,8,8,8,8,8,8,8,8,8' && report.validationUntouched && report.rawOk && report.rawFrozen && report.afterClose");
    }
}

test "api: closing an io runtime with pinned reads and writes in flight is safe" {
    var fx: Fixture = undefined;
    try setupBackend(&fx,
        \\import { Dir, IoError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const rt = api.io.create({ backend: '@BACKEND@' });
        \\  const fs = await api.fs.requestAsync({ io: rt, write: true });
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
        \\  const allowed = [IoError.Canceled, IoError.StaleHandle, IoError.BadHandle];
        \\  out.errors = settled.every(r => r.status === 'fulfilled' || allowed.includes(r.reason.errno));
        \\  out.canceled = settled.some(r => r.status === 'rejected' && r.reason.errno === IoError.Canceled) || settled.every(r => r.status === 'fulfilled');
        \\  // Whatever completed holds exactly what was read; nothing is resurrected into the dead buffers.
        \\  out.results = settled.every((r, i) => r.status !== 'fulfilled' || i % 3 === 1 || (r.value instanceof Uint8Array ? r.value.every(b => b === 65) : r.value.buffer.subarray(0, r.value.bytes).every(b => b === 65)));
        \\  out.deadViews = views.every(v => v.length === 0 || v.byteLength === 1 << 20);
        \\  // A new runtime still works.
        \\  const rt2 = api.io.create({});
        \\  const fs2 = await api.fs.requestAsync({ io: rt2 });
        \\  out.after = (await cwd.readFile(fs2, 'big.bin')).length === 4 << 20;
        \\  await rt2.close();
        \\  // Left in flight at Host.destroy.
        \\  const last = api.io.create({});
        \\  const lastFs = await api.fs.requestAsync({ io: last });
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
        \\  const fs = await api.fs.requestAsync({ io: rt, write: true });
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
    \\  const { Handle, Server, Socket } = api.net;
    \\  const io = api.io.create({ backend: '@BACKEND@' });
    \\  const server = api.net.listen(io, { port: 0 });
    \\  out.server = server instanceof Server && server instanceof Handle && server.port > 0 && server.io === io && !server.closed;
    \\
    \\  // Echo server: one connection, echo until end of stream.
    \\  const echoed = (async () => {
    \\    const conn = await server.accept();
    \\    let total = 0;
    \\    for (;;) {
    \\      const chunk = await conn.read(4096);
    \\      if (chunk.length === 0) break;
    \\      total += await conn.write(chunk);
    \\    }
    \\    await conn.close();
    \\    return total;
    \\  })();
    \\
    \\  const client = await api.net.connect(io, { host: '127.0.0.1', port: server.port });
    \\  out.client = client instanceof Socket && client instanceof Handle && client.remotePort === server.port;
    \\  const message = Uint8Array.from('ping-pong', c => c.charCodeAt(0));
    \\  let reply = '';
    \\  for (let i = 0; i < 3; i++) {
    \\    out.wrote = (await client.write(message)) === message.length;
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
    \\  await client.write(message);
    \\  const reuse = new Uint8Array(32);
    \\  let have = 0;
    \\  while (have < message.length) have += await client.readCopy(reuse.subarray(have));
    \\  out.readCopy = have === message.length && String.fromCharCode(...reuse.subarray(0, have)) === 'ping-pong' && reuse.buffer.byteLength === 32 &&
    \\    (await client.readCopy(new Uint8Array(0))) === 0 &&
    \\    (await client.readCopy({}).then(() => false, e => e instanceof TypeError));
    \\
    \\  // readInto: the buffer is detached and handed back as a new ArrayBuffer; undetachable buffers are refused untouched.
    \\  await client.write(message);
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
    \\  const sending = client.write(big);
    \\  let received = 0, ordered = true;
    \\  while (received < big.length) {
    \\    const part = await client.read(1 << 16);
    \\    for (let i = 0; i < part.length; i++) ordered &&= part[i] === ((received + i) & 255);
    \\    received += part.length;
    \\  }
    \\  out.big = (await sending) === big.length && received === big.length && ordered;
    \\
    \\  // Closing the client ends the echo loop; reads after close reject.
    \\  await client.close();
    \\  out.echoTotal = (await echoed) === 27 + 9 + 9 + (1 << 20);
    \\  out.closed = client.closed && (await client.read(1).then(() => false, e => e.name === 'BadHandle'));
    \\
    \\  // Errors and validation.
    \\  const refused = await api.net.connect(io, { port: server.port }).then(() => 'ok', e => e.name);
    \\  await server.close();
    \\  out.refused = refused === 'ConnectionRefused' || refused === 'ok';
    \\  out.denied = await api.net.connect(io, { host: '8.8.8.8', port: 53 }).then(() => false, e => e.name === 'AccessDenied');
    \\  out.badIo = (() => { try { api.net.listen({}, {}); return false; } catch (e) { return e.name === 'BadHandle'; } })();
    \\  out.badArgs = (() => { try { api.net.listen(io, { port: 70000 }); return false; } catch (e) { return e instanceof TypeError; } })();
    \\  out.noForge = (() => { try { new Socket({}, 1, io, 1); return false; } catch (e) { return e instanceof TypeError; } })() &&
    \\    await Socket.prototype.read.call({}, 1).then(() => false, e => e instanceof TypeError) &&
    \\    Object.isFrozen(api.net) && Object.isFrozen(Socket) && Object.isFrozen(Socket.prototype);
    \\
    \\  // Closing the runtime invalidates open handles.
    \\  const second = api.net.listen(io, {});
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
    \\  const server = api.net.listen(io, { port: 0 });
    \\  const enc = s => Uint8Array.from(s, c => c.charCodeAt(0));
    \\  let serverEnded = false, serverClosed = false, serverEvent = false, accepted = 0;
    \\
    \\  // Echo server over events: lease the chunk, send it back, give the lease back.
    \\  const reg = server.register('connection', conn => {
    \\    accepted++;
    \\    conn.register('data', ev => {
    \\      const buf = ev.buffer();
    \\      conn.send(buf);
    \\      buf.unref();
    \\    });
    \\    conn.register('end', () => { serverEnded = true; poke(); });
    \\    conn.register('close', () => { serverClosed = true; poke(); });
    \\  });
    \\  server.register('close', () => { serverEvent = true; });
    \\  // Handlers do not keep the program alive; a pending `io.run()` does (until every flowing handle closed).
    \\  const running = io.run();
    \\  let settled = false;
    \\  running.then(() => { settled = true; });
    \\
    \\  const client = await api.net.connect(io, { host: '127.0.0.1', port: server.port });
    \\  const waiters = [];
    \\  const poke = () => { for (const w of waiters.splice(0)) w(); };
    \\  const until = pred => new Promise(resolve => {
    \\    const check = () => (pred() ? resolve() : waiters.push(check));
    \\    check();
    \\  });
    \\
    \\  let text = '', total = 0, position = 0, ordered = true, countBytes = false;
    \\  let count = 0, ready = 0, retained = null, keptEvent = null, sameLease = false, extra = 0;
    \\  const errors = [];
    \\  client.register('error', e => { errors.push(e); poke(); });
    \\  client.register('ready', () => { ready++; poke(); });
    \\  client.register('data', ev => {
    \\    keptEvent = ev;
    \\    const buf = ev.buffer();
    \\    sameLease = ev.buffer() === buf && ev.length === buf.length && buf.buffer.byteLength >= buf.length;
    \\    total += buf.length;
    \\    if (countBytes) {
    \\      for (let i = 0; i < buf.length; i++) ordered &&= buf[i] === ((position + i) & 255);
    \\      position += buf.length;
    \\    } else {
    \\      text += String.fromCharCode(...buf);
    \\    }
    \\    if (text === 'ping-pong' && retained === null) retained = buf; // kept past the callback
    \\    else buf.unref();
    \\    poke();
    \\  });
    \\  // A throwing handler is routed to the error handlers; the other handlers still run.
    \\  client.register('data', ev => { if (ev.length === 4) throw new Error('boom'); });
    \\  // unregister stops delivery to that handler only.
    \\  const counted = client.register('data', () => { count++; });
    \\
    \\  out.sendTrue = client.send(enc('ping-pong')) === true;
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
    \\    client.send(enc(message));
    \\    await until(() => text.length >= message.length);
    \\    pooled &&= text === message;
    \\  }
    \\  out.pooled = pooled;
    \\
    \\  // Symbol.dispose releases like unref.
    \\  if (typeof Symbol.dispose === 'symbol') {
    \\    const lease = (() => { let got; const r = client.register('data', ev => { got ??= ev.buffer(); }); return { r, get: () => got }; })();
    \\    text = '';
    \\    client.send(enc('dispose'));
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
    \\  client.send(enc('boom'));
    \\  await until(() => errors.length === 1);
    \\  out.thrown = errors[0] instanceof Error && errors[0].message === 'boom' && text === 'boom';
    \\
    \\  const before = count;
    \\  counted.unregister();
    \\  text = '';
    \\  client.send(enc('after'));
    \\  await until(() => text === 'after');
    \\  out.unregistered = count === before && count > 0 && counted.unregister() === false;
    \\
    \\  // A large send answers false, `ready` follows, and everything comes back in order.
    \\  const big = new Uint8Array(4 << 20).map((_, i) => i & 255);
    \\  countBytes = true;
    \\  total = 0;
    \\  const wrote = client.send(big);
    \\  out.backpressure = wrote === false;
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
    \\    (() => { try { client.send(enc('x')); return false; } catch (e) { return e.name === 'BadHandle'; } })();
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
    \\  const server = api.net.listen(io, { port: 0 });
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
        try check(fx.scope, "report.sendTrue && report.echo && report.eventValid && report.retained && report.released && report.eventOver && report.pooled && report.dispose");
        try check(fx.scope, "report.thrown && report.unregistered && report.backpressure && report.big && report.closed && report.unreg");
        try check(fx.scope, "report.runWaits && report.run && report.runAfterClose");
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
