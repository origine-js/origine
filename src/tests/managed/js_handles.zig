const std = @import("std");
const t = std.testing;
const m = @import("@managed");
const support = @import("../support.zig");
const check = @import("support.zig").check;

/// Runs the public handle API against real sync and async grants in a temporary directory.
fn run(source: []const u8) !void {
    support.ensureV8();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "init.js", .data = source });
    const init = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}/init.js", .{tmp.sub_path});
    defer t.allocator.free(init);
    const rt = try m.Runtime.create(t.allocator, .{});
    defer rt.destroy();
    const host = try m.Api.Host.create(t.allocator, .{ .fs = .{ .root = .{ .handle = tmp.dir.handle } }, .runtime = .{} });
    defer host.destroy();
    const scope = try rt.createScope(host.initOptions());
    var info: m.ErrorInfo = .{};
    defer info.deinit();
    try host.run(scope, support.engine.platform, init, &info);
    try check(scope, "handleChecks");
}

test "JS handles: a plain grant takes any file handle and leaves the ids to the natives" {
    try run(
        \\import { Dir, File, IoError } from 'origine:@std/io';
        \\export function main(api) {
        \\  const fs = api.fs.requestSync({ handle: 'plain', access: 'rw' });
        \\  const file = IoError.check(fs, fs.dirOpenFile(Dir.cwd(), 'test', 'w'));
        \\  let getterReads = 0;
        \\  const literal = { get fs() { getterReads++; return file.fs; }, get id() { getterReads++; return file.id; }, kind: 'file' };
        \\  fs.fileStat(literal);
        \\  const literalRejected = fs.errno[0] === IoError.InvalidInput;
        \\  const empty = Object.create(Object.getPrototypeOf(file));
        \\  fs.fileStat(empty);
        \\  const emptyRejected = fs.errno[0] !== 0;
        \\  // A handle is a value like a file descriptor: rebuilding one from its fields names the same file.
        \\  const rebuilt = File.at(file.fs, file.id);
        \\  fs.fileStat(rebuilt);
        \\  const rebuiltAccepted = fs.errno[0] === 0 && File.is(rebuilt) && !File.is(literal);
        \\  globalThis.handleChecks = literalRejected && getterReads === 0 && emptyRejected && rebuiltAccepted && Object.isFrozen(file);
        \\  IoError.check(fs, fs.fileClose(file));
        \\}
    );
}

test "JS handles: a hardened grant takes only the handles it issued" {
    try run(
        \\import { Dir, File, IoError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const hard = api.fs.requestSync({ handle: 'hardened', access: 'rw' });
        \\  const plain = api.fs.requestSync({ handle: 'plain', access: 'rw' });
        \\  const mine = IoError.check(hard, hard.dirOpenFile(Dir.cwd(), 'test', 'w'));
        \\  const theirs = IoError.check(plain, plain.dirOpenFile(Dir.cwd(), 'other', 'w'));
        \\  const refused = handle => { hard.fileStat(handle); return hard.errno[0] === IoError.InvalidInput; };
        \\  hard.fileStat(mine);
        \\  const issued = hard.errno[0] === 0;
        \\  // Rebuilt from its fields, issued by another grant, or hand-made: none carries this grant's issuer.
        \\  const rebuilt = refused(File.at(mine.fs, mine.id));
        \\  const foreign = refused(theirs);
        \\  const literal = refused({ kind: 'file', fs: mine.fs, id: mine.id });
        \\  // The std methods rewrap a result of the grant and keep its issuer.
        \\  const wrapped = IoError.check(hard, Dir.cwd().openFile(hard, 'test'));
        \\  wrapped.stat(hard);
        \\  const rewrapped = File.is(wrapped);
        \\  // The root sentinel names no resource and works on a hardened grant.
        \\  const entries = hard.dirRead(Dir.cwd());
        \\  const sentinel = hard.errno[0] === 0 && Array.isArray(entries);
        \\  const io = api.io.create({ backend: 'threaded' });
        \\  const remote = await api.fs.requestAsync({ handle: 'hardened', io, access: 'rw' });
        \\  const opened = await remote.dirOpenFile(Dir.cwd(), 'async', 'w');
        \\  await remote.fileStat(opened);
        \\  const asyncRefused = await remote.fileStat(File.at(opened.fs, opened.id)).then(() => false, e => e instanceof IoError && e.errno === IoError.InvalidInput);
        \\  await remote.fileClose(opened);
        \\  await io.close();
        \\  globalThis.handleChecks = issued && rebuilt && foreign && literal && rewrapped && sentinel && asyncRefused;
        \\}
    );
}

test "JS handles: the handle option of a request is required" {
    try run(
        \\import { IoError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const code = f => { try { f(); return 0; } catch (e) { return e.errno; } };
        \\  const io = api.io.create({});
        \\  const missing = code(() => api.fs.requestSync({ access: 'r' }));
        \\  const unknown = code(() => api.fs.requestSync({ access: 'r', handle: 'strict' }));
        \\  const asyncMissing = await api.fs.requestAsync({ io, access: 'r' }).then(() => 0, e => e.errno);
        \\  const ok = code(() => api.fs.requestSync({ access: 'r', handle: 'plain' }));
        \\  await io.close();
        \\  globalThis.handleChecks = missing === IoError.InvalidInput && unknown === IoError.InvalidInput && asyncMissing === IoError.InvalidInput && ok === 0;
        \\}
    );
}

test "JS handles: closed references cannot name resources opened later in either filesystem" {
    try run(
        \\import { Dir, File, IoError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const sync = api.fs.requestSync({ handle: 'plain', access: 'rw' });
        \\  const first = IoError.check(sync, sync.dirOpenFile(Dir.cwd(), 'first', 'w'));
        \\  const alias = File.at(first.fs, first.id);
        \\  IoError.check(sync, sync.fileClose(first));
        \\  const second = IoError.check(sync, sync.dirOpenFile(Dir.cwd(), 'second', 'w'));
        \\  sync.fileStat(alias);
        \\  const syncStale = sync.errno[0] !== 0 && first.id !== second.id;
        \\  IoError.check(sync, sync.fileClose(second));
        \\  const io = api.io.create({ backend: 'threaded' });
        \\  const asyncFs = await api.fs.requestAsync({ handle: 'plain', io, access: 'rw' });
        \\  const opened = await asyncFs.dirOpenFile(Dir.cwd(), 'async-first', 'w');
        \\  const asyncAlias = File.at(opened.fs, opened.id);
        \\  await asyncFs.fileClose(opened);
        \\  const next = await asyncFs.dirOpenFile(Dir.cwd(), 'async-second', 'w');
        \\  let asyncStale = false;
        \\  try { await asyncFs.fileStat(asyncAlias); } catch (e) { asyncStale = e instanceof IoError || e.name === 'BadHandle' || e.name === 'StaleHandle'; }
        \\  await asyncFs.fileClose(next);
        \\  await io.close();
        \\  globalThis.handleChecks = syncStale && asyncStale && opened.id !== next.id;
        \\}
    );
}
