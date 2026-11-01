//! `native.dns.*`: address lookups on the io loop, built on `origine_dns`.
//!
//! A resolver is a list of servers (UDP, TCP, or TLS) plus, for `system()`, what `/etc/resolv.conf` and
//! `/etc/hosts` say. Each query opens its own socket on the resolver's runtime (a connected UDP socket, or a
//! stream, framed as RFC 1035 section 4.2.2 says, over TLS for DoT) and ends after one answer or its timeout.
//! The servers' sockets are not `api.net` sockets, so **servers must be loopback addresses for now**
//! (`PermissionDenied` otherwise, with the address as the detail): there is no embedder permission for wider
//! network access yet, and a resolver must not be a way around that.

use std::collections::BTreeMap;
use std::future::Future;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::os::fd::AsRawFd;
use std::rc::Rc;
use std::time::Duration;

use origine_api_core::{NativeError, errno};
use origine_dns::{Config, DnsError, Exchange, Family, Hosts, Resolver, Server, Transport as DnsTransport, parse_resolv_conf};
use origine_io::Loop;
use origine_io::rt::Handle;
use origine_transport::Transport;

use crate::HostState;
use crate::native;
use crate::native::{Op, ScopeKey};
use crate::net::{SEND_FLAGS, Socket, new_datagram, new_stream, sockaddr_bytes};
use crate::sockstream::SocketTransport;

/// Largest datagram answer read (EDNS is not used, so servers cut at 512 and set TC; this leaves room).
const DATAGRAM: usize = 4096;

struct NetExchange {
    key: ScopeKey,
    runtime: u32,
    lp: Rc<Loop>,
    #[cfg(feature = "tls")]
    tls: Option<origine_tls::TlsClient>,
}

fn to_io(e: NativeError) -> io::Error {
    io::Error::other(format!("{e:?}"))
}

impl NetExchange {
    async fn udp(&self, addr: SocketAddr, query: &[u8]) -> io::Result<Vec<u8>> {
        let fd = new_datagram(&addr).map_err(to_io)?;
        let raw = fd.as_raw_fd() as isize;
        self.lp.connect(raw, sockaddr_bytes(&addr)).await?;
        let (sent, _) = self.lp.send(raw, query.to_vec(), SEND_FLAGS).await;
        sent?;
        loop {
            let (read, mut buf) = self.lp.recv(raw, vec![0u8; DATAGRAM], 0).await;
            buf.truncate(read?);
            // A datagram that is not the answer to this query (another id) is somebody else's: keep waiting.
            if buf.len() >= 2 && buf[..2] == query[..2] {
                return Ok(buf);
            }
        }
    }

    async fn stream(&self, addr: SocketAddr) -> io::Result<SocketTransport> {
        let stream = new_stream(&addr).map_err(to_io)?;
        self.lp.connect(stream.as_raw_fd() as isize, sockaddr_bytes(&addr)).await?;
        let _ = stream.set_nodelay(true);
        Ok(SocketTransport { socket: Rc::new(Socket::accepted(self.key, self.runtime, stream)), lp: Rc::clone(&self.lp) })
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
        if !addr.ip().to_canonical().is_loopback() {
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
            }
        };
        match Handle::current().timeout(timeout, work).await {
            Ok(result) => result,
            Err(_) => Err(io::Error::from(io::ErrorKind::TimedOut)),
        }
    }
}

struct Entry {
    owner: ScopeKey,
    runtime: u32,
    resolver: Rc<Resolver<NetExchange>>,
}

/// The Host's resolvers. Ids are never reused while the table lives.
#[derive(Default)]
pub(crate) struct DnsState {
    next: u32,
    resolvers: BTreeMap<u32, Entry>,
}

impl DnsState {
    pub(crate) fn clear(&mut self) {
        self.resolvers.clear();
    }
}

fn dns_error(e: DnsError, name: &str) -> NativeError {
    let detailed = |code: u32, subject: String| NativeError::Errno(code).with_subject(subject);
    match e {
        DnsError::NotFound => detailed(errno::NOT_FOUND, name.to_owned()),
        DnsError::TimedOut => NativeError::Errno(errno::TIMED_OUT),
        DnsError::ServerFailure(code) => detailed(errno::SERVER_FAILURE, code),
        // A TLS failure travelled inside an `io::Error`: give it back its own meaning.
        #[cfg(feature = "tls")]
        DnsError::Io(e) if e.get_ref().is_some_and(|inner| inner.is::<origine_tls::TlsError>()) => {
            let inner = e.get_ref().and_then(|inner| inner.downcast_ref::<origine_tls::TlsError>());
            inner.map_or(NativeError::Errno(errno::UNEXPECTED), crate::tls::tls_error_of)
        }
        DnsError::Io(e) => NativeError::from(e),
        DnsError::InvalidName(n) => detailed(errno::INVALID_INPUT, n),
        DnsError::BadResponse(why) => detailed(errno::PROTOCOL_ERROR, why),
        _ => NativeError::Errno(errno::UNEXPECTED),
    }
}

fn denied(addr: &SocketAddr) -> NativeError {
    NativeError::Errno(errno::PERMISSION_DENIED).with_subject(addr.to_string())
}

