use std::cell::Cell;
use std::collections::hash_map::RandomState;
use std::future::Future;
use std::hash::BuildHasher;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::Duration;

use hickory_proto::op::{Message, MessageType, OpCode, Query, ResponseCode};
use hickory_proto::rr::{Name, RData, RecordType};

use crate::config::{Config, Family, Server, Transport};
use crate::error::DnsError;

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
}

/// What one question came to.
enum Answer {
    Addrs(Vec<IpAddr>),
    /// The name exists but has no record of that type.
    NoData,
    /// The name does not exist at all.
    NoName,
}

impl<E: Exchange> Resolver<E> {
    pub fn new(config: Config, exchange: E) -> Resolver<E> {
        Resolver { config, exchange, counter: Cell::new(0), random: RandomState::new() }
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
                Answer::Addrs(ips) => all.extend(ips),
                Answer::NoData => {}
                // The name does not exist for any type.
                Answer::NoName => return Ok(Vec::new()),
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

    /// Asks the servers in order, `tries` rounds, until one gives an answer that is about our question.
    async fn ask(&self, name: &Name, kind: RecordType) -> Result<Answer, DnsError> {
        let mut last: Option<DnsError> = None;
        for _ in 0..self.config.tries.max(1) {
            for server in &self.config.servers {
                for &addr in &server.addrs {
                    let id = self.next_id();
                    let mut query = Message::new();
                    query.set_id(id).set_message_type(MessageType::Query).set_op_code(OpCode::Query).set_recursion_desired(true);
                    query.add_query(Query::query(name.clone(), kind));
                    let bytes = query.to_vec().map_err(|e| DnsError::InvalidName(e.to_string()))?;
                    match self.try_server(server, addr, &bytes, id, name, kind).await {
                        Ok(answer) => return Ok(answer),
                        Err(e) => last = Some(e),
                    }
                }
            }
        }
        Err(last.unwrap_or(DnsError::TimedOut))
    }

    async fn try_server(
        &self,
        server: &Server,
        addr: SocketAddr,
        query: &[u8],
        id: u16,
        name: &Name,
        kind: RecordType,
    ) -> Result<Answer, DnsError> {
        let mut response = self.exchange_once(server, addr, query).await?;
        if parse(&response, id, name, kind)?.truncated() && server.transport == Transport::Udp {
            // The answer did not fit a datagram: ask again over a stream to the same address.
            let tcp = Server { transport: Transport::Tcp, addrs: vec![addr] };
            response = self.exchange_once(&tcp, addr, query).await?;
        }
        let message = parse(&response, id, name, kind)?;
        match message.response_code() {
            ResponseCode::NoError => {}
            ResponseCode::NXDomain => return Ok(Answer::NoName),
            other => return Err(DnsError::ServerFailure(other.to_string())),
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
        Ok(if ips.is_empty() { Answer::NoData } else { Answer::Addrs(ips) })
    }

    async fn exchange_once(&self, server: &Server, addr: SocketAddr, query: &[u8]) -> Result<Vec<u8>, DnsError> {
        match self.exchange.exchange(server, addr, query, self.config.timeout).await {
            Ok(bytes) => Ok(bytes),
            Err(e) if e.kind() == io::ErrorKind::TimedOut => Err(DnsError::TimedOut),
            Err(e) => Err(DnsError::Io(e)),
        }
    }
}

/// A response that answers this question (id, QR bit, question), or `BadResponse`.
fn parse(bytes: &[u8], id: u16, name: &Name, kind: RecordType) -> Result<Message, DnsError> {
    let message = Message::from_vec(bytes).map_err(|e| DnsError::BadResponse(e.to_string()))?;
    if message.id() != id || message.message_type() != MessageType::Response {
        return Err(DnsError::BadResponse("not the answer to our query".into()));
    }
    match message.queries() {
        [question] if question.name() == name && question.query_type() == kind => Ok(message),
        _ => Err(DnsError::BadResponse("the question is not ours".into())),
    }
}
