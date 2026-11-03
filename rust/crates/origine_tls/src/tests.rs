//! Handshake, data, close and failure behaviour over an in-memory pipe (no loop, no sockets).

use crate::{
    CertProblem, ClientAuth, ClientOptions, Identity, RootPki, ServerOptions, TlsClient, TlsError, TlsServer, TlsSessions, TlsStream,
    Version,
};
use futures_lite::future::{poll_once, zip};
use origine_transport::pipe::{Pipe, pipe};
use rcgen::{BasicConstraints, Certificate, CertificateParams, DnType, IsCa, KeyPair};
use std::cell::RefCell;

// ---- fixtures ----

struct Ca {
    cert: Certificate,
    key: KeyPair,
}

fn ca(name: &str) -> Ca {
    let mut params = CertificateParams::new(Vec::<String>::new()).unwrap();
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    params.distinguished_name.push(DnType::CommonName, name);
    let key = KeyPair::generate().unwrap();
    let cert = params.self_signed(&key).unwrap();
    Ca { cert, key }
}

impl Ca {
    fn roots(&self) -> RootPki {
        RootPki::from_pem(self.cert.pem().as_bytes()).unwrap()
    }

    fn identity(&self, names: &[&str]) -> Identity {
        let params = CertificateParams::new(names.iter().map(|n| n.to_string()).collect::<Vec<_>>()).unwrap();
        let key = KeyPair::generate().unwrap();
        let cert = params.signed_by(&key, &self.cert, &self.key).unwrap();
        Identity::from_pem(cert.pem().as_bytes(), key.serialize_pem().as_bytes()).unwrap()
    }
}

fn client(roots: RootPki, alpn: &[&str]) -> TlsClient {
    TlsClient::new(ClientOptions { roots, identity: None, alpn: alpn.iter().map(|s| s.to_string()).collect(), sessions: None }).unwrap()
}

fn server(identities: Vec<Identity>, alpn: &[&str]) -> TlsServer {
    TlsServer::new(ServerOptions { identities, client_auth: ClientAuth::none(), alpn: alpn.iter().map(|s| s.to_string()).collect() })
        .unwrap()
}

type Pair = (TlsStream<Pipe>, TlsStream<Pipe>);

async fn connected(client: &TlsClient, server: &TlsServer, name: &str) -> Pair {
    let (c, s) = pipe();
    let (c, s) = zip(TlsStream::connect(client, c, name), TlsStream::accept(server, s)).await;
    (c.unwrap(), s.unwrap())
}

async fn read_exact(stream: &TlsStream<Pipe>, len: usize) -> Vec<u8> {
    let mut out = vec![0; len];
    let mut got = 0;
    while got < len {
        let n = stream.read(&mut out[got..]).await.unwrap();
        assert!(n > 0, "stream ended after {got} of {len} bytes");
        got += n;
    }
    out
}

fn simple() -> (Ca, TlsClient, TlsServer) {
    let ca = ca("test ca");
    let c = client(ca.roots(), &[]);
    let s = server(vec![ca.identity(&["localhost"])], &[]);
    (ca, c, s)
}

// ---- tests ----

#[test]
fn handshake_and_echo() {
    pollster::block_on(async {
        let ca = ca("test ca");
        let c = client(ca.roots(), &["h2", "http/1.1"]);
        let s = server(vec![ca.identity(&["localhost"])], &["h2"]);
        let (client, server) = connected(&c, &s, "localhost").await;

        let ci = client.info();
        assert_eq!(ci.alpn.as_deref(), Some("h2"));
        assert_eq!(ci.version, Version::Tls13);
        assert_eq!(ci.servername.as_deref(), Some("localhost"));
        assert_eq!(ci.peer.len(), 1);
        assert!(!ci.resumed);
        let si = server.info();
        assert_eq!(si.servername.as_deref(), Some("localhost"));
        assert_eq!(si.alpn.as_deref(), Some("h2"));
        assert!(si.peer.is_empty());

        client.write(b"hello").await.unwrap();
        assert_eq!(read_exact(&server, 5).await, b"hello");
        server.write(b"world!").await.unwrap();
        assert_eq!(read_exact(&client, 6).await, b"world!");
    });
}

