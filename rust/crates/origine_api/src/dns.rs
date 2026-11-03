//! `native.dns.*`: address lookups on the io loop, built on `origine_dns`.
//!
//! A resolver is a list of servers (UDP, TCP, TLS, or HTTPS) plus, for `system()`, what `/etc/resolv.conf` and
//! `/etc/hosts` say. Each query opens its own socket on the resolver's runtime (a connected UDP socket, or a
//! stream, framed as RFC 1035 section 4.2.2 says, over TLS for DoT) and ends after one answer or its timeout.
//! The servers' sockets are not `api.net` sockets, so each server address is checked against the embedder's
//! network ceiling (`connect` rules; `PermissionDenied` otherwise, with the address as the detail) when the
//! resolver is made and again before every query: a resolver must not be a way around the ceiling.

use std::cell::RefCell;
use std::future::Future;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::os::fd::AsRawFd;
use std::rc::{Rc, Weak};
use std::time::Duration;

use origine_api_core::{NativeError, NetRules, errno};
use origine_dns::{
    CacheConfig, Config, DnsError, DohError, Exchange, Family, Hosts, Resolver, Server, Transport as DnsTransport, parse_resolv_conf,
};
use origine_io::Loop;
use origine_io::rt::Handle;
use origine_transport::Transport;

use crate::io::Io;
use crate::native::{Op, ScopeKey};
use crate::net::{SEND_FLAGS, Socket, new_datagram, new_stream, sockaddr_bytes};
use crate::sockstream::SocketTransport;
use crate::{HostState, class, native};

/// Largest datagram answer read (EDNS is not used, so servers cut at 512 and set TC; this leaves room).
const DATAGRAM: usize = 4096;

struct NetExchange {
    /// Weak: a resolver (owned by the garbage collector) must never be what keeps an event loop alive, or tears one
    /// down when it is collected. Once the runtime is closed a query fails.
    lp: Weak<Loop>,
    net: NetRules,
    #[cfg(feature = "tls")]
    tls: Option<origine_tls::TlsClient>,
    /// The same, negotiating `h2`, for DNS over HTTPS.
    #[cfg(all(feature = "tls", feature = "http"))]
    h2: Option<origine_tls::TlsClient>,
}

fn to_io(e: NativeError) -> io::Error {
    io::Error::other(format!("{e:?}"))
}

impl NetExchange {
    fn lp(&self) -> io::Result<Rc<Loop>> {
        self.lp.upgrade().ok_or_else(|| io::Error::new(io::ErrorKind::ConnectionAborted, "the event loop is closed"))
    }

    async fn udp(&self, addr: SocketAddr, query: &[u8]) -> io::Result<Vec<u8>> {
        let lp = self.lp()?;
        let fd = new_datagram(&addr).map_err(to_io)?;
        let raw = fd.as_raw_fd() as isize;
        lp.connect(raw, sockaddr_bytes(&addr)).await?;
        let (sent, _) = lp.send(raw, query.to_vec(), SEND_FLAGS).await;
        sent?;
        loop {
            let (read, mut buf) = lp.recv(raw, vec![0u8; DATAGRAM], 0).await;
            buf.truncate(read?);
            // A datagram that is not the answer to this query (another id) is somebody else's: keep waiting.
            if buf.len() >= 2 && buf[..2] == query[..2] {
                return Ok(buf);
            }
        }
    }

    async fn stream(&self, addr: SocketAddr) -> io::Result<SocketTransport> {
        let lp = self.lp()?;
        let stream = new_stream(&addr).map_err(to_io)?;
        lp.connect(stream.as_raw_fd() as isize, sockaddr_bytes(&addr)).await?;
        let _ = stream.set_nodelay(true);
        Ok(SocketTransport { socket: Rc::new(Socket::stream(stream)), lp })
    }

