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
    \\const pair = async (api, io) => {
    \\  const listener = api.net.listen(io, { mode: 'pull', socketMode: 'pull', port: 0 });
    \\  const plain = await api.net.connect(io, { mode: 'pull', port: listener.port });
    \\  return { plain, accepted: await listener.accept(), listener };
    \\};
    \\const secure = async (api, io, client, server, servername = 'localhost') => {
    \\  const { plain, accepted, listener } = await pair(api, io);
    \\  const [a, b] = await Promise.all([client.connect(plain, { servername, mode: 'pull' }), server.accept(accepted, { mode: 'pull' })]);
    \\  return { a, b, plain, accepted, listener };
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
        \\  out.negotiated = a.alpn === 'h2' && b.alpn === 'h2' && a.version === 'tls1.3' && a.servername === 'localhost' && b.servername === 'localhost';
        \\  out.peer = a.peer.length === 1 && b.peer.length === 0;
        \\  out.consumed = plain.closed && await outcome(plain.read(1)) === 'BadHandle';
        \\  await a.send(bytes('hello'));
        \\  out.up = text(await b.read(64));
        \\  await b.send(bytes('world'));
        \\  const buffer = new Uint8Array(16);
        \\  const n = await a.readCopy(buffer);
        \\  out.down = text(buffer.subarray(0, n));
        \\  // 300 kB each way at once.
        \\  const big = Uint8Array.from({ length: 300000 }, (_, i) => i % 251);
        \\  const drain = async (s, want) => { let got = 0, sum = 0; while (got < want) { const c = await s.read(65536); if (c.length === 0) break; got += c.length; for (const v of c) sum += v; } return [got, sum]; };
        \\  const expected = big.reduce((x, v) => x + v, 0);
        \\  const [, , up, down] = await Promise.all([a.send(big), b.send(big), drain(b, big.length), drain(a, big.length)]);
        \\  out.bulk = up[0] === big.length && up[1] === expected && down[0] === big.length && down[1] === expected;
        \\  // A clean close: close_notify ends the read side, the other direction still works.
        \\  await a.end('write');
        \\  out.eof = (await b.read(16)).length === 0;
        \\  out.writeAfterEnd = await outcome(a.send(bytes('x')));
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
        \\    const [c, s] = await Promise.allSettled([client.connect(plain, { servername, mode: 'pull' }), server.accept(accepted, { mode: 'pull' })]);
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
        \\  // Event-mode TLS sockets and a missing mode are refused before anything is touched.
        \\  const { plain } = await pair(api, io);
        \\  out.event = await outcome(client.connect(plain, { servername: 'localhost', mode: 'event' }));
        \\  out.stillUsable = !plain.closed;
        \\  out.noMode = await outcome(client.connect(plain, { servername: 'localhost' }));
        \\  await io.close();
        \\}
    );
    defer p.deinit();
    try p.run();
    try check(p.scope, "report.unknownIssuer === 'CertificateRejected' && report.wrongName === 'CertificateRejected' && report.fine === 'ok,ok' && report.noClientCert && report.badPem === 'InvalidData' && report.mismatch === 'InvalidData' && report.types && report.event === 'Unsupported' && report.stillUsable && report.noMode === 'TypeError'");
}
