//! The cache (injected clock) and DNS over HTTPS, against the same fake network as the parent module.

use std::cell::Cell;
use std::rc::Rc;

use hickory_proto::rr::Name;
use hickory_proto::rr::rdata::SOA;

use super::*;
use crate::{BadResponse, CacheConfig, Clock, DohError, Failure};

struct TestClock(Rc<Cell<Duration>>);

impl Clock for TestClock {
    fn now(&self) -> Duration {
        self.0.get()
    }
}

const SECOND: Duration = Duration::from_secs(1);

/// A response whose records have `ttl` seconds; a negative one carries a SOA (`ttl`, `minimum`) when given.
fn respond_ttl(query: &Message, code: ResponseCode, ips: &[&str], ttl: u32, soa: Option<(u32, u32)>) -> Vec<u8> {
    let mut response = Message::from_vec(&respond(query, code, ips, false)).unwrap();
    let answers: Vec<Record> = response.take_answers().into_iter().map(|mut r| r.set_ttl(ttl).clone()).collect();
    response.insert_answers(answers);
    if let Some((soa_ttl, minimum)) = soa {
        let origin = Name::from_ascii("test.").unwrap();
        let rdata = RData::SOA(SOA::new(origin.clone(), origin.clone(), 1, 2, 3, 4, minimum));
        response.add_name_server(Record::from_rdata(origin, soa_ttl, rdata));
    }
    response.to_vec().unwrap()
}

fn cached(entries: usize, min: u64, max: u64, negative_min: u64, negative_max: u64) -> CacheConfig {
    CacheConfig {
        entries,
        min: Duration::from_secs(min),
        max: Duration::from_secs(max),
        negative_min: Duration::from_secs(negative_min),
        negative_max: Duration::from_secs(negative_max),
    }
}

/// A caching resolver whose clock the test moves; `handler` answers.
fn caching(
    cache: CacheConfig,
    handler: impl Fn(&Server, SocketAddr, &Message) -> io::Result<Vec<u8>> + 'static,
) -> (Resolver<Fake>, Rc<Cell<Duration>>) {
    let mut config = Config::new(one(), Duration::from_millis(100), 1);
    config.cache = Some(cache);
    let now = Rc::new(Cell::new(Duration::ZERO));
    let r = Resolver::with_clock(config, Fake { handler: Box::new(handler), log: RefCell::default() }, Box::new(TestClock(now.clone())));
    (r, now)
}

#[test]
fn a_positive_answer_is_kept_for_its_ttl() {
    let (r, now) = caching(cached(8, 0, 3600, 0, 0), |_, _, q| Ok(respond_ttl(q, ResponseCode::NoError, &["192.0.2.1"], 30, None)));
    let ask = || pollster::block_on(r.lookup("web.test", Family::V4)).unwrap();
    assert_eq!(ask(), [a("192.0.2.1")]);
    now.set(29 * SECOND);
    assert_eq!(ask(), [a("192.0.2.1")]);
    assert_eq!(queried(&r).len(), 1, "the second lookup came from the cache");
    now.set(30 * SECOND);
    ask();
    assert_eq!(queried(&r).len(), 2, "the entry expired at its TTL");
}

#[test]
fn the_cache_is_shared_by_lookups_and_names_are_case_blind() {
    let (r, _) =
        caching(cached(8, 0, 3600, 0, 0), |_, _, q| Ok(respond_ttl(q, ResponseCode::NoError, &["192.0.2.1", "2001:db8::1"], 60, None)));
    pollster::block_on(r.lookup("Web.Test", Family::Any)).unwrap();
    assert_eq!(queried(&r).len(), 2);
    // Each family is its own question; both are held now.
    pollster::block_on(r.lookup("web.test", Family::V6)).unwrap();
    pollster::block_on(r.lookup("WEB.test", Family::V4)).unwrap();
    assert_eq!(queried(&r).len(), 2);
    assert_eq!(r.cached(), 2);
    r.clear_cache();
    assert_eq!(r.cached(), 0);
    pollster::block_on(r.lookup("web.test", Family::V4)).unwrap();
    assert_eq!(queried(&r).len(), 3);
}