    /// RFC 8484: one HTTP/2 connection over TLS, one POST of the query, the body of the answer. The connection
    /// lives only as long as this call (its driver is polled by it, not spawned), so an idle resolver holds
    /// nothing and keeps nothing alive.
    #[cfg(all(feature = "tls", feature = "http"))]
    async fn https(&self, addr: SocketAddr, name: &str, authority: &str, path: &str, query: &[u8]) -> io::Result<Vec<u8>> {
        use origine_h2::{Role, connect};
        let client = self.h2.as_ref().ok_or_else(|| io::Error::from(io::ErrorKind::Unsupported))?;
        let tls = origine_tls::TlsStream::connect(client, self.stream(addr).await?, name).await.map_err(io::Error::from)?;
        if tls.info().alpn.as_deref() != Some("h2") {
            // The server does not speak HTTP/2: there is nothing weaker to fall back to.
            return Err(io::Error::from(io::ErrorKind::Unsupported));
        }
        let limits = origine_h2::Limits { streams: 1, headers: 16 * 1024, window: 65535, connection: 65535, batch: 16 * 1024 };
        let (connection, driver) = connect(Role::Client, limits, tls).map_err(io::Error::other)?;
        both(doh_request(&connection, authority, path, query), driver.run()).await
    }

    async fn framed<T: Transport>(transport: &T, query: &[u8]) -> io::Result<Vec<u8>> {
        let length = u16::try_from(query.len()).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
        let mut message = Vec::with_capacity(2 + query.len());
        message.extend_from_slice(&length.to_be_bytes());
        message.extend_from_slice(query);
        transport.write_all(message).await.0?;
        let head = read_exact(transport, 2).await?;
        read_exact(transport, usize::from(u16::from_be_bytes([head[0], head[1]]))).await
    }
}

/// Polls `work` together with the connection's `driver` until `work` ends; a driver that ends first fails it.
#[cfg(all(feature = "tls", feature = "http"))]
async fn both(
    work: impl Future<Output = io::Result<Vec<u8>>>,
    driver: impl Future<Output = Result<(), origine_h2::ConnError>>,
) -> io::Result<Vec<u8>> {
    use std::pin::pin;
    use std::task::Poll;
    let (mut work, mut driver, mut driver_done) = (pin!(work), pin!(driver), false);
    std::future::poll_fn(move |cx| {
        // The driver first: when it ends it tells every stream, and `work` hears of it in the same poll.
        if !driver_done && driver.as_mut().poll(cx).is_ready() {
            driver_done = true;
        }
        match work.as_mut().poll(cx) {
            Poll::Pending if driver_done => Poll::Ready(Err(io::Error::from(io::ErrorKind::ConnectionAborted))),
            other => other,
        }
    })
    .await
}

#[cfg(all(feature = "tls", feature = "http"))]
fn conn_io(e: origine_h2::ConnError) -> io::Error {
    use origine_h2::ConnError;
    match e {
        ConnError::Transport(kind, _) => io::Error::from(kind),
        ConnError::Protocol(e) => io::Error::other(e),
        ConnError::Closed => io::Error::from(io::ErrorKind::ConnectionAborted),
    }
}

/// The largest DNS message there is.
#[cfg(all(feature = "tls", feature = "http"))]
const MAX_MESSAGE: usize = 65535;

/// The HTTP/2 error code `CANCEL`.
#[cfg(all(feature = "tls", feature = "http"))]
const CANCEL: u32 = 8;