fn addrs_of(list: &str) -> Result<Vec<SocketAddr>, NativeError> {
    let addrs = list
        .split(',')
        .filter(|a| !a.is_empty())
        .map(|a| a.parse::<SocketAddr>().map_err(|_| NativeError::Errno(errno::INVALID_INPUT).with_subject(a.to_owned())))
        .collect::<Result<Vec<_>, _>>()?;
    if addrs.is_empty() {
        return Err(NativeError::Errno(errno::INVALID_INPUT));
    }
    // Resolvers open sockets of their own: until there is an embedder permission for the network, loopback only.
    match addrs.iter().find(|a| !a.ip().to_canonical().is_loopback()) {
        Some(addr) => Err(denied(addr)),
        None => Ok(addrs),
    }
}

/// `native.dns.resolver(io, spec, roots, timeout, tries)`: a resolver over the servers in `spec`, one per line:
/// `udp <addrs>`, `tcp <addrs>`, `tls <name> <addrs>` (`addrs` are `ip:port`, comma-separated) or `system` (the
/// nameservers, search list and hosts file of this machine, read now). `roots` is the id of the roots TLS
/// servers are checked against (0 if there are none); `timeout` is milliseconds per attempt. Returns the id.
#[native(side_effect = "any", path = "dns.resolver", needs = "runtime")]
fn dns_resolver(
    host: &mut HostState,
    key: ScopeKey,
    io: u32,
    spec: String,
    roots: u32,
    timeout: u32,
    tries: u32,
) -> Result<u32, NativeError> {
    let lp = host.loop_of(key, io)?;
    let mut servers = Vec::new();
    let (mut search, mut ndots, mut hosts) = (Vec::new(), None, Hosts::new());
    let mut wants_tls = false;
    for line in spec.lines().filter(|l| !l.is_empty()) {
        let mut words = line.splitn(3, ' ');
        match (words.next(), words.next(), words.next()) {
            (Some("udp"), Some(addrs), None) => servers.push(Server { transport: DnsTransport::Udp, addrs: addrs_of(addrs)? }),
            (Some("tcp"), Some(addrs), None) => servers.push(Server { transport: DnsTransport::Tcp, addrs: addrs_of(addrs)? }),
            (Some("tls"), Some(name), Some(addrs)) => {
                wants_tls = true;
                servers.push(Server { transport: DnsTransport::Tls { name: name.to_owned() }, addrs: addrs_of(addrs)? });
            }
            (Some("system"), None, None) => {
                let conf = parse_resolv_conf(&std::fs::read_to_string("/etc/resolv.conf").unwrap_or_default());
                for ip in conf.nameservers {
                    servers.push(Server { transport: DnsTransport::Udp, addrs: addrs_of(&SocketAddr::new(ip, 53).to_string())? });
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
    let tls = if wants_tls {
        let roots = match roots {
            0 => return Err(NativeError::Errno(errno::INVALID_INPUT).with_subject("TLS servers need roots".to_owned())),
            id => crate::tls::roots_of(host, key, id)?,
        };
        Some(
            origine_tls::TlsClient::new(origine_tls::ClientOptions { roots, identity: None, alpn: Vec::new(), sessions: None })
                .map_err(|e| NativeError::Errno(errno::INVALID_DATA).with_subject(e.to_string()))?,
        )
    } else {
        None
    };
    #[cfg(not(feature = "tls"))]
    if wants_tls || roots != 0 {
        return Err(NativeError::Errno(errno::UNSUPPORTED));
    }
    let mut config = Config::new(servers, Duration::from_millis(u64::from(timeout.max(1))), tries.max(1));
    config.search = search;
    config.ndots = ndots.unwrap_or(1);
    config.hosts = hosts;
    let exchange = NetExchange {
        key,
        runtime: io,
        lp,
        #[cfg(feature = "tls")]
        tls,
    };
    host.dns.next = host.dns.next.checked_add(1).ok_or(NativeError::Errno(errno::PERMISSION_DENIED))?;
    let id = host.dns.next;
    host.dns.resolvers.insert(id, Entry { owner: key, runtime: io, resolver: Rc::new(Resolver::new(config, exchange)) });
    Ok(id)
}

/// `native.dns.lookup(resolver, name, family)`: Promise of the addresses, packed as `[4 | 6, octets]*`; `family` is
/// 4, 6 or 0 for both (IPv6 first). Rejects `NotFound` (`subject`: the name), `TimedOut`, `ServerFailure`, ...
#[native(side_effect = "any", path = "dns.lookup", needs = "runtime", promise)]
fn dns_lookup(
    host: &mut HostState,
    key: ScopeKey,
    id: u32,
    name: String,
    family: u32,
) -> Result<Op<'static, impl Future<Output = Result<Vec<u8>, NativeError>> + use<>>, NativeError> {
    let (resolver, runtime) = match host.dns.resolvers.get(&id) {
        Some(entry) if entry.owner == key => (Rc::clone(&entry.resolver), entry.runtime),
        _ => return Err(NativeError::Errno(errno::BAD_HANDLE)),
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

/// `native.dns.release(resolver)`: forgets a resolver; lookups in flight finish. `BadHandle` if unknown.
#[native(side_effect = "any", path = "dns.release", needs = "runtime")]
fn dns_release(host: &mut HostState, key: ScopeKey, id: u32) -> Result<(), NativeError> {
    match host.dns.resolvers.get(&id) {
        Some(entry) if entry.owner == key => {
            host.dns.resolvers.remove(&id);
            Ok(())
        }
        _ => Err(NativeError::Errno(errno::BAD_HANDLE)),
    }
}
