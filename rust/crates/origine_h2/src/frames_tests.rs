//! Two frame-level sessions back to back, and the frame driver over an in-memory pipe.

use crate::frames::{Category, FrameEvent, FrameOptions, FrameSession, Messaging, SettingId, Settings, StreamState};
use crate::{FieldList, H2Error, Next, Role, frame_connect};

fn settings() -> Settings {
    Settings {
        header_table_size: 4096,
        enable_push: false,
        max_concurrent_streams: 100,
        initial_window_size: 65535,
        max_frame_size: 16384,
        max_header_list_size: 16 * 1024,
        enable_connect_protocol: false,
        no_rfc7540_priorities: false,
    }
}

fn options() -> FrameOptions {
    FrameOptions { settings: settings(), window: 1 << 20, batch: 4096, padding: 0, extensions: vec![0xb0], messaging: Messaging::Http }
}

struct Pair {
    client: FrameSession,
    server: FrameSession,
    c: Vec<FrameEvent>,
    s: Vec<FrameEvent>,
}

impl Pair {
    fn new() -> Pair {
        Pair::with(options(), options())
    }

    fn with(client: FrameOptions, server: FrameOptions) -> Pair {
        Pair {
            client: FrameSession::new(Role::Client, &client).unwrap(),
            server: FrameSession::new(Role::Server, &server).unwrap(),
            c: Vec::new(),
            s: Vec::new(),
        }
    }

    fn pump(&mut self) {
        loop {
            let mut moved = false;
            let mut buf = Vec::new();
            self.client.send(&mut buf).unwrap();
            if !buf.is_empty() {
                moved = true;
                self.server.recv(&buf).unwrap();
            }
            buf.clear();
            self.server.send(&mut buf).unwrap();
            if !buf.is_empty() {
                moved = true;
                self.client.recv(&buf).unwrap();
            }
            while let Some(e) = self.client.next_event() {
                self.c.push(e);
            }
            while let Some(e) = self.server.next_event() {
                self.s.push(e);
            }
            if !moved {
                return;
            }
        }
    }
}

fn list(pairs: &[(&str, &str)]) -> FieldList {
    let mut f = FieldList::new();
    for (n, v) in pairs {
        f.put(n.as_bytes(), v.as_bytes()).unwrap();
    }
    f
}

fn request() -> FieldList {
    list(&[(":method", "POST"), (":scheme", "https"), (":authority", "example.test"), (":path", "/up"), ("x-a", "1"), ("x-a", "2")])
}

#[test]
fn settings_both_ways_with_every_field() {
    let mut p = Pair::new();
    p.pump();
    let got = p.s.iter().find_map(|e| match e {
        FrameEvent::Settings { ack: false, entries } => Some(entries.clone()),
        _ => None,
    });
    assert_eq!(got.unwrap(), settings().entries());
    assert!(p.c.iter().any(|e| matches!(e, FrameEvent::Settings { ack: true, .. })));
    assert_eq!(p.client.remote_settings().max_header_list_size, 16 * 1024);
    // A SETTINGS update any time.
    p.client.settings(&[(SettingId::MaxConcurrentStreams, 7)]).unwrap();
    p.pump();
    assert_eq!(p.server.remote_settings().max_concurrent_streams, 7);
    assert_eq!(p.client.local_settings().max_concurrent_streams, 7);
}

