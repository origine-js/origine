//! The driver over in-memory pipes: two connections and their I/O tasks on one local executor.

use crate::{Body, ConnError, Connection, Exchange, FieldList, H2Error, HeaderKind, Limits, RequestHead, Role, StreamEvent, connect};
use async_executor::LocalExecutor;
use futures_lite::future::block_on;
use origine_transport::Transport;
use origine_transport::pipe::pipe;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

fn limits() -> Limits {
    Limits { streams: 100, headers: 16 * 1024, window: 65535, connection: 1 << 20, batch: 4096 }
}

fn start<T: Transport + 'static>(
    ex: &LocalExecutor<'static>,
    role: Role,
    transport: T,
) -> (Connection, async_executor::Task<Result<(), ConnError>>) {
    let (connection, driver) = connect(role, limits(), transport).unwrap();
    (connection, ex.spawn(driver.run()))
}

fn head(path: &str) -> RequestHead<'_> {
    RequestHead { method: "GET", scheme: "https", authority: "example.test", path }
}

/// Reads a stream to its end; returns (status or method path, body, terminal code).
struct Seen {
    pseudo_path: Option<String>,
    status: Option<u16>,
    body: Vec<u8>,
    closed: Option<u32>,
    aborted: Option<ConnError>,
    trailers: Option<FieldList>,
}

async fn drain(ex: &Exchange) -> Seen {
    let mut seen = Seen { pseudo_path: None, status: None, body: Vec::new(), closed: None, aborted: None, trailers: None };
    while let Some(event) = ex.next().await {
        match event {
            StreamEvent::Headers { kind: HeaderKind::Trailers, fields, .. } => seen.trailers = Some(fields),
            StreamEvent::Headers { pseudo, .. } => {
                seen.pseudo_path = seen.pseudo_path.or(pseudo.path);
                seen.status = seen.status.or(pseudo.status);
            }
            StreamEvent::Data(data) => {
                ex.consume(data.len());
                seen.body.extend(data);
            }
            StreamEvent::End => {}
            StreamEvent::Closed(code) => seen.closed = Some(code),
            StreamEvent::Aborted(e) => seen.aborted = Some(e),
        }
    }
    seen
}

/// A server that answers every request with `200` and a body made by `make(path, request_body)`.
fn serve(ex: &Rc<LocalExecutor<'static>>, server: Connection, make: impl Fn(&str, &[u8]) -> Vec<u8> + 'static) {
    let make = Rc::new(make);
    let spawner = ex.clone();
    ex.spawn(async move {
        while let Some(exchange) = server.accept().await {
            let make = make.clone();
            spawner
                .spawn(async move {
                    let seen = read_request(&exchange).await;
                    let body = make(seen.pseudo_path.as_deref().unwrap_or(""), &seen.body);
                    exchange.respond(200, &FieldList::new(), Body::Stream).unwrap();
                    exchange.send(body).await.unwrap();
                    exchange.finish(None).unwrap();
                })
                .detach();
        }
    })
    .detach();
}

/// Reads until the request is complete (`End`, or a head/trailers with `end_stream`).
async fn read_request(ex: &Exchange) -> Seen {
    let mut seen = Seen { pseudo_path: None, status: None, body: Vec::new(), closed: None, aborted: None, trailers: None };
    while let Some(event) = ex.next().await {
        match event {
            StreamEvent::Headers { kind: HeaderKind::Trailers, fields, end_stream, .. } => {
                seen.trailers = Some(fields);
                if end_stream {
                    break;
                }
            }
            StreamEvent::Headers { pseudo, end_stream, .. } => {
                seen.pseudo_path = seen.pseudo_path.or(pseudo.path);
                if end_stream {
                    break;
                }
            }
            StreamEvent::Data(data) => {
                ex.consume(data.len());
                seen.body.extend(data);
            }
            StreamEvent::End => break,
            StreamEvent::Closed(code) => {
                seen.closed = Some(code);
                break;
            }
            StreamEvent::Aborted(e) => {
                seen.aborted = Some(e);
                break;
            }
        }
    }
    seen
}