#[cfg(all(feature = "tls", feature = "http"))]
async fn doh_request(connection: &origine_h2::Connection, authority: &str, path: &str, query: &[u8]) -> io::Result<Vec<u8>> {
    use origine_h2::{Body, FieldList, HeaderKind, RequestHead, StreamEvent};
    connection.ready().await.map_err(conn_io)?;
    let mut fields = FieldList::new();
    let length = query.len().to_string();
    for (name, value) in [("accept", "application/dns-message"), ("content-type", "application/dns-message"), ("content-length", &length)] {
        fields.put(name.as_bytes(), value.as_bytes()).map_err(io::Error::other)?;
    }
    let head = RequestHead { method: "POST", scheme: "https", authority, path };
    let exchange = connection.open(&head, &fields, Body::Stream).map_err(io::Error::other)?;
    exchange.send(query.to_vec()).await.map_err(io::Error::other)?;
    exchange.finish(None).map_err(io::Error::other)?;
    let (mut status, mut dns_type, mut body) = (0, false, Vec::new());
    while let Some(event) = exchange.next().await {
        match event {
            StreamEvent::Headers { kind: HeaderKind::Response, pseudo, fields, .. } => {
                status = pseudo.status.unwrap_or(status);
                if let Some(value) = fields.get("content-type") {
                    dns_type = value.eq_ignore_ascii_case(b"application/dns-message");
                }
            }
            StreamEvent::Data(data) => {
                exchange.consume(data.len());
                if body.len() + data.len() > MAX_MESSAGE {
                    exchange.reset(CANCEL);
                    return Err(io::Error::other(DohError::TooLarge));
                }
                body.extend_from_slice(&data);
            }
            StreamEvent::Closed(0) => break,
            StreamEvent::Closed(_) => return Err(io::Error::from(io::ErrorKind::ConnectionReset)),
            StreamEvent::Aborted(e) => return Err(conn_io(e)),
            _ => {}
        }
    }
    if status != 200 {
        return Err(io::Error::other(DohError::Status(status)));
    }
    if !dns_type {
        return Err(io::Error::other(DohError::ContentType));
    }
    Ok(body)
}

async fn read_exact<T: Transport>(transport: &T, len: usize) -> io::Result<Vec<u8>> {
    let mut out = Vec::with_capacity(len);
    while out.len() < len {
        let (read, buf) = transport.read(vec![0u8; len - out.len()]).await;
        let got = read?;
        if got == 0 {
            return Err(io::Error::from(io::ErrorKind::UnexpectedEof));
        }
        out.extend_from_slice(&buf[..got]);
    }
    Ok(out)
}

impl Exchange for NetExchange {
    async fn exchange(&self, server: &Server, addr: SocketAddr, query: &[u8], timeout: Duration) -> io::Result<Vec<u8>> {
        if !self.net.allows_connect(&addr) {
            return Err(io::Error::from(io::ErrorKind::PermissionDenied));
        }
        let work = async {
            match &server.transport {
                DnsTransport::Udp => self.udp(addr, query).await,
                DnsTransport::Tcp => NetExchange::framed(&self.stream(addr).await?, query).await,
                #[cfg(feature = "tls")]
                DnsTransport::Tls { name } => {
                    let client = self.tls.as_ref().ok_or_else(|| io::Error::from(io::ErrorKind::Unsupported))?;
                    let tls = origine_tls::TlsStream::connect(client, self.stream(addr).await?, name).await.map_err(io::Error::from)?;
                    NetExchange::framed(&tls, query).await
                }
                #[cfg(not(feature = "tls"))]
                DnsTransport::Tls { .. } => Err(io::Error::from(io::ErrorKind::Unsupported)),
                #[cfg(all(feature = "tls", feature = "http"))]
                DnsTransport::Https { name, authority, path } => self.https(addr, name, authority, path, query).await,
                #[cfg(not(all(feature = "tls", feature = "http")))]
                DnsTransport::Https { .. } => Err(io::Error::from(io::ErrorKind::Unsupported)),
            }
        };
        match Handle::current().timeout(timeout, work).await {
            Ok(result) => result,
            Err(_) => Err(io::Error::from(io::ErrorKind::TimedOut)),
        }
    }
}

/// `api.dns.Resolver`, a Rust-defined class (see `class`): the resolver, the scope that made it and the runtime its
/// queries run on. Dropping it, when the instance is collected, only lets go of shared data; a lookup in flight
/// holds its own copy of the resolver. `close()` lets go of it at once. `lookup`, `io` and `Symbol.asyncDispose`
/// are glue members (they return `IpAddr`s and the `api.io` handle).
pub(crate) struct ResolverHandle {
    owner: ScopeKey,
    runtime: u32,
    resolver: RefCell<Option<Rc<Resolver<NetExchange>>>>,
}

