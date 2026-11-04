//! Two sessions wired back to back: whatever one sends, the other receives. No sockets, no loop.

use crate::{Body, Event, FieldList, H2Error, HeaderKind, Limits, RequestHead, Role, Session};

const CANCEL: u32 = 8;
const ENHANCE_YOUR_CALM: u32 = 11;

fn limits() -> Limits {
    Limits { streams: 100, headers: 16 * 1024, window: 65535, connection: 1 << 20, batch: 4096 }
}

struct Pair {
    client: Session,
    server: Session,
    c_events: Vec<Event>,
    s_events: Vec<Event>,
    /// Hand received data back at once (the common case); flow-control tests turn it off.
    server_consumes: bool,
}

impl Pair {
    fn new() -> Pair {
        Pair::with(limits(), limits())
    }

    fn with(client: Limits, server: Limits) -> Pair {
        Pair {
            client: Session::new(Role::Client, client).unwrap(),
            server: Session::new(Role::Server, server).unwrap(),
            c_events: Vec::new(),
            s_events: Vec::new(),
            server_consumes: true,
        }
    }

    /// Moves bytes both ways until nothing is left to move.
    fn try_pump(&mut self) -> Result<(), (Role, H2Error)> {
        loop {
            let mut moved = false;
            let mut buf = Vec::new();
            self.client.send(&mut buf).map_err(|e| (Role::Client, e))?;
            if !buf.is_empty() {
                moved = true;
                self.server.recv(&buf).map_err(|e| (Role::Server, e))?;
            }
            buf.clear();
            self.server.send(&mut buf).map_err(|e| (Role::Server, e))?;
            if !buf.is_empty() {
                moved = true;
                self.client.recv(&buf).map_err(|e| (Role::Client, e))?;
            }
            while let Some(event) = self.client.next_event() {
                if let Event::Data { stream, data } = &event {
                    self.client.consume(*stream, data.len()).unwrap();
                }
                self.c_events.push(event);
            }
            while let Some(event) = self.server.next_event() {
                if let (Event::Data { stream, data }, true) = (&event, self.server_consumes) {
                    self.server.consume(*stream, data.len()).unwrap();
                }
                self.s_events.push(event);
            }
            if !moved {
                return Ok(());
            }
        }
    }

    fn pump(&mut self) {
        if let Err(e) = self.try_pump() {
            panic!("pump failed: {e:?}");
        }
    }
}

fn fields(pairs: &[(&str, &str)]) -> FieldList {
    let mut list = FieldList::new();
    for (n, v) in pairs {
        list.put(n.as_bytes(), v.as_bytes()).unwrap();
    }
    list
}

fn get(path: &str) -> RequestHead<'_> {
    RequestHead { method: "GET", scheme: "https", authority: "example.test", path }
}

fn post(path: &str) -> RequestHead<'_> {
    RequestHead { method: "POST", scheme: "https", authority: "example.test", path }
}

fn body_of(events: &[Event], id: u32) -> Vec<u8> {
    events
        .iter()
        .filter_map(|e| if let Event::Data { stream, data } = e { (*stream == id).then_some(data.clone()) } else { None })
        .flatten()
        .collect()
}

fn heads(events: &[Event], id: u32) -> Vec<&Event> {
    events.iter().filter(|e| matches!(e, Event::Headers { stream, .. } if *stream == id)).collect()
}

fn closed(events: &[Event], id: u32) -> Option<u32> {
    events.iter().find_map(|e| if let Event::Closed { stream, code } = e { (*stream == id).then_some(*code) } else { None })
}

