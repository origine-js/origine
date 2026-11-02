//! The resolver against a table-driven fake of the network.

use std::cell::RefCell;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::Duration;

use hickory_proto::op::{Message, MessageType, ResponseCode};
use hickory_proto::rr::rdata::{A, AAAA};
use hickory_proto::rr::{RData, Record, RecordType};

use crate::{Config, DnsError, Exchange, Family, Hosts, Resolver, Server, Transport, parse_resolv_conf};

type Handler = Box<dyn Fn(&Server, SocketAddr, &Message) -> io::Result<Vec<u8>>>;

struct Fake {
    handler: Handler,
    log: RefCell<Vec<(Transport, SocketAddr, String, RecordType)>>,
}

impl Exchange for Fake {
    async fn exchange(&self, server: &Server, addr: SocketAddr, query: &[u8], _timeout: Duration) -> io::Result<Vec<u8>> {
        let message = Message::from_vec(query).expect("a query we built");
        let q = message.query().expect("one question");
        self.log.borrow_mut().push((server.transport.clone(), addr, q.name().to_ascii(), q.query_type()));
        (self.handler)(server, addr, &message)
    }
}

fn a(s: &str) -> IpAddr {
    s.parse().unwrap()
}

/// A response to `query` with the given code and addresses (matched to the question's type).
fn respond(query: &Message, code: ResponseCode, ips: &[&str], truncated: bool) -> Vec<u8> {
    let mut response = Message::new();
    response.set_id(query.id()).set_message_type(MessageType::Response).set_response_code(code).set_recursion_available(true);
    response.set_truncated(truncated);
    let q = query.query().unwrap();
    response.add_query(q.clone());
    for ip in ips {
        let rdata = match a(ip) {
            IpAddr::V4(v4) if q.query_type() == RecordType::A => RData::A(A(v4)),
            IpAddr::V6(v6) if q.query_type() == RecordType::AAAA => RData::AAAA(AAAA(v6)),
            _ => continue,
        };
        response.add_answer(Record::from_rdata(q.name().clone(), 60, rdata));
    }
    response.to_vec().unwrap()
}

fn server(transport: Transport, addrs: &[&str]) -> Server {
    Server { transport, addrs: addrs.iter().map(|s| s.parse().unwrap()).collect() }
}

fn resolver(servers: Vec<Server>, handler: impl Fn(&Server, SocketAddr, &Message) -> io::Result<Vec<u8>> + 'static) -> Resolver<Fake> {
    let config = Config::new(servers, Duration::from_millis(100), 2);
    Resolver::new(config, Fake { handler: Box::new(handler), log: RefCell::default() })
}

fn queried(r: &Resolver<Fake>) -> Vec<String> {
    r.exchange()
        .log
        .borrow()
        .iter()
        .map(|(t, addr, name, kind)| {
            format!(
                "{} {addr} {name} {kind}",
                match t {
                    Transport::Udp => "udp",
                    Transport::Tcp => "tcp",
                    Transport::Tls { .. } => "tls",
                    Transport::Https { .. } => "https",
                }
            )
        })
        .collect()
}

pub(super) fn one() -> Vec<Server> {
    vec![server(Transport::Udp, &["127.0.0.1:53"])]
}

#[test]
fn both_families_are_combined_with_ipv6_first() {
    let r = resolver(one(), |_, _, q| Ok(respond(q, ResponseCode::NoError, &["2001:db8::1", "192.0.2.1", "192.0.2.2"], false)));
    let got = pollster::block_on(r.lookup("example.test", Family::Any)).unwrap();
    assert_eq!(got, [a("2001:db8::1"), a("192.0.2.1"), a("192.0.2.2")]);
    assert_eq!(queried(&r), ["udp 127.0.0.1:53 example.test. AAAA", "udp 127.0.0.1:53 example.test. A"]);
    let only4 = pollster::block_on(r.lookup("example.test", Family::V4)).unwrap();
    assert_eq!(only4, [a("192.0.2.1"), a("192.0.2.2")]);
}

#[test]
fn no_data_for_one_family_is_not_an_error_but_a_missing_name_is() {
    let r = resolver(one(), |_, _, q| {
        Ok(respond(q, ResponseCode::NoError, if q.query().unwrap().query_type() == RecordType::A { &["192.0.2.9"] } else { &[] }, false))
    });
    assert_eq!(pollster::block_on(r.lookup("v4only.test", Family::Any)).unwrap(), [a("192.0.2.9")]);
    assert!(matches!(pollster::block_on(r.lookup("v4only.test", Family::V6)), Err(DnsError::NotFound)));

    let missing = resolver(one(), |_, _, q| Ok(respond(q, ResponseCode::NXDomain, &[], false)));
    assert!(matches!(pollster::block_on(missing.lookup("nope.test", Family::Any)), Err(DnsError::NotFound)));
    // NXDOMAIN to the first question settles it: the second family is not asked.
    assert_eq!(queried(&missing).len(), 1);
}