#[test]
fn headers_and_padded_data_with_pseudo_fields_in_order() {
    let mut p = Pair::new();
    p.pump();
    let id = p.client.headers(0, &request(), false, Some(16)).unwrap();
    assert_eq!(id, 1);
    p.client.data(id, b"hello".to_vec(), false, Some(10)).unwrap();
    p.client.data(id, b" world".to_vec(), true, None).unwrap();
    p.pump();
    let head = p.s.iter().find_map(|e| match e {
        FrameEvent::Headers { stream: 1, category: Category::Request, fields, last: true, padding, .. } => Some((fields.clone(), *padding)),
        _ => None,
    });
    let (fields, padding) = head.unwrap();
    let names: Vec<&[u8]> = fields.iter().map(|(n, _)| n).collect();
    assert_eq!(names, [&b":method"[..], b":scheme", b":authority", b":path", b"x-a", b"x-a"]);
    assert!(padding > 0);
    let body: Vec<u8> =
        p.s.iter().filter_map(|e| if let FrameEvent::Data { data, .. } = e { Some(data.clone()) } else { None }).flatten().collect();
    assert_eq!(body, b"hello world");
    assert!(p.s.iter().any(|e| matches!(e, FrameEvent::Data { end_stream: true, .. })));
    assert!(p.s.iter().any(|e| matches!(e, FrameEvent::Data { padding: 10, .. })));
    assert_eq!(p.client.sent(id).0, 11);
    // The server answers with a head, then trailers after DATA that is still queued.
    p.server.headers(1, &list(&[(":status", "200")]), false, None).unwrap();
    p.server.data(1, b"ok".to_vec(), false, None).unwrap();
    p.server.headers(1, &list(&[("x-trailer", "t")]), true, None).unwrap();
    p.pump();
    let blocks: Vec<(Category, bool)> =
        p.c.iter()
            .filter_map(|e| {
                if let FrameEvent::Headers { category, end_stream, last: true, .. } = e { Some((*category, *end_stream)) } else { None }
            })
            .collect();
    assert_eq!(blocks, [(Category::Response, false), (Category::Headers, true)]);
    assert!(p.c.iter().any(|e| matches!(e, FrameEvent::Closed { stream: 1, code: 0 })));
    assert_eq!(p.client.stream_state(1), StreamState::Closed);
}

#[test]
fn control_frames_reach_the_peer() {
    let mut p = Pair::new();
    p.pump();
    let id = p.client.headers(0, &request(), false, None).unwrap();
    // RFC 9218 priorities need the peer's SETTINGS_NO_RFC7540_PRIORITIES.
    assert!(p.client.priority_update(id, b"u=1").is_err());
    p.client.ping(*b"12345678", false).unwrap();
    p.client.window_update(0, 1000).unwrap();
    p.pump();
    assert!(p.s.iter().any(|e| matches!(e, FrameEvent::Ping { data, ack: false } if data == b"12345678")));
    assert!(p.s.iter().any(|e| matches!(e, FrameEvent::WindowUpdate { stream: 0, increment: 1000 })));
    // PINGs are not answered for us.
    assert!(!p.c.iter().any(|e| matches!(e, FrameEvent::Ping { ack: true, .. })));
    p.server.ping(*b"12345678", true).unwrap();
    p.server.altsvc(0, b"https://example.test", b"h3=\":443\"").unwrap();
    p.server.origin(&[b"https://example.test".to_vec(), b"https://other.test".to_vec()]).unwrap();
    p.server.extension(0xb0, 3, 0, b"payload".to_vec()).unwrap();
    p.server.rst(1, 8).unwrap();
    p.pump();
    assert!(p.c.iter().any(|e| matches!(e, FrameEvent::Ping { ack: true, .. })));
    assert!(p.c.iter().any(
        |e| matches!(e, FrameEvent::Altsvc { stream: 0, origin, value } if origin == b"https://example.test" && value == b"h3=\":443\"")
    ));
    assert!(p.c.iter().any(|e| matches!(e, FrameEvent::Origin { origins } if origins.len() == 2)));
    assert!(p.c.iter().any(|e| matches!(e, FrameEvent::Unknown { kind: 0xb0, flags: 3, stream: 0, payload } if payload == b"payload")));
    assert!(p.c.iter().any(|e| matches!(e, FrameEvent::RstStream { stream: 1, code: 8 })));
    assert!(p.c.iter().any(|e| matches!(e, FrameEvent::Closed { stream: 1, code: 8 })));
    p.server.goaway(0, 0, b"bye").unwrap();
    p.pump();
    assert!(p.c.iter().any(|e| matches!(e, FrameEvent::GoAway { last_stream: 0, code: 0, debug } if debug == b"bye")));
}

#[test]
fn priority_update_reaches_a_server_without_rfc7540_priorities() {
    let server = FrameOptions { settings: Settings { no_rfc7540_priorities: true, ..settings() }, ..options() };
    let mut p = Pair::with(options(), server);
    p.pump();
    let id = p.client.headers(0, &request(), false, None).unwrap();
    p.client.priority_update(id, b"u=1, i").unwrap();
    p.pump();
    assert!(p.s.iter().any(|e| matches!(e, FrameEvent::PriorityUpdate { stream: 1, value } if value == b"u=1, i")));
}

