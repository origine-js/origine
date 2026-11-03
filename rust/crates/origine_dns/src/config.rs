use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use crate::cache::CacheConfig;
use crate::hosts::Hosts;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Family {
    V4,
    V6,
    Any,
}

/// How a server is reached.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Transport {
    /// Datagrams; a truncated answer is retried over TCP by the `Exchange`.
    Udp,
    Tcp,
    /// DNS over TLS (RFC 7858); the name the server's certificate must be valid for.
    Tls {
        name: String,
    },
    /// DNS over HTTPS (RFC 8484): HTTP/2, a POST of the query to `path`. `name` is what the server's
    /// certificate must be valid for (the URL's host); `authority` is the `:authority` of the request
    /// (the host, and the port when it is not 443). The answer travels inside the HTTP exchange, so
    /// the query id is 0 (RFC 8484 section 4.1).
    Https {
        name: String,
        authority: String,
        path: String,
    },
}

/// One server: how to reach it and where, in the order they are tried.
#[derive(Clone, Debug)]
pub struct Server {
    pub transport: Transport,
    pub addrs: Vec<SocketAddr>,
}

#[derive(Clone, Debug)]
pub struct Config {
    pub servers: Vec<Server>,
    /// Per attempt at one address.
    pub timeout: Duration,
    /// Rounds over all servers before giving up.
    pub tries: u32,
    /// Domains appended to a name with fewer than `ndots` dots, tried in order.
    pub search: Vec<String>,
    pub ndots: usize,
    pub hosts: Hosts,
    /// What to remember between lookups; `None` asks the servers every time.
    pub cache: Option<CacheConfig>,
}

impl Config {
    pub fn new(servers: Vec<Server>, timeout: Duration, tries: u32) -> Config {
        Config { servers, timeout, tries, search: Vec::new(), ndots: 1, hosts: Hosts::new(), cache: None }
    }
}

/// What `resolv.conf` says: nameserver addresses (port 53), the search list and `ndots`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SystemConfig {
    pub nameservers: Vec<IpAddr>,
    pub search: Vec<String>,
    pub ndots: Option<usize>,
}

/// Parses `/etc/resolv.conf` text. `search` replaces `domain`, the last of either wins; options other than
/// `ndots:n` are ignored; scope ids (`fe80::1%en0`) are dropped.
pub fn parse_resolv_conf(text: &str) -> SystemConfig {
    let mut config = SystemConfig::default();
    for line in text.lines() {
        let line = line.split(['#', ';']).next().unwrap_or("");
        let mut words = line.split_whitespace();
        match words.next() {
            Some("nameserver") => {
                if let Some(ip) = words.next().and_then(|w| w.split('%').next()).and_then(|w| w.parse::<IpAddr>().ok()) {
                    config.nameservers.push(ip);
                }
            }
            Some("search") => config.search = words.map(|w| w.trim_end_matches('.').to_owned()).collect(),
            Some("domain") => config.search = words.take(1).map(|w| w.trim_end_matches('.').to_owned()).collect(),
            Some("options") => {
                for option in words {
                    if let Some(n) = option.strip_prefix("ndots:").and_then(|n| n.parse::<usize>().ok()) {
                        config.ndots = Some(n.min(15));
                    }
                }
            }
            _ => {}
        }
    }
    config
}