#[test]
fn ttl_is_clamped_by_min_and_max() {
    let (r, now) = caching(cached(8, 10, 20, 0, 0), |_, _, q| {
        let ttl = if q.query().unwrap().name().to_ascii().starts_with("short") { 1 } else { 1000 };
        Ok(respond_ttl(q, ResponseCode::NoError, &["192.0.2.1"], ttl, None))
    });
    let ask = |name: &str| pollster::block_on(r.lookup(name, Family::V4)).unwrap();
    ask("short.test");
    ask("long.test");
    now.set(9 * SECOND);
    ask("short.test");
    ask("long.test");
    assert_eq!(queried(&r).len(), 2, "a TTL of 1 was raised to 10 and one of 1000 cut to 20");
    now.set(10 * SECOND);
    ask("short.test");
    ask("long.test");
    assert_eq!(queried(&r).len(), 3, "only the short one expired");
    now.set(20 * SECOND);
    ask("long.test");
    assert_eq!(queried(&r).len(), 4);
}

#[test]
fn the_shortest_record_of_an_answer_sets_its_life() {
    let (r, now) = caching(cached(8, 0, 3600, 0, 0), |_, _, q| {
        let mut response = Message::from_vec(&respond_ttl(q, ResponseCode::NoError, &["192.0.2.1", "192.0.2.2"], 100, None)).unwrap();
        let mut answers = response.take_answers();
        answers[1].set_ttl(5);
        response.insert_answers(answers);
        Ok(response.to_vec().unwrap())
    });
    pollster::block_on(r.lookup("web.test", Family::V4)).unwrap();
    now.set(5 * SECOND);
    pollster::block_on(r.lookup("web.test", Family::V4)).unwrap();
    assert_eq!(queried(&r).len(), 2);
}

#[test]
fn negative_answers_live_by_the_soa_and_are_clamped() {
    // NXDOMAIN with a SOA of ttl 300 and minimum 20: kept for the smaller, 20 seconds.
    let (r, now) = caching(cached(8, 0, 3600, 0, 3600), |_, _, q| Ok(respond_ttl(q, ResponseCode::NXDomain, &[], 0, Some((300, 20)))));
    let ask = || pollster::block_on(r.lookup("nope.test", Family::Any));
    assert!(matches!(ask(), Err(DnsError::NotFound)));
    now.set(19 * SECOND);
    assert!(matches!(ask(), Err(DnsError::NotFound)));
    assert_eq!(queried(&r).len(), 1);
    // The NXDOMAIN holds for the other family too.
    assert!(matches!(pollster::block_on(r.lookup("nope.test", Family::V4)), Err(DnsError::NotFound)));
    assert_eq!(queried(&r).len(), 1);
    now.set(20 * SECOND);
    assert!(matches!(ask(), Err(DnsError::NotFound)));
    assert_eq!(queried(&r).len(), 2);

    // The negative clamp cuts it.
    let (r, now) = caching(cached(8, 0, 3600, 0, 5), |_, _, q| Ok(respond_ttl(q, ResponseCode::NXDomain, &[], 0, Some((300, 300)))));
    assert!(pollster::block_on(r.lookup("nope.test", Family::V4)).is_err());
    now.set(5 * SECOND);
    assert!(pollster::block_on(r.lookup("nope.test", Family::V4)).is_err());
    assert_eq!(queried(&r).len(), 2);
}

#[test]
fn no_data_is_kept_per_type_and_other_failures_are_not_kept() {
    let (r, _) = caching(cached(8, 0, 3600, 0, 3600), |_, _, q| {
        if q.query().unwrap().query_type() == RecordType::A {
            Ok(respond_ttl(q, ResponseCode::NoError, &["192.0.2.1"], 60, None))
        } else {
            Ok(respond_ttl(q, ResponseCode::NoError, &[], 0, Some((60, 60))))
        }
    });
    assert!(matches!(pollster::block_on(r.lookup("v4.test", Family::V6)), Err(DnsError::NotFound)));
    assert!(matches!(pollster::block_on(r.lookup("v4.test", Family::V6)), Err(DnsError::NotFound)));
    assert_eq!(queried(&r).len(), 1, "the empty AAAA answer was kept");
    assert_eq!(pollster::block_on(r.lookup("v4.test", Family::V4)).unwrap(), [a("192.0.2.1")]);
    assert_eq!(queried(&r).len(), 2, "the A question is another entry");

    let (failing, _) = caching(cached(8, 0, 3600, 0, 3600), |_, _, q| Ok(respond_ttl(q, ResponseCode::ServFail, &[], 0, Some((60, 60)))));
    assert!(pollster::block_on(failing.lookup("x.test", Family::V4)).is_err());
    assert!(pollster::block_on(failing.lookup("x.test", Family::V4)).is_err());
    assert_eq!(queried(&failing).len(), 2);
    assert_eq!(failing.cached(), 0);
}

