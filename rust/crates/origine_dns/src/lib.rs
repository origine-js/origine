//! DNS lookups of addresses: a thin resolver over the hickory-proto wire codec.
//!
//! [`Resolver`] turns a name into addresses: the hosts file first, then the configured servers in order with
//! retries, trying the search domains the way `ndots` says. One query to one server is an
//! [`Exchange`], which the caller provides (UDP, TCP and TLS sockets in `origine_api`). Nothing here does
//! I/O, spawns or blocks. Not here yet: caching, DNSSEC, record types other than A and AAAA, IDNA (a name
//! must be ASCII).

mod config;
mod error;
mod hosts;
mod resolver;

pub use config::{Config, Family, Server, SystemConfig, Transport, parse_resolv_conf};
pub use error::DnsError;
pub use hosts::Hosts;
pub use resolver::{Exchange, Resolver};

#[cfg(test)]
mod tests;
