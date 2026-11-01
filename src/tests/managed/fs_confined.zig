const std = @import("std");
const t = std.testing;
const sys = @import("@managed").sys;
const check = @import("support.zig").check;
const Parent = @import("channel.zig").Parent;

/// `root/` is what the grants are rooted at; `outside.txt` and `up` lead out of it.
fn layout(p: *Parent) !void {
    try p.tmp.dir.createDirPath(t.io, "root/d");
    try p.tmp.dir.writeFile(t.io, .{ .sub_path = "outside.txt", .data = "SECRET" });
    try p.tmp.dir.writeFile(t.io, .{ .sub_path = "root/inner.txt", .data = "inner" });
    try p.tmp.dir.writeFile(t.io, .{ .sub_path = "root/d/f.txt", .data = "f" });
    const handle = p.tmp.dir.handle;
    try sys.light.posix.symlinkat("d", handle, "root/in");
    try sys.light.posix.symlinkat("d/f.txt", handle, "root/file");
    try sys.light.posix.symlinkat("d/../inner.txt", handle, "root/back");
    try sys.light.posix.symlinkat("..", handle, "root/up");
    try sys.light.posix.symlinkat("up/root", handle, "root/there");
    try sys.light.posix.symlinkat("/", handle, "root/abs");
    try sys.light.posix.symlinkat("../planted.txt", handle, "root/dangling");
    try sys.light.posix.symlinkat("loop", handle, "root/loop");
    try sys.light.posix.symlinkat("../inner.txt", handle, "root/d/parent");
}

const probes =
    \\import { Dir } from 'origine:@std/io';
    \\import { fs } from 'origine:@std/fs';
    \\const name = async f => { try { await f(); return 'ok'; } catch (e) { return e.name; } };
    \\const text = async f => { try { return String(await f()); } catch (e) { return e.name; } };
    \\const exercise = async (grant, cwd) => {
    \\  const r = fs(grant);
    \\  const read = path => text(() => r.read_to_string(path));
    \\  return {
    \\    inside: [await read('inner.txt'), await read('in/f.txt'), await read('file'), await read('back')].join(),
    \\    escape: [await read('up/outside.txt'), await read('abs/etc/hosts'), await read('there/inner.txt')].join(),
    \\    meta: [await name(() => r.metadata('up')), await name(() => r.try_exists('up/outside.txt'))].join(),
    \\    // The entry itself is not followed: a link is looked at and removed without going through it.
    \\    entry: [(await r.symlink_metadata('up')).is_symlink(), await name(() => r.symlink_metadata('up/outside.txt'))].join(),
    \\    write: [await name(() => r.write('up/planted.txt', 'x')), await name(() => r.write('dangling', 'x')), await name(() => r.create_dir('up/made')),
    \\      await name(() => r.create_dir_all('up/made/deep')), await name(() => r.remove_file('up/outside.txt')), await name(() => r.remove_dir_all('up/root')),
    \\      await name(() => r.rename('inner.txt', 'up/moved.txt')), await name(() => r.rename('up/outside.txt', 'took.txt'))].join(),
    \\    loop: await read('loop'),
    \\    missing: await read('nope/x'),
    \\    created: await name(() => r.write('in/new.txt', 'n')),
    \\    // An opened directory is the limit for the calls that name it.
    \\    opened: await text(async () => {
    \\      const d = await Dir.cwd().openDir(grant, 'd');
    \\      return name(() => fs(grant, d).read_to_string('parent'));
    \\    }),
    \\  };
    \\};
    \\const expected = JSON.stringify({
    \\  inside: 'inner,f,f,inner',
    \\  escape: 'PermissionDenied,PermissionDenied,PermissionDenied',
    \\  meta: 'PermissionDenied,PermissionDenied',
    \\  entry: 'true,PermissionDenied',
    \\  write: Array(8).fill('PermissionDenied').join(),
    \\  loop: 'FilesystemLoop',
    \\  missing: 'NotFound',
    \\  created: 'ok',
    \\  opened: 'PermissionDenied',
    \\});
    \\
;

