const std = @import("std");
const builtin = @import("builtin");
const check = @import("support.zig").check;
const Parent = @import("channel.zig").Parent;
const tls_prelude = @import("tls.zig").prelude;
const m = @import("@managed");
const t = std.testing;

// A DNS zone, a framed (TCP and DoT) server for it written in JS, and a datagram server in Zig on a thread.
const prelude = tls_prelude ++
    \\import { IpAddr, SocketAddr } from 'origine:@std/net';
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
    \\  if (typeof s.pulling === 'function') s = s.pulling();
    \\  try {
    \\    for (;;) {
    \\      const head = await readExact(s, 2);
    \\      const a = reply(await readExact(s, (head[0] << 8) | head[1]));
    \\      const out = new Uint8Array(2 + a.length); out[0] = a.length >> 8; out[1] = a.length & 255; out.set(a, 2);
    \\      await sendOn(s, out);
    \\    }
    \\  } catch { /* the client went away */ }
    \\};
    \\// A loopback listener handing each connection (unshaped) to `handle`.
    \\const listen = (api, io, handle) => {
    \\  const listener = io.tcp.listen(local(api, 0)).pulling();
    \\  (async () => { for (;;) { let s; try { s = await listener.accept(); } catch { return; } handle(s); } })();
    \\  return { port: listener.localAddr.port, close: () => listener.close() };
    \\};
    \\const local = (api, port) => SocketAddr.new(IpAddr.v4(127, 0, 0, 1), port);
    \\const options = { dnssec: 'off', timeout: 2000, tries: 1 };
    \\const show = ips => ips.map(String).join();
    \\
;

/// A datagram DNS server on loopback: an A record 192.0.2.1 for every name but `missing.test` (NXDOMAIN), no AAAA.
/// A `truncating` one answers every question with an empty answer that has the TC bit set (RFC 1035 section 4.1.1):
/// "ask again over TCP".
const Udp = struct {
    fd: c_int,
    port: u16,
    truncating: bool = false,
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
        return startWith(false);
    }

    fn startWith(truncating: bool) !*Udp {
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
        self.* = .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.port), .truncating = truncating };
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
            const answers: u8 = if (!missing and qtype == 1 and !self.truncating) 1 else 0;
            var out: [512]u8 = undefined;
            @memcpy(out[0..end], query[0..end]);
            out[2] = if (self.truncating) 0x83 else 0x81;
            out[3] = 0x80 | @as(u8, if (missing and !self.truncating) 3 else 0);
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

