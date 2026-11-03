const std = @import("std");
const check = @import("support.zig").check;
const Parent = @import("channel.zig").Parent;
const m = @import("@managed");
const t = std.testing;

const prelude =
    \\import * as stdNet from 'origine:@std/net';
    \\const at = (host, port) => stdNet.SocketAddr.parse(host.includes(':') ? `[${host}]:${port}` : `${host}:${port}`);
    \\const outcome = promise => promise.then(() => 'ok', e => e.name);
    \\const detail = promise => promise.then(() => undefined, e => e.subject);
    \\const throws = f => { try { f(); return 'ok'; } catch (e) { return e.name; } };
    \\const subject = f => { try { f(); return undefined; } catch (e) { return e.subject; } };
    \\// An allowed address that nobody answers either hangs or is refused, never denied: give it 150 ms.
    \\const allowed = async (timers, promise) => (await Promise.race([outcome(promise), timers.timer.sleep(150).then(() => 'hang')])) !== 'PermissionDenied';
    \\
;

test "net grant: the default ceiling is loopback only" {
    if (!m.Api.dns_enabled) return error.SkipZigTest; // these look at the resolvers too
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const timers = api.io.create();
        \\  const listen = (host, port) => io.tcp.listen(at(host, port));
        \\  const connect = (host, port) => io.tcp.connect(at(host, port));
        \\  out.loopback = throws(() => listen('127.0.0.1', 0)) === 'ok' && throws(() => listen('::1', 0)) === 'ok' && throws(() => io.udp.bind(at('127.0.0.1', 0))) === 'ok';
        \\  out.any = throws(() => listen('0.0.0.0', 0));
        \\  out.anySubject = subject(() => listen('0.0.0.0', 0));
        \\  out.any6 = throws(() => listen('::', 0));
        \\  out.udpAny = throws(() => io.udp.bind(at('0.0.0.0', 0)));
        \\  out.lan = await outcome(connect('10.0.0.1', 80));
        \\  out.lanSubject = await detail(connect('10.0.0.1', 80));
        \\  // A datagram cannot reach what a connection could not.
        \\  const udp = io.udp.bind(at('127.0.0.1', 0)).pulling();
        \\  out.udpLan = await outcome(udp.sendTo(Uint8Array.of(1), at('10.0.0.1', 53)));
        \\  out.udpConnect = throws(() => udp.connect(at('10.0.0.1', 53)));
        \\  // A name is not an address: resolve it with api.dns and pass the address.
        \\  out.name = throws(() => stdNet.SocketAddr.parse('example.com:80'));
        \\  // An IPv4-mapped address is checked as the IPv4 address it stands for.
        \\  out.mapped = await outcome(connect('::ffff:10.0.0.1', 80));
        \\  out.mappedLoopback = await allowed(timers, connect('::ffff:127.0.0.1', 1));
        \\  // DNS servers are connections too.
        \\  const { DnsServer } = api.dns;
        \\  const { IpAddr } = await import('origine:@std/net');
        \\  const options = { dnssec: 'off', timeout: 100, tries: 1 };
        \\  out.dnsLan = throws(() => api.dns.resolver(io, { servers: [DnsServer.udp([IpAddr.parse('10.0.0.1')])], ...options }));
        \\  out.dnsLoopback = throws(() => api.dns.resolver(io, { servers: [DnsServer.udp([IpAddr.parse('127.0.0.1')])], ...options }));
        \\  await io.close();
        \\  await timers.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.loopback && report.any === 'PermissionDenied' && report.anySubject === '0.0.0.0:0' && report.any6 === 'PermissionDenied' && report.lan === 'PermissionDenied' && report.lanSubject === '10.0.0.1:80' && report.udpAny === 'PermissionDenied' && report.udpLan === 'PermissionDenied' && report.udpConnect === 'PermissionDenied' && report.name === 'TypeError' && report.mapped === 'PermissionDenied' && report.mappedLoopback && report.dnsLan === 'PermissionDenied' && report.dnsLoopback === 'ok'");
}

