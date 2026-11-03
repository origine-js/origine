use std::cell::{Cell, RefCell};
use std::collections::hash_map::RandomState;
use std::future::Future;
use std::hash::BuildHasher;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::Duration;

use hickory_proto::op::{Message, MessageType, OpCode, Query, ResponseCode};
use hickory_proto::rr::{Name, RData, RecordType};

use crate::cache::{Cache, Cached, Clock, MonotonicClock};
use crate::config::{Config, Family, Server, Transport};
use crate::error::{BadResponse, DnsError, DohError, Failure};

/// One query to one server: the caller's I/O. `query` is a DNS message (no length prefix); the answer is the
/// server's message. A datagram transport returns what one datagram held; a stream transport frames the
/// message (RFC 1035 section 4.2.2) itself. A timeout is `io::ErrorKind::TimedOut`.
pub trait Exchange {
    fn exchange(&self, server: &Server, addr: SocketAddr, query: &[u8], timeout: Duration) -> impl Future<Output = io::Result<Vec<u8>>>;
}

pub struct Resolver<E> {
    config: Config,
    exchange: E,
    counter: Cell<u64>,
    random: RandomState,
    /// Shared by every lookup of this resolver.
    cache: Option<RefCell<Cache>>,
}

impl<E: Exchange> Resolver<E> {
    pub fn new(config: Config, exchange: E) -> Resolver<E> {
        Resolver::with_clock(config, exchange, Box::new(MonotonicClock::new()))
    }

    /// As [`Resolver::new`], with the clock the cache's expiry is measured on.
    pub fn with_clock(config: Config, exchange: E, clock: Box<dyn Clock>) -> Resolver<E> {
        let cache = config.cache.map(|cache| RefCell::new(Cache::new(cache, clock)));
        Resolver { config, exchange, counter: Cell::new(0), random: RandomState::new(), cache }
    }

    /// Forgets every cached answer.
    pub fn clear_cache(&self) {
        if let Some(cache) = &self.cache {
            cache.borrow_mut().clear();
        }
    }

    /// Answers held by the cache right now (expired ones that nobody asked about yet included).
    pub fn cached(&self) -> usize {
        self.cache.as_ref().map_or(0, |cache| cache.borrow().len())
    }

    #[cfg(test)]
    pub(crate) fn exchange(&self) -> &E {
        &self.exchange
    }

    /// The addresses of `name`, each family in the order the server gave, IPv6 first for [`Family::Any`].
    ///
    /// In order: an IP literal is itself; `localhost` (and `*.localhost`) is the loopback addresses (RFC 6761,
    /// never asked of a server); the hosts file; then the servers, trying search domains as `ndots` says. A
    /// trailing dot makes a name absolute (no search).
    pub async fn lookup(&self, name: &str, family: Family) -> Result<Vec<IpAddr>, DnsError> {
        let bare = name.trim_end_matches('.');
        if bare.is_empty() || !bare.is_ascii() || bare.len() > 253 || bare.split('.').any(|label| label.is_empty() || label.len() > 63) {
            return Err(DnsError::InvalidName(name.to_owned()));
        }
        let wanted = |ip: &IpAddr| matches!((family, ip), (Family::Any, _) | (Family::V4, IpAddr::V4(_)) | (Family::V6, IpAddr::V6(_)));
        let found = |ips: Vec<IpAddr>| {
            let ips: Vec<IpAddr> = ips.into_iter().filter(wanted).collect();
            if ips.is_empty() { Err(DnsError::NotFound) } else { Ok(ips) }
        };
        if let Ok(ip) = bare.parse::<IpAddr>() {
            return found(vec![ip]);
        }
        let lower = bare.to_ascii_lowercase();
        if lower == "localhost" || lower.ends_with(".localhost") {
            return found(vec![IpAddr::V6(Ipv6Addr::LOCALHOST), IpAddr::V4(Ipv4Addr::LOCALHOST)]);
        }
        if let Ok(ips) = found(self.config.hosts.get(bare).to_vec()) {
            return Ok(ips);
        }

        let dots = bare.matches('.').count();
        let searched = self.config.search.iter().map(|domain| format!("{bare}.{domain}"));
        let candidates: Vec<String> = if name.ends_with('.') {
            vec![bare.to_owned()]
        } else if dots >= self.config.ndots {
            std::iter::once(bare.to_owned()).chain(searched).collect()
        } else {
            searched.chain(std::iter::once(bare.to_owned())).collect()
        };
        for candidate in candidates {
            match self.resolve(&candidate, family).await {
                Ok(ips) if !ips.is_empty() => return Ok(ips),
                // Nothing under this name: the next search domain.
                Ok(_) | Err(DnsError::NotFound) => {}
                Err(e) => return Err(e),
            }
        }
        Err(DnsError::NotFound)
    }