#[test]
fn push_promise_and_windows() {
    let client = FrameOptions { settings: Settings { enable_push: true, ..settings() }, ..options() };
    let mut p = Pair::with(client, options());
    p.pump();
    let id = p
        .client
        .headers(0, &list(&[(":method", "GET"), (":scheme", "https"), (":authority", "example.test"), (":path", "/")]), true, None)
        .unwrap();
    p.pump();
    let promised = p
        .server
        .push(id, &list(&[(":method", "GET"), (":scheme", "https"), (":authority", "example.test"), (":path", "/style.css")]))
        .unwrap();
    assert_eq!(promised, 2);
    p.pump();
    assert!(p.c.iter().any(|e| matches!(e, FrameEvent::Headers { stream: 1, category: Category::PushPromise, last: true, .. })));
    assert!(p.c.iter().any(|e| matches!(e, FrameEvent::PushPromise { stream: 1, promised: 2 })));
    assert_eq!(p.client.stream_state(2), StreamState::ReservedRemote);
    let (send, receive) = p.client.windows(0);
    assert!(send >= 65535 && receive >= 65535);
    assert_eq!(p.client.next_stream_id(), 3);
}

#[test]
fn unconsumed_data_holds_the_sender_and_consume_releases_it() {
    let mut p = Pair::new();
    p.pump();
    let id = p.client.headers(0, &request(), false, None).unwrap();
    p.client.data(id, vec![7; 100_000], true, None).unwrap();
    p.pump();
    let got: usize = p.s.iter().map(|e| if let FrameEvent::Data { data, .. } = e { data.len() } else { 0 }).sum();
    assert_eq!(got, 65535);
    p.server.consume(id, got).unwrap();
    p.pump();
    let got: usize = p.s.iter().map(|e| if let FrameEvent::Data { data, .. } = e { data.len() } else { 0 }).sum();
    assert_eq!(got, 100_000);
}

#[test]
fn bad_inputs_are_refused() {
    let mut p = Pair::new();
    assert!(matches!(p.server.headers(0, &request(), true, None), Err(H2Error::InvalidState(_))));
    assert!(matches!(p.client.extension(4, 0, 0, Vec::new()), Err(H2Error::InvalidField(_))));
    assert!(p.client.window_update(0, 0).is_err());
    assert!(p.server.priority_update(1, b"u=1").is_err());
    let bad = FrameOptions { extensions: vec![1], ..options() };
    assert!(FrameSession::new(Role::Client, &bad).is_err());
}

#[test]
fn the_driver_moves_frames_over_a_pipe() {
    use async_executor::LocalExecutor;
    use futures_lite::future::block_on;
    use origine_transport::pipe::pipe;
    let ex = LocalExecutor::new();
    block_on(ex.run(async {
        let (a, b) = pipe();
        let (client, cd) = frame_connect(Role::Client, &options(), a).unwrap();
        let (server, sd) = frame_connect(Role::Server, &options(), b).unwrap();
        let c_task = ex.spawn(cd.run());
        let s_task = ex.spawn(sd.run());
        let id = client.with(|s| s.headers(0, &request(), false, None)).unwrap();
        let sent = client.data(id, vec![1; 70_000], true, None).unwrap();
        let reader = ex.spawn({
            let server = server.clone();
            async move {
                let mut got = 0;
                loop {
                    match server.next().await {
                        Next::Event(FrameEvent::Data { stream, data, end_stream, .. }) => {
                            got += data.len();
                            server.with(|s| s.consume(stream, data.len())).unwrap();
                            if end_stream {
                                return got;
                            }
                        }
                        Next::Event(_) => {}
                        other => panic!("{other:?}"),
                    }
                }
            }
        });
        sent.await.unwrap();
        assert_eq!(reader.await, 70_000);
        // Closing ends the drivers; after the end, `next` answers the end again.
        client.close();
        server.close();
        c_task.await.unwrap();
        s_task.await.unwrap();
        while let Next::Event(_) = client.next().await {}
        assert_eq!(client.next().await, Next::End);
    }));
}