#[test]
fn a_request_and_its_response() {
    let mut p = Pair::new();
    let mut f = fields(&[("accept", "*/*")]);
    f.put(b"x-dup", b"1").unwrap();
    f.put(b"x-dup", b"2").unwrap();
    let id = p.client.submit_request(&get("/a?b=1"), &f, Body::None).unwrap();
    p.pump();

    assert!(p.s_events.contains(&Event::Settings));
    assert!(p.c_events.contains(&Event::Settings));
    let seen = heads(&p.s_events, id);
    assert_eq!(seen.len(), 1);
    let Event::Headers { kind, pseudo, fields, last, end_stream, .. } = seen[0] else { unreachable!() };
    assert_eq!((*kind, *last, *end_stream), (HeaderKind::Request, true, true));
    assert_eq!(pseudo.method.as_deref(), Some("GET"));
    assert_eq!(pseudo.scheme.as_deref(), Some("https"));
    assert_eq!(pseudo.authority.as_deref(), Some("example.test"));
    assert_eq!(pseudo.path.as_deref(), Some("/a?b=1"));
    assert_eq!(fields.get("accept"), Some(&b"*/*"[..]));
    assert_eq!(fields.get_all("x-dup").collect::<Vec<_>>(), [&b"1"[..], &b"2"[..]]);

    p.server.submit_response(id, 200, &fields_of("content-type", "text/plain"), Body::Stream).unwrap();
    p.server.send_data(id, b"hello ".to_vec()).unwrap();
    p.server.send_data(id, b"world".to_vec()).unwrap();
    p.server.finish(id, None).unwrap();
    p.pump();

    let seen = heads(&p.c_events, id);
    let Event::Headers { kind, pseudo, fields, end_stream, .. } = seen[0] else { unreachable!() };
    assert_eq!((*kind, pseudo.status, *end_stream), (HeaderKind::Response, Some(200), false));
    assert_eq!(fields.get("content-type"), Some(&b"text/plain"[..]));
    assert_eq!(body_of(&p.c_events, id), b"hello world");
    assert!(p.c_events.contains(&Event::End { stream: id }));
    assert_eq!(closed(&p.c_events, id), Some(0));
    assert_eq!(closed(&p.s_events, id), Some(0));
}

fn fields_of(name: &str, value: &str) -> FieldList {
    fields(&[(name, value)])
}

#[test]
fn a_response_can_be_just_a_head() {
    let mut p = Pair::new();
    let id = p.client.submit_request(&get("/"), &FieldList::new(), Body::None).unwrap();
    p.pump();
    p.server.submit_response(id, 204, &FieldList::new(), Body::None).unwrap();
    p.pump();
    let seen = heads(&p.c_events, id);
    let Event::Headers { pseudo, end_stream, .. } = seen[0] else { unreachable!() };
    assert_eq!((pseudo.status, *end_stream), (Some(204), true));
    assert_eq!(closed(&p.c_events, id), Some(0));
}

#[test]
fn a_streamed_request_body_with_trailers() {
    let mut p = Pair::new();
    let id = p.client.submit_request(&post("/upload"), &fields_of("content-type", "application/octet-stream"), Body::Stream).unwrap();
    p.client.send_data(id, b"part one, ".to_vec()).unwrap();
    p.pump();
    p.client.send_data(id, b"part two".to_vec()).unwrap();
    p.client.finish(id, Some(fields_of("x-checksum", "abc123"))).unwrap();
    p.pump();

    assert_eq!(body_of(&p.s_events, id), b"part one, part two");
    let seen = heads(&p.s_events, id);
    assert_eq!(seen.len(), 2);
    let Event::Headers { kind: first, end_stream: first_end, .. } = seen[0] else { unreachable!() };
    assert_eq!((*first, *first_end), (HeaderKind::Request, false));
    let Event::Headers { kind, fields, end_stream, .. } = seen[1] else { unreachable!() };
    assert_eq!((*kind, *end_stream), (HeaderKind::Trailers, true));
    assert_eq!(fields.get("x-checksum"), Some(&b"abc123"[..]));

    p.server.submit_response(id, 201, &FieldList::new(), Body::Stream).unwrap();
    p.server.finish(id, Some(fields_of("x-server-timing", "db;dur=5"))).unwrap();
    p.pump();
    let seen = heads(&p.c_events, id);
    assert_eq!(seen.len(), 2);
    let Event::Headers { kind, fields, .. } = seen[1] else { unreachable!() };
    assert_eq!(*kind, HeaderKind::Trailers);
    assert_eq!(fields.get("x-server-timing"), Some(&b"db;dur=5"[..]));
}

#[test]
fn unconsumed_data_holds_the_sender_back() {
    let server = Limits { window: 1000, ..limits() };
    let mut p = Pair::with(limits(), server);
    p.server_consumes = false;
    // Until the server's SETTINGS arrive the client may use the default 65535-byte window.
    p.pump();
    let id = p.client.submit_request(&post("/big"), &FieldList::new(), Body::Stream).unwrap();
    p.client.send_data(id, vec![7; 10_000]).unwrap();
    p.pump();

    let got = body_of(&p.s_events, id).len();
    assert!(got > 0 && got <= 1000, "the peer's window is 1000, got {got}");
    assert!(p.client.queued(id) >= 10_000 - 1000, "the rest waits in the sender: {}", p.client.queued(id));

    // Using the data opens the window again, a window's worth at a time.
    let mut total = got;
    let mut rounds = 0;
    while total < 10_000 {
        p.server.consume(id, total).unwrap_or(());
        p.server.consume(id, usize::MAX).unwrap();
        p.pump();
        total = body_of(&p.s_events, id).len();
        rounds += 1;
        assert!(rounds < 100, "stalled at {total}");
    }
    assert_eq!(total, 10_000);
    assert_eq!(p.client.queued(id), 0);
}