    async fn resolve(&self, name: &str, family: Family) -> Result<Vec<IpAddr>, DnsError> {
        let mut name = Name::from_ascii(name).map_err(|_| DnsError::InvalidName(name.to_owned()))?;
        // Absolute: on the wire every name is, and a response's names are compared with ours.
        name.set_fqdn(true);
        let types: &[RecordType] = match family {
            Family::V4 => &[RecordType::A],
            Family::V6 => &[RecordType::AAAA],
            Family::Any => &[RecordType::AAAA, RecordType::A],
        };
        let mut all = Vec::new();
        for &kind in types {
            match self.ask(&name, kind).await? {
                Cached::Addrs(ips) => all.extend(ips),
                Cached::NoData => {}
                // The name does not exist for any type.
                Cached::NoName => return Ok(Vec::new()),
            }
        }
        Ok(all)
    }

    fn next_id(&self) -> u16 {
        let n = self.counter.get().wrapping_add(1);
        self.counter.set(n);
        // Keyed by process-random state: not guessable from the previous ids.
        (self.random.hash_one(n) >> 24) as u16
    }

    /// The cached answer to a question, or the servers': they are asked in order, `tries` rounds, until one
    /// gives an answer that is about our question.
    async fn ask(&self, name: &Name, kind: RecordType) -> Result<Cached, DnsError> {
        let text = name.to_ascii();
        if let Some(cache) = &self.cache
            && let Some(hit) = cache.borrow_mut().get(&text, kind)
        {
            return Ok(hit);
        }
        let mut last: Option<DnsError> = None;
        for _ in 0..self.config.tries.max(1) {
            for server in &self.config.servers {
                for &addr in &server.addrs {
                    // Over HTTPS the exchange pairs the answer with the query, and RFC 8484 asks for id 0.
                    let id = if matches!(server.transport, Transport::Https { .. }) { 0 } else { self.next_id() };
                    let mut query = Message::new();
                    query.set_id(id).set_message_type(MessageType::Query).set_op_code(OpCode::Query).set_recursion_desired(true);
                    query.add_query(Query::query(name.clone(), kind));
                    let bytes = query.to_vec().map_err(|_| DnsError::InvalidName(text.clone()))?;
                    match self.try_server(server, addr, &bytes, id, name, kind).await {
                        Ok((answer, ttl)) => {
                            if let (Some(cache), Some(ttl)) = (&self.cache, ttl) {
                                cache.borrow_mut().put(&text, kind, answer.clone(), ttl);
                            }
                            return Ok(answer);
                        }
                        Err(e) => last = Some(e),
                    }
                }
            }
        }
        Err(last.unwrap_or(DnsError::TimedOut))
    }

