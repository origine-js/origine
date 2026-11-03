const check = @import("support.zig").check;
const Parent = @import("channel.zig").Parent;
const tls_enabled = @import("@managed").Api.tls_enabled;

// Test certificates (ECDSA P-256, valid for 100 years): `CA` signs `SERVER`, `ROGUE` is signed by an
// authority nobody trusts; both are for `localhost` and 127.0.0.1.
pub const prelude =
    \\const CA = `
    \\-----BEGIN CERTIFICATE-----
    \\MIIBSTCB8KADAgECAgkAkg9t6NzB0RMwCgYIKoZIzj0EAwIwFzEVMBMGA1UEAwwM
    \\Z29vZCB0ZXN0IGNhMCAXDTI2MTEwMTEyMzAzM1oYDzIxMjYxMDA4MTIzMDMzWjAX
    \\MRUwEwYDVQQDDAxnb29kIHRlc3QgY2EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNC
    \\AAQ47Vj1PBQj7ynWR7pFzdzNRllKMbK5p+EeyCMNtiyQT+73MG72S+aGcMG6evPt
    \\dzTxZoPu03RDMlN/MX3KUPewoyMwITAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB
    \\/wQEAwIBBjAKBggqhkjOPQQDAgNIADBFAiEAyR4P/JVz4mlCS7oJxGF8V5PA2XUJ
    \\91CvzCRbO/ckrNACIGyEizGkxl8W2lpxtDEz9z3tgtrQLnCIk1O45F8teYIc
    \\-----END CERTIFICATE-----
    \\`;
    \\const SERVER = `
    \\-----BEGIN CERTIFICATE-----
    \\MIIBeTCCAR+gAwIBAgIJALpgIyabo+nxMAoGCCqGSM49BAMCMBcxFTATBgNVBAMM
    \\DGdvb2QgdGVzdCBjYTAgFw0yNjExMDExMjMwMzNaGA8yMTI2MTAwODEyMzAzM1ow
    \\FDESMBAGA1UEAwwJbG9jYWxob3N0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE
    \\omKaAfOfiFerMebZawrKlx9eoufxh+PNFoAzvt64snloaxf2TQ1ZDEyRyvbn0v/a
    \\c5WUj20/tDf6q5+fHbWeT6NVMFMwGgYDVR0RBBMwEYIJbG9jYWxob3N0hwR/AAAB
    \\MAkGA1UdEwQCMAAwCwYDVR0PBAQDAgeAMB0GA1UdJQQWMBQGCCsGAQUFBwMBBggr
    \\BgEFBQcDAjAKBggqhkjOPQQDAgNIADBFAiAUOKPRYYV2gEEFXR/xIpavpJRVDAe2
    \\xycINJIXP9jWyQIhAP/y4qCRhslwnFnr3YhJYEKKKpmO+9MMAv04XoovQ2tH
    \\-----END CERTIFICATE-----
    \\`;
    \\const KEY = `
    \\-----BEGIN PRIVATE KEY-----
    \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQguW/ZyVU2SChmxkbJ
    \\Ad2ofhoNuiuA+ESKy343wGrY12yhRANCAASiYpoB85+IV6sx5tlrCsqXH16i5/GH
    \\480WgDO+3riyeWhrF/ZNDVkMTJHK9ufS/9pzlZSPbT+0N/qrn58dtZ5P
    \\-----END PRIVATE KEY-----
    \\`;
    \\const ROGUE = `
    \\-----BEGIN CERTIFICATE-----
    \\MIIBezCCASCgAwIBAgIJAIyH/gbCL7zyMAoGCCqGSM49BAMCMBgxFjAUBgNVBAMM
    \\DXJvZ3VlIHRlc3QgY2EwIBcNMjYxMTAxMTIzMDMzWhgPMjEyNjEwMDgxMjMwMzNa
    \\MBQxEjAQBgNVBAMMCWxvY2FsaG9zdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IA
    \\BI01nif6OrZDVFcQaFZfWCC2gkh/YfA9kg0PJrxS/4nN0Z4QXUxABqJsMJcA+SMT
    \\iPwInC5A6I4letNXjbYLkGCjVTBTMBoGA1UdEQQTMBGCCWxvY2FsaG9zdIcEfwAA
    \\ATAJBgNVHRMEAjAAMAsGA1UdDwQEAwIHgDAdBgNVHSUEFjAUBggrBgEFBQcDAQYI
    \\KwYBBQUHAwIwCgYIKoZIzj0EAwIDSQAwRgIhAL5s46sJGs4WmbvdVA2JK7LIum79
    \\NKzkjjAsL6gtNbI4AiEA1uwbI6UGQw/ECUVnp3TmYx5UxfChgnYZpqENWMLqa8Q=
    \\-----END CERTIFICATE-----
    \\`;
    \\const ROGUE_KEY = `
    \\-----BEGIN PRIVATE KEY-----
    \\MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgz5UwK5TEEpTPgLAR
    \\eS9BQ5j38ymW7MtTP3kaeX2+RiahRANCAASNNZ4n+jq2Q1RXEGhWX1ggtoJIf2Hw
    \\PZINDya8Uv+JzdGeEF1MQAaibDCXAPkjE4j8CJwuQOiOJXrTV422C5Bg
    \\-----END PRIVATE KEY-----
    \\`;
    \\const bytes = s => Uint8Array.from(s, c => c.charCodeAt(0));
    \\const text = b => String.fromCharCode(...b);
    \\import * as stdNet from 'origine:@std/net';
    \\// Two ends of a loopback connection, unshaped.
    \\const pair = async (api, io) => {
    \\  const listener = io.tcp.listen(stdNet.SocketAddr.parse('127.0.0.1:0')).pulling();
    \\  const plain = await io.tcp.connect(listener.localAddr);
    \\  return { plain, accepted: await listener.accept(), listener };
    \\};
    \\const secure = async (api, io, client, server, servername = 'localhost') => {
    \\  const { plain, accepted, listener } = await pair(api, io);
    \\  const [a, b] = await Promise.all([client.connect(plain, { servername }), server.accept(accepted)]);
    \\  return { a: a.pulling(), b: b.pulling(), plain, accepted, listener };
    \\};
    \\const outcome = promise => promise.then(() => 'resolved', e => e.name);
    \\
