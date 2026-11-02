//! The network ceiling the embedder grants: which addresses and ports a program may connect to and listen on.
//!
//! A rule is `connect <cidr> [ports]` or `listen <cidr> [ports]`, one per line (`#` starts a comment).
//! `<cidr>` is `10.0.0.0/8`, `::1/128` or a bare address (one host); `ports` is `*` (the default), a port,
//! a range `8000-8100`, or a comma-separated list of those. **A rule is about addresses, not names**:
//! checks run on the address a program is about to use, canonicalised (`::ffff:a.b.c.d` is `a.b.c.d`), so a
//! name that resolves to a forbidden address, a redirect, or a DNS answer cannot get around them.
//! Nothing is allowed unless a rule says so.

use std::net::{IpAddr, SocketAddr};

/// What the shell and embedders get when they say nothing: loopback only, both ways.
pub const LOOPBACK: &str = "connect 127.0.0.0/8\nconnect ::1/128\nlisten 127.0.0.0/8\nlisten ::1/128\n";

#[derive(Clone, Debug, PartialEq, Eq)]
struct Rule {
    ip: IpAddr,
    prefix: u8,
    /// Inclusive ranges; never empty.
    ports: Vec<(u16, u16)>,
}

impl Rule {
    fn matches(&self, addr: &SocketAddr) -> bool {
        let ip = addr.ip().to_canonical();
        let port = addr.port();
        self.ports.iter().any(|&(lo, hi)| lo <= port && port <= hi) && in_prefix(&self.ip, &ip, self.prefix)
    }
}

