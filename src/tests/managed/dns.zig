const std = @import("std");
const builtin = @import("builtin");
const check = @import("support.zig").check;
const Parent = @import("channel.zig").Parent;
const tls_prelude = @import("tls.zig").prelude;
const m = @import("@managed");
const t = std.testing;

// A DNS zone, a framed (TCP and DoT) server for it written in JS, and a datagram server in Zig on a thread.
const prelude = tls_prelude ++
    \\const u16 = (b, at) => (b[at] << 8) | b[at + 1];
    \\const question = q => {
    \\  let at = 12; const labels = [];
    \\  while (q[at] !== 0) { labels.push(text(q.subarray(at + 1, at + 1 + q[at]))); at += 1 + q[at]; }
    \\  return { name: labels.join('.'), type: u16(q, at + 1), end: at + 5 };
    \\};
    \\const record = (type, data) => [0xc0, 0x0c, 0, type, 0, 1, 0, 0, 0, 60, 0, data.length, ...data];
    \\const answer = (q, rcode, ips) => {
    \\  const { end } = question(q);
    \\  const out = Uint8Array.from([...q.subarray(0, end), ...ips.flatMap(ip => record(ip.length === 4 ? 1 : 28, ip))]);
    \\  out[2] = 0x81; out[3] = 0x80 | rcode; out[6] = 0; out[7] = ips.length; out[8] = out[9] = out[10] = out[11] = 0;
    \\  return out;
    \\};
    \\const zone = {
    \\  'web.test': { 1: [[192, 0, 2, 7]], 28: [[0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7]] },
    \\  'v4only.test': { 1: [[192, 0, 2, 8]] },
    \\};
    \\const stats = { queries: 0 };
    \\const reply = q => {
    \\  stats.queries++;
    \\  const { name, type } = question(q);
    \\  const entry = zone[name.toLowerCase()];
    \\  return entry === undefined ? answer(q, 3, []) : answer(q, 0, entry[type] ?? []);
    \\};
    \\const readExact = async (s, n) => {
    \\  const out = new Uint8Array(n); let got = 0;
    \\  while (got < n) { const c = await s.read(n - got); if (c.length === 0) throw new Error('eof'); out.set(c, got); got += c.length; }
    \\  return out;
    \\};
    \\const sendOn = (s, data) => ('queued' in s ? s.queued.send(data) : s.send(data));
    \\const framed = async s => {
    \\  try {
    \\    for (;;) {
    \\      const head = await readExact(s, 2);
    \\      const a = reply(await readExact(s, (head[0] << 8) | head[1]));
    \\      const out = new Uint8Array(2 + a.length); out[0] = a.length >> 8; out[1] = a.length & 255; out.set(a, 2);
    \\      await sendOn(s, out);
    \\    }
    \\  } catch { /* the client went away */ }
    \\};
    \\const listen = (api, io, handle) => {
    \\  const listener = api.net.listen(io, { mode: 'pull', socketMode: 'pull', port: 0 });
    \\  (async () => { for (;;) { let s; try { s = await listener.accept(); } catch { return; } handle(s); } })();
    \\  return listener;
    \\};
    \\const local = (api, port) => api.dns.SocketAddr.new(api.dns.IpAddr.v4(127, 0, 0, 1), port);
    \\const options = { dnssec: 'off', timeout: 2000, tries: 1 };
    \\const show = ips => ips.map(String).join();
    \\
;

