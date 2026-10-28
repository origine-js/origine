const std = @import("std");
const check = @import("support.zig").check;
const Parent = @import("channel.zig").Parent;

test "net: pull sockets and servers iterate with for await" {
    var p: Parent = undefined;
    try p.setup("init.js",
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const server = api.net.listen(io, { mode: 'pull', socketMode: 'pull', port: 0 });
        \\  const client = await api.net.connect(io, { mode: 'pull', port: server.port });
        \\  const conn = await server.accept();
        \\  await client.queued.send(Uint8Array.from([1, 2, 3]));
        \\  await client.end('write');
        \\  const bytes = [];
        \\  for await (const chunk of conn) bytes.push(...chunk);
        \\  out.bytes = bytes.join();
        \\  // A server yields its connections; `break` leaves the loop and the server stays usable.
        \\  const second = [];
        \\  const loop = (async () => { for await (const socket of server) { second.push(socket.remotePort > 0); if (second.length === 2) break; } })();
        \\  const a = await api.net.connect(io, { mode: 'pull', port: server.port });
        \\  const b = await api.net.connect(io, { mode: 'pull', port: server.port });
        \\  await loop;
        \\  out.accepted = second.join();
        \\  await a.close(); await b.close(); await client.close(); await conn.close(); await server.close();
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.bytes === '1,2,3' && report.accepted === 'true,true'");
    _ = std;
}