test "net grant: rules widen or narrow what is reachable" {
    if (!m.Api.dns_enabled) return error.SkipZigTest; // these look at the resolvers too
    var p: Parent = undefined;
    try p.setupNet("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const timers = api.io.create();
        \\  const listen = (host, port) => io.tcp.listen(at(host, port));
        \\  const connect = (host, port) => io.tcp.connect(at(host, port));
        \\  // connect: 192.0.2.0/24 port 80 only; 2001:db8::/32 any port. listen: loopback v4 any port. Not loopback connect.
        \\  out.range = await allowed(timers, connect('192.0.2.5', 80));
        \\  out.otherPort = await outcome(connect('192.0.2.5', 81));
        \\  out.otherNet = await outcome(connect('192.0.3.5', 80));
        \\  out.v6 = await allowed(timers, connect('2001:db8::1', 9));
        \\  out.v6Other = await outcome(connect('2001:db9::1', 9));
        \\  out.mappedInRange = await allowed(timers, connect('::ffff:192.0.2.9', 80));
        \\  out.noLoopbackConnect = await outcome(connect('127.0.0.1', 1));
        \\  out.listen = throws(() => listen('127.0.0.1', 0));
        \\  out.listenOther = throws(() => listen('::1', 0));
        \\  out.listenWide = throws(() => listen('0.0.0.0', 0));
        \\  // DNS servers follow the connect rules (address and port), checked when the resolver is made.
        \\  const { DnsServer } = api.dns;
        \\  const { IpAddr, SocketAddr } = await import('origine:@std/net');
        \\  const options = { dnssec: 'off', timeout: 100, tries: 1 };
        \\  const server = (ip, port) => throws(() => api.dns.resolver(io, { servers: [DnsServer.udp([SocketAddr.new(IpAddr.parse(ip), port)])], ...options }));
        \\  out.dnsOk = server('192.0.2.53', 80);
        \\  out.dnsPort = server('192.0.2.53', 53);
        \\  out.dnsDefaultPort = throws(() => api.dns.resolver(io, { servers: [DnsServer.udp([IpAddr.parse('192.0.2.53')])], ...options }));
        \\  out.dnsMapped = server('::ffff:192.0.2.53', 80);
        \\  await io.close();
        \\  await timers.close();
        \\}
    , "connect 192.0.2.0/24 80\nconnect 2001:db8::/32\nlisten 127.0.0.1\n");
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.range && report.otherPort === 'PermissionDenied' && report.otherNet === 'PermissionDenied' && report.v6 && report.v6Other === 'PermissionDenied' && report.mappedInRange && report.noLoopbackConnect === 'PermissionDenied' && report.listen === 'ok' && report.listenOther === 'PermissionDenied' && report.listenWide === 'PermissionDenied' && report.dnsOk === 'ok' && report.dnsPort === 'PermissionDenied' && report.dnsDefaultPort === 'PermissionDenied' && report.dnsMapped === 'ok'");
}

test "net grant: empty rules allow nothing, even loopback" {
    if (!m.Api.dns_enabled) return error.SkipZigTest; // these look at the resolvers too
    var p: Parent = undefined;
    try p.setupNet("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  out.listen = throws(() => io.tcp.listen(at('127.0.0.1', 0)));
        \\  out.connect = await outcome(io.tcp.connect(at('127.0.0.1', 1)));
        \\  out.localhost = await outcome(io.tcp.connect(at('::1', 1)));
        \\  const { SocketAddr } = await import('origine:@std/net');
        \\  out.dns = throws(() => api.dns.resolver(io, { servers: [api.dns.DnsServer.tcp([SocketAddr.parse('127.0.0.1:53')])], dnssec: 'off', timeout: 100, tries: 1 }));
        \\  await io.close();
        \\}
    , "# nothing is granted\n");
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.listen === 'PermissionDenied' && report.connect === 'PermissionDenied' && report.localhost === 'PermissionDenied' && report.dns === 'PermissionDenied'");
}

test "net grant: rule text is checked up front" {
    var message: [256]u8 = undefined;
    try t.expect(m.Api.checkNetRules(m.Api.loopback_rules, &message) == null);
    try t.expect(m.Api.checkNetRules("", &message) == null);
    try t.expect(m.Api.checkNetRules("connect 10.0.0.0/8 80,443,8000-8100\nlisten ::/0\n", &message) == null);
    const why = m.Api.checkNetRules("connect 10.0.0.0/33\n", &message) orelse return error.TestExpectedError;
    try t.expect(std.mem.indexOf(u8, why, "line 1") != null);
    try t.expect(m.Api.checkNetRules("allow everything\n", &message) != null);
    try t.expect(m.Api.checkNetRules("connect 1.2.3.4 70000\n", &message) != null);
}