/// A datagram DNS server on loopback: an A record 192.0.2.1 for every name but `missing.test` (NXDOMAIN), no AAAA.
const Udp = struct {
    fd: c_int,
    port: u16,
    stop: std.atomic.Value(bool) = .init(false),
    queries: std.atomic.Value(u32) = .init(0),
    thread: std.Thread = undefined,

    const sys = struct {
        extern "c" fn socket(domain: c_int, kind: c_int, protocol: c_int) c_int;
        extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: u32) c_int;
        extern "c" fn getsockname(fd: c_int, addr: *anyopaque, len: *u32) c_int;
        extern "c" fn setsockopt(fd: c_int, level: c_int, name: c_int, value: *const anyopaque, len: u32) c_int;
        extern "c" fn recvfrom(fd: c_int, buf: [*]u8, len: usize, flags: c_int, addr: ?*anyopaque, alen: ?*u32) isize;
        extern "c" fn sendto(fd: c_int, buf: [*]const u8, len: usize, flags: c_int, addr: ?*const anyopaque, alen: u32) isize;
        extern "c" fn close(fd: c_int) c_int;
    };

    fn start() !*Udp {
        const self = try t.allocator.create(Udp);
        errdefer t.allocator.destroy(self);
        const fd = sys.socket(2, 2, 0);
        if (fd < 0) return error.SocketUnavailable;
        errdefer _ = sys.close(fd);
        var addr = std.mem.zeroes(std.c.sockaddr.in);
        addr.family = 2;
        addr.addr = std.mem.nativeToBig(u32, 0x7f000001);
        if (sys.bind(fd, &addr, @sizeOf(std.c.sockaddr.in)) != 0) return error.SocketUnavailable;
        var len: u32 = @sizeOf(std.c.sockaddr.in);
        if (sys.getsockname(fd, &addr, &len) != 0) return error.SocketUnavailable;
        // Wake up every 50 ms to look at the stop flag.
        const SOL_SOCKET: c_int = if (builtin.os.tag == .linux) 1 else 0xffff;
        const SO_RCVTIMEO: c_int = if (builtin.os.tag == .linux) 20 else 0x1006;
        var tv: std.c.timeval = .{ .sec = 0, .usec = 50_000 };
        if (sys.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, @sizeOf(std.c.timeval)) != 0) return error.SocketUnavailable;
        self.* = .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    fn run(self: *Udp) void {
        var buf: [512]u8 = undefined;
        while (!self.stop.load(.acquire)) {
            var peer: std.c.sockaddr.storage = undefined;
            var peer_len: u32 = @sizeOf(std.c.sockaddr.storage);
            const n = sys.recvfrom(self.fd, &buf, buf.len, 0, &peer, &peer_len);
            if (n < 13) continue;
            const query = buf[0..@intCast(n)];
            _ = self.queries.fetchAdd(1, .monotonic);
            // The question: labels, then type and class.
            var at: usize = 12;
            var name: [64]u8 = undefined;
            var name_len: usize = 0;
            while (at < query.len and query[at] != 0) : (at += 1 + @as(usize, query[at])) {
                const l: usize = query[at];
                if (at + 1 + l > query.len or name_len + l + 1 > name.len) break;
                if (name_len > 0) {
                    name[name_len] = '.';
                    name_len += 1;
                }
                @memcpy(name[name_len .. name_len + l], query[at + 1 .. at + 1 + l]);
                name_len += l;
            }
            const end = at + 5;
            if (end > query.len) continue;
            const qtype = std.mem.readInt(u16, query[at + 1 ..][0..2], .big);
            const missing = std.mem.eql(u8, name[0..name_len], "missing.test");
            const answers: u8 = if (!missing and qtype == 1) 1 else 0;
            var out: [512]u8 = undefined;
            @memcpy(out[0..end], query[0..end]);
            out[2] = 0x81;
            out[3] = 0x80 | @as(u8, if (missing) 3 else 0);
            @memset(out[4..12], 0);
            out[5] = 1;
            out[7] = answers;
            var len = end;
            if (answers == 1) {
                const rr = [_]u8{ 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 1 };
                @memcpy(out[len .. len + rr.len], &rr);
                len += rr.len;
            }
            _ = sys.sendto(self.fd, &out, len, 0, &peer, peer_len);
        }
    }

    fn deinit(self: *Udp) void {
        self.stop.store(true, .release);
        self.thread.join();
        _ = sys.close(self.fd);
        t.allocator.destroy(self);
    }
};