test "fs: a confined grant refuses symlinks that leave the directory, in both kinds" {
    var p: Parent = undefined;
    try p.setup("init.js", probes ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const sync = await exercise(api.fs.requestSync({ access: 'rw', root: 'root', handle: 'plain', symlinks: 'confined' }));
        \\  out.sync = JSON.stringify(sync) === expected || JSON.stringify(sync);
        \\  const asyncResult = await exercise(await api.fs.requestAsync({ io, access: 'rw', root: 'root', handle: 'plain', symlinks: 'confined' }));
        \\  out.asyncResult = JSON.stringify(asyncResult) === expected || JSON.stringify(asyncResult);
        \\  const outside = fs(api.fs.requestSync({ access: 'r', handle: 'plain' }));
        \\  // A link itself can go: removing it does not pass through it.
        \\  out.unlink = await name(() => fs(api.fs.requestSync({ access: 'rw', root: 'root', handle: 'plain', symlinks: 'confined' })).remove_file('up')) === 'ok';
        \\  out.untouched = outside.read_to_string('outside.txt') === 'SECRET' && !outside.exists('planted.txt') && !outside.exists('made') && !outside.exists('moved.txt');
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try layout(&p);
    try p.run();
    try check(p.scope, "report.sync === true && report.asyncResult === true && report.unlink && report.untouched");
}

test "fs: symlinks option: default follows, bad values and a root through a link are refused" {
    var p: Parent = undefined;
    try p.setup("init.js", probes ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const request = options => api.fs.requestSync({ access: 'r', handle: 'plain', ...options });
        \\  const requestAsync = options => api.fs.requestAsync({ io, access: 'r', handle: 'plain', ...options });
        \\  out.follows = fs(request({ root: 'root' })).read_to_string('up/outside.txt') === 'SECRET'
        \\    && fs(request({ root: 'root', symlinks: 'follow' })).read_to_string('up/outside.txt') === 'SECRET'
        \\    && await fs(await requestAsync({ root: 'root' })).read_to_string('up/outside.txt') === 'SECRET';
        \\  out.bad = await name(() => request({ symlinks: 'nope' })) === 'InvalidInput' && await name(() => requestAsync({ symlinks: true })) === 'InvalidInput';
        \\  out.root = await name(() => request({ root: 'root/abs', symlinks: 'confined' })) === 'PermissionDenied'
        \\    && await name(() => requestAsync({ root: 'root/abs', symlinks: 'confined' })) === 'PermissionDenied'
        \\    && await name(() => request({ root: 'root/in', symlinks: 'confined' })) === 'ok'
        \\    // The limit of a root is the host's root: this link climbs out of `root` but not out of that.
        \\    && await name(() => request({ root: 'root/up', symlinks: 'confined' })) === 'ok';
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try layout(&p);
    try p.run();
    try check(p.scope, "report.follows && report.bad && report.root");
}

test "fs: the graph reads through a confined grant's checks" {
    var p: Parent = undefined;
    try p.setup("init.js",
        \\import { ImportHandler } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative } from 'origine:@std/graph/resolve/layers';
        \\import { fsProvider } from 'origine:@std/graph/providers';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const attempt = async grant => {
        \\    const handler = ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [fsProvider({ fs: grant, read: 'copy' })] });
        \\    const context = await api.context.create({ import: handler, graph: api.graph.create() });
        \\    return context.import('./up/out.js').then(() => 'ok', e => e.errno);
        \\  };
        \\  const denied = (await import('origine:@std/io')).IoError.PermissionDenied;
        \\  out.sync = await attempt(api.fs.requestSync({ access: 'r', root: 'root', handle: 'plain', symlinks: 'confined' })) === denied;
        \\  out.asyncResult = await attempt(await api.fs.requestAsync({ io, access: 'r', root: 'root', handle: 'plain', symlinks: 'confined' })) === denied;
        \\  out.follow = await attempt(api.fs.requestSync({ access: 'r', root: 'root', handle: 'plain' })) === 'ok';
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try layout(&p);
    try p.tmp.dir.writeFile(t.io, .{ .sub_path = "out.js", .data = "export const out = 1;" });
    try p.run();
    try check(p.scope, "report.sync && report.asyncResult && report.follow");
}