/// Whether `ip` is inside `net/prefix`; different families never match.
fn in_prefix(net: &IpAddr, ip: &IpAddr, prefix: u8) -> bool {
    let (a, b): (Vec<u8>, Vec<u8>) = match (net, ip) {
        (IpAddr::V4(n), IpAddr::V4(i)) => (n.octets().to_vec(), i.octets().to_vec()),
        (IpAddr::V6(n), IpAddr::V6(i)) => (n.octets().to_vec(), i.octets().to_vec()),
        _ => return false,
    };
    let whole = usize::from(prefix / 8);
    if a[..whole] != b[..whole] {
        return false;
    }
    match prefix % 8 {
        0 => true,
        rest => {
            let mask = 0xffu8 << (8 - rest);
            a[whole] & mask == b[whole] & mask
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct NetRules {
    connect: Vec<Rule>,
    listen: Vec<Rule>,
}

impl NetRules {
    /// Allows nothing: what a host has before it is configured.
    pub fn none() -> NetRules {
        NetRules::default()
    }

    /// Parses the rule text; the error names the line.
    pub fn parse(text: &str) -> Result<NetRules, String> {
        let mut rules = NetRules::none();
        for (number, line) in text.lines().enumerate() {
            let line = line.split('#').next().unwrap_or("").trim();
            if line.is_empty() {
                continue;
            }
            let fail = |why: &str| format!("line {}: {why}: {line:?}", number + 1);
            let mut words = line.split_whitespace();
            let kind = words.next().unwrap_or("");
            let cidr = words.next().ok_or_else(|| fail("missing address"))?;
            let ports = words.next();
            if words.next().is_some() {
                return Err(fail("too many words"));
            }
            let rule = parse_rule(cidr, ports).map_err(|why| fail(&why))?;
            match kind {
                "connect" => rules.connect.push(rule),
                "listen" => rules.listen.push(rule),
                _ => return Err(fail("a rule starts with connect or listen")),
            }
        }
        Ok(rules)
    }

    /// May a program connect to `addr`?
    pub fn allows_connect(&self, addr: &SocketAddr) -> bool {
        self.connect.iter().any(|rule| rule.matches(addr))
    }

    /// May a program listen on `addr`? (Port 0 asks the system for a port: only a rule with `*` allows it.)
    pub fn allows_listen(&self, addr: &SocketAddr) -> bool {
        self.listen.iter().any(|rule| rule.matches(addr))
    }
}

fn parse_rule(cidr: &str, ports: Option<&str>) -> Result<Rule, String> {
    let (host, prefix) = match cidr.split_once('/') {
        Some((host, prefix)) => (host, Some(prefix.parse::<u8>().map_err(|_| "bad prefix length".to_owned())?)),
        None => (cidr, None),
    };
    let mut ip: IpAddr = host.parse().map_err(|_| "bad address".to_owned())?;
    let mut prefix = prefix.unwrap_or(if ip.is_ipv4() { 32 } else { 128 });
    if prefix > if ip.is_ipv4() { 32 } else { 128 } {
        return Err("prefix length too long".into());
    }
    // Addresses are matched canonicalised, so a mapped rule is the v4 rule it stands for.
    if let IpAddr::V6(v6) = ip
        && let Some(v4) = v6.to_ipv4_mapped()
    {
        if prefix < 96 {
            return Err("an IPv4-mapped rule needs a prefix of at least 96".into());
        }
        ip = IpAddr::V4(v4);
        prefix -= 96;
    }
    Ok(Rule { ip, prefix, ports: parse_ports(ports.unwrap_or("*"))? })
}

fn parse_ports(text: &str) -> Result<Vec<(u16, u16)>, String> {
    if text == "*" {
        return Ok(vec![(0, u16::MAX)]);
    }
    let port = |s: &str| s.parse::<u16>().map_err(|_| format!("bad port {s:?}"));
    text.split(',')
        .map(|part| match part.split_once('-') {
            Some((lo, hi)) => {
                let (lo, hi) = (port(lo)?, port(hi)?);
                if lo > hi { Err(format!("empty port range {part:?}")) } else { Ok((lo, hi)) }
            }
            None => port(part).map(|p| (p, p)),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sa(text: &str) -> SocketAddr {
        text.parse().unwrap()
    }

    #[test]
    fn nothing_is_allowed_by_default_and_loopback_is_what_the_text_says() {
        let none = NetRules::none();
        assert!(!none.allows_connect(&sa("127.0.0.1:80")) && !none.allows_listen(&sa("127.0.0.1:80")));
        let lo = NetRules::parse(LOOPBACK).unwrap();
        for ok in ["127.0.0.1:80", "127.255.255.254:1", "[::1]:443", "127.0.0.1:0", "[::ffff:127.0.0.1]:80"] {
            assert!(lo.allows_connect(&sa(ok)) && lo.allows_listen(&sa(ok)), "{ok}");
        }
        for no in ["128.0.0.1:80", "10.0.0.1:80", "[::2]:80", "[fe80::1]:80", "0.0.0.0:80", "[::ffff:10.0.0.1]:80"] {
            assert!(!lo.allows_connect(&sa(no)) && !lo.allows_listen(&sa(no)), "{no}");
        }
    }

    #[test]
    fn prefixes_and_ports_are_exact() {
        let rules =
            NetRules::parse("connect 10.1.2.0/23 80,443,8000-8100\nconnect 192.0.2.7\nlisten 0.0.0.0/0 9000\nconnect 2001:db8::/32 *\n")
                .unwrap();
        for ok in ["10.1.2.5:80", "10.1.3.255:443", "10.1.2.0:8050", "192.0.2.7:1", "[2001:db8:ffff::1]:5"] {
            assert!(rules.allows_connect(&sa(ok)), "{ok}");
        }
        for no in ["10.1.4.0:80", "10.1.1.255:80", "10.1.2.5:81", "10.1.2.5:8101", "192.0.2.8:1", "[2001:db9::1]:5", "[::1]:80"] {
            assert!(!rules.allows_connect(&sa(no)), "{no}");
        }
        assert!(rules.allows_listen(&sa("203.0.113.9:9000")) && !rules.allows_listen(&sa("203.0.113.9:9001")));
        assert!(!rules.allows_listen(&sa("10.1.2.5:80")), "connect rules do not listen");
        // Port 0 (any port) needs a rule that allows every port.
        assert!(!rules.allows_listen(&sa("203.0.113.9:0")));
        assert!(NetRules::parse("listen 127.0.0.1 *").unwrap().allows_listen(&sa("127.0.0.1:0")));
    }

    #[test]
    fn mapped_addresses_cannot_get_around_a_rule() {
        let rules = NetRules::parse("connect 10.0.0.0/8\n").unwrap();
        assert!(rules.allows_connect(&sa("[::ffff:10.1.1.1]:80")));
        assert!(!rules.allows_connect(&sa("[::ffff:11.1.1.1]:80")));
        // A rule written as mapped is the v4 rule.
        let mapped = NetRules::parse("connect ::ffff:192.0.2.0/120\n").unwrap();
        assert!(mapped.allows_connect(&sa("192.0.2.9:80")) && !mapped.allows_connect(&sa("192.0.3.9:80")));
        assert!(NetRules::parse("connect ::ffff:0:0/64\n").is_err());
    }

    #[test]
    fn bad_text_names_its_line() {
        for (text, needle) in [
            ("allow 1.2.3.4\n", "starts with connect or listen"),
            ("connect\n", "missing address"),
            ("connect 1.2.3.4/33\n", "too long"),
            ("connect ::1/129\n", "too long"),
            ("connect nope\n", "bad address"),
            ("connect 1.2.3.4/x\n", "bad prefix"),
            ("connect 1.2.3.4 80-70\n", "empty port range"),
            ("connect 1.2.3.4 99999\n", "bad port"),
            ("connect 1.2.3.4 80 extra\n", "too many words"),
            ("# fine\n\nconnect 1.2.3.4\nconnect bad\n", "line 4"),
        ] {
            let error = NetRules::parse(text).unwrap_err();
            assert!(error.contains(needle), "{text:?}: {error}");
        }
        assert_eq!(NetRules::parse("# nothing\n\n").unwrap(), NetRules::none());
    }
}