#[test]
fn large_transfers_both_ways_at_once() {
    pollster::block_on(async {
        let (_ca, c, s) = simple();
        let (client, server) = connected(&c, &s, "localhost").await;
        let up: Vec<u8> = (0..1_000_000u32).map(|i| (i % 251) as u8).collect();
        let down: Vec<u8> = (0..400_000u32).map(|i| (i % 241) as u8).collect();
        let (c2, s2) = (client.clone(), server.clone());
        let ((), ((), (got_up, got_down))) = zip(
            async {
                client.write(&up).await.unwrap();
            },
            zip(
                async {
                    server.write(&down).await.unwrap();
                },
                zip(read_exact(&s2, up.len()), read_exact(&c2, down.len())),
            ),
        )
        .await;
        assert!(got_up == up && got_down == down);
    });
}

#[test]
fn close_notify_ends_one_side_at_a_time() {
    pollster::block_on(async {
        let (_ca, c, s) = simple();
        let (client, server) = connected(&c, &s, "localhost").await;
        client.write(b"last words").await.unwrap();
        client.shutdown().await.unwrap();
        assert_eq!(read_exact(&server, 10).await, b"last words");
        let mut buf = [0; 8];
        assert_eq!(server.read(&mut buf).await.unwrap(), 0, "close_notify is a clean end");
        // The server can still talk; the client can still listen.
        server.write(b"bye").await.unwrap();
        assert_eq!(read_exact(&client, 3).await, b"bye");
        // The client's side is closed for writing.
        assert!(client.write(b"more").await.is_err());
        server.shutdown().await.unwrap();
        assert_eq!(client.read(&mut buf).await.unwrap(), 0);
    });
}

#[test]
fn transport_ending_without_close_notify_is_an_error() {
    pollster::block_on(async {
        let (_ca, c, s) = simple();
        let (client, server) = connected(&c, &s, "localhost").await;
        client.write(b"cut").await.unwrap();
        drop(client);
        assert_eq!(read_exact(&server, 3).await, b"cut");
        let mut buf = [0; 8];
        assert!(matches!(server.read(&mut buf).await, Err(TlsError::UnexpectedEof)));
    });
}

#[test]
fn transport_ending_during_the_handshake_is_an_error() {
    pollster::block_on(async {
        let (_ca, c, _s) = simple();
        let (a, b) = pipe();
        drop(b);
        assert!(matches!(TlsStream::connect(&c, a, "localhost").await, Err(TlsError::UnexpectedEof)));
    });
}

#[test]
fn an_unknown_issuer_is_refused() {
    pollster::block_on(async {
        let trusted = ca("trusted");
        let rogue = ca("rogue");
        let c = client(trusted.roots(), &[]);
        let s = server(vec![rogue.identity(&["localhost"])], &[]);
        let (a, b) = pipe();
        let (cr, sr) = zip(TlsStream::connect(&c, a, "localhost"), TlsStream::accept(&s, b)).await;
        assert!(matches!(cr, Err(TlsError::Certificate(CertProblem::UnknownIssuer))), "{:?}", cr.err());
        assert!(sr.is_err());
    });
}

#[test]
fn a_certificate_for_another_name_is_refused() {
    pollster::block_on(async {
        let (_ca, c, s) = simple();
        let (a, b) = pipe();
        let (cr, _) = zip(TlsStream::connect(&c, a, "example.com"), TlsStream::accept(&s, b)).await;
        assert!(matches!(cr, Err(TlsError::Certificate(CertProblem::NotValidForName))), "{:?}", cr.err());
    });
}

#[test]
fn a_bad_server_name_is_refused_before_any_io() {
    pollster::block_on(async {
        let (_ca, c, _s) = simple();
        let (a, _b) = pipe();
        assert!(matches!(TlsStream::connect(&c, a, "not a name").await, Err(TlsError::InvalidServerName(_))));
    });
}