#[test]
fn a_negative_answer_without_a_soa_or_with_negative_caching_off_is_not_kept() {
    let (r, _) = caching(cached(8, 0, 3600, 0, 3600), |_, _, q| Ok(respond_ttl(q, ResponseCode::NXDomain, &[], 0, None)));
    for _ in 0..2 {
        assert!(pollster::block_on(r.lookup("nope.test", Family::V4)).is_err());
    }
    assert_eq!(queried(&r).len(), 2);
    let (off, _) = caching(cached(8, 0, 3600, 0, 0), |_, _, q| Ok(respond_ttl(q, ResponseCode::NXDomain, &[], 0, Some((60, 60)))));
    for _ in 0..2 {
        assert!(pollster::block_on(off.lookup("nope.test", Family::V4)).is_err());
    }
    assert_eq!(queried(&off).len(), 2);
    assert_eq!(off.cached(), 0);
}

#[test]
fn a_full_cache_drops_the_entry_nearest_to_expiry() {
    let (r, now) = caching(cached(2, 0, 3600, 0, 0), |_, _, q| {
        let ttl = match q.query().unwrap().name().to_ascii().as_str() {
            "a.test." => 100,
            "b.test." => 50,
            _ => 200,
        };
        Ok(respond_ttl(q, ResponseCode::NoError, &["192.0.2.1"], ttl, None))
    });
    let ask = |name: &str| pollster::block_on(r.lookup(name, Family::V4)).unwrap();
    ask("a.test");
    now.set(SECOND);
    ask("b.test");
    ask("c.test");
    assert_eq!(r.cached(), 2);
    assert_eq!(queried(&r).len(), 3);
    ask("a.test");
    ask("c.test");
    assert_eq!(queried(&r).len(), 3, "a and c are held; b, nearest to expiry, made room");
    ask("b.test");
    assert_eq!(queried(&r).len(), 4);
}

#[test]
fn no_cache_asks_every_time() {
    let r = resolver(one(), |_, _, q| Ok(respond(q, ResponseCode::NoError, &["192.0.2.1"], false)));
    for _ in 0..3 {
        pollster::block_on(r.lookup("web.test", Family::V4)).unwrap();
    }
    assert_eq!(queried(&r).len(), 3);
    assert_eq!(r.cached(), 0);
}

#[test]
fn cache_numbers_are_checked() {
    assert!(cached(1, 0, 0, 0, 0).valid());
    assert!(!cached(0, 0, 10, 0, 10).valid());
    assert!(!cached(1, 11, 10, 0, 10).valid());
    assert!(!cached(1, 0, 10, 11, 10).valid());
}

fn https() -> Vec<Server> {
    vec![server(Transport::Https { name: "dns.test".into(), authority: "dns.test".into(), path: "/dns-query".into() }, &["127.0.0.1:443"])]
}

#[test]
fn queries_over_https_use_id_zero_and_an_http_failure_is_a_server_failure() {
    let r = resolver(https(), |_, _, q| {
        assert_eq!(q.id(), 0, "RFC 8484 asks for id 0");
        Ok(respond(q, ResponseCode::NoError, &["192.0.2.1"], false))
    });
    assert_eq!(pollster::block_on(r.lookup("web.test", Family::V4)).unwrap(), [a("192.0.2.1")]);
    assert_eq!(queried(&r), ["https 127.0.0.1:443 web.test. A"]);

    let status = resolver(https(), |_, _, _| Err(io::Error::other(DohError::Status(503))));
    assert!(matches!(pollster::block_on(status.lookup("x.test", Family::V4)), Err(DnsError::ServerFailure(Failure::Http(503)))));
    let kind = resolver(https(), |_, _, _| Err(io::Error::other(DohError::ContentType)));
    assert!(matches!(
        pollster::block_on(kind.lookup("x.test", Family::V4)),
        Err(DnsError::BadResponse(BadResponse::Doh(DohError::ContentType)))
    ));
}
