const std = @import("std");
const check = @import("support.zig").check;
const Parent = @import("channel.zig").Parent;

test "net: pull sockets and servers iterate with for await" {
    var p: Parent = undefined;
    try p.setup("init.js",
        \\import { SocketAddr } from 'origine:@std/net';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const server = io.tcp.listen(SocketAddr.parse('127.0.0.1:0')).pulling();
        \\  const accepting = server.accept();
        \\  const client = (await io.tcp.connect(server.localAddr)).pulling();
        \\  const conn = (await accepting).pulling();
        \\  await client.queued.send(Uint8Array.from([1, 2, 3]));
        \\  await client.end('write');
        \\  const bytes = [];
        \\  for await (const chunk of conn) bytes.push(...chunk);
        \\  out.bytes = bytes.join();
        \\  // A listener yields its connections (unshaped); `break` leaves the loop and the listener stays usable.
        \\  const second = [];
        \\  const loop = (async () => { for await (const socket of server) { second.push(socket.peerAddr.port > 0); await socket.close(); if (second.length === 2) break; } })();
        \\  const a = await io.tcp.connect(server.localAddr);
        \\  const b = await io.tcp.connect(server.localAddr);
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
