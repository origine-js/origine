use std::collections::HashMap;
use std::net::IpAddr;

/// The hosts file: names (lowercase) to addresses, in file order.
#[derive(Clone, Debug, Default)]
pub struct Hosts {
    names: HashMap<String, Vec<IpAddr>>,
}

impl Hosts {
    pub fn new() -> Hosts {
        Hosts::default()
    }

    /// Parses `/etc/hosts` text: `address name [alias...]` per line, `#` starts a comment, bad lines are skipped.
    pub fn parse(text: &str) -> Hosts {
        let mut hosts = Hosts::new();
        for line in text.lines() {
            let line = line.split('#').next().unwrap_or("");
            let mut words = line.split_whitespace();
            let Some(ip) = words.next().and_then(|w| w.split('%').next()).and_then(|w| w.parse::<IpAddr>().ok()) else { continue };
            for name in words {
                hosts.add(name, ip);
            }
        }
        hosts
    }

    pub fn add(&mut self, name: &str, ip: IpAddr) {
        let entry = self.names.entry(name.trim_end_matches('.').to_ascii_lowercase()).or_default();
        if !entry.contains(&ip) {
            entry.push(ip);
        }
    }

    /// The addresses of `name` (case-insensitive, a trailing dot is ignored).
    pub fn get(&self, name: &str) -> &[IpAddr] {
        self.names.get(&name.trim_end_matches('.').to_ascii_lowercase()).map_or(&[], Vec::as_slice)
    }
}
