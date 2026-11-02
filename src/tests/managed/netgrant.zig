const std = @import("std");
const check = @import("support.zig").check;
const Parent = @import("channel.zig").Parent;
const m = @import("@managed");
const t = std.testing;

const prelude =
    \\const outcome = promise => promise.then(() => 'ok', e => e.name);
    \\const detail = promise => promise.then(() => undefined, e => e.subject);
    \\const throws = f => { try { f(); return 'ok'; } catch (e) { return e.name; } };
    \\const subject = f => { try { f(); return undefined; } catch (e) { return e.subject; } };
    \\// An allowed address that nobody answers either hangs or is refused, never denied: give it 150 ms.
    \\const allowed = async (timers, promise) => (await Promise.race([outcome(promise), timers.sleep(150).then(() => 'hang')])) !== 'PermissionDenied';
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
        \\  const mode = { mode: 'pull', socketMode: 'pull' };
        \\  out.loopback = throws(() => api.net.listen(io, { ...mode, host: '127.0.0.1', port: 0 })) === 'ok' && throws(() => api.net.listen(io, { ...mode, host: '::1', port: 0 })) === 'ok'
        \\    && throws(() => api.net.listen(io, { ...mode, host: 'localhost', port: 0 })) === 'ok';
        \\  out.any = throws(() => api.net.listen(io, { ...mode, host: '0.0.0.0', port: 0 }));
        \\  out.anySubject = subject(() => api.net.listen(io, { ...mode, host: '0.0.0.0', port: 0 }));
        \\  out.any6 = throws(() => api.net.listen(io, { ...mode, host: '::', port: 0 }));
        \\  out.lan = await outcome(api.net.connect(io, { host: '10.0.0.1', port: 80, mode: 'pull' }));
        \\  out.lanSubject = await detail(api.net.connect(io, { host: '10.0.0.1', port: 80, mode: 'pull' }));
        \\  // A name is refused whatever it would resolve to: resolve it with api.dns and pass the address.
        \\  out.name = await outcome(api.net.connect(io, { host: 'example.com', port: 80, mode: 'pull' }));
        \\  out.nameSubject = await detail(api.net.connect(io, { host: 'example.com', port: 80, mode: 'pull' }));
        \\  // An IPv4-mapped address is checked as the IPv4 address it stands for.
        \\  out.mapped = await outcome(api.net.connect(io, { host: '::ffff:10.0.0.1', port: 80, mode: 'pull' }));
        \\  out.mappedLoopback = await allowed(timers, api.net.connect(io, { host: '::ffff:127.0.0.1', port: 1, mode: 'pull' }));
        \\  // DNS servers are connections too.
        \\  const { DnsServer, IpAddr } = api.dns;
        \\  const options = { dnssec: 'off', timeout: 100, tries: 1 };
        \\  out.dnsLan = throws(() => api.dns.resolver(io, { servers: [DnsServer.udp([IpAddr.parse('10.0.0.1')])], ...options }));
        \\  out.dnsLoopback = throws(() => api.dns.resolver(io, { servers: [DnsServer.udp([IpAddr.parse('127.0.0.1')])], ...options }));
        \\  await io.close();
        \\  await timers.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.loopback && report.any === 'PermissionDenied' && report.anySubject === '0.0.0.0:0' && report.any6 === 'PermissionDenied' && report.lan === 'PermissionDenied' && report.lanSubject === '10.0.0.1:80' && report.name === 'PermissionDenied' && report.nameSubject === 'example.com' && report.mapped === 'PermissionDenied' && report.mappedLoopback && report.dnsLan === 'PermissionDenied' && report.dnsLoopback === 'ok'");
}

test "net grant: rules widen or narrow what is reachable" {
    if (!m.Api.dns_enabled) return error.SkipZigTest; // these look at the resolvers too
    var p: Parent = undefined;
    try p.setupNet("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const timers = api.io.create();
        \\  const mode = { mode: 'pull', socketMode: 'pull' };
        \\  const connect = (host, port) => api.net.connect(io, { host, port, mode: 'pull' });
        \\  // connect: 192.0.2.0/24 port 80 only; 2001:db8::/32 any port. listen: loopback v4 any port. Not loopback connect.
        \\  out.range = await allowed(timers, connect('192.0.2.5', 80));
        \\  out.otherPort = await outcome(connect('192.0.2.5', 81));
        \\  out.otherNet = await outcome(connect('192.0.3.5', 80));
        \\  out.v6 = await allowed(timers, connect('2001:db8::1', 9));
        \\  out.v6Other = await outcome(connect('2001:db9::1', 9));
        \\  out.mappedInRange = await allowed(timers, connect('::ffff:192.0.2.9', 80));
        \\  out.noLoopbackConnect = await outcome(connect('127.0.0.1', 1));
        \\  out.listen = throws(() => api.net.listen(io, { ...mode, host: '127.0.0.1', port: 0 }));
        \\  out.listenOther = throws(() => api.net.listen(io, { ...mode, host: '::1', port: 0 }));
        \\  out.listenWide = throws(() => api.net.listen(io, { ...mode, host: '0.0.0.0', port: 0 }));
        \\  // DNS servers follow the connect rules (address and port), checked when the resolver is made.
        \\  const { DnsServer, IpAddr, SocketAddr } = api.dns;
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
        \\  out.listen = throws(() => api.net.listen(io, { mode: 'pull', socketMode: 'pull', host: '127.0.0.1', port: 0 }));
        \\  out.connect = await outcome(api.net.connect(io, { host: '127.0.0.1', port: 1, mode: 'pull' }));
        \\  out.localhost = await outcome(api.net.connect(io, { host: 'localhost', port: 1, mode: 'pull' }));
        \\  out.dns = throws(() => api.dns.resolver(io, { servers: [api.dns.DnsServer.tcp([api.dns.SocketAddr.parse('127.0.0.1:53')])], dnssec: 'off', timeout: 100, tries: 1 }));
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
