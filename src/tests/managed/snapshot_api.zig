const std = @import("std");
const check = @import("support.zig").check;
const isolate = @import("isolate.zig");

test "snapshot: create, save, load and start isolates from it" {
    var c: isolate.Case = undefined;
    try c.setup(isolate.prelude ++
        \\import { Dir, IoError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const { Snapshot } = api.host;
        \\  const init = childPath(api);
        \\  const snapshot = Snapshot.create({ init });
        \\  out.init = snapshot.init === init;
        \\  const raw = snapshot.blob();
        \\  out.raw = raw instanceof Uint8Array && raw.length > 1000;
        \\  const file = snapshot.origineDataBlob();
        \\  out.file = file instanceof Uint8Array && file.length > raw.length;
        \\  const loaded = Snapshot.fromOrigineDataBlob(file, { init });
        \\  out.same = loaded.origineDataBlob().length === file.length && loaded.init === init;
        \\  const bare = Snapshot.fromRaw(raw);
        \\  out.bare = bare.init === undefined && bare.blob().length === raw.length;
        \\  try { bare.origineDataBlob(); out.bareFile = 'made'; } catch (e) { out.bareFile = e.name; }
        \\  try { Snapshot.fromRaw(new Uint8Array(1024)); out.junk = 'loaded'; } catch (e) { out.junk = e.name; }
        \\  try { Snapshot.fromOrigineDataBlob(file, { init: init + '.other' }); out.other = 'loaded'; } catch (e) { out.other = e.name; }
        \\  try { new Snapshot({}, 1); out.ctor = 'made'; } catch (e) { out.ctor = e.name; }
        \\  // The source changes after the snapshot: an isolate made from it still runs what was snapshotted,
        \\  // and the saved file no longer fits the sources.
        \\  const sync = api.fs.requestSync({ access: 'rw' });
        \\  const f = IoError.check(sync, sync.dirOpenFile(Dir.cwd(), 'child.js', 'w'));
        \\  sync.fileWriteAll(f, Uint8Array.from("export function main() { throw new Error('changed'); }", c => c.charCodeAt(0)));
        \\  sync.fileClose(f);
        \\  try { Snapshot.fromOrigineDataBlob(file, { init }); out.stale = 'loaded'; } catch (e) { out.stale = e.name; }
        \\  const [mine, theirs] = new api.host.threading.Channel({ mode: 'pull' });
        \\  const iso = api.isolate.create({ init, snapshot, data: { port: theirs }, transfer: [theirs] });
        \\  out.reply = (await mine.recv()).data;
        \\  mine.close();
        \\  out.joined = (await iso.join()).status;
        \\  try { api.isolate.create({ init: init + '.other', snapshot }); out.mismatch = 'created'; } catch (e) { out.mismatch = e.name; }
        \\  try { api.isolate.create({ init, snapshot: {} }); out.notSnapshot = 'created'; } catch (e) { out.notSnapshot = e.name; }
        \\  loaded.close();
        \\  try { loaded.blob(); out.closed = 'read'; } catch (e) { out.closed = e.name; }
        \\  try { api.isolate.create({ init, snapshot: loaded }); out.useClosed = 'created'; } catch (e) { out.useClosed = e.name; }
        \\}
    ,
        \\export const built = 'evaluated before the snapshot';
        \\export async function main(api, { port }) {
        \\  await port.send(built);
        \\  for await (const event of port) { /* until the parent closes */ }
        \\}
    );
    defer c.deinit();
    try c.parent.run();
    try check(c.parent.scope, "report.init && report.raw && report.file && report.same && report.bare");
    try check(c.parent.scope, "report.bareFile === 'Unsupported' && report.junk === 'InvalidData' && report.other === 'InvalidData' && report.ctor === 'TypeError'");
    try check(c.parent.scope, "report.stale === 'InvalidData' && report.reply === 'evaluated before the snapshot' && report.joined === 'completed'");
    try check(c.parent.scope, "report.mismatch === 'InvalidInput' && report.notSnapshot === 'TypeError' && report.closed === 'BadHandle' && report.useClosed === 'BadHandle'");
    _ = std;
}