#[test]
fn client_certificates_can_be_required() {
    pollster::block_on(async {
        let ca = ca("test ca");
        let id = ca.identity(&["localhost"]);
        let s = TlsServer::new(ServerOptions { identities: vec![id], client_auth: ClientAuth::require(ca.roots()), alpn: vec![] }).unwrap();

        // Without one the handshake fails on the server.
        let anon = client(ca.roots(), &[]);
        let (a, b) = pipe();
        let (_, sr) = zip(TlsStream::connect(&anon, a, "localhost"), TlsStream::accept(&s, b)).await;
        assert!(sr.is_err());

        // With one it works and the server sees it.
        let who = TlsClient::new(ClientOptions {
            roots: ca.roots(),
            identity: Some(ca.identity(&["client.test"])),
            alpn: vec![],
            sessions: None,
        })
        .unwrap();
        let (a, b) = pipe();
        let (cr, sr) = zip(TlsStream::connect(&who, a, "localhost"), TlsStream::accept(&s, b)).await;
        cr.unwrap();
        assert_eq!(sr.unwrap().info().peer.len(), 1);
    });
}

#[test]
fn no_common_alpn_protocol_fails() {
    pollster::block_on(async {
        let ca = ca("test ca");
        let c = client(ca.roots(), &["h2"]);
        let s = server(vec![ca.identity(&["localhost"])], &["http/1.1"]);
        let (a, b) = pipe();
        let (cr, sr) = zip(TlsStream::connect(&c, a, "localhost"), TlsStream::accept(&s, b)).await;
        assert!(matches!(sr, Err(TlsError::NoApplicationProtocol)), "{:?}", sr.err());
        assert!(cr.is_err());
    });
}

#[test]
fn the_server_picks_the_identity_for_the_name() {
    pollster::block_on(async {
        let ca = ca("test ca");
        let one = ca.identity(&["one.test"]);
        let two = ca.identity(&["two.test"]);
        let two_der = two.chain[0].as_ref().to_vec();
        let s = server(vec![one, two], &[]);
        let c = client(ca.roots(), &[]);

        let (a, b) = pipe();
        let (cr, sr) = zip(TlsStream::connect(&c, a, "two.test"), TlsStream::accept(&s, b)).await;
        sr.unwrap();
        assert_eq!(cr.unwrap().info().peer[0], two_der);

        // No match: the server answers with its first identity and the client refuses it.
        let (a, b) = pipe();
        let (cr, sr) = zip(TlsStream::connect(&c, a, "three.test"), TlsStream::accept(&s, b)).await;
        assert!(matches!(cr, Err(TlsError::Certificate(CertProblem::NotValidForName))), "{:?}", cr.err());
        assert!(sr.is_err());
    });
}

#[test]
fn a_session_cache_resumes() {
    pollster::block_on(async {
        let ca = ca("test ca");
        let c = TlsClient::new(ClientOptions { roots: ca.roots(), identity: None, alpn: vec![], sessions: Some(TlsSessions::create(8)) })
            .unwrap();
        let s = server(vec![ca.identity(&["localhost"])], &[]);

        let (client, server) = connected(&c, &s, "localhost").await;
        assert!(!client.info().resumed);
        // TLS 1.3 tickets reach the client with the first data it reads.
        server.write(b"hi").await.unwrap();
        assert_eq!(read_exact(&client, 2).await, b"hi");
        drop((client, server));

        let (client, _server) = connected(&c, &s, "localhost").await;
        assert!(client.info().resumed);
    });
}

#[test]
fn without_a_session_cache_nothing_resumes() {
    pollster::block_on(async {
        let (_ca, c, s) = simple();
        let (client, server) = connected(&c, &s, "localhost").await;
        server.write(b"hi").await.unwrap();
        assert_eq!(read_exact(&client, 2).await, b"hi");
        drop((client, server));
        let (client, _server) = connected(&c, &s, "localhost").await;
        assert!(!client.info().resumed);
    });
}

#[test]
fn a_dropped_write_poisons_the_stream() {
    pollster::block_on(async {
        let (_ca, c, s) = simple();
        let (a, b) = pipe();
        let hang = a.hang.clone();
        let (client, _server) = zip(TlsStream::connect(&c, a, "localhost"), TlsStream::accept(&s, b)).await;
        let client = client.unwrap();
        hang.set(true);
        // The write reaches the transport and stays there; dropping it loses the record.
        let mut write = Box::pin(client.write(b"stuck"));
        assert!(poll_once(&mut write).await.is_none());
        drop(write);
        hang.set(false);
        assert!(matches!(client.write(b"again").await, Err(TlsError::Poisoned)));
        // Reading is unaffected.
        assert!(poll_once(async { client.read(&mut [0; 4]).await }).await.is_none());
    });
}