test "dns: lookups over TCP, failover, timeouts and inputs" {
    if (!m.Api.dns_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const { DnsServer } = api.dns;
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
        \\  const dot = listen(api, io, async plain => { try { framed(await serverTls.accept(plain)); } catch { /* a failed handshake */ } });
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

test "dns: cache honours TTL clamps and is opt-in" {
    if (!m.Api.dns_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const { DnsServer } = api.dns;
        \\  const tcp = listen(api, io, framed);
        \\  const servers = [DnsServer.tcp([local(api, tcp.port)])];
        \\  const cache = { limit: 16, ttl: { min: 0, max: 400 }, negative: { min: 0, max: 400 } };
        \\  const cached = api.dns.resolver(io, { servers, ...options, cache });
        \\  const ask = (r, name = 'web.test') => r.lookup(name, { family: 'ipv4' });
        \\  let before = stats.queries;
        \\  const first = show(await ask(cached));
        \\  const second = show(await ask(cached));
        \\  out.hit = first === '192.0.2.7' && second === first && stats.queries === before + 1;
        \\  // The zone's records say 60 s; the resolver's max clamp is 400 ms.
        \\  await io.timer.sleep(600);
        \\  await ask(cached);
        \\  out.expired = stats.queries === before + 2;
        \\  // Every lookup asks without a cache option.
        \\  const plain = api.dns.resolver(io, { servers, ...options });
        \\  before = stats.queries;
        \\  await ask(plain); await ask(plain);
        \\  out.optIn = stats.queries === before + 2;
        \\  // This zone sends no SOA, so NXDOMAIN is not kept (RFC 2308 gives no lifetime).
        \\  before = stats.queries;
        \\  await outcome(ask(cached, 'missing.test')); await outcome(ask(cached, 'missing.test'));
        \\  out.negative = stats.queries === before + 2;
        \\  const throws = f => { try { f(); return 'no'; } catch (e) { return e.name; } };
        \\  const bad = c => throws(() => api.dns.resolver(io, { servers, ...options, cache: c }));
        \\  out.checked = [
        \\    { ...cache, limit: 0 }, { ...cache, limit: 1.5 }, { ...cache, ttl: { min: 5, max: 1 } }, { ...cache, ttl: { min: 0 } },
        \\    { ...cache, negative: { min: -1, max: 1 } }, { limit: 1, ttl: cache.ttl }, 5,
        \\  ].every(c => bad(c) === 'TypeError');
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.hit && report.expired && report.optIn && report.negative && report.checked");
}

test "dns: DNS over HTTPS" {
    if (!m.Api.dns_enabled or !m.Api.tls_enabled or !m.Api.http_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\const limits = { streams: 100, headers: 16384, window: 65535, connection: 1 << 20, batch: 4096 };
        \\const seen = [];
        \\// A DoH server: the zone above behind POST /dns-query, and failures behind other paths.
        \\const doh = (api, io, serverTls) => {
        \\  const server = api.http.serve(io, { listen: { port: 0 }, tls: serverTls, mode: 'pull', limits });
        \\  (async () => {
        \\    for await (const ex of server) {
        \\      (async () => {
        \\        let head; const body = [];
        \\        for (let ev; (ev = await ex.next()); ) {
        \\          if (ev.type === 'headers' && ev.kind === 'request') head = ev;
        \\          if (ev.type === 'data') { body.push(...ev.data); ex.consume(ev.data.length); }
        \\          if (ev.type === 'end' || ev.type === 'closed' || (ev.type === 'headers' && ev.endStream)) break;
        \\        }
        \\        const query = Uint8Array.from(body);
        \\        seen.push({ method: head.method, path: head.path, type: head.headers.get('content-type'), accept: head.headers.get('accept'), id: (query[0] << 8) | query[1] });
        \\        const send = async (status, type, data) => {
        \\          const h = new api.http.HeaderList(); h.put('content-type', type);
        \\          ex.respond({ status, headers: h, body: 'stream' });
        \\          await ex.send(data); ex.finish();
        \\        };
        \\        if (head.path === '/status') await send(503, 'application/dns-message', new Uint8Array(0));
        \\        else if (head.path === '/type') await send(200, 'text/plain', reply(query));
        \\        else if (head.path === '/redirect') await send(302, 'application/dns-message', reply(query));
        \\        else await send(200, 'application/dns-message', reply(query));
        \\      })();
        \\    }
        \\  })();
        \\  return server;
        \\};
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const { tls, dns } = api;
        \\  const roots = tls.RootPki.fromPem(bytes(CA));
        \\  const serverTls = tls.server({ identities: [tls.Identity.fromPem(bytes(SERVER), bytes(KEY))], clientAuth: tls.ClientAuth.none(), alpn: ['h2'] });
        \\  const server = doh(api, io, serverTls);
        \\  const loopback = IpAddr.v4(127, 0, 0, 1);
        \\  const url = path => `https://localhost:${server.port}${path}`;
        \\  const via = (path, extra = {}) => dns.resolver(io, { servers: [dns.DnsServer.https(url(path), [loopback])], roots, ...options, ...extra });
        \\  const resolver = via('/dns-query');
        \\  out.both = show(await resolver.lookup('web.test', { family: 'any' })) === '2001:db8::7,192.0.2.7';
        \\  out.request = seen.length === 2 && seen.every(r => r.method === 'POST' && r.path === '/dns-query' && r.type === 'application/dns-message' && r.accept === 'application/dns-message' && r.id === 0);
        \\  out.missing = await outcome(resolver.lookup('missing.test', { family: 'any' }));
        \\  // Other failures of the HTTP layer, each with its own meaning; a redirect is not followed.
        \\  out.status = await via('/status').lookup('web.test', { family: 'ipv4' }).catch(e => e.name + ':' + e.subject);
        \\  out.type = await outcome(via('/type').lookup('web.test', { family: 'ipv4' }));
        \\  out.redirect = await via('/redirect').lookup('web.test', { family: 'ipv4' }).catch(e => e.name + ':' + e.subject);
        \\  // A cache spares the second connection.
        \\  const kept = via('/dns-query', { cache: { limit: 8, ttl: { min: 0, max: 60000 }, negative: { min: 0, max: 0 } } });
        \\  const before = seen.length;
        \\  await kept.lookup('web.test', { family: 'ipv4' }); await kept.lookup('web.test', { family: 'ipv4' });
        \\  out.cached = seen.length === before + 1;
        \\  // The certificate must be valid for the URL's host, and chain to the roots given.
        \\  const wrong = dns.resolver(io, { servers: [dns.DnsServer.https(`https://example.com:${server.port}/dns-query`, [loopback])], roots, ...options });
        \\  out.wrongName = await outcome(wrong.lookup('web.test', { family: 'any' }));
        \\  const stranger = via('/dns-query', { roots: tls.RootPki.fromPem(bytes(ROGUE)) });
        \\  out.unknownIssuer = await outcome(stranger.lookup('web.test', { family: 'any' }));
        \\  // Inputs.
        \\  const throws = f => { try { f(); return 'no'; } catch (e) { return e.name; } };
        \\  const { DnsServer } = dns;
        \\  out.urls = ['http://dns.test/q', 'https://', 'https://u@dns.test/q', 'https://dns.test:0/q', 'https://dns.test:65536/q', 'https://dns.test/q#frag', 'https://[::1]/q', 'https://dns .test/q', 'ftp://dns.test', '', 42, undefined].every(u => throws(() => DnsServer.https(u, [loopback])) === 'TypeError');
        \\  out.good = ['https://dns.test', 'https://DNS.test:8443/a/b?x=1', 'https://1.1.1.1/dns-query'].every(u => throws(() => DnsServer.https(u, [loopback])) === 'no');
        \\  out.needsRoots = throws(() => dns.resolver(io, { servers: [DnsServer.https(url('/dns-query'), [loopback])], ...options }));
        \\  out.ceiling = throws(() => dns.resolver(io, { servers: [DnsServer.https('https://dns.test/dns-query', [IpAddr.parse('192.0.2.1')])], roots, ...options }));
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.both && report.request && report.missing === 'NotFound' && report.status === 'ServerFailure:HTTP status 503' && report.type === 'ProtocolError' && report.redirect === 'ServerFailure:HTTP status 302' && report.cached && report.wrongName === 'CertificateRejected' && report.unknownIssuer === 'CertificateRejected' && report.urls && report.good && report.needsRoots === 'TypeError' && report.ceiling === 'PermissionDenied'");
}

test "dns: presets are pinned data over the public constructors" {
    if (!m.Api.dns_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\import { presets } from 'origine:@std/dns/presets';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const table = {
        \\    cloudflare: ['Cloudflare', '1.1.1.1,1.0.0.1,2606:4700:4700::1111,2606:4700:4700::1001'],
        \\    cloudflareMalware: ['Cloudflare Malware', '1.1.1.2,1.0.0.2,2606:4700:4700::1112,2606:4700:4700::1002'],
        \\    cloudflareFamily: ['Cloudflare Family', '1.1.1.3,1.0.0.3,2606:4700:4700::1113,2606:4700:4700::1003'],
        \\    adguard: ['AdGuard', '94.140.14.14,94.140.15.15,2a10:50c0::ad1:ff,2a10:50c0::ad2:ff'],
        \\    google: ['Google', '8.8.8.8,8.8.4.4,2001:4860:4860::8888,2001:4860:4860::8844'],
        \\    quad9: ['Quad9', '9.9.9.9,149.112.112.112,2620:fe::fe,2620:fe::9'],
        \\  };
        \\  out.keys = Object.keys(presets).join() === Object.keys(table).join();
        \\  out.table = Object.entries(table).every(([key, [name, ips]]) => presets[key].name === name && show(presets[key].servers) === ips);
        \\  out.frozen = Object.isFrozen(presets) && Object.isFrozen(presets.google) && Object.isFrozen(presets.google.servers);
        \\  out.servers = presets.google.servers.every(ip => ip instanceof IpAddr);
        \\  out.made = Object.values(presets).every(p => ['udp', 'tcp', 'tls', 'https'].every(k => p[k]() instanceof api.dns.DnsServer)) && presets.google.udp() !== presets.google.udp();
        \\  out.noQuic = presets.google.quic === undefined;
        \\  // They are public addresses: the network ceiling refuses them unless the embedder allows them.
        \\  const io = api.io.create();
        \\  const roots = api.tls.RootPki.fromPem(bytes(CA));
        \\  const throws = f => { try { f(); return 'no'; } catch (e) { return e.name; } };
        \\  out.ceiling = ['udp', 'tcp', 'tls', 'https'].map(k => throws(() => api.dns.resolver(io, { servers: [presets.cloudflare[k]()], roots, ...options }))).every(n => n === 'PermissionDenied');
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.keys && report.table && report.frozen && report.servers && report.made && report.noQuic && report.ceiling");
}

test "dns: a truncated datagram answer is asked again over TCP, at the same address" {
    if (!m.Api.dns_enabled) return error.SkipZigTest;
    // The datagram server answers every question with an empty answer and the TC bit; the stream server (JS, the
    // zone above) listens on the same port number and has the records.
    const udp = try Udp.startWith(true);
    defer udp.deinit();
    // This one is truncating too, and nothing listens for TCP on its port.
    const lonely = try Udp.startWith(true);
    defer lonely.deinit();
    const source = try std.fmt.allocPrint(t.allocator, "const UDP_PORT = {d};\nconst LONELY_PORT = {d};\n{s}", .{
        udp.port,
        lonely.port,
        prelude ++
            \\export async function main(api) {
            \\  const out = globalThis.report = {};
            \\  const io = api.io.create();
            \\  const { DnsServer } = api.dns;
            \\  const listener = io.tcp.listen(local(api, UDP_PORT)).pulling();
            \\  (async () => { for (;;) { let s; try { s = await listener.accept(); } catch { return; } framed(s); } })();
            \\  const resolver = api.dns.resolver(io, { servers: [DnsServer.udp([local(api, UDP_PORT)])], ...options });
            \\  out.a = show(await resolver.lookup('web.test', { family: 'ipv4' })) === '192.0.2.7';
            \\  out.tcpAsked = stats.queries === 1;
            \\  // Both families: each question goes out by datagram first, then by stream.
            \\  out.both = show(await resolver.lookup('web.test', { family: 'any' })) === '2001:db8::7,192.0.2.7' && stats.queries === 3;
            \\  // The stream answer is the answer: a name the zone lacks is NXDOMAIN there, whatever the datagram said.
            \\  out.missing = await outcome(resolver.lookup('missing.test', { family: 'any' }));
            \\  out.streamQueries = stats.queries;
            \\  // A truncated answer is never used as if it were whole: with no stream server the lookup fails.
            \\  const lonely = api.dns.resolver(io, { servers: [DnsServer.udp([local(api, LONELY_PORT)])], ...options });
            \\  out.noStream = await outcome(lonely.lookup('web.test', { family: 'ipv4' }));
            \\  await io.close();
            \\}
    });
    defer t.allocator.free(source);
    var p: Parent = undefined;
    try p.setup("init.js", source);
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.a && report.tcpAsked && report.both && report.missing === 'NotFound' && report.streamQueries === 4 && report.noStream === 'ConnectionRefused'");
    // One datagram per question (A; AAAA and A; AAAA of the missing name, which settles it), each then asked over TCP.
    try t.expectEqual(@as(u32, 4), udp.queries.load(.monotonic));
    try t.expectEqual(@as(u32, 1), lonely.queries.load(.monotonic));
}