test "fs: remove_dir_all keeps its Rust meaning" {
    var p: Parent = undefined;
    try p.setup("init.js",
        \\import { fs } from 'origine:@std/fs';
        \\const name = async f => { try { await f(); return 'ok'; } catch (e) { return e.name; } };
        \\const exercise = async (grant, base) => {
        \\  const r = fs(grant);
        \\  await r.create_dir_all(base + '/full/deep');
        \\  await r.write(base + '/full/deep/f.txt', 'x');
        \\  await r.create_dir(base + '/empty');
        \\  await r.write(base + '/file.txt', 'x');
        \\  const results = [
        \\    await name(() => r.remove_dir_all(base + '/missing')),
        \\    await name(() => r.remove_dir_all(base + '/file.txt')),
        \\    await r.exists(base + '/file.txt'),
        \\    await name(() => r.remove_dir_all(base + '/empty')),
        \\    await r.exists(base + '/empty'),
        \\    await name(() => r.remove_dir_all(base + '/full')),
        \\    await r.exists(base + '/full'),
        \\  ];
        \\  return results.join();
        \\};
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  out.sync = await exercise(api.fs.requestSync({ access: 'rw', handle: 'plain' }), 's');
        \\  out.asyncResult = await exercise(await api.fs.requestAsync({ io, access: 'rw', handle: 'plain' }), 'a');
        \\  // The link goes, what it points to stays.
        \\  const r = fs(api.fs.requestSync({ access: 'rw', handle: 'plain' }));
        \\  out.link = await name(() => r.remove_dir_all('link')) === 'ok' && !r.exists('link') && r.exists('kept/f.txt');
        \\  const wo = fs(api.fs.requestSync({ access: 'w', handle: 'plain' }));
        \\  await r.create_dir_all('w/deep');
        \\  out.writeOnly = await name(() => wo.remove_dir_all('w')) === 'ok' && !r.exists('w');
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.tmp.dir.createDirPath(t.io, "kept");
    try p.tmp.dir.writeFile(t.io, .{ .sub_path = "kept/f.txt", .data = "f" });
    try sys.light.posix.symlinkat("kept", p.tmp.dir.handle, "link");
    try p.run();
    const want = "'NotFound,NotADirectory,true,ok,false,ok,false'";
    try check(p.scope, "report.sync === " ++ want ++ " && report.asyncResult === " ++ want ++ " && report.link && report.writeOnly");
}

test "graph: read 'mmap' lets V8 read an ASCII file in place, and copies what it cannot" {
    var p: Parent = undefined;
    try p.setup("init.js",
        \\import { fs } from 'origine:@std/fs';
        \\import { ImportHandler, MakeRecipe } from 'origine:@std/graph/import';
        \\import { ImportResolver } from 'origine:@std/graph/resolve';
        \\import { relative } from 'origine:@std/graph/resolve/layers';
        \\import { fsProvider } from 'origine:@std/graph/providers';
        \\const body = marker => `export const f = () => '${marker}';`;
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const grant = api.fs.requestSync({ access: 'rw', handle: 'plain' });
        \\  const r = fs(grant);
        \\  const load = async (read, path, maker) => {
        \\    const handler = ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [fsProvider({ fs: grant, read })], ...(maker ? { maker } : {}) });
        \\    const graph = api.graph.create();
        \\    const context = await api.context.create({ import: handler, graph });
        \\    return graph.exports(await context.import('./' + path));
        \\  };
        \\  r.write('mapped.js', body('AAAA'));
        \\  out.mapped = (await load('mmap', 'mapped.js')).f() === 'AAAA';
        \\  r.write('copied.js', body('AAAA'));
        \\  out.copied = (await load('copy', 'copied.js')).f() === 'AAAA';
        \\  const maker = MakeRecipe.fn(() => ({}));
        \\  r.write('maker.js', body('AAAA'));
        \\  out.maker = (await load('mmap', 'maker.js', maker)).f() === 'AAAA';
        \\  r.write('utf8.js', "export const s = 'café 世界';");
        \\  out.utf8 = (await load('mmap', 'utf8.js')).s === 'café 世界';
        \\  r.write('empty.js', '');
        \\  out.empty = Object.keys(await load('mmap', 'empty.js')).length === 0;
        \\  out.missing = await load('mmap', 'nope.js').then(() => false, e => e.errno !== undefined);
        \\  r.create_dir('dir.js');
        \\  out.directory = await load('mmap', 'dir.js').then(() => false, e => e.errno !== undefined);
        \\  // Collecting what is mapped releases it; a later import maps again.
        \\  const big = 'export const n = 1;\n' + '// padding padding padding padding\n'.repeat(4096);
        \\  r.write('big.js', big);
        \\  for (let i = 0; i < 20; i++) await load('mmap', 'big.js');
        \\  // The loop has no mapping: an async grant fails where the handler is taken, not silently.
        \\  const asyncGrant = await api.fs.requestAsync({ io, access: 'r', handle: 'plain' });
        \\  const handler = ImportHandler.make({ resolver: ImportResolver.layered().layer(relative()), hooks: [fsProvider({ fs: asyncGrant, read: 'mmap' })] });
        \\  out.asyncGrant = await api.context.create({ import: handler, graph: api.graph.create() }).then(() => 'made', e => e.name);
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.mapped && report.copied && report.maker && report.utf8 && report.empty && report.missing && report.directory && report.asyncGrant === 'Unsupported'");
    // mapped.js and the 20 imports of big.js; not the copy, the maker's, the UTF-8 or the empty one.
    try t.expectEqual(@as(usize, 21), p.host.mapped_sources);
}

