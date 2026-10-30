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

test "JS handles: private state rejects forged constructors, prototypes, proxies and getters" {
    try run(
        \\import { Dir, File, IoError } from 'origine:@std/io';
        \\export function main(api) {
        \\  const fs = api.fs.requestSync({ access: 'rw' });
        \\  const file = IoError.check(fs, fs.dirOpenFile(Dir.cwd(), 'test', 'w'));
        \\  let constructorRejected = false, getterReads = 0, borrowedRejected = false;
        \\  try { new file.constructor(file.id); } catch (e) { constructorRejected = e instanceof TypeError; }
        \\  const forged = { get fs() { getterReads++; return file.fs; }, get id() { getterReads++; return file.id; }, kind: 'file' };
        \\  fs.fileStat(forged);
        \\  const forgedRejected = fs.errno[0] === IoError.InvalidInput;
        \\  const stateHidden = file.constructor.unwrap === undefined && Object.getPrototypeOf(file.constructor).unwrap === undefined;
        \\  const fake = Object.create(Object.getPrototypeOf(file));
        \\  fs.fileStat(fake);
        \\  const prototypeRejected = fs.errno[0] === IoError.InvalidInput && !File.is(fake);
        \\  const proxy = new Proxy(file, {});
        \\  fs.fileStat(proxy);
        \\  const proxyRejected = fs.errno[0] === IoError.InvalidInput && !File.is(proxy);
        \\  const stdFile = File.at(file.fs, file.id);
        \\  try { stdFile.readStreaming.call(fake, fs, new Uint8Array(1)); } catch (e) { borrowedRejected = e instanceof IoError; }
        \\  globalThis.handleChecks = constructorRejected && stateHidden && getterReads === 0 && forgedRejected && prototypeRejected && proxyRejected && borrowedRejected && Object.isFrozen(file);
        \\  IoError.check(fs, fs.fileClose(file));
        \\}
    );
}

test "JS handles: closed references cannot name resources opened later in either filesystem" {
    try run(
        \\import { Dir, File, IoError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const sync = api.fs.requestSync({ access: 'rw' });
        \\  const first = IoError.check(sync, sync.dirOpenFile(Dir.cwd(), 'first', 'w'));
        \\  const alias = File.at(first.fs, first.id);
        \\  IoError.check(sync, sync.fileClose(first));
        \\  const second = IoError.check(sync, sync.dirOpenFile(Dir.cwd(), 'second', 'w'));
        \\  sync.fileStat(alias);
        \\  const syncStale = sync.errno[0] !== 0 && first.id !== second.id;
        \\  IoError.check(sync, sync.fileClose(second));
        \\  const io = api.io.create({ backend: 'threaded' });
        \\  const asyncFs = await api.fs.requestAsync({ io, access: 'rw' });
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