#[test]
fn literals_localhost_and_the_hosts_file_never_reach_a_server() {
    let mut config = Config::new(one(), Duration::from_millis(100), 1);
    config.hosts = Hosts::parse("# comment\n10.0.0.7 printer.lan PRINTER # inline\n::1 localhost\nbad line here\nfe80::1%en0 router.lan\n");
    let r = Resolver::new(config, Fake { handler: Box::new(|_, _, _| panic!("no query expected")), log: RefCell::default() });
    let lookup = |name: &str, family| pollster::block_on(r.lookup(name, family));
    assert_eq!(lookup("192.0.2.5", Family::Any).unwrap(), [a("192.0.2.5")]);
    assert!(matches!(lookup("192.0.2.5", Family::V6), Err(DnsError::NotFound)));
    assert_eq!(lookup("::1", Family::Any).unwrap(), [a("::1")]);
    assert_eq!(lookup("LocalHost", Family::V4).unwrap(), [a("127.0.0.1")]);
    assert_eq!(lookup("app.localhost.", Family::Any).unwrap(), [a("::1"), a("127.0.0.1")]);
    assert_eq!(lookup("printer.lan", Family::Any).unwrap(), [a("10.0.0.7")]);
    assert_eq!(lookup("Printer.LAN.", Family::V4).unwrap(), [a("10.0.0.7")]);
    assert_eq!(lookup("router.lan", Family::Any).unwrap(), [a("fe80::1")]);
}

#[test]
fn search_domains_follow_ndots() {
    let ask = |name: &str, ndots: usize| {
        let mut config = Config::new(one(), Duration::from_millis(100), 1);
        config.search = vec!["corp.test".into(), "lab.test".into()];
        config.ndots = ndots;
        let r = Resolver::new(
            config,
            Fake {
                handler: Box::new(|_, _, q| {
                    // Only web.lab.test exists.
                    let found = q.query().unwrap().name().to_ascii() == "web.lab.test.";
                    Ok(respond(q, if found { ResponseCode::NoError } else { ResponseCode::NXDomain }, &["192.0.2.3"], false))
                }),
                log: RefCell::default(),
            },
        );
        let result = pollster::block_on(r.lookup(name, Family::V4));
        (result, queried(&r))
    };
    // Fewer dots than ndots: the search domains first, then the name as it is.
    let (result, log) = ask("web", 1);
    assert_eq!(result.unwrap(), [a("192.0.2.3")]);
    assert_eq!(log, ["udp 127.0.0.1:53 web.corp.test. A", "udp 127.0.0.1:53 web.lab.test. A"]);
    let (result, log) = ask("missing", 1);
    assert!(matches!(result, Err(DnsError::NotFound)));
    assert_eq!(log.last().unwrap(), "udp 127.0.0.1:53 missing. A");
    // Enough dots: the name first.
    let (_, log) = ask("a.b", 1);
    assert_eq!(log[0], "udp 127.0.0.1:53 a.b. A");
    // A trailing dot is absolute: no search at all.
    let (result, log) = ask("web.", 1);
    assert!(matches!(result, Err(DnsError::NotFound)));
    assert_eq!(log, ["udp 127.0.0.1:53 web. A"]);
}

#[test]
fn a_failing_server_hands_over_to_the_next_and_to_the_next_round() {
    let servers = vec![server(Transport::Udp, &["127.0.0.1:53", "127.0.0.2:53"]), server(Transport::Tcp, &["127.0.0.3:53"])];
    let r = resolver(servers, |_, addr, q| match addr.ip().to_string().as_str() {
        "127.0.0.1" => Err(io::Error::from(io::ErrorKind::TimedOut)),
        "127.0.0.2" => Ok(respond(q, ResponseCode::ServFail, &[], false)),
        _ => Ok(respond(q, ResponseCode::NoError, &["192.0.2.4"], false)),
    });
    assert_eq!(pollster::block_on(r.lookup("x.test", Family::V4)).unwrap(), [a("192.0.2.4")]);
    assert_eq!(queried(&r).len(), 3);

    // Every server down for every round: the last kind of failure is reported.
    let dead = resolver(one(), |_, _, _| Err(io::Error::from(io::ErrorKind::TimedOut)));
    assert!(matches!(pollster::block_on(dead.lookup("x.test", Family::V4)), Err(DnsError::TimedOut)));
    assert_eq!(queried(&dead).len(), 2, "two tries");
    let refused = resolver(one(), |_, _, _| Err(io::Error::from(io::ErrorKind::ConnectionRefused)));
    assert!(
        matches!(pollster::block_on(refused.lookup("x.test", Family::V4)), Err(DnsError::Io(e)) if e.kind() == io::ErrorKind::ConnectionRefused)
    );
    let failing = resolver(one(), |_, _, q| Ok(respond(q, ResponseCode::Refused, &[], false)));
    assert!(matches!(pollster::block_on(failing.lookup("x.test", Family::V4)), Err(DnsError::ServerFailure(_))));
}