test "fs: errors mean one thing in both kinds" {
    var p: Parent = undefined;
    try p.setup("init.js",
        \\import { Dir, File } from 'origine:@std/io';
        \\import { fs } from 'origine:@std/fs';
        \\const name = async f => { try { await f(); return 'ok'; } catch (e) { return e.name; } };
        \\const exercise = async grant => {
        \\  const r = fs(grant);
        \\  await r.write('g.txt', 'hello');
        \\  const reading = await r.File.open('g.txt');
        \\  const writing = await r.File.create('h.txt');
        \\  const bytes = new Uint8Array(1);
        \\  const raw = await Dir.cwd().openFile(grant, 'g.txt', { mode: 'read_write' });
        \\  const out = {
        \\    write: await name(() => reading.write_all('x')),
        \\    writeOne: await name(() => reading.write('x')),
        \\    typo: await name(() => Dir.cwd().openFile(grant, 'g.txt', { mode: 'wirte_only' })),
        \\    badLength: [await name(() => writing.set_len(-1)), await name(() => writing.set_len(1.5)), await name(() => writing.set_len(NaN))].join(),
        \\    goodLength: await name(() => writing.set_len(2)),
        \\    badOffset: [await name(() => raw.readPositional(grant, bytes, 1.5)), await name(() => raw.writePositionalAll(grant, bytes, -1))].join(),
        \\  };
        \\  await reading.close();
        \\  await writing.close();
        \\  await raw.close(grant);
        \\  return JSON.stringify(out);
        \\};
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  out.sync = await exercise(api.fs.requestSync({ access: 'rw', handle: 'plain' }));
        \\  const grant = await api.fs.requestAsync({ io, access: 'rw', handle: 'plain' });
        \\  out.asyncResult = await exercise(grant);
        \\  out.expected = JSON.stringify({ write: 'PermissionDenied', writeOne: 'PermissionDenied', typo: 'InvalidInput', badLength: 'InvalidInput,InvalidInput,InvalidInput', goodLength: 'ok', badOffset: 'InvalidInput,InvalidInput' });
        \\  // No silent copy: a buffer that cannot be detached is refused, untouched; an empty one is fine.
        \\  const file = await grant.dirOpenFile(Dir.cwd(), 'g.txt');
        \\  const shared = new Uint8Array(new SharedArrayBuffer(4));
        \\  const resizable = new ArrayBuffer(4, { maxByteLength: 8 });
        \\  out.into = [await name(() => grant.fileReadInto(file, shared)), await name(() => grant.fileReadInto(file, resizable)), await name(() => grant.filePreadInto(file, shared, 0)), resizable.detached, await name(() => grant.fileReadInto(file, new Uint8Array(0)))].join();
        \\  out.limitNull = await name(() => grant.fileReadAll(file, null));
        \\  // A write-only grant opens a directory to write through the handle, and still cannot list it.
        \\  const onlySync = api.fs.requestSync({ access: 'w', handle: 'plain' });
        \\  const onlyAsync = await api.fs.requestAsync({ io, access: 'w', handle: 'plain' });
        \\  await fs(api.fs.requestSync({ access: 'rw', handle: 'plain' })).create_dir('d');
        \\  const results = [];
        \\  for (const only of [onlySync, onlyAsync]) {
        \\    const d = await Dir.cwd().openDir(only, 'd');
        \\    const name2 = only.kind + '.txt';
        \\    results.push(await name(() => d.writeFile(only, { sub_path: name2, data: new Uint8Array(1) })), await name(() => d.iterate(only)));
        \\    await d.close(only);
        \\  }
        \\  out.writeOnly = results.join();
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.sync === report.expected && report.asyncResult === report.expected");
    try check(p.scope, "report.into === 'Unsupported,Unsupported,Unsupported,false,ok' && report.limitNull === 'ok'");
    try check(p.scope, "report.writeOnly === 'ok,PermissionDenied,ok,PermissionDenied'");
}