#[test]
fn a_dropped_read_loses_nothing() {
    pollster::block_on(async {
        let (_ca, c, s) = simple();
        let (client, server) = connected(&c, &s, "localhost").await;
        let mut buf = [0; 16];
        {
            let mut read = Box::pin(client.read(&mut buf));
            assert!(poll_once(&mut read).await.is_none());
        }
        server.write(b"after the drop").await.unwrap();
        assert_eq!(read_exact(&client, 14).await, b"after the drop");
    });
}

#[test]
fn pki_values_reject_bad_input() {
    assert!(matches!(RootPki::from_pem(b"nothing here"), Err(TlsError::BadCertificate(_))));
    assert!(matches!(RootPki::from_der::<Vec<u8>>(&[]), Err(TlsError::BadCertificate(_))));
    assert!(matches!(RootPki::from_der(&[vec![1, 2, 3]]), Err(TlsError::BadCertificate(_))));
    assert!(RootPki::bundled().len() > 100);

    let a = ca("a");
    let good = a.identity(&["x.test"]);
    let other_key = KeyPair::generate().unwrap().serialize_pem();
    let cert_pem = {
        let params = CertificateParams::new(vec!["x.test".to_string()]).unwrap();
        let key = KeyPair::generate().unwrap();
        params.signed_by(&key, &a.cert, &a.key).unwrap().pem()
    };
    assert!(matches!(Identity::from_pem(cert_pem.as_bytes(), other_key.as_bytes()), Err(TlsError::BadKey(_))));
    assert!(matches!(Identity::from_pem(b"", b""), Err(TlsError::BadCertificate(_)) | Err(TlsError::BadKey(_))));
    assert!(matches!(
        TlsServer::new(ServerOptions { identities: vec![], client_auth: ClientAuth::none(), alpn: vec![] }),
        Err(TlsError::BadCertificate(_))
    ));
    drop(good);
}

#[test]
fn the_gate_is_first_come_first_served() {
    use crate::gate::Gate;
    pollster::block_on(async {
        let gate = Gate::new();
        let order = RefCell::new(Vec::new());
        let first = gate.lock().await;
        let task = |tag: u8| {
            let (gate, order) = (&gate, &order);
            async move {
                let _guard = gate.lock().await;
                order.borrow_mut().push(tag);
            }
        };
        let mut a = Box::pin(task(1));
        let mut b = Box::pin(task(2));
        assert!(poll_once(&mut a).await.is_none());
        assert!(poll_once(&mut b).await.is_none());
        drop(first);
        zip(a, b).await;
        assert_eq!(*order.borrow(), [1, 2]);
    });
}

#[test]
fn bytes_held_back_while_plaintext_is_full_are_not_lost() {
    pollster::block_on(async {
        let (_ca, c, s) = simple();
        let (client, server) = connected(&c, &s, "localhost").await;
        // A full-size record followed by a tiny one, over and over: one transport read then holds more
        // than rustls' 16 KiB of plaintext, so the rest of it has to wait for the reader.
        let mut expected = Vec::new();
        for round in 0..40u8 {
            let big = vec![round; 16384];
            let small = vec![round.wrapping_add(100); 20];
            client.write(&big).await.unwrap();
            client.write(&small).await.unwrap();
            expected.extend_from_slice(&big);
            expected.extend_from_slice(&small);
        }
        client.shutdown().await.unwrap();
        let mut got = Vec::new();
        let mut buf = vec![0; 16384];
        loop {
            let n = server.read(&mut buf).await.unwrap();
            if n == 0 {
                break;
            }
            got.extend_from_slice(&buf[..n]);
        }
        assert_eq!(got.len(), expected.len());
        assert!(got == expected, "the bytes arrived out of order or damaged");
    });
}
