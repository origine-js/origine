const check = @import("support.zig").check;
const Parent = @import("channel.zig").Parent;
const m = @import("@managed");

test "net: IpAddr and SocketAddr parse, print and classify like Rust's" {
    var p: Parent = undefined;
    try p.setup("init.js",
        \\import { IpAddr, SocketAddr } from 'origine:@std/net';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const throws = f => { try { f(); return 'no'; } catch (e) { return e.name; } };
        \\  const rt = s => IpAddr.parse(s).toString();
        \\  out.v4 = rt('1.2.3.4') === '1.2.3.4' && IpAddr.parse('1.2.3.4').family === 4 && IpAddr.v4(10, 0, 0, 1).toString() === '10.0.0.1';
        \\  out.v6 = rt('::1') === '::1' && rt('2001:0db8:0:0:0:0:0:1') === '2001:db8::1' && rt('::') === '::' && rt('fe80::1:0:0:1') === 'fe80::1:0:0:1'
        \\    && rt('1:0:0:2:0:0:0:3') === '1:0:0:2::3' && rt('::ffff:1.2.3.4') === '::ffff:1.2.3.4' && rt('1:2:3:4:5:6:7:8') === '1:2:3:4:5:6:7:8'
        \\    && rt('ABCD::EF') === 'abcd::ef' && rt('::1.2.3.4') === '::102:304' && IpAddr.v6(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1).toString() === '2001:db8::1';
        \\  out.bad = ['', '1.2.3', '1.2.3.4.5', '256.1.1.1', '01.2.3.4', '1.2.3.-4', ':::', '1::2::3', '12345::', 'g::1', '1:2:3:4:5:6:7', '1:2:3:4:5:6:7:8:9', '::1%en0', '[::1]', '1.2.3.4:5', ' 1.2.3.4'].map(s => throws(() => IpAddr.parse(s))).every(n => n === 'TypeError');
        \\  out.octets = IpAddr.parse('1.2.3.4').octets().join() === '1,2,3,4' && IpAddr.parse('::1').octets().length === 16 && IpAddr.fromOctets(Uint8Array.of(9, 8, 7, 6)).toString() === '9.8.7.6'
        \\    && throws(() => IpAddr.fromOctets(new Uint8Array(5))) === 'TypeError' && throws(() => new IpAddr()) === 'TypeError';
        \\  const c = s => { const a = IpAddr.parse(s); return [a.isLoopback(), a.isUnspecified(), a.isMulticast(), a.isPrivate(), a.isLinkLocal(), a.isDocumentation()].map(Number).join(''); };
        \\  out.classes = c('127.0.0.1') === '100000' && c('::1') === '100000' && c('0.0.0.0') === '010000' && c('::') === '010000' && c('224.0.0.1') === '001000' && c('ff02::1') === '001000'
        \\    && c('10.1.1.1') === '000100' && c('172.16.0.1') === '000100' && c('172.32.0.1') === '000000' && c('192.168.1.1') === '000100' && c('fc00::1') === '000100' && c('fd12::1') === '000100'
        \\    && c('169.254.1.1') === '000010' && c('fe80::1') === '000010' && c('192.0.2.1') === '000001' && c('2001:db8::1') === '000001' && c('8.8.8.8') === '000000' && c('2606:4700::1') === '000000';
        \\  const mapped = IpAddr.parse('::ffff:127.0.0.1');
        \\  out.canonical = !mapped.isLoopback() && mapped.toCanonical().isLoopback() && mapped.toCanonical().toString() === '127.0.0.1' && IpAddr.parse('::1').toCanonical().toString() === '::1' && IpAddr.parse('::1.2.3.4').toCanonical().isV6();
        \\  out.equals = IpAddr.parse('1.2.3.4').equals(IpAddr.v4(1, 2, 3, 4)) && !IpAddr.parse('::1').equals(IpAddr.parse('1.2.3.4')) && !IpAddr.parse('1.2.3.4').equals('1.2.3.4');
        \\  const s = SocketAddr.parse('[::1]:853');
        \\  out.socket = s.toString() === '[::1]:853' && s.port === 853 && s.ip.isV6() && SocketAddr.parse('1.2.3.4:53').toString() === '1.2.3.4:53' && SocketAddr.parse('1.2.3.4:00053').port === 53 && SocketAddr.parse('[::ffff:1.2.3.4]:65535').port === 65535 && SocketAddr.new(IpAddr.v4(1, 2, 3, 4), 0).port === 0 && s.equals(SocketAddr.new(IpAddr.parse('::1'), 853));
        \\  out.socketBad = ['1.2.3.4', '[1.2.3.4]:53', '::1:53', '1.2.3.4:65536', '1.2.3.4:', ':53', '[::1]', '1.2.3.4:5a', '[::1]]:53', 5, undefined].map(x => throws(() => SocketAddr.parse(x))).every(n => n === 'TypeError') && throws(() => SocketAddr.new(IpAddr.v4(1, 1, 1, 1), 70000)) === 'TypeError' && throws(() => SocketAddr.new('1.1.1.1', 1)) === 'TypeError';
        \\  out.shared = IpAddr === (await import('origine:@std/net')).IpAddr && throws(() => new SocketAddr()) === 'TypeError';
        \\  out.frozen = Object.isFrozen(IpAddr.parse('1.2.3.4')) && Object.isFrozen(IpAddr) && Object.isFrozen(IpAddr.prototype);
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.v4 && report.v6 && report.bad && report.octets && report.classes && report.canonical && report.equals && report.socket && report.socketBad && report.shared && report.frozen");
}

test "net: api.dns returns the module's IpAddr and does not re-export the classes" {
    if (!m.Api.dns_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js",
        \\import { IpAddr, SocketAddr } from 'origine:@std/net';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  out.absent = api.dns.IpAddr === undefined && api.dns.SocketAddr === undefined;
        \\  const io = api.io.create();
        \\  const resolver = api.dns.resolver(io, { servers: [api.dns.DnsServer.udp([SocketAddr.new(IpAddr.v4(127, 0, 0, 1), 9)])], dnssec: 'off', timeout: 100, tries: 1 });
        \\  const found = await resolver.lookup('127.0.0.1', { family: 'ipv4' });
        \\  out.lookup = found.length === 1 && found[0] instanceof IpAddr && found[0].equals(IpAddr.v4(127, 0, 0, 1));
        \\  await resolver.close();
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.absent && report.lookup");
}