#[test]
fn a_closed_stream_returns_its_unread_bytes_to_the_connection() {
    // The connection window is as small as it can be; two streams of 60 000 bytes only get through
    // if the first stream's unread bytes are handed back when it is reset.
    let server = Limits { connection: 65535, ..limits() };
    let mut p = Pair::with(limits(), server);
    p.server_consumes = false;
    p.pump();
    let first = p.client.submit_request(&post("/a"), &FieldList::new(), Body::Stream).unwrap();
    p.client.send_data(first, vec![1; 60_000]).unwrap();
    p.pump();
    assert_eq!(body_of(&p.s_events, first).len(), 60_000);
    p.client.reset(first, CANCEL).unwrap();
    p.pump();
    assert_eq!(closed(&p.s_events, first), Some(CANCEL));

    let second = p.client.submit_request(&post("/b"), &FieldList::new(), Body::Stream).unwrap();
    p.client.send_data(second, vec![2; 60_000]).unwrap();
    p.pump();
    assert_eq!(body_of(&p.s_events, second).len(), 60_000);
}

#[test]
fn a_big_header_block_arrives_in_batches() {
    let server = Limits { batch: 2048, headers: 64 * 1024, ..limits() };
    let mut p = Pair::with(limits(), server);
    let mut f = FieldList::new();
    for i in 0..300 {
        f.put(format!("x-field-{i:03}").as_bytes(), format!("value number {i} {}", "v".repeat(20)).as_bytes()).unwrap();
    }
    let id = p.client.submit_request(&get("/"), &f, Body::None).unwrap();
    p.pump();

    let seen = heads(&p.s_events, id);
    assert!(seen.len() >= 4, "{} batches", seen.len());
    let mut names = Vec::new();
    for (i, event) in seen.iter().enumerate() {
        let Event::Headers { pseudo, fields, last, end_stream, .. } = event else { unreachable!() };
        assert_eq!(*last, i == seen.len() - 1);
        assert_eq!(*end_stream, *last);
        assert_eq!(pseudo.method.is_some(), i == 0, "pseudo headers come with the first batch only");
        names.extend(fields.iter().map(|(n, _)| String::from_utf8_lossy(n).into_owned()));
    }
    let expected: Vec<String> = (0..300).map(|i| format!("x-field-{i:03}")).collect();
    assert_eq!(names, expected);
}

#[test]
fn a_header_block_over_the_limit_resets_the_stream() {
    let server = Limits { headers: 1024, ..limits() };
    let mut p = Pair::with(limits(), server);
    let mut f = FieldList::new();
    for i in 0..40 {
        f.put(format!("x-{i}").as_bytes(), "y".repeat(100).as_bytes()).unwrap();
    }
    let id = p.client.submit_request(&get("/"), &f, Body::None).unwrap();
    // Either nghttp2 refuses to send it or the server resets the stream; both are the limit working.
    match p.try_pump() {
        Ok(()) => assert_eq!(closed(&p.c_events, id), Some(ENHANCE_YOUR_CALM)),
        Err((_, e)) => assert!(matches!(e, H2Error::Library(..)), "{e:?}"),
    }
    assert!(!p.s_events.iter().any(|e| matches!(e, Event::Headers { stream, last: true, .. } if *stream == id)));
}

#[test]
fn a_reset_ends_the_stream_on_both_sides() {
    let mut p = Pair::new();
    let id = p.client.submit_request(&post("/slow"), &FieldList::new(), Body::Stream).unwrap();
    p.client.send_data(id, b"some".to_vec()).unwrap();
    p.pump();
    p.client.reset(id, CANCEL).unwrap();
    p.pump();
    assert_eq!(closed(&p.s_events, id), Some(CANCEL));
    assert_eq!(closed(&p.c_events, id), Some(CANCEL));
    assert!(matches!(p.client.send_data(id, b"more".to_vec()), Err(H2Error::InvalidState(_))));
}

#[test]
fn goaway_and_ping_reach_the_peer() {
    let mut p = Pair::new();
    p.pump();
    p.client.ping([1, 2, 3, 4, 5, 6, 7, 8]).unwrap();
    p.pump();
    assert!(p.c_events.contains(&Event::PingAck { data: [1, 2, 3, 4, 5, 6, 7, 8] }));
    p.client.goaway(0).unwrap();
    p.pump();
    assert!(p.s_events.iter().any(|e| matches!(e, Event::GoAway { code: 0, .. })));
}