    /// One server's answer and how long it may be kept (`None`: not at all, e.g. a negative answer without
    /// the SOA that says how long).
    async fn try_server(
        &self,
        server: &Server,
        addr: SocketAddr,
        query: &[u8],
        id: u16,
        name: &Name,
        kind: RecordType,
    ) -> Result<(Cached, Option<Duration>), DnsError> {
        let mut response = self.exchange_once(server, addr, query).await?;
        if parse(&response, id, name, kind)?.truncated() && server.transport == Transport::Udp {
            // The answer did not fit a datagram: ask again over a stream to the same address.
            let tcp = Server { transport: Transport::Tcp, addrs: vec![addr] };
            response = self.exchange_once(&tcp, addr, query).await?;
        }
        let message = parse(&response, id, name, kind)?;
        match message.response_code() {
            ResponseCode::NoError => {}
            ResponseCode::NXDomain => return Ok((Cached::NoName, negative_ttl(&message))),
            other => return Err(DnsError::ServerFailure(Failure::Code(other))),
        }
        let ips: Vec<IpAddr> = message
            .answers()
            .iter()
            .filter_map(|record| match record.data() {
                RData::A(a) if kind == RecordType::A => Some(IpAddr::V4(a.0)),
                RData::AAAA(a) if kind == RecordType::AAAA => Some(IpAddr::V6(a.0)),
                _ => None,
            })
            .collect();
        if ips.is_empty() {
            return Ok((Cached::NoData, negative_ttl(&message)));
        }
        // An answer is as old as its shortest-lived record (a CNAME on the way included).
        let ttl = message.answers().iter().map(|record| record.ttl()).min().map(|secs| Duration::from_secs(u64::from(secs)));
        Ok((Cached::Addrs(ips), ttl))
    }

    async fn exchange_once(&self, server: &Server, addr: SocketAddr, query: &[u8]) -> Result<Vec<u8>, DnsError> {
        match self.exchange.exchange(server, addr, query, self.config.timeout).await {
            Ok(bytes) => Ok(bytes),
            Err(e) if e.kind() == io::ErrorKind::TimedOut => Err(DnsError::TimedOut),
            Err(e) => Err(match doh_error(e) {
                Ok(DohError::Status(code)) => DnsError::ServerFailure(Failure::Http(code)),
                Ok(other) => DnsError::BadResponse(BadResponse::Doh(other)),
                Err(e) => DnsError::Io(e),
            }),
        }
    }
}

/// The DoH failure an `io::Error` carries, or the error back.
fn doh_error(e: io::Error) -> Result<DohError, io::Error> {
    if !e.get_ref().is_some_and(|inner| inner.is::<DohError>()) {
        return Err(e);
    }
    match e.into_inner().map(|inner| inner.downcast::<DohError>()) {
        Some(Ok(doh)) => Ok(*doh),
        Some(Err(inner)) => Err(io::Error::other(inner)),
        None => Err(io::Error::from(io::ErrorKind::Other)),
    }
}

/// How long a negative answer may be kept (RFC 2308 section 5): the smaller of the SOA record's own TTL and its
/// MINIMUM field, from the authority section. Without a SOA there is no say, so it is not kept.
fn negative_ttl(message: &Message) -> Option<Duration> {
    message
        .name_servers()
        .iter()
        .filter_map(|record| match record.data() {
            RData::SOA(soa) => Some(record.ttl().min(soa.minimum())),
            _ => None,
        })
        .min()
        .map(|secs| Duration::from_secs(u64::from(secs)))
}

/// A response that answers this question (id, QR bit, question), or `BadResponse`.
fn parse(bytes: &[u8], id: u16, name: &Name, kind: RecordType) -> Result<Message, DnsError> {
    let message = Message::from_vec(bytes).map_err(|e| DnsError::BadResponse(BadResponse::Wire(Box::new(e))))?;
    if message.id() != id || message.message_type() != MessageType::Response {
        return Err(DnsError::BadResponse(BadResponse::NotOurQuery));
    }
    match message.queries() {
        [question] if question.name() == name && question.query_type() == kind => Ok(message),
        _ => Err(DnsError::BadResponse(BadResponse::NotOurQuestion)),
    }
}
