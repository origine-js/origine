//! The resolver's cache: what a server answered, kept until its TTL says to forget it.
//!
//! One entry per question (a name and A or AAAA): the addresses, or the fact that there are none
//! ([`Cached::NoData`]), or that the name does not exist ([`Cached::NoName`], which holds for both types).
//! Positive entries live as long as the records' TTL, negative ones (RFC 2308) as long as the SOA of the
//! authority section says. Both are clamped by the caller's [`CacheConfig`]: nothing here has a default.
//! The clock is injected ([`Clock`]) so expiry is testable without sleeping.

use std::collections::{BTreeMap, HashMap};
use std::net::IpAddr;
use std::time::{Duration, Instant};

use hickory_proto::rr::RecordType;

/// A monotonic clock: how long since some fixed starting point. Only differences matter.
pub trait Clock {
    fn now(&self) -> Duration;
}

/// The operating system's monotonic clock, counted from when it was made.
pub struct MonotonicClock {
    start: Instant,
}

impl MonotonicClock {
    pub fn new() -> MonotonicClock {
        MonotonicClock { start: Instant::now() }
    }
}

impl Default for MonotonicClock {
    fn default() -> MonotonicClock {
        MonotonicClock::new()
    }
}

impl Clock for MonotonicClock {
    fn now(&self) -> Duration {
        self.start.elapsed()
    }
}

/// How much to keep and for how long. Every field is the caller's choice.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CacheConfig {
    /// Most entries held at once (at least 1); when full, the entry nearest to expiry makes room.
    pub entries: usize,
    /// A positive answer is kept for its TTL raised to at least `min` and cut to at most `max`.
    pub min: Duration,
    pub max: Duration,
    /// The same clamps for a negative answer (NXDOMAIN, or no records of the type). A `max` of zero
    /// turns negative caching off.
    pub negative_min: Duration,
    pub negative_max: Duration,
}

impl CacheConfig {
    /// Whether the numbers make sense: room for an entry, and no clamp with its `min` over its `max`.
    pub fn valid(&self) -> bool {
        self.entries >= 1 && self.min <= self.max && self.negative_min <= self.negative_max
    }
}

/// What the cache remembers about one question.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Cached {
    Addrs(Vec<IpAddr>),
    /// The name exists but has no record of the asked type.
    NoData,
    /// The name does not exist at all.
    NoName,
}

/// `kind` 0 is the name-wide NXDOMAIN entry.
type Key = (String, u16);

struct Entry {
    value: Cached,
    expires: Duration,
    seq: u64,
}

pub struct Cache {
    config: CacheConfig,
    clock: Box<dyn Clock>,
    entries: HashMap<Key, Entry>,
    /// Expiry order: the first one is the next to go.
    order: BTreeMap<(Duration, u64), Key>,
    seq: u64,
}

fn key(name: &str, kind: RecordType) -> Key {
    (name.to_ascii_lowercase(), kind.into())
}

impl Cache {
    pub fn new(config: CacheConfig, clock: Box<dyn Clock>) -> Cache {
        Cache { config, clock, entries: HashMap::new(), order: BTreeMap::new(), seq: 0 }
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Forgets everything.
    pub fn clear(&mut self) {
        self.entries.clear();
        self.order.clear();
    }

    /// What is known about `name` and `kind` right now; an entry past its time is dropped.
    pub fn get(&mut self, name: &str, kind: RecordType) -> Option<Cached> {
        let now = self.clock.now();
        for k in [key(name, RecordType::Unknown(0)), key(name, kind)] {
            let Some(entry) = self.entries.get(&k) else { continue };
            if entry.expires > now {
                return Some(entry.value.clone());
            }
            self.remove(&k);
        }
        None
    }

    /// Remembers an answer for `ttl` (as the server gave it) after the clamps. `NoName` holds for every type.
    pub fn put(&mut self, name: &str, kind: RecordType, value: Cached, ttl: Duration) {
        let (min, max) = match value {
            Cached::Addrs(_) => (self.config.min, self.config.max),
            Cached::NoData | Cached::NoName => (self.config.negative_min, self.config.negative_max),
        };
        let ttl = ttl.max(min).min(max);
        if ttl.is_zero() {
            return;
        }
        let k = if value == Cached::NoName { key(name, RecordType::Unknown(0)) } else { key(name, kind) };
        self.remove(&k);
        while self.entries.len() >= self.config.entries {
            let Some((_, oldest)) = self.order.pop_first() else { break };
            self.entries.remove(&oldest);
        }
        self.seq += 1;
        let expires = self.clock.now().saturating_add(ttl);
        self.order.insert((expires, self.seq), k.clone());
        self.entries.insert(k, Entry { value, expires, seq: self.seq });
    }

    fn remove(&mut self, k: &Key) {
        if let Some(entry) = self.entries.remove(k) {
            self.order.remove(&(entry.expires, entry.seq));
        }
    }
}