#[test]
fn requests_over_the_concurrency_limit_wait_their_turn() {
    let server = Limits { streams: 2, ..limits() };
    let mut p = Pair::with(limits(), server);
    // A client that has not seen the server's SETTINGS yet may overshoot the limit and get
    // REFUSED_STREAM; wait for them, as the driver above this crate does.
    p.pump();
    let ids: Vec<u32> = (0..5).map(|i| p.client.submit_request(&get(&format!("/{i}")), &FieldList::new(), Body::None).unwrap()).collect();
    let mut answered = Vec::new();
    for _ in 0..20 {
        p.pump();
        let waiting: Vec<u32> = p
            .s_events
            .iter()
            .filter_map(|e| if let Event::Headers { stream, kind: HeaderKind::Request, .. } = e { Some(*stream) } else { None })
            .filter(|id| !answered.contains(id))
            .collect();
        assert!(waiting.len() <= 2, "more than the limit in flight: {waiting:?}");
        for id in waiting {
            p.server.submit_response(id, 200, &FieldList::new(), Body::None).unwrap();
            answered.push(id);
        }
        if ids.iter().all(|id| closed(&p.c_events, *id).is_some()) {
            break;
        }
    }
    assert!(ids.iter().all(|id| closed(&p.c_events, *id) == Some(0)), "{:?}", p.c_events);
}

#[test]
fn http_one_is_not_a_preface() {
    let mut server = Session::new(Role::Server, limits()).unwrap();
    let err = server.recv(b"GET / HTTP/1.1\r\nhost: example.test\r\n\r\n").unwrap_err();
    assert_eq!(err, H2Error::BadPreface);
}

#[test]
fn fields_are_checked_when_they_are_put() {
    let mut f = FieldList::new();
    for bad in
        [&b"Content-Type"[..], b"", b":", b":Path", b"connection", b"keep-alive", b"transfer-encoding", b"upgrade", b"has space", b"te"]
    {
        assert!(matches!(f.put(bad, b"x"), Err(H2Error::InvalidField(_))), "{:?}", String::from_utf8_lossy(bad));
    }
    assert!(f.put(b"te", b"gzip").is_err());
    f.put(b"te", b"trailers").unwrap();
    assert!(f.put(b"x", b"line\nbreak").is_err());
    assert!(f.put(b"x", b"nul\0").is_err());
    f.put(b"x", b"").unwrap();
    assert_eq!(f.len(), 2);
    // Pseudo headers lead the list, as on the wire.
    assert!(matches!(f.put(b":path", b"/"), Err(H2Error::InvalidField(_))));
    let mut head = FieldList::new();
    head.put(b":method", b"GET").unwrap();
    head.put(b"accept", b"*/*").unwrap();
    assert!(head.has_pseudo() && !f.has_pseudo());
}

#[test]
fn a_packed_list_round_trips_and_malformed_ones_are_refused() {
    let list = fields(&[("a", "1"), ("b", ""), ("a", "3")]);
    let again = FieldList::from_packed(list.as_bytes().to_vec()).unwrap();
    assert_eq!(again, list);
    assert_eq!(
        again.iter().map(|(n, v)| (n.to_vec(), v.to_vec())).collect::<Vec<_>>(),
        [(b"a".to_vec(), b"1".to_vec()), (b"b".to_vec(), vec![]), (b"a".to_vec(), b"3".to_vec())]
    );
    let bytes = list.into_bytes();
    assert_eq!(FieldList::from_packed(bytes[..bytes.len() - 1].to_vec()), Err(H2Error::BadPacking));
    assert_eq!(FieldList::from_packed(vec![1, 0]), Err(H2Error::BadPacking));
    assert!(FieldList::from_packed(Vec::new()).unwrap().is_empty());
}

#[test]
fn bad_pseudo_headers_and_windows_are_refused_up_front() {
    let mut p = Pair::new();
    let bad = RequestHead { method: "GE T", scheme: "https", authority: "x", path: "/" };
    assert!(matches!(p.client.submit_request(&bad, &FieldList::new(), Body::None), Err(H2Error::InvalidField(_))));
    let empty_path = RequestHead { path: "", ..get("/") };
    assert!(matches!(p.client.submit_request(&empty_path, &FieldList::new(), Body::None), Err(H2Error::InvalidField(_))));
    assert!(Session::new(Role::Client, Limits { connection: 100, ..limits() }).is_err());
    assert!(matches!(p.server.submit_response(99, 200, &FieldList::new(), Body::None), Err(H2Error::InvalidState(_))));
}