#[class(path = "dns.Resolver", side_effect = "any", needs = "runtime")]
impl ResolverHandle {
    /// `close()` was called, or the runtime closed.
    #[getter]
    fn closed(&self, host: &HostState) -> bool {
        self.resolver.borrow().is_none() || host.loop_of(self.owner, self.runtime).is_err()
    }

    /// Forgets the resolver; lookups in flight finish. Idempotent; resolves at once.
    fn close<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> Option<v8::Local<'s, v8::Promise>> {
        let taken = self.resolver.borrow_mut().take();
        drop(taken);
        let resolver = v8::PromiseResolver::new(scope)?;
        let undefined = v8::undefined(scope).into();
        resolver.resolve(scope, undefined);
        Some(resolver.get_promise(scope))
    }
}

fn dns_error(e: DnsError, name: &str) -> NativeError {
    let detailed = |code: u32, subject: String| NativeError::Errno(code).with_subject(subject);
    match e {
        DnsError::NotFound => detailed(errno::NOT_FOUND, name.to_owned()),
        DnsError::TimedOut => NativeError::Errno(errno::TIMED_OUT),
        DnsError::ServerFailure(failure) => detailed(errno::SERVER_FAILURE, failure.to_string()),
        // A TLS failure travelled inside an `io::Error`: give it back its own meaning.
        #[cfg(feature = "tls")]
        DnsError::Io(e) if e.get_ref().is_some_and(|inner| inner.is::<origine_tls::TlsError>()) => {
            let inner = e.get_ref().and_then(|inner| inner.downcast_ref::<origine_tls::TlsError>());
            inner.map_or(NativeError::Errno(errno::UNEXPECTED), crate::tls::tls_error_of)
        }
        DnsError::Io(e) => NativeError::from(e),
        DnsError::InvalidName(n) => detailed(errno::INVALID_INPUT, n),
        DnsError::BadResponse(why) => detailed(errno::PROTOCOL_ERROR, why.to_string()),
        _ => NativeError::Errno(errno::UNEXPECTED),
    }
}

fn denied(addr: &SocketAddr) -> NativeError {
    NativeError::Errno(errno::PERMISSION_DENIED).with_subject(addr.to_string())
}

fn addrs_of(list: &str, net: &NetRules) -> Result<Vec<SocketAddr>, NativeError> {
    let addrs = list
        .split(',')
        .filter(|a| !a.is_empty())
        .map(|a| a.parse::<SocketAddr>().map_err(|_| NativeError::Errno(errno::INVALID_INPUT).with_subject(a.to_owned())))
        .collect::<Result<Vec<_>, _>>()?;
    if addrs.is_empty() {
        return Err(NativeError::Errno(errno::INVALID_INPUT));
    }
    // Resolvers open sockets of their own, so the ceiling applies to them as it does to `api.net`.
    match addrs.iter().find(|a| !net.allows_connect(a)) {
        Some(addr) => Err(denied(addr)),
        None => Ok(addrs),
    }
}

/// The roots TLS servers are checked against: a `RootPki` (without the `tls` feature, any value, refused).
#[cfg(feature = "tls")]
type Roots<'s> = &'s crate::tls::RootPki;
#[cfg(not(feature = "tls"))]
type Roots<'s> = v8::Local<'s, v8::Value>;