#[test]
fn a_truncated_datagram_answer_is_asked_again_over_tcp() {
    let r = resolver(one(), |server, _, q| {
        Ok(match server.transport {
            Transport::Udp => respond(q, ResponseCode::NoError, &[], true),
            _ => respond(q, ResponseCode::NoError, &["192.0.2.8"], false),
        })
    });
    assert_eq!(pollster::block_on(r.lookup("big.test", Family::V4)).unwrap(), [a("192.0.2.8")]);
    assert_eq!(queried(&r), ["udp 127.0.0.1:53 big.test. A", "tcp 127.0.0.1:53 big.test. A"]);
}

#[test]
fn answers_to_other_questions_are_not_believed() {
    // A spoofed id, then an answer about another name, then the real one from the second server.
    let servers = vec![server(Transport::Udp, &["127.0.0.1:53", "127.0.0.2:53", "127.0.0.3:53"])];
    let r = resolver(servers, |_, addr, q| {
        let mut other = Message::from_vec(&respond(q, ResponseCode::NoError, &["192.0.2.66"], false)).unwrap();
        match addr.ip().to_string().as_str() {
            "127.0.0.1" => {
                other.set_id(q.id().wrapping_add(1));
                Ok(other.to_vec().unwrap())
            }
            "127.0.0.2" => {
                let mut wrong = Message::new();
                wrong.set_id(q.id()).set_message_type(MessageType::Response);
                wrong.add_query(hickory_proto::op::Query::query("evil.test.".parse().unwrap(), RecordType::A));
                Ok(wrong.to_vec().unwrap())
            }
            _ => Ok(respond(q, ResponseCode::NoError, &["192.0.2.10"], false)),
        }
    });
    assert_eq!(pollster::block_on(r.lookup("real.test", Family::V4)).unwrap(), [a("192.0.2.10")]);
    let garbage = resolver(one(), |_, _, _| Ok(vec![1, 2, 3]));
    assert!(matches!(pollster::block_on(garbage.lookup("x.test", Family::V4)), Err(DnsError::BadResponse(_))));
}

#[test]
fn names_are_checked_before_anything_is_sent() {
    let r = resolver(one(), |_, _, _| panic!("no query expected"));
    for bad in ["", ".", "a..b", "caf\u{e9}.test", &"x".repeat(64), &format!("{}.test", ["abcdefghij"; 26].join("."))] {
        assert!(matches!(pollster::block_on(r.lookup(bad, Family::Any)), Err(DnsError::InvalidName(_))), "{bad:?}");
    }
}

#[test]
fn resolv_conf_and_hosts_parse() {
    let conf = parse_resolv_conf(
        "# c\nnameserver 10.0.0.1\nnameserver fe80::1%en0\nnameserver not-an-ip\nsearch corp.test. lab.test\noptions timeout:2 ndots:3 rotate\n; x\n",
    );
    assert_eq!(conf.nameservers, [a("10.0.0.1"), a("fe80::1")]);
    assert_eq!(conf.search, ["corp.test", "lab.test"]);
    assert_eq!(conf.ndots, Some(3));
    assert_eq!(parse_resolv_conf("domain only.test\nsearch a.test\n").search, ["a.test"]);
    assert_eq!(parse_resolv_conf("domain only.test extra\n").search, ["only.test"]);
    assert_eq!(parse_resolv_conf("").ndots, None);
    let hosts = Hosts::parse("127.0.0.1 a b\n127.0.0.1 a\n::1 a\n");
    assert_eq!(hosts.get("A"), [a("127.0.0.1"), a("::1")]);
    let _ = (Ipv4Addr::LOCALHOST, Ipv6Addr::LOCALHOST);
}

mod cache_tests;