;

test "tls: a handshake, data both ways, a clean close and a cut connection" {
    if (!tls_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const { tls } = api;
        \\  const client = tls.client({ roots: tls.RootPki.fromPem(bytes(CA)), alpn: ['h2', 'http/1.1'] });
        \\  const server = tls.server({ identities: [tls.Identity.fromPem(bytes(SERVER), bytes(KEY))], clientAuth: tls.ClientAuth.none(), alpn: ['h2'] });
        \\  const { a, b, plain } = await secure(api, io, client, server);
        \\  out.negotiated = tls.info(a).alpn === 'h2' && tls.info(b).alpn === 'h2' && tls.info(a).version === 'tls1.3' && tls.info(a).servername === 'localhost' && tls.info(b).servername === 'localhost';
        \\  out.peer = tls.info(a).peer.length === 1 && tls.info(b).peer.length === 0;
        \\  out.consumed = plain.closed && (() => { try { plain.pulling(); return 'no'; } catch (e) { return e.name; } })() === 'BadHandle';
        \\  await a.queued.send(bytes('hello'));
        \\  out.up = text(await b.read(64));
        \\  await b.queued.send(bytes('world'));
        \\  const buffer = new Uint8Array(16);
        \\  const n = await a.readCopy(buffer);
        \\  out.down = text(buffer.subarray(0, n));
        \\  // 300 kB each way at once.
        \\  const big = Uint8Array.from({ length: 300000 }, (_, i) => i % 251);
        \\  const drain = async (s, want) => { let got = 0, sum = 0; while (got < want) { const c = await s.read(65536); if (c.length === 0) break; got += c.length; for (const v of c) sum += v; } return [got, sum]; };
        \\  const expected = big.reduce((x, v) => x + v, 0);
        \\  const [, , up, down] = await Promise.all([a.queued.send(big), b.queued.send(big), drain(b, big.length), drain(a, big.length)]);
        \\  out.bulk = up[0] === big.length && up[1] === expected && down[0] === big.length && down[1] === expected;
        \\  // A clean close: close_notify ends the read side, the other direction still works.
        \\  await a.end('write');
        \\  out.eof = (await b.read(16)).length === 0;
        \\  out.writeAfterEnd = await outcome(a.queued.send(bytes('x')));
        \\  await b.end('write');
        \\  out.eofBoth = (await a.read(16)).length === 0;
        \\  await a.close();
        \\  await b.close();
        \\  // A cut connection is an error, not an end of stream.
        \\  const cut = await secure(api, io, client, server);
        \\  await cut.a.close();
        \\  out.cut = await outcome(cut.b.read(16));
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.negotiated && report.peer && report.consumed && report.up === 'hello' && report.down === 'world' && report.bulk && report.eof && report.writeAfterEnd === 'BrokenPipe' && report.eofBoth && report.cut === 'UnexpectedEof'");
}

test "tls: refused certificates, bad inputs and what is not there yet" {
    if (!tls_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const { tls } = api;
        \\  const good = tls.Identity.fromPem(bytes(SERVER), bytes(KEY));
        \\  const client = tls.client({ roots: tls.RootPki.fromPem(bytes(CA)) });
        \\  const rogue = tls.server({ identities: [tls.Identity.fromPem(bytes(ROGUE), bytes(ROGUE_KEY))], clientAuth: tls.ClientAuth.none() });
        \\  const fine = tls.server({ identities: [good], clientAuth: tls.ClientAuth.none() });
        \\  const handshake = async (client, server, servername) => {
        \\    const { plain, accepted } = await pair(api, io);
        \\    const [c, s] = await Promise.allSettled([client.connect(plain, { servername }), server.accept(accepted)]);
        \\    return [c.status === 'fulfilled' ? 'ok' : c.reason.name, s.status === 'fulfilled' ? 'ok' : s.reason.name];
        \\  };
        \\  out.unknownIssuer = (await handshake(client, rogue, 'localhost'))[0];
        \\  out.wrongName = (await handshake(client, fine, 'example.com'))[0];
        \\  out.fine = (await handshake(client, fine, 'localhost')).join();
        \\  // The server asks for a certificate the client does not have.
        \\  const needy = tls.server({ identities: [good], clientAuth: tls.ClientAuth.require(tls.RootPki.fromPem(bytes(CA))) });
        \\  out.noClientCert = (await handshake(client, needy, 'localhost'))[1] !== 'ok';
        \\  // Inputs are checked where they are made.
        \\  const throws = f => { try { f(); return 'no'; } catch (e) { return e.name; } };
        \\  out.badPem = throws(() => tls.RootPki.fromPem(bytes('not a certificate')));
        \\  out.mismatch = throws(() => tls.Identity.fromPem(bytes(SERVER), bytes(ROGUE_KEY)));
        \\  out.types = throws(() => tls.client({ roots: {} })) === 'TypeError' && throws(() => new tls.RootPki()) === 'TypeError';
        \\  // A missing servername is refused before anything is touched: the stream stays usable.
        \\  const { plain } = await pair(api, io);
        \\  out.noMode = await outcome(client.connect(plain, {}));
        \\  out.stillUsable = !plain.closed && plain.pulling() instanceof api.net.PullTcpStream;
        \\  out.notAStream = await outcome(client.connect({ read() {} }, { servername: 'localhost' }));
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.unknownIssuer === 'CertificateRejected' && report.wrongName === 'CertificateRejected' && report.fine === 'ok,ok' && report.noClientCert && report.badPem === 'InvalidData' && report.mismatch === 'InvalidData' && report.types && report.stillUsable && report.noMode === 'TypeError' && report.notAStream === 'TypeError'");
}

test "tls: event-mode sockets deliver plaintext, send and end with close_notify" {
    if (!tls_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const { tls } = api;
        \\  const client = tls.client({ roots: tls.RootPki.fromPem(bytes(CA)) });
        \\  const server = tls.server({ identities: [tls.Identity.fromPem(bytes(SERVER), bytes(KEY))], clientAuth: tls.ClientAuth.none() });
        \\  const { plain, accepted } = await pair(api, io);
        \\  const [ua, ub] = await Promise.all([client.connect(plain, { servername: 'localhost' }), server.accept(accepted)]);
        \\  out.unshaped = ua instanceof api.net.TcpStreamUnshaped && tls.info(ua).alpn === undefined;
        \\  const a = ua.evented(), b = ub.evented();
        \\  out.kinds = out.unshaped && a instanceof api.net.EventTcpStream && b instanceof api.net.EventTcpStream;
        \\  out.info = tls.info(a).version === 'tls1.3' && tls.info(b).servername === 'localhost';
        \\  const big = Uint8Array.from({ length: 200000 }, (_, i) => i % 251);
        \\  const expected = big.reduce((x, v) => x + v, 0);
        \\  let got = 0, sum = 0, ended = false, failed = null;
        \\  const finished = new Promise(resolve => {
        \\    b.register('data', event => { const chunk = event.buffer(); got += chunk.length; for (const v of chunk) sum += v; event.buffer().unref(); });
        \\    b.register('end', () => { ended = true; resolve(); });
        \\    b.register('error', e => { failed = e.name; resolve(); });
        \\  });
        \\  // Handlers do not keep the program alive; a pending `io.run()` does (until every flowing handle closed).
        \\  const running = io.run();
        \\  await a.queued.send(big);
        \\  await a.end('write');
        \\  await finished;
        \\  out.bulk = got === big.length && sum === expected && ended && failed === null;
        \\  // The other way: b answers after the end.
        \\  const reply = new Promise(resolve => a.register('data', event => resolve(text(event.buffer()))));
        \\  await b.queued.send(bytes('pong'));
        \\  out.reply = await reply;
        \\  out.badInfo = (() => { try { tls.info(plain); return 'no'; } catch (e) { return e.name; } })();
        \\  await a.close();
        \\  await b.close();
        \\  await running;
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.kinds && report.info && report.bulk && report.reply === 'pong' && report.badInfo === 'BadHandle'");
}

test "tls: the value classes are Rust-defined classes, frozen and brand-checked" {
    if (!tls_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\import { IoError } from 'origine:@std/io';
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const { tls } = api;
        \\  const throws = f => { try { f(); return 'no'; } catch (e) { return e.name; } };
        \\  const classes = [tls.RootPki, tls.Identity, tls.ClientAuth, tls.TlsSessions, tls.TlsClient, tls.TlsServer];
        \\  out.names = classes.map(C => C.name).join() === 'RootPki,Identity,ClientAuth,TlsSessions,TlsClient,TlsServer';
        \\  out.noNew = classes.every(C => throws(() => new C()) === 'TypeError') && throws(() => tls.RootPki()) === 'TypeError';
        \\  out.frozen = classes.every(C => Object.isFrozen(C) && Object.isFrozen(C.prototype) &&
        \\    Object.values(Object.getOwnPropertyDescriptors(C)).every(d => typeof d.value !== 'function' || Object.isFrozen(d.value)) &&
        \\    Object.values(Object.getOwnPropertyDescriptors(C.prototype)).every(d => (typeof d.value !== 'function' || Object.isFrozen(d.value)) && !d.enumerable));
        \\  out.statics = throws(() => { tls.RootPki.fromPem = null; }) === 'TypeError' && !Reflect.set(tls.RootPki, 'bundled', null) && typeof tls.RootPki.bundled === 'function';
        \\  out.same = api.tls.RootPki === tls.RootPki && tls.RootPki.fromPem.name === 'fromPem' && tls.RootPki.fromPem.length === 1 && tls.TlsClient.prototype.connect.length === 2;
        \\  const roots = tls.RootPki.bundled();
        \\  const client = tls.client({ roots });
        \\  const server = tls.server({ identities: [tls.Identity.fromPem(bytes(SERVER), bytes(KEY))], clientAuth: tls.ClientAuth.require(roots) });
        \\  out.instances = roots instanceof tls.RootPki && client instanceof tls.TlsClient && server instanceof tls.TlsServer && !(roots instanceof tls.Identity) &&
        \\    tls.TlsSessions.create({ limit: 4 }) instanceof tls.TlsSessions && tls.ClientAuth.none() instanceof tls.ClientAuth &&
        \\    Object.getPrototypeOf(roots) === tls.RootPki.prototype && Object.keys(roots).length === 0;
        \\  out.receiver = throws(() => tls.RootPki.prototype.release.call(client)) === 'TypeError' && throws(() => tls.RootPki.prototype.release.call({})) === 'TypeError' &&
        \\    throws(() => Object.create(tls.RootPki.prototype).release()) === 'TypeError';
        \\  out.wrongConnect = await outcome(tls.TlsClient.prototype.connect.call(server, {}, { servername: 'x' }));
        \\  out.args = throws(() => tls.RootPki.fromPem('pem')) === 'TypeError' && throws(() => tls.TlsSessions.create({ limit: 0 })) === 'TypeError' &&
        \\    throws(() => tls.server({ identities: [], clientAuth: tls.ClientAuth.none() })) === 'TypeError' && throws(() => tls.client({ roots, alpn: [''] })) === 'TypeError' &&
        \\    throws(() => tls.server({ identities: [roots], clientAuth: tls.ClientAuth.none() })) === 'TypeError';
        \\  try { tls.RootPki.fromPem(bytes('nothing')); } catch (e) { out.errorClass = e instanceof IoError && e.name === 'InvalidData'; }
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.names && report.noNew && report.frozen && report.statics && report.same && report.instances && report.receiver && report.wrongConnect === 'TypeError' && report.args && report.errorClass");
}

test "tls: native values are freed with their wrappers and what was built from them survives" {
    if (!tls_enabled) return error.SkipZigTest;
    var p: Parent = undefined;
    try p.setup("init.js", prelude ++
        \\export async function main(api) {
        \\  const out = globalThis.report = {};
        \\  const io = api.io.create();
        \\  const { tls } = api;
        \\  // The client is built from roots and an identity that are then dropped and collected.
        \\  let roots = tls.RootPki.fromPem(bytes(CA));
        \\  const client = tls.client({ roots, alpn: ['h2'] });
        \\  let identity = tls.Identity.fromPem(bytes(SERVER), bytes(KEY));
        \\  const server = tls.server({ identities: [identity], clientAuth: tls.ClientAuth.none(), alpn: ['h2'] });
        \\  roots = identity = undefined;
        \\  // A burst of throwaway values, then collections that free them.
        \\  for (let i = 0; i < 300; i++) tls.RootPki.bundled();
        \\  for (let i = 0; i < 3; i++) { %CollectGarbage(null); await Promise.resolve(); }
        \\  const { plain, accepted } = await pair(api, io);
        \\  const [a, b] = await Promise.all([client.connect(plain, { servername: 'localhost' }), server.accept(accepted)]);
        \\  out.survives = tls.info(a).alpn === 'h2' && tls.info(b).alpn === 'h2';
        \\  // Releasing by hand makes the value unusable but not what was built from it.
        \\  const spare = tls.RootPki.bundled();
        \\  spare.release();
        \\  out.released = (() => { try { tls.client({ roots: spare }); return 'no'; } catch (e) { return e.name; } })();
        \\  out.wrongKind = (() => { try { tls.client({ roots: client }); return 'no'; } catch (e) { return e.name; } })();
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.survives && report.released === 'BadHandle' && report.wrongKind === 'TypeError'");
}