test "dns: addresses parse, print and classify like Rust's" {
    if (!m.Api.dns_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const { IpAddr, SocketAddr } = api.dns;
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
        \\  out.socket = s.toString() === '[::1]:853' && s.port === 853 && s.ip.isV6() && SocketAddr.parse('1.2.3.4:53').toString() === '1.2.3.4:53' && SocketAddr.new(IpAddr.v4(1, 2, 3, 4), 0).port === 0 && s.equals(SocketAddr.new(IpAddr.parse('::1'), 853));
        \\  out.socketBad = ['1.2.3.4', '[1.2.3.4]:53', '::1:53', '1.2.3.4:65536', '1.2.3.4:', ':53', '[::1]'].map(x => throws(() => SocketAddr.parse(x))).every(n => n === 'TypeError') && throws(() => SocketAddr.new(IpAddr.v4(1, 1, 1, 1), 70000)) === 'TypeError' && throws(() => SocketAddr.new('1.1.1.1', 1)) === 'TypeError';
        \\  out.frozen = Object.isFrozen(IpAddr.parse('1.2.3.4')) && Object.isFrozen(IpAddr) && Object.isFrozen(IpAddr.prototype);
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.v4 && report.v6 && report.bad && report.octets && report.classes && report.canonical && report.equals && report.socket && report.socketBad && report.frozen");
}

test "dns: lookups over TCP, failover, timeouts and inputs" {
    if (!m.Api.dns_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const { DnsServer, IpAddr } = api.dns;
        \\  const tcp = listen(api, io, framed);
        \\  const resolver = api.dns.resolver(io, { servers: [DnsServer.tcp([local(api, tcp.port)])], ...options });
        \\  out.both = show(await resolver.lookup('web.test', { family: 'any' })) === '2001:db8::7,192.0.2.7';
        \\  out.family = show(await resolver.lookup('web.test', { family: 'ipv4' })) === '192.0.2.7' && show(await resolver.lookup('web.test', { family: 'ipv6' })) === '2001:db8::7';
        \\  out.noData = await outcome(resolver.lookup('v4only.test', { family: 'ipv6' }));
        \\  out.missing = await outcome(resolver.lookup('missing.test', { family: 'any' }));
        \\  out.subject = await resolver.lookup('missing.test', { family: 'any' }).catch(e => e.subject);
        \\  out.local = show(await resolver.lookup('10.1.2.3', { family: 'any' })) === '10.1.2.3' && show(await resolver.lookup('localhost', { family: 'any' })) === '::1,127.0.0.1';
        \\  const before = stats.queries;
        \\  await resolver.lookup('10.1.2.3', { family: 'any' }); await resolver.lookup('localhost', { family: 'ipv4' });
        \\  out.noQuery = stats.queries === before;
        \\  // A server that is down hands over to the next one.
        \\  const failover = api.dns.resolver(io, { servers: [DnsServer.tcp([local(api, 1)]), DnsServer.tcp([local(api, tcp.port)])], ...options });
        \\  out.failover = show(await failover.lookup('web.test', { family: 'ipv4' })) === '192.0.2.7';
        \\  const down = api.dns.resolver(io, { servers: [DnsServer.tcp([local(api, 1)])], ...options });
        \\  out.refused = await outcome(down.lookup('web.test', { family: 'ipv4' }));
        \\  // A server that accepts and never answers times out.
        \\  const silent = listen(api, io, () => {});
        \\  const slow = api.dns.resolver(io, { servers: [DnsServer.tcp([local(api, silent.port)])], dnssec: 'off', timeout: 100, tries: 2 });
        \\  const t0 = Date.now();
        \\  out.timeout = await outcome(slow.lookup('web.test', { family: 'ipv4' }));
        \\  out.timeoutTook = Date.now() - t0 >= 150;
        \\  // Inputs.
        \\  const throws = f => { try { f(); return 'no'; } catch (e) { return e.name; } };
        \\  out.family2 = await outcome(resolver.lookup('web.test', { family: 'any6' })) === 'TypeError' && await outcome(resolver.lookup('web.test')) === 'TypeError';
        \\  out.name = await outcome(resolver.lookup('café.test', { family: 'any' }));
        \\  out.empty = await outcome(resolver.lookup('', { family: 'any' }));
        \\  out.nonLoopback = throws(() => api.dns.resolver(io, { servers: [DnsServer.tcp([IpAddr.parse('192.0.2.1')])], ...options }));
        \\  out.mapped = throws(() => api.dns.resolver(io, { servers: [DnsServer.udp([IpAddr.parse('::ffff:8.8.8.8')])], ...options }));
        \\  out.dnssec = throws(() => api.dns.resolver(io, { servers: [DnsServer.tcp([local(api, 1)])], ...options, dnssec: 'validate' }));
        \\  out.required = ['dnssec', 'timeout', 'tries', 'servers'].map(k => { const o = { servers: [DnsServer.tcp([local(api, 1)])], ...options }; delete o[k]; return throws(() => api.dns.resolver(io, o)); }).every(n => n === 'TypeError');
        \\  out.tlsNeedsRoots = throws(() => api.dns.resolver(io, { servers: [DnsServer.tls('dns.test', [local(api, 1)])], ...options }));
        \\  out.badServers = throws(() => DnsServer.udp([])) === 'TypeError' && throws(() => DnsServer.udp(['1.1.1.1'])) === 'TypeError' && throws(() => new DnsServer()) === 'TypeError';
        \\  await resolver.close();
        \\  out.closed = resolver.closed && await outcome(resolver.lookup('web.test', { family: 'any' }));
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.both && report.family && report.noData === 'NotFound' && report.missing === 'NotFound' && report.subject === 'missing.test' && report.local && report.noQuery && report.failover && report.refused === 'ConnectionRefused' && report.timeout === 'TimedOut' && report.timeoutTook && report.family2 && report.name === 'InvalidInput' && report.empty === 'InvalidInput' && report.nonLoopback === 'PermissionDenied' && report.mapped === 'PermissionDenied' && report.dnssec === 'Unsupported' && report.required && report.tlsNeedsRoots === 'TypeError' && report.badServers && report.closed === 'BadHandle'");
}

test "dns: DNS over TLS" {
    if (!m.Api.dns_enabled or !m.Api.tls_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const { tls, dns } = api;
        \\  const roots = tls.RootPki.fromPem(bytes(CA));
        \\  const serverTls = tls.server({ identities: [tls.Identity.fromPem(bytes(SERVER), bytes(KEY))], clientAuth: tls.ClientAuth.none() });
        \\  const dot = listen(api, io, async plain => { try { framed(await serverTls.accept(plain, { mode: 'pull' })); } catch { /* a failed handshake */ } });
        \\  const resolver = dns.resolver(io, { servers: [dns.DnsServer.tls('localhost', [local(api, dot.port)])], roots, ...options });
        \\  out.dot = show(await resolver.lookup('web.test', { family: 'any' })) === '2001:db8::7,192.0.2.7';
        \\  out.missing = await outcome(resolver.lookup('missing.test', { family: 'any' }));
        \\  // A server certificate that is not valid for the name is refused with its own error.
        \\  const wrong = dns.resolver(io, { servers: [dns.DnsServer.tls('example.com', [local(api, dot.port)])], roots, ...options });
        \\  out.wrongName = await outcome(wrong.lookup('web.test', { family: 'any' }));
        \\  const stranger = dns.resolver(io, { servers: [dns.DnsServer.tls('localhost', [local(api, dot.port)])], roots: tls.RootPki.fromPem(bytes(ROGUE)), ...options });
        \\  out.unknownIssuer = await outcome(stranger.lookup('web.test', { family: 'any' }));
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.dot && report.missing === 'NotFound' && report.wrongName === 'CertificateRejected' && report.unknownIssuer === 'CertificateRejected'");
}

test "dns: datagrams" {
    if (!m.Api.dns_enabled) return error.SkipZigTest;
    const udp = try Udp.start();
    defer udp.deinit();
    const source = try std.fmt.allocPrint(t.allocator, "const UDP_PORT = {d};\n{s}", .{
        udp.port,
        prelude ++
            \\export async function main(api) {
            \\  const out = globalThis.report = {};
            \\  const io = api.io.create();
            \\  const { DnsServer } = api.dns;
            \\  const resolver = api.dns.resolver(io, { servers: [DnsServer.udp([local(api, UDP_PORT)])], ...options });
            \\  out.a = show(await resolver.lookup('anything.test', { family: 'any' })) === '192.0.2.1';
            \\  out.noAaaa = await outcome(resolver.lookup('anything.test', { family: 'ipv6' }));
            \\  out.missing = await outcome(resolver.lookup('missing.test', { family: 'any' }));
            \\  // Many at once, each with its own socket and id.
            \\  const many = await Promise.all(Array.from({ length: 30 }, (_, i) => resolver.lookup(`host${i}.test`, { family: 'ipv4' })));
            \\  out.many = many.every(ips => show(ips) === '192.0.2.1');
            \\  // The first server is silent, the second answers.
            \\  const dead = api.dns.resolver(io, { servers: [DnsServer.udp([local(api, 1)]), DnsServer.udp([local(api, UDP_PORT)])], dnssec: 'off', timeout: 300, tries: 1 });
            \\  out.failover = show(await dead.lookup('web.test', { family: 'ipv4' })) === '192.0.2.1';
            \\  await io.close();
            \\}
    });
    defer t.allocator.free(source);
    var p: Parent = undefined;
    try p.setup("init.js", source);
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.a && report.noAaaa === 'NotFound' && report.missing === 'NotFound' && report.many && report.failover");
    try t.expect(udp.queries.load(.monotonic) >= 33);
}

test "dns: Resolver is a Rust-defined class, frozen and brand-checked" {
    if (!m.Api.dns_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const { Resolver, DnsServer } = api.dns;
        \\  const throws = f => { try { f(); return 'no'; } catch (e) { return e.name; } };
        \\  const resolver = api.dns.resolver(io, { servers: [DnsServer.tcp([local(api, 1)])], ...options });
        \\  out.cls = Resolver.name === 'Resolver' && resolver instanceof Resolver && Object.getPrototypeOf(resolver) === Resolver.prototype && api.dns.Resolver === Resolver;
        \\  out.noNew = throws(() => new Resolver()) === 'TypeError';
        \\  const closedGetter = Object.getOwnPropertyDescriptor(Resolver.prototype, 'closed').get;
        \\  out.frozen = Object.isFrozen(Resolver) && Object.isFrozen(Resolver.prototype) && Object.isFrozen(Resolver.prototype.lookup) && Object.isFrozen(closedGetter) &&
        \\    typeof Resolver.prototype[Symbol.asyncDispose] === 'function';
        \\  out.members = resolver.io === io && resolver.closed === false;
        \\  out.receiver = throws(() => Resolver.prototype.close.call({})) === 'TypeError' && throws(() => closedGetter.call(io)) === 'TypeError' &&
        \\    throws(() => Object.getOwnPropertyDescriptor(Resolver.prototype, 'io').get.call({})) === 'TypeError' && await outcome(Resolver.prototype.lookup.call({}, 'x.test', { family: 'any' })) === 'TypeError';
        \\  await resolver[Symbol.asyncDispose]();
        \\  out.closed = resolver.closed && await outcome(resolver.lookup('x.test', { family: 'any' })) === 'BadHandle' && (await resolver.close()) === undefined;
        \\  const other = api.dns.resolver(io, { servers: [DnsServer.tcp([local(api, 1)])], ...options });
        \\  await io.close();
        \\  out.ioClosed = other.closed;
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.cls && report.noNew && report.frozen && report.members && report.receiver && report.closed && report.ioClosed");
}