/// `native.dns.resolver(io, spec, roots, timeout, tries, entries, min, max, negative_min, negative_max)` (`io` an `Io`): a resolver
/// over the servers in `spec`, one per line: `udp <addrs>`, `tcp <addrs>`, `tls <name> <addrs>`,
/// `https <authority> <path> <addrs>` (`addrs` are `ip:port`, comma-separated; the authority is the host and a
/// `:port` that is not 443) or `system` (the nameservers, search list and hosts file of this machine, read
/// now). `roots` is the roots TLS and HTTPS servers are checked against (undefined if there are none);
/// `timeout` is milliseconds per attempt. `entries` is the cache's size (0: no cache) and the four that follow are
/// its TTL clamps in milliseconds. Returns the resolver.
#[native(side_effect = "any", path = "dns.resolver", needs = "runtime")]
#[allow(clippy::too_many_arguments)]
fn dns_resolver(
    host: &mut HostState,
    key: ScopeKey,
    io: &Io,
    spec: String,
    roots: Option<Roots<'_>>,
    timeout: u32,
    tries: u32,
    entries: u64,
    min: u64,
    max: u64,
    negative_min: u64,
    negative_max: u64,
) -> Result<ResolverHandle, NativeError> {
    if io.0.owner != key {
        return Err(NativeError::Errno(errno::BAD_HANDLE));
    }
    let lp = io.0.lp(host)?;
    let io = io.0.runtime;
    let net = host.net.clone();
    let mut servers = Vec::new();
    let (mut search, mut ndots, mut hosts) = (Vec::new(), None, Hosts::new());
    let (mut wants_tls, mut wants_h2) = (false, false);
    for line in spec.lines().filter(|l| !l.is_empty()) {
        let mut words = line.splitn(3, ' ');
        match (words.next(), words.next(), words.next()) {
            (Some("udp"), Some(addrs), None) => servers.push(Server { transport: DnsTransport::Udp, addrs: addrs_of(addrs, &net)? }),
            (Some("tcp"), Some(addrs), None) => servers.push(Server { transport: DnsTransport::Tcp, addrs: addrs_of(addrs, &net)? }),
            (Some("tls"), Some(name), Some(addrs)) => {
                wants_tls = true;
                servers.push(Server { transport: DnsTransport::Tls { name: name.to_owned() }, addrs: addrs_of(addrs, &net)? });
            }
            (Some("https"), Some(authority), Some(rest)) => {
                wants_h2 = true;
                let (path, addrs) =
                    rest.split_once(' ').ok_or_else(|| NativeError::Errno(errno::INVALID_INPUT).with_subject(line.to_owned()))?;
                let name = authority.rsplit_once(':').map_or(authority, |(host, _)| host);
                servers.push(Server {
                    transport: DnsTransport::Https { name: name.to_owned(), authority: authority.to_owned(), path: path.to_owned() },
                    addrs: addrs_of(addrs, &net)?,
                });
            }
            (Some("system"), None, None) => {
                let conf = parse_resolv_conf(&std::fs::read_to_string("/etc/resolv.conf").unwrap_or_default());
                for ip in conf.nameservers {
                    servers.push(Server { transport: DnsTransport::Udp, addrs: addrs_of(&SocketAddr::new(ip, 53).to_string(), &net)? });
                }
                search = conf.search;
                ndots = conf.ndots;
                hosts = Hosts::parse(&std::fs::read_to_string("/etc/hosts").unwrap_or_default());
            }
            _ => return Err(NativeError::Errno(errno::INVALID_INPUT).with_subject(line.to_owned())),
        }
    }
    if servers.is_empty() {
        return Err(NativeError::Errno(errno::INVALID_INPUT).with_subject("no servers".to_owned()));
    }
    #[cfg(feature = "tls")]
    #[cfg(feature = "tls")]
    let roots = roots.map(|roots| roots.get()).transpose()?;
    #[cfg(feature = "tls")]
    let client = |wanted: bool, alpn: &[&str]| -> Result<Option<origine_tls::TlsClient>, NativeError> {
        if !wanted {
            return Ok(None);
        }
        let Some(roots) = roots.clone() else {
            return Err(NativeError::Errno(errno::INVALID_INPUT).with_subject("TLS servers need roots".to_owned()));
        };
        let alpn = alpn.iter().map(|name| (*name).to_owned()).collect();
        origine_tls::TlsClient::new(origine_tls::ClientOptions { roots, identity: None, alpn, sessions: None })
            .map(Some)
            .map_err(|e| NativeError::Errno(errno::INVALID_DATA).with_subject(e.to_string()))
    };
    #[cfg(feature = "tls")]
    let tls = client(wants_tls, &[])?;
    // DNS over HTTPS needs the HTTP/2 client as well as TLS: without both it is `Unsupported`, never a weaker path.
    #[cfg(all(feature = "tls", feature = "http"))]
    let h2 = client(wants_h2, &["h2"])?;
    #[cfg(not(all(feature = "tls", feature = "http")))]
    if wants_h2 {
        return Err(NativeError::Errno(errno::UNSUPPORTED));
    }
    #[cfg(not(feature = "tls"))]
    if wants_tls || roots.is_some() {
        return Err(NativeError::Errno(errno::UNSUPPORTED));
    }
    let mut config = Config::new(servers, Duration::from_millis(u64::from(timeout.max(1))), tries.max(1));
    config.search = search;
    config.ndots = ndots.unwrap_or(1);
    config.hosts = hosts;
    if entries > 0 {
        let ms = Duration::from_millis;
        let cache = CacheConfig {
            entries: usize::try_from(entries).map_err(|_| NativeError::Errno(errno::INVALID_INPUT))?,
            min: ms(min),
            max: ms(max),
            negative_min: ms(negative_min),
            negative_max: ms(negative_max),
        };
        if !cache.valid() {
            return Err(NativeError::Errno(errno::INVALID_INPUT).with_subject("cache".to_owned()));
        }
        config.cache = Some(cache);
    }
    let exchange = NetExchange {
        lp: Rc::downgrade(&lp),
        net,
        #[cfg(feature = "tls")]
        tls,
        #[cfg(all(feature = "tls", feature = "http"))]
        h2,
    };
    Ok(ResolverHandle { owner: key, runtime: io, resolver: RefCell::new(Some(Rc::new(Resolver::new(config, exchange)))) })
}