fn run<F: std::future::Future>(f: impl FnOnce(Rc<LocalExecutor<'static>>) -> F) -> F::Output {
    let ex = Rc::new(LocalExecutor::new());
    let fut = f(ex.clone());
    block_on(ex.run(fut))
}

#[test]
fn a_request_and_a_response() {
    run(|ex| async move {
        let (c, s) = pipe();
        let (client, _cd) = start(&ex, Role::Client, c);
        let (server, _sd) = start(&ex, Role::Server, s);
        serve(&ex, server, |path, _| format!("you asked for {path}").into_bytes());

        client.ready().await.unwrap();
        let exchange = client.open(&head("/hello"), &FieldList::new(), Body::None).unwrap();
        let seen = drain(&exchange).await;
        assert_eq!((seen.status, seen.closed), (Some(200), Some(0)));
        assert_eq!(seen.body, b"you asked for /hello");
    });
}

#[test]
fn a_big_upload_is_throttled_by_the_peer() {
    run(|ex| async move {
        let (c, s) = pipe();
        let (client, _cd) = start(&ex, Role::Client, c);
        let (server, _sd) = start(&ex, Role::Server, s);
        serve(&ex, server, |_, body| format!("got {} bytes, sum {}", body.len(), body.iter().map(|&b| b as u64).sum::<u64>()).into_bytes());

        client.ready().await.unwrap();
        let post = RequestHead { method: "POST", ..head("/upload") };
        let exchange = client.open(&post, &FieldList::new(), Body::Stream).unwrap();
        let chunk: Vec<u8> = (0..16 * 1024).map(|i| (i % 7) as u8).collect();
        let (n, mut worst) = (64, 0);
        for _ in 0..n {
            exchange.send(chunk.clone()).await.unwrap();
            worst = worst.max(exchange.queued());
        }
        exchange.finish(None).unwrap();
        // The writer never ran far ahead of the peer: at most the window plus the chunk it was admitted with.
        assert!(worst <= 65535 + chunk.len(), "queued up to {worst}");
        let seen = drain(&exchange).await;
        let sum: u64 = chunk.iter().map(|&b| b as u64).sum::<u64>() * n as u64;
        assert_eq!(String::from_utf8(seen.body).unwrap(), format!("got {} bytes, sum {sum}", chunk.len() * n));
    });
}

#[test]
fn many_requests_share_one_connection() {
    run(|ex| async move {
        let (c, s) = pipe();
        let (client, _cd) = start(&ex, Role::Client, c);
        let (server, _sd) = start(&ex, Role::Server, s);
        serve(&ex, server, |path, _| path.as_bytes().repeat(100));

        client.ready().await.unwrap();
        let done = Rc::new(Cell::new(0));
        let tasks: Vec<_> = (0..60)
            .map(|i| {
                let (client, done) = (client.clone(), done.clone());
                ex.spawn(async move {
                    let path = format!("/item/{i}");
                    let exchange = client.open(&head(&path), &FieldList::new(), Body::None).unwrap();
                    let seen = drain(&exchange).await;
                    assert_eq!(seen.body, path.as_bytes().repeat(100));
                    done.set(done.get() + 1);
                })
            })
            .collect();
        for t in tasks {
            t.await;
        }
        assert_eq!(done.get(), 60);
    });
}

#[test]
fn trailers_arrive_after_the_body() {
    run(|ex| async move {
        let (c, s) = pipe();
        let (client, _cd) = start(&ex, Role::Client, c);
        let (server, _sd) = start(&ex, Role::Server, s);
        ex.spawn(async move {
            let exchange = server.accept().await.unwrap();
            read_request(&exchange).await;
            exchange.respond(200, &FieldList::new(), Body::Stream).unwrap();
            exchange.send(b"body".to_vec()).await.unwrap();
            let mut trailers = FieldList::new();
            trailers.put(b"x-done", b"yes").unwrap();
            exchange.finish(Some(trailers)).unwrap();
        })
        .detach();

        client.ready().await.unwrap();
        let exchange = client.open(&head("/"), &FieldList::new(), Body::None).unwrap();
        let seen = drain(&exchange).await;
        assert_eq!(seen.body, b"body");
        assert_eq!(seen.trailers.unwrap().get("x-done"), Some(&b"yes"[..]));
    });
}

#[test]
fn ping_measures_a_round_trip() {
    run(|ex| async move {
        let (c, s) = pipe();
        let (client, _cd) = start(&ex, Role::Client, c);
        let (_server, _sd) = start(&ex, Role::Server, s);
        client.ready().await.unwrap();
        client.ping().await.unwrap();
    });
}

#[test]
fn a_graceful_close_ends_both_drivers() {
    run(|ex| async move {
        let (c, s) = pipe();
        let (client, cd) = start(&ex, Role::Client, c);
        let (server, sd) = start(&ex, Role::Server, s);
        serve(&ex, server.clone(), |_, _| b"ok".to_vec());
        client.ready().await.unwrap();
        let exchange = client.open(&head("/"), &FieldList::new(), Body::None).unwrap();
        assert_eq!(drain(&exchange).await.body, b"ok");
        drop(exchange);

        server.close();
        assert_eq!(sd.await, Ok(()));
        assert_eq!(cd.await, Ok(()));
        assert!(client.open(&head("/again"), &FieldList::new(), Body::None).is_err());
        assert!(server.accept().await.is_none());
    });
}

#[test]
fn a_lost_transport_aborts_open_streams() {
    run(|ex| async move {
        let (c, s) = pipe();
        let (client, cd) = start(&ex, Role::Client, c);
        let (server, sd) = start(&ex, Role::Server, s);
        client.ready().await.unwrap();
        let exchange = client.open(&head("/never-answered"), &FieldList::new(), Body::None).unwrap();
        // The server accepts, then its whole side disappears.
        let accepted = server.accept().await.unwrap();
        drop(accepted);
        drop(sd); // cancels the server's driver task, dropping its end of the pipe
        drop(server);
        let seen = drain(&exchange).await;
        assert!(matches!(seen.aborted, Some(ConnError::Transport(..))), "{:?}", seen.aborted);
        assert!(matches!(cd.await, Err(ConnError::Transport(..))));
        assert!(matches!(client.error(), Some(ConnError::Transport(..))));
    });
}

#[test]
fn dropping_an_unfinished_upload_cancels_it_but_a_finished_one_is_left_alone() {
    run(|ex| async move {
        let (c, s) = pipe();
        let (client, _cd) = start(&ex, Role::Client, c);
        let (server, _sd) = start(&ex, Role::Server, s);
        let codes = Rc::new(RefCell::new(Vec::new()));
        let log = codes.clone();
        ex.spawn(async move {
            while let Some(exchange) = server.accept().await {
                let log = log.clone();
                let path = RefCell::new(String::new());
                // Collect until the stream closes, whatever the reason.
                while let Some(event) = exchange.next().await {
                    match event {
                        StreamEvent::Headers { pseudo, .. } => {
                            if let Some(p) = pseudo.path {
                                *path.borrow_mut() = p;
                            }
                        }
                        StreamEvent::Data(d) => exchange.consume(d.len()),
                        StreamEvent::Closed(code) => log.borrow_mut().push((path.borrow().clone(), code)),
                        _ => {}
                    }
                    if path.borrow().as_str() == "/done" {
                        // A request that ended normally: answer so the stream can close.
                        let _ = exchange.respond(204, &FieldList::new(), Body::None);
                    }
                }
            }
        })
        .detach();

        client.ready().await.unwrap();
        let post = RequestHead { method: "POST", ..head("/cut") };
        let unfinished = client.open(&post, &FieldList::new(), Body::Stream).unwrap();
        unfinished.send(b"half a body".to_vec()).await.unwrap();
        // Let the head and the bytes reach the server first: a stream cancelled before anything was sent
        // simply never exists on the wire.
        client.ping().await.unwrap();
        drop(unfinished);

        let finished = client.open(&RequestHead { method: "POST", ..head("/done") }, &FieldList::new(), Body::Stream).unwrap();
        finished.send(b"whole body".to_vec()).await.unwrap();
        finished.finish(None).unwrap();
        let seen = drain(&finished).await;
        assert_eq!(seen.status, Some(204));

        client.ping().await.unwrap();
        // The server's task logs when it gets to the event; give it a few turns.
        for _ in 0..50 {
            if codes.borrow().len() >= 2 {
                break;
            }
            futures_lite::future::yield_now().await;
        }
        let log = codes.borrow();
        assert!(log.contains(&("/cut".to_string(), 8)), "{log:?}");
        assert!(log.contains(&("/done".to_string(), 0)), "{log:?}");
    });
}

#[test]
fn garbage_from_a_client_ends_the_server_with_a_protocol_error() {
    run(|ex| async move {
        let (raw, s) = pipe();
        let (_server, sd) = start(&ex, Role::Server, s);
        let (result, _) = raw.write_all(b"GET / HTTP/1.1\r\nhost: example.test\r\n\r\n".to_vec()).await;
        result.unwrap();
        assert_eq!(sd.await, Err(ConnError::Protocol(H2Error::BadPreface)));
    });
}

#[test]
fn http2_over_tls_over_a_pipe() {
    use origine_tls::{ClientAuth, ClientOptions, Identity, RootPki, ServerOptions, TlsClient, TlsServer, TlsStream};
    use rcgen::{BasicConstraints, CertificateParams, DnType, IsCa, KeyPair};

    let mut ca_params = CertificateParams::new(Vec::<String>::new()).unwrap();
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    ca_params.distinguished_name.push(DnType::CommonName, "test ca");
    let ca_key = KeyPair::generate().unwrap();
    let ca = ca_params.self_signed(&ca_key).unwrap();
    let leaf_key = KeyPair::generate().unwrap();
    let leaf = CertificateParams::new(vec!["localhost".to_string()]).unwrap().signed_by(&leaf_key, &ca, &ca_key).unwrap();
    let identity = Identity::from_pem(leaf.pem().as_bytes(), leaf_key.serialize_pem().as_bytes()).unwrap();
    let tls_client = TlsClient::new(ClientOptions {
        roots: RootPki::from_pem(ca.pem().as_bytes()).unwrap(),
        identity: None,
        alpn: vec!["h2".into()],
        sessions: None,
    })
    .unwrap();
    let tls_server =
        TlsServer::new(ServerOptions { identities: vec![identity], client_auth: ClientAuth::none(), alpn: vec!["h2".into()] }).unwrap();

    run(|ex| async move {
        let (c, s) = pipe();
        let (secure_client, secure_server) =
            futures_lite::future::zip(TlsStream::connect(&tls_client, c, "localhost"), TlsStream::accept(&tls_server, s)).await;
        let (secure_client, secure_server) = (secure_client.unwrap(), secure_server.unwrap());
        assert_eq!(secure_client.info().alpn.as_deref(), Some("h2"));

        let (client, _cd) = start(&ex, Role::Client, secure_client);
        let (server, _sd) = start(&ex, Role::Server, secure_server);
        serve(&ex, server, |path, _| format!("secure {path}").into_bytes());
        client.ready().await.unwrap();
        let exchange = client.open(&head("/tls"), &FieldList::new(), Body::None).unwrap();
        let seen = drain(&exchange).await;
        assert_eq!((seen.status, seen.body), (Some(200), b"secure /tls".to_vec()));
    });
}

#[test]
fn a_big_upload_over_tls_over_a_pipe() {
    use origine_tls::{ClientAuth, ClientOptions, Identity, RootPki, ServerOptions, TlsClient, TlsServer, TlsStream};
    use rcgen::{BasicConstraints, CertificateParams, DnType, IsCa, KeyPair};

    let mut ca_params = CertificateParams::new(Vec::<String>::new()).unwrap();
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    ca_params.distinguished_name.push(DnType::CommonName, "test ca");
    let ca_key = KeyPair::generate().unwrap();
    let ca = ca_params.self_signed(&ca_key).unwrap();
    let leaf_key = KeyPair::generate().unwrap();
    let leaf = CertificateParams::new(vec!["localhost".to_string()]).unwrap().signed_by(&leaf_key, &ca, &ca_key).unwrap();
    let identity = Identity::from_pem(leaf.pem().as_bytes(), leaf_key.serialize_pem().as_bytes()).unwrap();
    let tls_client = TlsClient::new(ClientOptions {
        roots: RootPki::from_pem(ca.pem().as_bytes()).unwrap(),
        identity: None,
        alpn: vec!["h2".into()],
        sessions: None,
    })
    .unwrap();
    let tls_server =
        TlsServer::new(ServerOptions { identities: vec![identity], client_auth: ClientAuth::none(), alpn: vec!["h2".into()] }).unwrap();

    run(|ex| async move {
        let (c, s) = pipe();
        let (secure_client, secure_server) =
            futures_lite::future::zip(TlsStream::connect(&tls_client, c, "localhost"), TlsStream::accept(&tls_server, s)).await;
        let (client, _cd) = start(&ex, Role::Client, secure_client.unwrap());
        let (server, _sd) = start(&ex, Role::Server, secure_server.unwrap());
        serve(&ex, server, |_, body| format!("got {}", body.len()).into_bytes());
        client.ready().await.unwrap();
        let post = RequestHead { method: "POST", ..head("/big") };
        let exchange = client.open(&post, &FieldList::new(), Body::Stream).unwrap();
        for i in 0..20u8 {
            exchange.send(vec![i; 32768]).await.unwrap();
        }
        exchange.finish(None).unwrap();
        let seen = drain(&exchange).await;
        assert_eq!(String::from_utf8(seen.body).unwrap(), format!("got {}", 20 * 32768), "{:?}", seen.aborted);
    });
}

/// A transport that behaves like a socket under load: reads return odd-sized pieces, writes go out in pieces
/// with a turn given to other tasks in between.
struct Trickle<T> {
    inner: T,
    seed: Cell<u32>,
}

impl<T: Transport> Transport for Trickle<T> {
    async fn read(&self, mut buf: Vec<u8>) -> (std::io::Result<usize>, Vec<u8>) {
        let seed = self.seed.get().wrapping_mul(1664525).wrapping_add(1013904223);
        self.seed.set(seed);
        let cap = 1 + (seed >> 16) as usize % 5000;
        buf.truncate(cap.min(buf.len()));
        let (result, mut back) = self.inner.read(buf).await;
        back.resize(16 * 1024, 0);
        (result, back)
    }

    async fn write_all(&self, buf: Vec<u8>) -> (std::io::Result<()>, Vec<u8>) {
        for piece in buf.chunks(3000) {
            let (result, _) = self.inner.write_all(piece.to_vec()).await;
            if let Err(e) = result {
                return (Err(e), buf);
            }
            futures_lite::future::yield_now().await;
        }
        (Ok(()), buf)
    }
}

#[test]
fn a_big_upload_over_tls_over_a_trickling_transport() {
    use origine_tls::{ClientAuth, ClientOptions, Identity, RootPki, ServerOptions, TlsClient, TlsServer, TlsStream};
    use rcgen::{BasicConstraints, CertificateParams, DnType, IsCa, KeyPair};

    let mut ca_params = CertificateParams::new(Vec::<String>::new()).unwrap();
    ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    ca_params.distinguished_name.push(DnType::CommonName, "test ca");
    let ca_key = KeyPair::generate().unwrap();
    let ca = ca_params.self_signed(&ca_key).unwrap();
    let leaf_key = KeyPair::generate().unwrap();
    let leaf = CertificateParams::new(vec!["localhost".to_string()]).unwrap().signed_by(&leaf_key, &ca, &ca_key).unwrap();
    let identity = Identity::from_pem(leaf.pem().as_bytes(), leaf_key.serialize_pem().as_bytes()).unwrap();
    let tls_client = TlsClient::new(ClientOptions {
        roots: RootPki::from_pem(ca.pem().as_bytes()).unwrap(),
        identity: None,
        alpn: vec!["h2".into()],
        sessions: None,
    })
    .unwrap();
    let tls_server =
        TlsServer::new(ServerOptions { identities: vec![identity], client_auth: ClientAuth::none(), alpn: vec!["h2".into()] }).unwrap();

    run(|ex| async move {
        let (c, s) = pipe();
        let (c, s) = (Trickle { inner: c, seed: Cell::new(1) }, Trickle { inner: s, seed: Cell::new(99) });
        let (secure_client, secure_server) =
            futures_lite::future::zip(TlsStream::connect(&tls_client, c, "localhost"), TlsStream::accept(&tls_server, s)).await;
        let (client, _cd) = start(&ex, Role::Client, secure_client.unwrap());
        let (server, _sd) = start(&ex, Role::Server, secure_server.unwrap());
        serve(&ex, server, |_, body| format!("got {}", body.len()).into_bytes());
        client.ready().await.unwrap();
        let post = RequestHead { method: "POST", ..head("/big") };
        let exchange = client.open(&post, &FieldList::new(), Body::Stream).unwrap();
        for i in 0..20u8 {
            exchange.send(vec![i; 32768]).await.unwrap();
        }
        exchange.finish(None).unwrap();
        let seen = drain(&exchange).await;
        assert_eq!(String::from_utf8(seen.body).unwrap(), format!("got {}", 20 * 32768), "{:?}", seen.aborted);
    });
}