/// `native.dns.lookup(resolver, name, family)` (`resolver` a `Resolver`; `BadHandle` once closed or for another scope's): Promise of the addresses, packed as `[4 | 6, octets]*`; `family` is
/// 4, 6 or 0 for both (IPv6 first). Rejects `NotFound` (`subject`: the name), `TimedOut`, `ServerFailure`, ...
#[native(side_effect = "any", path = "dns.lookup", needs = "runtime", promise)]
fn dns_lookup(
    host: &mut HostState,
    key: ScopeKey,
    resolver: &ResolverHandle,
    name: String,
    family: u32,
) -> Result<Op<'static, impl Future<Output = Result<Vec<u8>, NativeError>> + use<>>, NativeError> {
    let (owner, runtime) = (resolver.owner, resolver.runtime);
    // The lookup outlives the call: it holds its own copy of the resolver.
    let resolver = resolver.resolver.borrow().clone();
    let Some(resolver) = resolver.filter(|_| owner == key) else {
        return Err(NativeError::Errno(errno::BAD_HANDLE));
    };
    let family = match family {
        0 => Family::Any,
        4 => Family::V4,
        6 => Family::V6,
        _ => return Err(NativeError::Errno(errno::INVALID_INPUT)),
    };
    host.loop_of(key, runtime)?;
    Ok(Op::new(runtime, async move {
        let ips = resolver.lookup(&name, family).await.map_err(|e| dns_error(e, &name))?;
        let mut packed = Vec::with_capacity(ips.len() * 17);
        for ip in ips {
            match ip {
                IpAddr::V4(v4) => {
                    packed.push(4);
                    packed.extend_from_slice(&v4.octets());
                }
                IpAddr::V6(v6) => {
                    packed.push(6);
                    packed.extend_from_slice(&v6.octets());
                }
            }
        }
        Ok(packed)
    }))
}
